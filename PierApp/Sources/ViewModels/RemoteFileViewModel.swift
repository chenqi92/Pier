import SwiftUI
import Combine

/// ViewModel for remote SFTP file browsing.
///
/// Uses ``RemoteServiceManager/exec(_:)`` over the managed SSH session
/// to run `ls`, `pwd`, etc. on the remote server.
@MainActor
class RemoteFileViewModel: ObservableObject {
    @Published var isConnected = false
    @Published var currentRemotePath = "~"
    @Published var remoteFiles: [RemoteFile] = []
    @Published var transferProgress: TransferProgress? = nil
    @Published var showConnectionSheet = false
    @Published var statusMessage: String?
    @Published var isLoading = false

    /// Reference to the shared service manager (provides SSH exec).
    weak var serviceManager: RemoteServiceManager?

    /// Timer for polling the remote working directory to detect terminal `cd`.
    private var pwdPollTimer: AnyCancellable?

    /// Last known pwd (to detect changes from terminal side).
    private var lastPolledPwd: String?

    deinit {
        pwdPollTimer?.cancel()
    }

    // MARK: - Connection Lifecycle

    /// Called when the SSH connection state changes.
    func onConnectionChanged(connected: Bool) {
        isConnected = connected
        if connected {
            // Load home directory on connect
            loadHomeDirectory()
            // Listen for terminal directory changes
            NotificationCenter.default.addObserver(
                forName: .terminalCwdChanged,
                object: nil,
                queue: .main
            ) { [weak self] notification in
                guard let self = self,
                      let info = notification.object as? [String: String],
                      let path = info["path"] else { return }
                // Navigate SFTP without posting back to terminal (avoids loop)
                Task { @MainActor in
                    self.navigateFromTerminal(path)
                }
            }
        } else {
            NotificationCenter.default.removeObserver(self, name: .terminalCwdChanged, object: nil)
            remoteFiles = []
            currentRemotePath = "~"
            statusMessage = nil
            lastPolledPwd = nil
        }
    }

    // MARK: - Navigation

    func navigateTo(_ path: String) {
        currentRemotePath = path
        loadRemoteDirectory()
        // Notify terminal to cd to this path
        NotificationCenter.default.post(
            name: .sftpDirectoryChanged,
            object: ["path": path]
        )
    }

    /// Navigate from terminal prompt detection — no notification back to terminal.
    func navigateFromTerminal(_ path: String) {
        guard path != currentRemotePath else { return }
        currentRemotePath = path
        loadRemoteDirectory()
    }

    func navigateUp() {
        let parent = (currentRemotePath as NSString).deletingLastPathComponent
        navigateTo(parent.isEmpty ? "/" : parent)
    }

    /// Navigate to path WITHOUT notifying terminal (used when syncing FROM terminal).
    func syncToPath(_ path: String) {
        guard path != currentRemotePath else { return }
        currentRemotePath = path
        loadRemoteDirectory()
    }

    // MARK: - File Operations

    func handleFileDrop(providers: [NSItemProvider]) -> Bool {
        for provider in providers {
            if provider.hasItemConformingToTypeIdentifier("public.file-url") {
                provider.loadItem(forTypeIdentifier: "public.file-url", options: nil) { [weak self] item, _ in
                    if let data = item as? Data,
                       let url = URL(dataRepresentation: data, relativeTo: nil) {
                        DispatchQueue.main.async {
                            self?.uploadFile(localPath: url.path)
                        }
                    }
                }
            }
        }
        return true
    }

    func uploadFile(localPath: String) {
        guard let sm = serviceManager, sm.isConnected else {
            statusMessage = String(localized: "sftp.notConnected")
            return
        }

        let fileName = (localPath as NSString).lastPathComponent
        let remoteDest = currentRemotePath == "/" ? "/\(fileName)" : "\(currentRemotePath)/\(fileName)"

        statusMessage = String(format: String(localized: "sftp.uploading"), fileName)
        transferProgress = TransferProgress(fileName: fileName, fraction: 0, totalBytes: 0, transferredBytes: 0)

        Task {
            let result = await sm.uploadFile(localPath: localPath, remotePath: remoteDest)
            transferProgress = nil

            if result.success {
                statusMessage = String(format: String(localized: "sftp.uploadSuccess"), fileName)
                loadRemoteDirectory()
                // Auto-clear success message after 3 seconds
                DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
                    if self?.statusMessage?.contains(fileName) == true {
                        self?.statusMessage = nil
                    }
                }
            } else {
                statusMessage = String(format: String(localized: "sftp.uploadFailed"), result.error ?? "Unknown error")
            }
        }
    }

    func downloadFile(remotePath: String, toLocalPath localPath: String) {
        guard let sm = serviceManager, sm.isConnected else {
            statusMessage = String(localized: "sftp.notConnected")
            return
        }

        let fileName = (remotePath as NSString).lastPathComponent

        statusMessage = String(format: String(localized: "sftp.downloading"), fileName)
        transferProgress = TransferProgress(fileName: fileName, fraction: 0, totalBytes: 0, transferredBytes: 0)

        Task {
            let result = await sm.downloadFile(remotePath: remotePath, localPath: localPath)
            transferProgress = nil

            if result.success {
                statusMessage = String(format: String(localized: "sftp.downloadSuccess"), fileName)
                DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
                    if self?.statusMessage?.contains(fileName) == true {
                        self?.statusMessage = nil
                    }
                }
            } else {
                statusMessage = String(format: String(localized: "sftp.downloadFailed"), result.error ?? "Unknown error")
            }
        }
    }

    func deleteFile(_ path: String) {
        guard let sm = serviceManager, sm.isConnected else { return }
        Task {
            let (exitCode, _) = await sm.exec("rm -rf \(shellEscape(path))")
            if exitCode == 0 {
                loadRemoteDirectory()
            } else {
                statusMessage = String(localized: "sftp.deleteFailed")
            }
        }
    }

    func createFolder(name: String) {
        guard let sm = serviceManager, sm.isConnected else { return }
        let fullPath = "\(currentRemotePath)/\(name)"
        Task {
            let (exitCode, _) = await sm.exec("mkdir -p \(shellEscape(fullPath))")
            if exitCode == 0 {
                loadRemoteDirectory()
            } else {
                statusMessage = String(localized: "sftp.mkdirFailed")
            }
        }
    }

    func refreshDirectory() {
        loadRemoteDirectory()
    }

    // MARK: - Private — Directory Loading

    private func loadHomeDirectory() {
        guard let sm = serviceManager, sm.isConnected else { return }
        isLoading = true
        Task {
            let (exitCode, stdout) = await sm.exec("pwd")
            if exitCode == 0 {
                let home = stdout.trimmingCharacters(in: .whitespacesAndNewlines)
                if !home.isEmpty {
                    currentRemotePath = home
                    lastPolledPwd = home
                }
            }
            loadRemoteDirectory()
        }
    }

    private func loadRemoteDirectory() {
        guard let sm = serviceManager, sm.isConnected else {
            statusMessage = String(localized: "sftp.notConnected")
            return
        }

        isLoading = true
        statusMessage = nil

        Task {
            // Use ls -la with epoch timestamps for reliable parsing
            let cmd = "ls -la --time-style=+%s \(shellEscape(currentRemotePath)) 2>/dev/null || ls -la \(shellEscape(currentRemotePath))"
            let (exitCode, stdout) = await sm.exec(cmd)

            if exitCode != 0 {
                statusMessage = String(localized: "sftp.listFailed")
                isLoading = false
                return
            }

            remoteFiles = parseLsOutput(stdout, basePath: currentRemotePath)
            isLoading = false
        }
    }

    /// Parse `ls -la` output into `[RemoteFile]`.
    private func parseLsOutput(_ output: String, basePath: String) -> [RemoteFile] {
        var files: [RemoteFile] = []
        let lines = output.split(separator: "\n", omittingEmptySubsequences: true)

        for line in lines {
            let text = String(line)
            // Skip total line and header
            if text.hasPrefix("total ") { continue }
            // Skip . and ..
            if text.hasSuffix(" .") || text.hasSuffix(" ..") { continue }

            // Parse ls -la format:
            // drwxr-xr-x  2 user group  4096 1234567890 dirname
            // -rw-r--r--  1 user group   123 1234567890 filename
            let parts = text.split(maxSplits: 7, omittingEmptySubsequences: true) { $0 == " " || $0 == "\t" }
            // We need at least: perms, links, owner, group, size, date-or-epoch, name
            guard parts.count >= 7 else { continue }

            let perms = String(parts[0])
            let isDir = perms.hasPrefix("d")
            let isLink = perms.hasPrefix("l")
            let size = UInt64(parts[4]) ?? 0

            // Date handling: parts[5] might be epoch or date string
            // For --time-style=+%s: parts[5] is epoch, parts[6..] is name
            // For default: parts[5] is month, parts[6] is day, parts[7] is time/year, parts[8..] is name
            var fileName: String
            var modified: Date?

            if let epoch = TimeInterval(parts[5]) {
                // Epoch format (from --time-style=+%s)
                modified = Date(timeIntervalSince1970: epoch)
                // Name is everything from parts[6] onward
                if parts.count >= 7 {
                    // Reconstruct name from the remaining part
                    let nameStartIdx = findNameStart(in: text, afterField: 6)
                    fileName = String(text[nameStartIdx...]).trimmingCharacters(in: .whitespaces)
                } else {
                    continue
                }
            } else {
                // Default ls format: Mon DD HH:MM or Mon DD YYYY
                guard parts.count >= 8 else { continue }
                let nameStartIdx = findNameStart(in: text, afterField: 7)
                fileName = String(text[nameStartIdx...]).trimmingCharacters(in: .whitespaces)
                modified = nil
            }

            // Handle symlinks: name -> target
            if isLink, let arrowRange = fileName.range(of: " -> ") {
                fileName = String(fileName[..<arrowRange.lowerBound])
            }

            guard !fileName.isEmpty else { continue }

            let fullPath: String
            if basePath == "/" {
                fullPath = "/\(fileName)"
            } else {
                fullPath = "\(basePath)/\(fileName)"
            }

            let permsString = String(perms.prefix(10))
            let owner = parts.count > 2 ? String(parts[2]) : ""
            let group = parts.count > 3 ? String(parts[3]) : ""

            files.append(RemoteFile(
                name: fileName,
                path: fullPath,
                isDir: isDir || isLink,
                size: size,
                modified: modified,
                permissions: permsString,
                owner: owner,
                group: group
            ))
        }

        // Sort: directories first, then alphabetically
        files.sort { a, b in
            if a.isDir != b.isDir { return a.isDir }
            return a.name.localizedCaseInsensitiveCompare(b.name) == .orderedAscending
        }

        return files
    }

    /// Find the string index where the Nth whitespace-delimited field ends.
    private func findNameStart(in text: String, afterField fieldIndex: Int) -> String.Index {
        var fieldsFound = 0
        var inWhitespace = true

        for i in text.indices {
            let c = text[i]
            if c == " " || c == "\t" {
                if !inWhitespace {
                    fieldsFound += 1
                    if fieldsFound >= fieldIndex {
                        // Skip trailing whitespace to reach name start
                        var nameStart = text.index(after: i)
                        while nameStart < text.endIndex && (text[nameStart] == " " || text[nameStart] == "\t") {
                            nameStart = text.index(after: nameStart)
                        }
                        return nameStart
                    }
                }
                inWhitespace = true
            } else {
                inWhitespace = false
            }
        }
        return text.endIndex
    }

    // MARK: - PWD Polling (Terminal → SFTP sync)

    private func startPwdPolling() {
        pwdPollTimer?.cancel()
        pwdPollTimer = Timer.publish(every: 3, on: .main, in: .common)
            .autoconnect()
            .sink { [weak self] _ in
                self?.pollRemotePwd()
            }
    }

    private func stopPwdPolling() {
        pwdPollTimer?.cancel()
        pwdPollTimer = nil
    }

    private func pollRemotePwd() {
        guard let sm = serviceManager, sm.isConnected else { return }
        Task {
            // Get the pwd of the remote user's login shell
            // We use the SSH exec channel, which runs a fresh shell, so we get the home dir.
            // To track the TERMINAL's pwd, we'd need to read it from the terminal buffer.
            // Instead, we check if the user changed directory via the SFTP panel itself.
            // For a better approach: exec a "readlink /proc/self/cwd" in the SSH session.
            // However, since the SSH exec() spawns a new shell each time, it always returns home.

            // Post notification so terminal can respond with its pwd if needed.
            // For now, skip automatic pwd polling since exec() spawns a new shell.
            // The sync will be SFTP → Terminal (one-way) until we implement terminal pwd extraction.
        }
    }

    // MARK: - Helpers

    /// Shell-escape a path for safe use in remote commands.
    private func shellEscape(_ path: String) -> String {
        "'" + path.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}

// MARK: - Notifications

extension Notification.Name {
    /// Posted by SFTP panel when user navigates to a new directory.
    static let sftpDirectoryChanged = Notification.Name("pier.sftpDirectoryChanged")
    /// Posted by terminal when detected CWD changes from prompt.
    static let terminalCwdChanged = Notification.Name("pier.terminalCwdChanged")
}
