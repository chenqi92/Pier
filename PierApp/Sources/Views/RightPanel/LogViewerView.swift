import SwiftUI

/// Real-time log file viewer with filtering and highlighting.
struct LogViewerView: View {
    @StateObject private var viewModel = LogViewModel()
    var serviceManager: RemoteServiceManager?

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
        .onAppear {
            if let sm = serviceManager {
                viewModel.serviceManager = sm
                if sm.isConnected {
                    viewModel.discoverRemoteLogFiles()
                }
            }
        }
        .onChange(of: serviceManager?.isConnected) { _, connected in
            if connected == true {
                viewModel.serviceManager = serviceManager
                viewModel.discoverRemoteLogFiles()
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .terminalCwdChanged)) { notification in
            guard let info = notification.object as? [String: String],
                  let path = info["path"] else { return }
            viewModel.currentRemoteCwd = path
            // Re-discover logs when terminal directory changes
            if viewModel.serviceManager?.isConnected == true {
                viewModel.discoverRemoteLogFiles(cwdPath: path)
            }
        }
    }

    // MARK: - Header

    private var logHeader: some View {
        HStack {
            Image(systemName: "doc.text.magnifyingglass")
                .foregroundColor(.green)
                .font(.caption)
            Text(LS("log.title"))
                .font(.caption)
                .fontWeight(.medium)

            if viewModel.isRemoteMode {
                Text(LS("log.remote"))
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundColor(.orange)
                    .padding(.horizontal, 4)
                    .padding(.vertical, 1)
                    .background(Color.orange.opacity(0.15))
                    .cornerRadius(3)
            }

            Spacer()

            // Remote logs dropdown
            if !viewModel.remoteLogFiles.isEmpty {
                Menu {
                    ForEach(viewModel.remoteLogFiles, id: \.self) { path in
                        Button((path as NSString).lastPathComponent) {
                            viewModel.loadRemoteFile(path)
                        }
                    }
                } label: {
                    Image(systemName: "server.rack")
                        .font(.caption)
                }
                .menuStyle(.borderlessButton)
                .frame(width: 20)
                .help(LS("log.remoteLogs"))
            }

            Button(action: { viewModel.discoverRemoteLogFiles() }) {
                Image(systemName: "magnifyingglass.circle")
                    .font(.caption)
            }
            .buttonStyle(.borderless)
            .help(LS("log.discoverFiles"))

            // JSON toggle
            Button(action: {
                viewModel.isJsonMode.toggle()
            }) {
                Image(systemName: viewModel.isJsonMode ? "curlybraces.square.fill" : "curlybraces.square")
                    .font(.caption)
                    .foregroundColor(viewModel.isJsonMode ? .blue : .secondary)
            }
            .buttonStyle(.borderless)
            .help("JSON")

            Button(action: { viewModel.openLogFile() }) {
                Image(systemName: "folder")
                    .font(.caption)
            }
            .buttonStyle(.borderless)
            .help(LS("log.openFile"))

            Button(action: { viewModel.toggleAutoScroll() }) {
                Image(systemName: viewModel.autoScroll ? "arrow.down.to.line.compact" : "arrow.down.to.line")
                    .font(.caption)
                    .foregroundColor(viewModel.autoScroll ? .green : .secondary)
            }
            .buttonStyle(.borderless)
            .help(LS("log.autoScroll"))

            Button(action: { viewModel.clearLog() }) {
                Image(systemName: "trash")
                    .font(.caption)
            }
            .buttonStyle(.borderless)
            .help(LS("log.clear"))
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

            // Regex toggle
            Button(action: {
                viewModel.isRegexFilter.toggle()
                // Re-trigger filter
                viewModel.filterText = viewModel.filterText
            }) {
                Text(".*")
                    .font(.system(size: 10, weight: .bold, design: .monospaced))
                    .foregroundColor(viewModel.isRegexFilter ? .blue : .secondary)
                    .padding(.horizontal, 4)
                    .padding(.vertical, 2)
                    .background(viewModel.isRegexFilter ? Color.blue.opacity(0.15) : Color.clear)
                    .cornerRadius(3)
            }
            .buttonStyle(.borderless)
            .help(LS("log.regexFilter"))

            if let error = viewModel.regexError {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 9))
                    .foregroundColor(.red)
                    .help(error)
            }

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

            // Export button
            Button(action: {
                if let url = viewModel.exportLog() {
                    NSWorkspace.shared.selectFile(url.path, inFileViewerRootedAtPath: "")
                }
            }) {
                Image(systemName: "square.and.arrow.up")
                    .font(.system(size: 9))
            }
            .buttonStyle(.borderless)
            .help(LS("db.export"))
            .disabled(viewModel.filteredLines.isEmpty)

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
            Text(LS("log.noFile"))
                .font(.caption)
                .foregroundColor(.secondary)
            Text(LS("log.noFileDesc"))
                .font(.system(size: 10))
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)

            HStack(spacing: 8) {
                Button(LS("log.openFileButton")) { viewModel.openLogFile() }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
