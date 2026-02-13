import SwiftUI

/// Real-time log file viewer with filtering and highlighting.
struct LogViewerView: View {
    @StateObject private var viewModel = LogViewModel()

    var body: some View {
        VStack(spacing: 0) {
            // Header
            logHeader

            Divider()

            // Filter bar
            filterBar

            Divider()

            if viewModel.logFilePath == nil {
                emptyState
            } else {
                // Log content
                logContentView

                Divider()

                // Status bar
                logStatusBar
            }
        }
    }

    // MARK: - Header

    private var logHeader: some View {
        HStack {
            Image(systemName: "doc.text.magnifyingglass")
                .foregroundColor(.green)
                .font(.caption)
            Text("log.title")
                .font(.caption)
                .fontWeight(.medium)

            Spacer()

            Button(action: { viewModel.openLogFile() }) {
                Image(systemName: "folder")
                    .font(.caption)
            }
            .buttonStyle(.borderless)
            .help(String(localized: "log.openFile"))

            Button(action: { viewModel.toggleAutoScroll() }) {
                Image(systemName: viewModel.autoScroll ? "arrow.down.to.line.compact" : "arrow.down.to.line")
                    .font(.caption)
                    .foregroundColor(viewModel.autoScroll ? .green : .secondary)
            }
            .buttonStyle(.borderless)
            .help(String(localized: "log.autoScroll"))

            Button(action: { viewModel.clearLog() }) {
                Image(systemName: "trash")
                    .font(.caption)
            }
            .buttonStyle(.borderless)
            .help(String(localized: "log.clear"))
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
    }

    // MARK: - Filter Bar

    private var filterBar: some View {
        HStack(spacing: 6) {
            Image(systemName: "line.3.horizontal.decrease.circle")
                .foregroundColor(.secondary)
                .font(.caption)

            TextField("Filter logs...", text: $viewModel.filterText)
                .textFieldStyle(.plain)
                .font(.caption)

            // Log level filters
            ForEach(LogLevel.allCases, id: \.self) { level in
                Button(action: { viewModel.toggleLevel(level) }) {
                    Text(level.badge)
                        .font(.system(size: 8, weight: .bold, design: .monospaced))
                        .padding(.horizontal, 4)
                        .padding(.vertical, 2)
                        .background(viewModel.enabledLevels.contains(level)
                            ? level.color.opacity(0.2) : Color.clear)
                        .foregroundColor(viewModel.enabledLevels.contains(level)
                            ? level.color : .secondary)
                        .cornerRadius(3)
                }
                .buttonStyle(.borderless)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 4)
    }

    // MARK: - Log Content

    private var logContentView: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(viewModel.filteredLines) { line in
                        logLineView(line)
                            .id(line.id)
                    }
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 2)
            }
            .font(.system(size: 11, design: .monospaced))
            .background(Color(red: 0.08, green: 0.08, blue: 0.1))
            .onChange(of: viewModel.filteredLines.count) { _, _ in
                if viewModel.autoScroll, let lastLine = viewModel.filteredLines.last {
                    withAnimation(.easeOut(duration: 0.1)) {
                        proxy.scrollTo(lastLine.id, anchor: .bottom)
                    }
                }
            }
        }
    }

    private func logLineView(_ line: LogLine) -> some View {
        HStack(alignment: .top, spacing: 6) {
            // Line number
            Text("\(line.lineNumber)")
                .font(.system(size: 9, design: .monospaced))
                .foregroundColor(.secondary)
                .frame(width: 30, alignment: .trailing)

            // Timestamp
            if let timestamp = line.timestamp {
                Text(timestamp)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundColor(.gray)
            }

            // Level badge
            if let level = line.level {
                Text(level.badge)
                    .font(.system(size: 9, weight: .bold, design: .monospaced))
                    .foregroundColor(level.color)
                    .frame(width: 32)
            }

            // Message
            Text(highlightedText(line.message))
                .font(.system(size: 11, design: .monospaced))
                .foregroundColor(line.level?.textColor ?? .white)
                .textSelection(.enabled)
        }
        .padding(.vertical, 1)
        .background(line.level == .error
            ? Color.red.opacity(0.05)
            : Color.clear)
    }

    private func highlightedText(_ text: String) -> AttributedString {
        var attributed = AttributedString(text)
        if !viewModel.filterText.isEmpty,
           let range = attributed.range(of: viewModel.filterText, options: .caseInsensitive) {
            attributed[range].backgroundColor = .yellow.opacity(0.3)
            attributed[range].foregroundColor = .yellow
        }
        return attributed
    }

    // MARK: - Status Bar

    private var logStatusBar: some View {
        HStack {
            if let path = viewModel.logFilePath {
                Image(systemName: "doc.text")
                    .font(.system(size: 9))
                    .foregroundColor(.secondary)
                Text((path as NSString).lastPathComponent)
                    .font(.system(size: 9))
                    .foregroundColor(.secondary)
                    .lineLimit(1)
            }
            Spacer()
            Text("\(viewModel.filteredLines.count)/\(viewModel.allLines.count) lines")
                .font(.system(size: 9))
                .foregroundColor(.secondary)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 4)
        .background(Color(nsColor: .controlBackgroundColor))
    }

    // MARK: - Empty State

    private var emptyState: some View {
        VStack(spacing: 16) {
            Image(systemName: "doc.text.magnifyingglass")
                .font(.system(size: 36))
                .foregroundColor(.secondary)
            Text("log.noFile")
                .font(.caption)
                .foregroundColor(.secondary)
            Text("log.noFileDesc")
                .font(.system(size: 10))
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)

            HStack(spacing: 8) {
                Button("log.openFileButton") { viewModel.openLogFile() }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
