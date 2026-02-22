import SwiftUI
import Combine

// MARK: - Data Models

enum LogLevel: String, CaseIterable {
    case debug = "DEBUG"
    case info = "INFO"
    case warn = "WARN"
    case error = "ERROR"
    case fatal = "FATAL"

    var badge: String {
        switch self {
        case .debug: return "DBG"
        case .info:  return "INF"
        case .warn:  return "WRN"
        case .error: return "ERR"
        case .fatal: return "FTL"
        }
    }

    var color: Color {
        switch self {
        case .debug: return .gray
        case .info:  return .blue
        case .warn:  return .orange
        case .error: return .red
        case .fatal: return .purple
        }
    }

    var textColor: Color {
        switch self {
        case .debug: return .gray
        case .info:  return .white
        case .warn:  return .orange
        case .error: return .red
        case .fatal: return .red
        }
    }
}

struct LogLine: Identifiable {
    let id: Int
    let lineNumber: Int
    let rawText: String
    let timestamp: String?
    let level: LogLevel?
    let message: String
}

/// Represents a running process detected on the remote server.
struct RunningProcess: Identifiable, Hashable {
    let id: String  // PID or container ID
    let pid: String
    let command: String
    let type: ProcessType
    let displayName: String

    enum ProcessType: String {
        case java = "java"
        case python = "python"
        case node = "node"
        case docker = "docker"
        case other = "other"

        var icon: String {
            switch self {
            case .java:   return "cup.and.saucer.fill"
            case .python: return "chevron.left.forwardslash.chevron.right"
            case .node:   return "diamond.fill"
            case .docker: return "shippingbox.fill"
            case .other:  return "gearshape.fill"
            }
        }

        var color: Color {
            switch self {
            case .java:   return .orange
            case .python: return .yellow
            case .node:   return .green
            case .docker: return .blue
            case .other:  return .secondary
            }
        }
    }
}

/// View mode for the file/log viewer.
enum FileViewMode {
    case empty       // No file open
    case logFile     // Log file with parsing, level filter, auto-scroll
    case textFile    // Regular file with syntax display and editing
    case processLog  // Running process stdout
}

// MARK: - ViewModel

@MainActor
class LogViewModel: ObservableObject {
    @Published var logFilePath: String? = nil
    @Published var filterText = ""
    @Published var autoScroll = true
    @Published var enabledLevels: Set<LogLevel> = Set(LogLevel.allCases)
    @Published var allLines: [LogLine] = []
    @Published var filteredLines: [LogLine] = []
    @Published var isRemoteMode = false
    @Published var cwdLogFiles: [String] = []          // Full paths
    @Published var cwdLogDisplayNames: [String] = []   // Relative/short names for UI
    @Published var runningProcesses: [RunningProcess] = []
    @Published var activeProcess: RunningProcess? = nil
    @Published var isRegexFilter = false
    @Published var regexError: String? = nil

    // File/Log mode
    @Published var viewMode: FileViewMode = .empty
    @Published var fileContent: String = ""       // Raw file content for text mode
    @Published var isEditing: Bool = false         // Edit mode active
    @Published var isSaving: Bool = false
    @Published var saveMessage: String? = nil      // "Saved" / error message

    private var fileMonitor: DispatchSourceFileSystemObject?
    private var lastReadOffset: UInt64 = 0
    private var remoteLineCount: Int = 0
    private var remotePollingTimer: Timer?
    private var cancellables = Set<AnyCancellable>()

    /// Optional reference to RemoteServiceManager for SSH.
    weak var serviceManager: RemoteServiceManager?

    init() {
        // Re-filter when filter text or level toggles change
        Publishers.CombineLatest($filterText, $enabledLevels)
            .debounce(for: .milliseconds(200), scheduler: RunLoop.main)
            .sink { [weak self] _, _ in
                self?.applyFilter()
            }
            .store(in: &cancellables)
    }

    deinit {
        fileMonitor?.cancel()
        remotePollingTimer?.invalidate()
    }

    // MARK: - File Extension Helpers

    /// File extension of the currently open file.
    var fileExtension: String {
        guard let path = logFilePath else { return "" }
        return (path as NSString).pathExtension.lowercased()
    }

    /// Whether the current file should be treated as a log file.
    static let logExtensions: Set<String> = ["log"]

    /// Whether a file path should be opened in log mode.
    static func isLogFile(_ path: String) -> Bool {
        let ext = (path as NSString).pathExtension.lowercased()
        return logExtensions.contains(ext) || path.contains(".log.")
    }

    // MARK: - Actions

    func openLogFile() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.plainText, .log]
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.message = "Select a file to view"

        if panel.runModal() == .OK, let url = panel.url {
            loadFile(url.path)
        }
    }

    func loadFile(_ path: String) {
        // Stop any existing monitor
        fileMonitor?.cancel()
        remotePollingTimer?.invalidate()
        activeProcess = nil
        isEditing = false
        saveMessage = nil

        logFilePath = path
        allLines = []
        lastReadOffset = 0

        if Self.isLogFile(path) {
            viewMode = .logFile
            readFileContent()
            startFileMonitor(path)
        } else {
            viewMode = .textFile
            readFileContent()
        }
    }

    func clearLog() {
        allLines = []
        filteredLines = []
        fileContent = ""
        lastReadOffset = 0
    }

    func toggleAutoScroll() {
        autoScroll.toggle()
    }

    func toggleLevel(_ level: LogLevel) {
        if enabledLevels.contains(level) {
            enabledLevels.remove(level)
        } else {
            enabledLevels.insert(level)
        }
    }

    /// Append raw text (e.g. from terminal piping)
    func appendText(_ text: String) {
        let newLines = text.split(separator: "\n", omittingEmptySubsequences: false)
        let startNum = allLines.count + 1

        for (i, line) in newLines.enumerated() {
            let parsed = parseLine(String(line), lineNumber: startNum + i)
            allLines.append(parsed)
        }

        applyFilter()
    }

    // MARK: - File Reading

    private func readFileContent() {
        guard let path = logFilePath else { return }
        guard let handle = FileHandle(forReadingAtPath: path) else { return }
        defer { try? handle.close() }

        handle.seek(toFileOffset: lastReadOffset)
        let data = handle.readDataToEndOfFile()
        lastReadOffset = handle.offsetInFile

        guard let text = String(data: data, encoding: .utf8), !text.isEmpty else { return }

        if viewMode == .textFile {
            // Text mode: store raw content
            fileContent += text
        }
        // Always parse into lines for display
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        let startNum = allLines.count + 1

        for (i, line) in lines.enumerated() {
            if line.isEmpty && i == lines.count - 1 { continue }
            let parsed = parseLine(String(line), lineNumber: startNum + i)
            allLines.append(parsed)
        }

        applyFilter()
    }

    private func startFileMonitor(_ path: String) {
        fileMonitor?.cancel()
        fileMonitor = nil

        let fd = open(path, O_RDONLY)
        guard fd >= 0 else { return }

        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd,
            eventMask: [.write, .extend],
            queue: .global()
        )

        source.setEventHandler { [weak self] in
            DispatchQueue.main.async {
                self?.readFileContent()
            }
        }

        source.setCancelHandler {
            close(fd)
        }

        source.resume()
        fileMonitor = source
    }

    // MARK: - Parsing

    private func parseLine(_ text: String, lineNumber: Int) -> LogLine {
        // For text files, skip log-specific parsing
        if viewMode == .textFile {
            return LogLine(id: lineNumber, lineNumber: lineNumber, rawText: text,
                           timestamp: nil, level: nil, message: text)
        }

        var timestamp: String? = nil
        var level: LogLevel? = nil
        var message = text

        let patterns: [(String, Int)] = [
            (#"\d{4}-\d{2}-\d{2}[T ]\d{2}:\d{2}:\d{2}[\.\d]*"#, 0),
            (#"\d{2}:\d{2}:\d{2}[\.\d]*"#, 0),
        ]

        for (pattern, _) in patterns {
            if let range = text.range(of: pattern, options: .regularExpression) {
                timestamp = String(text[range])
                message = String(text[range.upperBound...]).trimmingCharacters(in: .whitespaces)
                break
            }
        }

        let levelPatterns = [
            ("DEBUG", LogLevel.debug), ("DBG", .debug),
            ("INFO", .info), ("INF", .info),
            ("WARN", .warn), ("WARNING", .warn), ("WRN", .warn),
            ("ERROR", .error), ("ERR", .error),
            ("FATAL", .fatal), ("FTL", .fatal), ("PANIC", .fatal),
        ]

        let upperMessage = message.uppercased()
        for (pat, lv) in levelPatterns {
            if upperMessage.contains("[\(pat)]") || upperMessage.hasPrefix("\(pat) ") || upperMessage.hasPrefix("\(pat):") {
                level = lv
                break
            }
        }

        return LogLine(
            id: lineNumber,
            lineNumber: lineNumber,
            rawText: text,
            timestamp: timestamp,
            level: level,
            message: message
        )
    }

    // MARK: - Filtering

    private func applyFilter() {
        var regex: NSRegularExpression?
        if isRegexFilter && !filterText.isEmpty {
            do {
                regex = try NSRegularExpression(pattern: filterText, options: .caseInsensitive)
                regexError = nil
            } catch {
                regexError = error.localizedDescription
                regex = nil
            }
        } else {
            regexError = nil
        }

        filteredLines = allLines.filter { line in
            if viewMode == .logFile {
                if let level = line.level, !enabledLevels.contains(level) {
                    return false
                }
            }

            if !filterText.isEmpty {
                if isRegexFilter, let regex = regex {
                    let range = NSRange(line.rawText.startIndex..., in: line.rawText)
                    return regex.firstMatch(in: line.rawText, range: range) != nil
                } else {
                    return line.rawText.localizedCaseInsensitiveContains(filterText)
                }
            }

            return true
        }
    }

    // MARK: - Remote Log / File Support

    /// Load a remote file via SSH. Auto-detects log vs text mode.
    func loadRemoteFile(_ path: String) {
        guard let sm = serviceManager, sm.isConnected else { return }

        // Stop any existing monitor
        fileMonitor?.cancel()
        remotePollingTimer?.invalidate()
        activeProcess = nil
        isEditing = false
        saveMessage = nil

        isRemoteMode = true
        logFilePath = path
        allLines = []
        fileContent = ""
        remoteLineCount = 0

        let isLog = Self.isLogFile(path)
        viewMode = isLog ? .logFile : .textFile

        Task {
            let command: String
            if isLog {
                // For log files, tail last 500 lines
                command = "tail -n 500 \(shellEscape(path))"
            } else {
                // For text files, cat the entire file
                command = "cat \(shellEscape(path))"
            }

            let (exitCode, stdout) = await sm.exec(command, timeout: 60)
            if exitCode == 0 || !stdout.isEmpty {
                if viewMode == .textFile {
                    fileContent = stdout
                }
                appendText(stdout)
                remoteLineCount = allLines.count
                if isLog {
                    startRemotePolling(path: path)
                }
            }
        }
    }

    /// Save the current file content to remote.
    func saveRemoteFile() {
        guard let sm = serviceManager, sm.isConnected,
              let path = logFilePath, viewMode == .textFile else { return }

        isSaving = true
        saveMessage = nil

        Task {
            let command = "cat > \(shellEscape(path)) << 'PIER_EOF'\n\(fileContent)\nPIER_EOF"
            let (exitCode, _) = await sm.exec(command, timeout: 30)

            isSaving = false
            if exitCode == 0 {
                saveMessage = LS("log.saved")
                isEditing = false
                // Clear message after 2 seconds
                Task {
                    try? await Task.sleep(nanoseconds: 2_000_000_000)
                    if saveMessage == LS("log.saved") {
                        saveMessage = nil
                    }
                }
            } else {
                saveMessage = LS("log.saveFailed")
            }
        }
    }

    /// Periodically poll remote file for new lines (every 3 seconds).
    private func startRemotePolling(path: String) {
        remotePollingTimer?.invalidate()
        remotePollingTimer = Timer.scheduledTimer(withTimeInterval: 3.0, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, let sm = self.serviceManager, sm.isConnected else { return }
                let skipLines = self.remoteLineCount
                let (exitCode, stdout) = await sm.exec("tail -n +\(skipLines + 1) \(self.shellEscape(path)) 2>/dev/null", timeout: 15)
                if exitCode == 0 && !stdout.isEmpty {
                    self.appendText(stdout)
                    self.remoteLineCount = self.allLines.count
                }
            }
        }
    }

    /// Discover log files in the current terminal CWD only.
    func discoverRemoteLogFiles(cwdPath: String? = nil) {
        guard let sm = serviceManager, sm.isConnected else { return }

        Task {
            var paths: [String] = []

            let searchDir = cwdPath ?? currentRemoteCwd
            if let cwd = searchDir, !cwd.isEmpty {
                let (ec1, stdout1) = await sm.exec(
                    "find \(shellEscape(cwd)) -maxdepth 3 \\( -name '*.log' -o -name '*.log.*' \\) -type f 2>/dev/null | head -50",
                    timeout: 15
                )
                if ec1 == 0 {
                    let found = stdout1.split(separator: "\n").map(String.init).filter { !$0.isEmpty }
                    paths.append(contentsOf: found)
                }
                let (ec2, stdout2) = await sm.exec(
                    "ls -1p \(shellEscape(cwd)) 2>/dev/null | grep -v '/'",
                    timeout: 10
                )
                if ec2 == 0 {
                    let directFiles = stdout2.split(separator: "\n").map(String.init).filter { !$0.isEmpty }
                    let existing = Set(paths.map { ($0 as NSString).lastPathComponent })
                    for file in directFiles {
                        if !existing.contains(file) {
                            let fullPath = (cwd as NSString).appendingPathComponent(file)
                            paths.append(fullPath)
                        }
                    }
                }
            }

            cwdLogFiles = paths
            let cwd = searchDir ?? currentRemoteCwd ?? ""
            cwdLogDisplayNames = paths.map { path in
                if !cwd.isEmpty && path.hasPrefix(cwd + "/") {
                    return String(path.dropFirst(cwd.count + 1))
                }
                return (path as NSString).lastPathComponent
            }

            discoverRunningProcesses(cwdPath: cwdPath)
        }
    }

    // MARK: - Running Process Discovery

    func discoverRunningProcesses(cwdPath: String? = nil) {
        guard let sm = serviceManager, sm.isConnected else { return }

        Task {
            var processes: [RunningProcess] = []
            let cwd = cwdPath ?? currentRemoteCwd ?? ""

            if !cwd.isEmpty {
                let (ec, stdout) = await sm.exec(
                    "ps aux 2>/dev/null | grep -E '(java|python|node|ruby|go run)' | grep -v grep | grep \(shellEscape(cwd))",
                    timeout: 15
                )
                if ec == 0 && !stdout.isEmpty {
                    let lines = stdout.split(separator: "\n").map(String.init)
                    for line in lines {
                        let parts = line.split(separator: " ", maxSplits: 10, omittingEmptySubsequences: true)
                        guard parts.count >= 11 else { continue }
                        let pid = String(parts[1])
                        let cmd = parts[10...].joined(separator: " ")
                        let type = detectProcessType(cmd)
                        let name = abbreviateCommand(cmd, cwd: cwd)
                        processes.append(RunningProcess(
                            id: pid, pid: pid, command: cmd,
                            type: type, displayName: name
                        ))
                    }
                }
            }

            if processes.isEmpty && !cwd.isEmpty {
                let (ec2, stdout2) = await sm.exec(
                    "ls -l /proc/*/cwd 2>/dev/null | grep \(shellEscape(cwd)) | awk -F'/' '{print $3}'",
                    timeout: 15
                )
                if ec2 == 0 && !stdout2.isEmpty {
                    let pids = stdout2.split(separator: "\n").map(String.init).filter { !$0.isEmpty }
                    for pid in pids.prefix(10) {
                        let (ec3, cmdline) = await sm.exec("cat /proc/\(pid)/cmdline 2>/dev/null | tr '\\0' ' '", timeout: 10)
                        if ec3 == 0 && !cmdline.isEmpty {
                            let cmd = cmdline.trimmingCharacters(in: .whitespacesAndNewlines)
                            let type = detectProcessType(cmd)
                            if type == .other && !cmd.contains("python") && !cmd.contains("node") { continue }
                            let name = abbreviateCommand(cmd, cwd: cwd)
                            if !processes.contains(where: { $0.pid == pid }) {
                                processes.append(RunningProcess(
                                    id: pid, pid: pid, command: cmd,
                                    type: type, displayName: name
                                ))
                            }
                        }
                    }
                }
            }

            let (ecDocker, dockerOut) = await sm.exec(
                "docker ps --format '{{.ID}}\\t{{.Names}}\\t{{.Image}}\\t{{.Status}}' 2>/dev/null",
                timeout: 15
            )
            if ecDocker == 0 && !dockerOut.isEmpty {
                let lines = dockerOut.split(separator: "\n").map(String.init)
                for line in lines {
                    let parts = line.split(separator: "\t", maxSplits: 3).map(String.init)
                    guard parts.count >= 3 else { continue }
                    let containerId = parts[0]
                    let name = parts[1]
                    let image = parts[2]
                    processes.append(RunningProcess(
                        id: "docker-\(containerId)", pid: containerId,
                        command: "docker: \(image)", type: .docker,
                        displayName: name
                    ))
                }
            }

            runningProcesses = processes
        }
    }

    private func detectProcessType(_ cmd: String) -> RunningProcess.ProcessType {
        let lower = cmd.lowercased()
        if lower.contains("java") || lower.contains(".jar") { return .java }
        if lower.contains("python") { return .python }
        if lower.contains("node") { return .node }
        if lower.contains("docker") { return .docker }
        return .other
    }

    private func abbreviateCommand(_ cmd: String, cwd: String) -> String {
        var display = cmd
        if !cwd.isEmpty {
            display = display.replacingOccurrences(of: cwd + "/", with: "")
            display = display.replacingOccurrences(of: cwd, with: ".")
        }
        if display.count > 60 {
            display = String(display.prefix(57)) + "..."
        }
        return display
    }

    /// Tail process stdout in real time.
    func tailProcessLog(_ process: RunningProcess) {
        guard let sm = serviceManager, sm.isConnected else { return }

        fileMonitor?.cancel()
        remotePollingTimer?.invalidate()

        isRemoteMode = true
        activeProcess = process
        viewMode = .processLog
        isEditing = false
        allLines = []
        remoteLineCount = 0

        let tailCommand: String
        if process.type == .docker {
            tailCommand = "docker logs --tail 500 \(process.pid) 2>&1"
            logFilePath = "docker://\(process.displayName)"
        } else {
            tailCommand = "tail -n 500 /proc/\(process.pid)/fd/1 2>/dev/null || " +
                          "strace -p \(process.pid) -e trace=write -s 1024 2>&1 | head -500"
            logFilePath = "process://\(process.pid)"
        }

        Task {
            let (exitCode, stdout) = await sm.exec(tailCommand, timeout: 60)
            if exitCode == 0 || !stdout.isEmpty {
                appendText(stdout)
                remoteLineCount = allLines.count
                startProcessPolling(process)
            }
        }
    }

    private func startProcessPolling(_ process: RunningProcess) {
        remotePollingTimer?.invalidate()
        remotePollingTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, let sm = self.serviceManager, sm.isConnected else { return }
                guard self.activeProcess?.id == process.id else { return }

                let skipLines = self.remoteLineCount
                let pollCommand: String
                if process.type == .docker {
                    pollCommand = "docker logs --tail 100 \(process.pid) 2>&1 | tail -n +\(skipLines + 1)"
                } else {
                    pollCommand = "tail -n +\(skipLines + 1) /proc/\(process.pid)/fd/1 2>/dev/null"
                }

                let (exitCode, stdout) = await sm.exec(pollCommand, timeout: 15)
                if exitCode == 0 && !stdout.isEmpty {
                    self.appendText(stdout)
                    self.remoteLineCount = self.allLines.count
                }
            }
        }
    }

    var currentRemoteCwd: String?

    private func shellEscape(_ path: String) -> String {
        "'" + path.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    func stopRemotePolling() {
        remotePollingTimer?.invalidate()
        remotePollingTimer = nil
    }

    // MARK: - JSON Log Support

    @Published var isJsonMode = false

    func detectJsonLog() {
        let sample = allLines.prefix(10)
        let jsonCount = sample.filter { $0.rawText.trimmingCharacters(in: .whitespaces).hasPrefix("{") }.count
        isJsonMode = jsonCount > sample.count / 2
    }

    func formatJsonLine(_ text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        guard trimmed.hasPrefix("{"),
              let data = trimmed.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data),
              let pretty = try? JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted, .sortedKeys]),
              let output = String(data: pretty, encoding: .utf8) else {
            return text
        }
        return output
    }

    // MARK: - Log Export

    func exportLog() -> URL? {
        guard !filteredLines.isEmpty else { return nil }

        let timestamp = ISO8601DateFormatter().string(from: Date())
            .replacingOccurrences(of: ":", with: "-")
        let filename = "pier_log_\(timestamp).log"
        let url = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first!
            .appendingPathComponent(filename)

        let content = filteredLines.map(\.rawText).joined(separator: "\n")
        guard let data = content.data(using: .utf8) else { return nil }
        try? data.write(to: url, options: .atomic)
        return url
    }

    /// Backward compat
    var remoteLogFiles: [String] { cwdLogFiles }
}
