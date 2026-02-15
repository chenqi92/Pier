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
    @Published var remoteLogFiles: [String] = []
    @Published var isRegexFilter = false
    @Published var regexError: String? = nil

    private var fileMonitor: DispatchSourceFileSystemObject?
    private var lastReadOffset: UInt64 = 0
    private var remoteLineCount: Int = 0
    private var remotePollingTimer: Timer?
    private var cancellables = Set<AnyCancellable>()

    /// Optional reference to RemoteServiceManager for SSH log tailing.
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

    // MARK: - Actions

    func openLogFile() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.plainText, .log]
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.message = "Select a log file to view"

        if panel.runModal() == .OK, let url = panel.url {
            loadFile(url.path)
        }
    }

    func loadFile(_ path: String) {
        // Stop any existing monitor
        fileMonitor?.cancel()

        logFilePath = path
        allLines = []
        lastReadOffset = 0

        // Read initial content
        readFileContent()

        // Set up file monitoring for tail -f behavior
        startFileMonitor(path)
    }

    func clearLog() {
        allLines = []
        filteredLines = []
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

        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        let startNum = allLines.count + 1

        for (i, line) in lines.enumerated() {
            if line.isEmpty && i == lines.count - 1 { continue } // skip trailing newline
            let parsed = parseLine(String(line), lineNumber: startNum + i)
            allLines.append(parsed)
        }

        applyFilter()
    }

    private func startFileMonitor(_ path: String) {
        // Cancel any existing monitor first to avoid fd leaks (M3 fix)
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
        var timestamp: String? = nil
        var level: LogLevel? = nil
        var message = text

        // Try to extract timestamp (common formats)
        // ISO 8601: 2024-01-15T12:34:56
        // Common: 2024-01-15 12:34:56
        // Short: 12:34:56
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

        // Try to extract log level
        let levelPatterns = [
            ("DEBUG", LogLevel.debug), ("DBG", .debug),
            ("INFO", .info), ("INF", .info),
            ("WARN", .warn), ("WARNING", .warn), ("WRN", .warn),
            ("ERROR", .error), ("ERR", .error),
            ("FATAL", .fatal), ("FTL", .fatal), ("PANIC", .fatal),
        ]

        let upperMessage = message.uppercased()
        for (pat, lv) in levelPatterns {
            // Check for [LEVEL] or LEVEL: or just LEVEL with word boundary
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
        // Compile regex if needed
        var regex: NSRegularExpression?
        if isRegexFilter && !filterText.isEmpty {
            do {
                regex = try NSRegularExpression(pattern: filterText, options: .caseInsensitive)
                regexError = nil
            } catch {
                regexError = error.localizedDescription
                // Fall back to plain text search on invalid regex
                regex = nil
            }
        } else {
            regexError = nil
        }

        filteredLines = allLines.filter { line in
            // Level filter
            if let level = line.level, !enabledLevels.contains(level) {
                return false
            }

            // Text / Regex filter
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

    // MARK: - Remote Log Support

    /// Load a remote log file via SSH exec (tail -n 500).
    func loadRemoteFile(_ path: String) {
        guard let sm = serviceManager, sm.isConnected else { return }

        // Stop local monitoring
        fileMonitor?.cancel()
        remotePollingTimer?.invalidate()

        isRemoteMode = true
        logFilePath = path
        allLines = []
        remoteLineCount = 0

        Task {
            let (exitCode, stdout) = await sm.exec("tail -n 500 '\(path)'")
            if exitCode == 0 {
                appendText(stdout)
                remoteLineCount = allLines.count
                startRemotePolling(path: path)
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
                let (exitCode, stdout) = await sm.exec("tail -n +\(skipLines + 1) '\(path)' 2>/dev/null")
                if exitCode == 0 && !stdout.isEmpty {
                    self.appendText(stdout)
                    self.remoteLineCount = self.allLines.count
                }
            }
        }
    }

    /// Discover log files on the remote server.
    /// Searches the current terminal CWD first, then /var/log and /opt.
    func discoverRemoteLogFiles(cwdPath: String? = nil) {
        guard let sm = serviceManager, sm.isConnected else { return }

        Task {
            var allPaths: [String] = []

            // 1. Search the current terminal working directory first
            let searchDir = cwdPath ?? currentRemoteCwd
            if let cwd = searchDir, !cwd.isEmpty {
                let (ec1, stdout1) = await sm.exec(
                    "find \(shellEscape(cwd)) -maxdepth 3 -name '*.log' -type f 2>/dev/null | head -20"
                )
                if ec1 == 0 {
                    let cwdLogs = stdout1.split(separator: "\n").map(String.init).filter { !$0.isEmpty }
                    allPaths.append(contentsOf: cwdLogs)
                }
            }

            // 2. Then search standard log directories
            let (ec2, stdout2) = await sm.exec(
                "find /var/log -name '*.log' -type f 2>/dev/null | head -30; " +
                "find /opt -name '*.log' -type f -maxdepth 4 2>/dev/null | head -20"
            )
            if ec2 == 0 {
                let stdLogs = stdout2.split(separator: "\n").map(String.init).filter { !$0.isEmpty }
                // Add only those not already discovered from CWD
                let existing = Set(allPaths)
                allPaths.append(contentsOf: stdLogs.filter { !existing.contains($0) })
            }

            remoteLogFiles = allPaths
        }
    }

    /// Current terminal working directory (updated via notification).
    var currentRemoteCwd: String?

    /// Shell-escape a path for remote commands.
    private func shellEscape(_ path: String) -> String {
        "'" + path.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// Stop remote log polling.
    func stopRemotePolling() {
        remotePollingTimer?.invalidate()
        remotePollingTimer = nil
    }

    // MARK: - JSON Log Support

    @Published var isJsonMode = false

    /// Auto-detect if log lines appear to be JSON.
    func detectJsonLog() {
        let sample = allLines.prefix(10)
        let jsonCount = sample.filter { $0.rawText.trimmingCharacters(in: .whitespaces).hasPrefix("{") }.count
        isJsonMode = jsonCount > sample.count / 2
    }

    /// Format a JSON log line as pretty-printed string.
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

    /// Export filtered log lines to ~/Downloads. Returns file URL on success.
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
}
