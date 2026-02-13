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

    private var fileMonitor: DispatchSourceFileSystemObject?
    private var lastReadOffset: UInt64 = 0
    private var cancellables = Set<AnyCancellable>()

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
        filteredLines = allLines.filter { line in
            // Level filter
            if let level = line.level, !enabledLevels.contains(level) {
                return false
            }

            // Text filter
            if !filterText.isEmpty {
                return line.rawText.localizedCaseInsensitiveContains(filterText)
            }

            return true
        }
    }
}
