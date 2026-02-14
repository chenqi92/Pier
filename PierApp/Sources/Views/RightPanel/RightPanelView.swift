import SwiftUI

/// Right panel with switchable modes: Markdown preview, SFTP file browser,
/// Docker management, Git panel, MySQL client, Redis, Log viewer.
/// Remote-context tabs only appear when services are detected via SSH.
struct RightPanelView: View {
    @State private var selectedMode: RightPanelMode = .markdown
    @State private var markdownPath: String? = nil
    @StateObject private var remoteFileVM = RemoteFileViewModel()
    @EnvironmentObject var serviceManager: RemoteServiceManager

    var body: some View {
        VStack(spacing: 0) {
            // Connection status bar
            if serviceManager.isConnected || serviceManager.isConnecting {
                connectionStatusBar
                Divider()
            }

            // Mode switcher
            modeSwitcher

            Divider()

            // Service detection prompt when not connected
            if !serviceManager.isConnected && !serviceManager.isConnecting
                && selectedMode == .markdown && serviceManager.detectedServices.isEmpty {
                serviceDetectionPrompt
                Divider()
            }

            // Detected services summary (when connected)
            if serviceManager.isConnected && !serviceManager.detectedServices.isEmpty {
                detectedServicesBar
                Divider()
            }

            // Content based on selected mode
            switch selectedMode {
            case .markdown:
                MarkdownPreviewView(filePath: markdownPath)
            case .sftp:
                RemoteFileView(viewModel: remoteFileVM)
            case .docker:
                DockerManageView()
            case .git:
                GitPanelView()
            case .database:
                DatabaseClientView()
            case .redis:
                RedisClientView()
            case .logViewer:
                LogViewerView()
            }
        }
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.5))
        .onAppear {
            remoteFileVM.serviceManager = serviceManager
        }
        .onReceive(NotificationCenter.default.publisher(for: .previewMarkdown)) { notification in
            if let path = notification.object as? String {
                markdownPath = path
                selectedMode = .markdown
            }
        }
        .onChange(of: serviceManager.isConnected) { _, connected in
            if connected {
                // Auto-switch to SFTP and load remote files
                remoteFileVM.serviceManager = serviceManager
                remoteFileVM.onConnectionChanged(connected: true)
                selectedMode = .sftp
            } else {
                remoteFileVM.onConnectionChanged(connected: false)
                if selectedMode.context == .remote {
                    selectedMode = .markdown
                }
            }
        }
    }

    // MARK: - Connection Status Bar

    private var connectionStatusBar: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(serviceManager.isConnected ? Color.green : Color.orange)
                .frame(width: 6, height: 6)

            if serviceManager.isConnecting {
                ProgressView()
                    .scaleEffect(0.5)
                    .frame(width: 12, height: 12)
            }

            Text(serviceManager.connectionStatus)
                .font(.system(size: 9))
                .foregroundColor(.secondary)
                .lineLimit(1)

            Spacer()

            if serviceManager.isConnected {
                Text(serviceManager.connectedHost)
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundColor(.secondary)

                Button(action: { serviceManager.disconnect() }) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }
                .buttonStyle(.borderless)
                .help(LS("ssh.disconnect"))
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 4)
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.3))
    }

    // MARK: - Mode Switcher

    private var modeSwitcher: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 2) {
                ForEach(serviceManager.availablePanelModes, id: \.self) { mode in
                    Button(action: { selectedMode = mode }) {
                        HStack(spacing: 4) {
                            Image(systemName: mode.iconName)
                                .font(.caption2)
                            Text(mode.title)
                                .font(.caption)
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(selectedMode == mode
                            ? Color.accentColor.opacity(0.2)
                            : Color.clear)
                        .cornerRadius(4)
                    }
                    .buttonStyle(.borderless)
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
        }
    }

    // MARK: - Service Detection Prompt

    @State private var showConnectionManager = false

    private var serviceDetectionPrompt: some View {
        VStack(spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "antenna.radiowaves.left.and.right")
                    .font(.caption)
                    .foregroundColor(.orange)
                Text(LS("ssh.serviceDetectionTitle"))
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundColor(.secondary)
                Spacer()
            }
            Text(LS("ssh.serviceDetectionDesc"))
                .font(.system(size: 10))
                .foregroundColor(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Button(LS("ssh.connectNow")) {
                    NotificationCenter.default.post(name: .newSSHConnection, object: nil)
                }
                .controlSize(.small)
                .buttonStyle(.borderedProminent)

                Text("⌘⇧K")
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundColor(.secondary)
                Spacer()
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Color.orange.opacity(0.05))
    }

    // MARK: - Detected Services Bar

    private var detectedServicesBar: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 4) {
                Image(systemName: "checkmark.shield.fill")
                    .font(.caption2)
                    .foregroundColor(.green)
                Text(LS("ssh.detectedServicesTitle"))
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundColor(.secondary)
                Spacer()
                Button(action: { serviceManager.refreshServices() }) {
                    Image(systemName: "arrow.clockwise")
                        .font(.caption2)
                }
                .buttonStyle(.borderless)
                .help(LS("ssh.refreshServices"))
            }

            ForEach(serviceManager.detectedServices) { service in
                HStack(spacing: 6) {
                    Circle()
                        .fill(service.isRunning ? Color.green : Color.orange)
                        .frame(width: 6, height: 6)
                    Text(service.name)
                        .font(.system(size: 10, weight: .medium))
                    Text(service.version)
                        .font(.system(size: 9, design: .monospaced))
                        .foregroundColor(.secondary)
                    Spacer()
                    Text(service.status)
                        .font(.system(size: 9))
                        .foregroundColor(service.isRunning ? .green : .orange)

                    if let mode = service.panelMode {
                        Button(action: { selectedMode = mode }) {
                            Image(systemName: "arrow.right.circle.fill")
                                .font(.caption2)
                                .foregroundColor(.accentColor)
                        }
                        .buttonStyle(.borderless)
                        .help("Open \(service.name)")
                    }
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
    }
}

enum RightPanelMode: String, CaseIterable {
    case markdown = "Markdown"
    case sftp = "SFTP"
    case docker = "Docker"
    case git = "Git"
    case database = "MySQL"
    case redis = "Redis"
    case logViewer = "Logs"

    var title: String { rawValue }

    var iconName: String {
        switch self {
        case .markdown:  return "doc.text"
        case .sftp:      return "externaldrive.connected.to.line.below"
        case .docker:    return "shippingbox.fill"
        case .git:       return "arrow.triangle.branch"
        case .database:  return "cylinder.fill"
        case .redis:     return "server.rack"
        case .logViewer: return "doc.text.magnifyingglass"
        }
    }

    enum Context { case local, remote }

    var context: Context {
        switch self {
        case .markdown, .git: return .local
        case .sftp, .docker, .database, .redis, .logViewer: return .remote
        }
    }
}

// MARK: - Markdown Preview

struct MarkdownPreviewView: View {
    let filePath: String?
    @State private var markdownContent: String = ""

    var body: some View {
        if let path = filePath {
            ScrollView {
                // Simple markdown rendering using Text with AttributedString
                VStack(alignment: .leading, spacing: 8) {
                    if let attributed = try? AttributedString(markdown: markdownContent,
                        options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)) {
                        Text(attributed)
                            .font(.system(.body, design: .default))
                            .textSelection(.enabled)
                    } else {
                        Text(markdownContent)
                            .font(.system(.body, design: .monospaced))
                            .textSelection(.enabled)
                    }
                }
                .padding()
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .onAppear { loadMarkdown(path) }
            .onChange(of: filePath) { _, newPath in
                if let p = newPath { loadMarkdown(p) }
            }
        } else {
            VStack(spacing: 12) {
                Image(systemName: "doc.text")
                    .font(.system(size: 36))
                    .foregroundColor(.secondary)
                Text(LS("sftp.selectMarkdown"))
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func loadMarkdown(_ path: String) {
        do {
            markdownContent = try String(contentsOfFile: path, encoding: .utf8)
        } catch {
            markdownContent = "Error loading file: \(error.localizedDescription)"
        }
    }
}

// MARK: - Remote File View (SFTP)

struct RemoteFileView: View {
    @ObservedObject var viewModel: RemoteFileViewModel
    @State private var showNewFolderAlert = false
    @State private var newFolderName = ""

    private static let sizeFormatter: ByteCountFormatter = {
        let f = ByteCountFormatter()
        f.allowedUnits = [.useKB, .useMB, .useGB]
        f.countStyle = .file
        return f
    }()

    var body: some View {
        VStack(spacing: 0) {
            if viewModel.isConnected {
                // Remote path bar
                pathBar
                Divider()

                // Loading indicator
                if viewModel.isLoading {
                    ProgressView()
                        .controlSize(.small)
                        .padding(.vertical, 6)
                }

                // Status message
                if let status = viewModel.statusMessage {
                    HStack(spacing: 4) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.caption2)
                            .foregroundColor(.orange)
                        Text(status)
                            .font(.caption2)
                            .foregroundColor(.secondary)
                        Spacer()
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 4)
                }

                // Remote file list
                fileList
                    .listStyle(.plain)

                // Transfer progress
                if let progress = viewModel.transferProgress {
                    HStack {
                        ProgressView(value: progress.fraction)
                            .progressViewStyle(.linear)
                        Text(progress.description)
                            .font(.caption2)
                            .foregroundColor(.secondary)
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 4)
                }
            } else {
                // Not connected state
                VStack(spacing: 16) {
                    Image(systemName: "network.slash")
                        .font(.system(size: 36))
                        .foregroundColor(.secondary)
                    Text(LS("sftp.notConnected"))
                        .font(.caption)
                        .foregroundColor(.secondary)
                    Button(LS("sftp.connectToServer")) {
                        viewModel.showConnectionSheet = true
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .onDrop(of: [.fileURL], isTargeted: nil) { providers in
            viewModel.handleFileDrop(providers: providers)
        }
        .alert(LS("sftp.newFolder"), isPresented: $showNewFolderAlert) {
            TextField(LS("sftp.folderName"), text: $newFolderName)
            Button(LS("sftp.create")) {
                if !newFolderName.isEmpty {
                    viewModel.createFolder(name: newFolderName)
                    newFolderName = ""
                }
            }
            Button(LS("sftp.cancel"), role: .cancel) {
                newFolderName = ""
            }
        }
    }

    // MARK: - Path Bar

    private var pathBar: some View {
        HStack(spacing: 6) {
            Image(systemName: "server.rack")
                .foregroundColor(.green)
                .font(.caption)
            Text(viewModel.currentRemotePath)
                .font(.system(size: 11, design: .monospaced))
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer()
            Button(action: {
                showNewFolderAlert = true
            }) {
                Image(systemName: "folder.badge.plus")
                    .font(.caption)
            }
            .buttonStyle(.borderless)
            .help(LS("sftp.newFolder"))

            Button(action: { viewModel.refreshDirectory() }) {
                Image(systemName: "arrow.clockwise")
                    .font(.caption)
            }
            .buttonStyle(.borderless)
            .help(LS("sftp.refresh"))

            Button(action: { viewModel.navigateUp() }) {
                Image(systemName: "arrow.up")
                    .font(.caption)
            }
            .buttonStyle(.borderless)
            .help(LS("sftp.goUp"))
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
    }

    // MARK: - File List

    private var fileList: some View {
        List(viewModel.remoteFiles, id: \.path) { file in
            fileRow(file)
                .contentShape(Rectangle())
                .onTapGesture {
                    if file.isDir {
                        viewModel.navigateTo(file.path)
                    }
                }
                .contextMenu {
                    if file.isDir {
                        Button {
                            viewModel.navigateTo(file.path)
                        } label: {
                            Label(LS("sftp.open"), systemImage: "folder")
                        }
                    }
                    Divider()
                    Button(role: .destructive) {
                        viewModel.deleteFile(file.path)
                    } label: {
                        Label(LS("sftp.delete"), systemImage: "trash")
                    }
                }
        }
    }

    private func fileRow(_ file: RemoteFile) -> some View {
        HStack(spacing: 6) {
            // Icon
            Image(systemName: iconName(for: file))
                .foregroundColor(file.isDir ? .accentColor : iconColor(for: file))
                .font(.caption)
                .frame(width: 16)

            // Name
            VStack(alignment: .leading, spacing: 1) {
                Text(file.name)
                    .font(.system(size: 12))
                    .lineLimit(1)
                HStack(spacing: 6) {
                    Text(file.permissions)
                        .font(.system(size: 9, design: .monospaced))
                    if !file.owner.isEmpty {
                        Text(file.owner)
                            .font(.system(size: 9))
                    }
                }
                .foregroundColor(.secondary)
            }

            Spacer()

            // Size (files only)
            if !file.isDir {
                Text(Self.sizeFormatter.string(fromByteCount: Int64(file.size)))
                    .font(.system(size: 10))
                    .foregroundColor(.secondary)
            }
        }
        .padding(.vertical, 2)
    }

    // MARK: - Helpers

    private func iconName(for file: RemoteFile) -> String {
        if file.isDir { return "folder.fill" }
        let ext = (file.name as NSString).pathExtension.lowercased()
        switch ext {
        case "py": return "chevron.left.forwardslash.chevron.right"
        case "js", "ts", "jsx", "tsx": return "chevron.left.forwardslash.chevron.right"
        case "rs", "swift", "go", "java", "c", "cpp", "h": return "chevron.left.forwardslash.chevron.right"
        case "json", "yaml", "yml", "toml": return "curlybraces"
        case "md", "txt": return "doc.text"
        case "sh", "bash", "zsh": return "terminal"
        case "png", "jpg", "jpeg", "gif", "svg": return "photo"
        case "zip", "tar", "gz", "bz2": return "doc.zipper"
        case "log": return "text.alignleft"
        case "conf", "cfg", "ini": return "gearshape"
        default: return "doc"
        }
    }

    private func iconColor(for file: RemoteFile) -> Color {
        let ext = (file.name as NSString).pathExtension.lowercased()
        switch ext {
        case "py": return .yellow
        case "js", "ts": return .yellow
        case "rs": return .brown
        case "swift": return .orange
        case "go": return .cyan
        case "sh", "bash", "zsh": return .green
        case "json": return .green
        case "md": return .blue
        case "log": return .orange
        default: return .secondary
        }
    }
}

