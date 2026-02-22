import SwiftUI

/// Combined file viewer and log viewer with editing support.
struct LogViewerView: View {
    @StateObject private var viewModel = LogViewModel()
    var serviceManager: RemoteServiceManager?

    var body: some View {
        VStack(spacing: 0) {
            // Header
            viewerHeader

            Divider()

            // Filter / search bar
            filterBar

            Divider()

            if viewModel.viewMode == .empty {
                emptyState
            } else if viewModel.viewMode == .textFile && viewModel.isEditing {
                // Edit mode: TextEditor
                editorView
            } else {
                // View mode: log lines or file lines
                contentView

                Divider()

                statusBar
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
            if viewModel.serviceManager?.isConnected == true {
                viewModel.discoverRemoteLogFiles(cwdPath: path)
            }
        }
    }

    // MARK: - Header

    private var viewerHeader: some View {
        HStack(spacing: 6) {
            // Title + mode badges
            Image(systemName: viewModel.viewMode == .logFile || viewModel.viewMode == .processLog
                  ? "doc.text.magnifyingglass" : "doc.text")
                .foregroundColor(.green)
                .font(.caption)
            Text(LS("log.fileViewer"))
                .font(.caption)
                .fontWeight(.medium)

            // Mode badge
            switch viewModel.viewMode {
            case .logFile:
                modeBadge(LS("log.logMode"), color: .orange)
            case .textFile:
                modeBadge(LS("log.fileMode"), color: .blue)
            case .processLog:
                modeBadge(LS("log.processLog"), color: .purple)
            case .empty:
                EmptyView()
            }

            if viewModel.isRemoteMode {
                modeBadge(LS("log.remote"), color: .cyan)
            }

            Spacer()

            // ---- File list dropdown ----
            if !viewModel.cwdLogFiles.isEmpty {
                Menu {
                    ForEach(Array(zip(viewModel.cwdLogFiles, viewModel.cwdLogDisplayNames)), id: \.0) { path, displayName in
                        Button(action: { viewModel.loadRemoteFile(path) }) {
                            Label(displayName, systemImage: LogViewModel.isLogFile(path)
                                  ? "doc.text" : "doc")
                        }
                    }
                } label: {
                    Image(systemName: "doc.text")
                        .font(.caption)
                        .frame(width: 14, height: 14)
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .help(LS("log.cwdFiles"))
            }

            // ---- Process list dropdown ----
            if !viewModel.runningProcesses.isEmpty {
                Menu {
                    ForEach(viewModel.runningProcesses) { process in
                        Button(action: { viewModel.tailProcessLog(process) }) {
                            Label {
                                Text(process.displayName)
                            } icon: {
                                Image(systemName: process.type.icon)
                            }
                        }
                    }
                } label: {
                    Image(systemName: "play.circle")
                        .font(.caption)
                        .frame(width: 14, height: 14)
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .help(LS("log.processes"))
            }

            // ---- Refresh ----
            Button(action: { viewModel.discoverRemoteLogFiles() }) {
                Image(systemName: "arrow.clockwise")
                    .font(.caption)
            }
            .buttonStyle(.borderless)
            .help(LS("log.refresh"))

            // ---- Mode-specific buttons ----

            // Log mode: JSON toggle
            if viewModel.viewMode == .logFile || viewModel.viewMode == .processLog {
                Button(action: { viewModel.isJsonMode.toggle() }) {
                    Image(systemName: viewModel.isJsonMode ? "curlybraces.square.fill" : "curlybraces.square")
                        .font(.caption)
                        .foregroundColor(viewModel.isJsonMode ? .blue : .secondary)
                }
                .buttonStyle(.borderless)
                .help("JSON")

                // Auto-scroll
                Button(action: { viewModel.toggleAutoScroll() }) {
                    Image(systemName: viewModel.autoScroll ? "arrow.down.to.line.compact" : "arrow.down.to.line")
                        .font(.caption)
                        .foregroundColor(viewModel.autoScroll ? .green : .secondary)
                }
                .buttonStyle(.borderless)
                .help(LS("log.autoScroll"))
            }

            // Text file mode: Edit / Save
            if viewModel.viewMode == .textFile {
                if viewModel.isEditing {
                    // Save button
                    Button(action: { viewModel.saveRemoteFile() }) {
                        HStack(spacing: 2) {
                            Image(systemName: "square.and.arrow.down")
                                .font(.caption)
                            Text(LS("log.save"))
                                .font(.system(size: 9))
                        }
                        .foregroundColor(.green)
                    }
                    .buttonStyle(.borderless)
                    .disabled(viewModel.isSaving)
                    .help(LS("log.save"))

                    // Cancel edit
                    Button(action: { viewModel.isEditing = false }) {
                        Image(systemName: "xmark.circle")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    .buttonStyle(.borderless)
                    .help(LS("log.cancelEdit"))
                } else {
                    // Edit button
                    Button(action: { viewModel.isEditing = true }) {
                        Image(systemName: "pencil.circle")
                            .font(.caption)
                            .foregroundColor(.blue)
                    }
                    .buttonStyle(.borderless)
                    .help(LS("log.edit"))
                }
            }

            // ---- Open local file ----
            Button(action: { viewModel.openLogFile() }) {
                Image(systemName: "folder")
                    .font(.caption)
            }
            .buttonStyle(.borderless)
            .help(LS("log.openFile"))

            // ---- Export ----
            Button(action: {
                if let url = viewModel.exportLog() {
                    NSWorkspace.shared.selectFile(url.path, inFileViewerRootedAtPath: "")
                }
            }) {
                Image(systemName: "square.and.arrow.up")
                    .font(.caption)
            }
            .buttonStyle(.borderless)
            .disabled(viewModel.filteredLines.isEmpty)
            .help(LS("db.export"))

            // ---- Clear ----
            Button(action: { viewModel.clearLog() }) {
                Image(systemName: "trash")
                    .font(.caption)
            }
            .buttonStyle(.borderless)
            .help(LS("log.clear"))
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
    }

    private func modeBadge(_ text: String, color: Color) -> some View {
        Text(text)
            .font(.system(size: 9, weight: .semibold))
            .foregroundColor(color)
            .padding(.horizontal, 4)
            .padding(.vertical, 1)
            .background(color.opacity(0.15))
            .cornerRadius(3)
    }

    // MARK: - Filter Bar

    private var filterBar: some View {
        HStack(spacing: 6) {
            Image(systemName: "line.3.horizontal.decrease.circle")
                .foregroundColor(.secondary)
                .font(.caption)

            TextField(LS("log.filterPlaceholder"), text: $viewModel.filterText)
                .textFieldStyle(.plain)
                .font(.caption)

            // Regex toggle
            Button(action: {
                viewModel.isRegexFilter.toggle()
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

            // Log level filters (only for log/process mode)
            if viewModel.viewMode == .logFile || viewModel.viewMode == .processLog {
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
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 4)
    }

    // MARK: - Content View (Read-only)

    private var contentView: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(viewModel.filteredLines) { line in
                        lineView(line)
                            .id(line.id)
                    }
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 2)
            }
            .font(.system(size: 11, design: .monospaced))
            .background(Color(nsColor: .textBackgroundColor))
            .onChange(of: viewModel.filteredLines.count) { _, _ in
                if viewModel.autoScroll && (viewModel.viewMode == .logFile || viewModel.viewMode == .processLog),
                   let lastLine = viewModel.filteredLines.last {
                    withAnimation(.easeOut(duration: 0.1)) {
                        proxy.scrollTo(lastLine.id, anchor: .bottom)
                    }
                }
            }
        }
    }

    private func lineView(_ line: LogLine) -> some View {
        HStack(alignment: .top, spacing: 4) {
            // Line number
            Text("\(line.lineNumber)")
                .font(.system(size: 9, design: .monospaced))
                .foregroundColor(.secondary)
                .frame(width: 28, alignment: .trailing)

            if viewModel.viewMode == .logFile || viewModel.viewMode == .processLog {
                // Timestamp (time-only)
                if let timestamp = line.timestamp {
                    Text(shortenTimestamp(timestamp))
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundColor(.gray)
                        .frame(width: 65, alignment: .leading)
                }

                // Level badge
                if let level = line.level {
                    Text(level.badge)
                        .font(.system(size: 9, weight: .bold, design: .monospaced))
                        .foregroundColor(level.color)
                        .frame(width: 28)
                }

                // Message (with optional JSON formatting)
                let displayText = viewModel.isJsonMode ? viewModel.formatJsonLine(line.message) : line.message
                Text(highlightedText(displayText))
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundColor(line.level?.textColor ?? Color(nsColor: .labelColor))
                    .textSelection(.enabled)
            } else {
                // Text file: just show the line with basic coloring
                Text(highlightedText(line.message))
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundColor(textFileLineColor(line.message))
                    .textSelection(.enabled)
            }
        }
        .padding(.vertical, 1)
        .background(line.level == .error
            ? Color.red.opacity(0.05)
            : Color.clear)
    }

    /// Basic syntax coloring for text files.
    private func textFileLineColor(_ text: String) -> Color {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        // Comments
        if trimmed.hasPrefix("#") || trimmed.hasPrefix("//") || trimmed.hasPrefix("--") {
            return .gray
        }
        // YAML keys
        if viewModel.fileExtension == "yml" || viewModel.fileExtension == "yaml" {
            if trimmed.contains(":") && !trimmed.hasPrefix("-") {
                return .blue
            }
        }
        // Shell shebang
        if trimmed.hasPrefix("#!") {
            return .purple
        }
        return Color(nsColor: .labelColor)
    }

    private func shortenTimestamp(_ ts: String) -> String {
        if ts.count > 12, let spaceIdx = ts.firstIndex(where: { $0 == "T" || $0 == " " }) {
            let timeStart = ts.index(after: spaceIdx)
            if timeStart < ts.endIndex {
                return String(ts[timeStart...])
            }
        }
        return ts
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

    // MARK: - Editor View

    private var editorView: some View {
        VStack(spacing: 0) {
            TextEditor(text: $viewModel.fileContent)
                .font(.system(size: 11, design: .monospaced))
                .scrollContentBackground(.hidden)
                .background(Color(nsColor: .textBackgroundColor))

            Divider()

            // Editor status bar
            HStack {
                if let path = viewModel.logFilePath {
                    Image(systemName: "pencil.circle.fill")
                        .font(.system(size: 9))
                        .foregroundColor(.blue)
                    Text((path as NSString).lastPathComponent)
                        .font(.system(size: 9))
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                }

                if viewModel.isSaving {
                    ProgressView()
                        .controlSize(.mini)
                    Text(LS("log.saving"))
                        .font(.system(size: 9))
                        .foregroundColor(.secondary)
                }

                if let msg = viewModel.saveMessage {
                    Text(msg)
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundColor(msg == LS("log.saved") ? .green : .red)
                }

                Spacer()

                Text("\(viewModel.fileContent.components(separatedBy: "\n").count) lines")
                    .font(.system(size: 9))
                    .foregroundColor(.secondary)

                // Keyboard hint
                Text("⌘S " + LS("log.save"))
                    .font(.system(size: 9))
                    .foregroundColor(.secondary)
                    .padding(.horizontal, 4)
                    .padding(.vertical, 1)
                    .background(Color.secondary.opacity(0.1))
                    .cornerRadius(3)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 4)
            .background(Color(nsColor: .controlBackgroundColor))
        }
    }

    // MARK: - Status Bar

    private var statusBar: some View {
        HStack {
            if let process = viewModel.activeProcess {
                Image(systemName: process.type.icon)
                    .font(.system(size: 9))
                    .foregroundColor(process.type.color)
                Text(process.displayName)
                    .font(.system(size: 9))
                    .foregroundColor(.secondary)
                    .lineLimit(1)
                Text("PID: \(process.pid)")
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundColor(.secondary)
            } else if let path = viewModel.logFilePath {
                Image(systemName: viewModel.viewMode == .textFile ? "doc" : "doc.text")
                    .font(.system(size: 9))
                    .foregroundColor(.secondary)
                Text((path as NSString).lastPathComponent)
                    .font(.system(size: 9))
                    .foregroundColor(.secondary)
                    .lineLimit(1)

                if viewModel.viewMode == .textFile {
                    Text("·")
                        .foregroundColor(.secondary)
                    Text(viewModel.fileExtension.uppercased())
                        .font(.system(size: 8, weight: .bold, design: .monospaced))
                        .foregroundColor(.secondary)
                        .padding(.horizontal, 3)
                        .padding(.vertical, 1)
                        .background(Color.secondary.opacity(0.1))
                        .cornerRadius(2)
                }
            }

            Spacer()

            Text(String(format: LS("log.lineCount"), viewModel.filteredLines.count, viewModel.allLines.count))
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
