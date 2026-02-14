import SwiftUI

/// Main three-panel layout view — the heart of Pier Terminal.
///
/// Layout:
/// ┌──────────┬────────────────────────┬──────────────┐
/// │  Local   │       Terminal         │  Right Panel │
/// │  Files   │    (Shell / SSH)       │  (MD/SFTP)   │
/// │          │                        │              │
/// └──────────┴────────────────────────┴──────────────┘
struct MainView: View {
    @StateObject private var fileViewModel = FileViewModel()
    @StateObject private var terminalViewModel = TerminalViewModel()
    @EnvironmentObject var serviceManager: RemoteServiceManager

    /// The service manager for the currently selected terminal tab.
    /// Falls back to the global service manager for local tabs.
    private var activeServiceManager: RemoteServiceManager {
        terminalViewModel.activeServiceManager ?? serviceManager
    }

    @State private var showLeftPanel = true
    @State private var showRightPanel = true
    @State private var leftPanelWidth: CGFloat = 250
    @State private var rightPanelWidth: CGFloat = 300
    @State private var showNewTabChooser = false
    @State private var showConnectionManager = false

    var body: some View {
        HSplitView {
            // ── Left Panel: Local File Browser ──
            if showLeftPanel {
                LocalFileView(viewModel: fileViewModel)
                    .frame(minWidth: 180, idealWidth: leftPanelWidth, maxWidth: 400)
            }

            // ── Center Panel: Terminal ──
            TerminalContainerView(viewModel: terminalViewModel)
                .frame(minWidth: 400)
                .layoutPriority(1)
                .onDrop(of: [.fileURL, .utf8PlainText], isTargeted: nil) { providers in
                    handleFileDrop(providers: providers)
                }

            // ── Right Panel: Multi-function Area ──
            if showRightPanel {
                RightPanelView(serviceManager: activeServiceManager)
                    .frame(minWidth: 200, idealWidth: rightPanelWidth, maxWidth: 500)
                    .id(terminalViewModel.selectedTabId)
            }
        }
        .toolbar {
            ToolbarItemGroup(placement: .navigation) {
                Button(action: { withAnimation { showLeftPanel.toggle() } }) {
                    Image(systemName: "sidebar.left")
                }
                .help(LS("toolbar.toggleFilesBrowser"))
            }

            ToolbarItemGroup(placement: .primaryAction) {
                Button(action: { showNewTabChooser = true }) {
                    Image(systemName: "plus")
                }
                .help(LS("toolbar.newTerminalTab"))

                Button(action: { showConnectionManager = true }) {
                    Image(systemName: "server.rack")
                }
                .help(LS("toolbar.sshConnectionManager"))

                Button(action: { withAnimation { showRightPanel.toggle() } }) {
                    Image(systemName: "sidebar.right")
                }
                .help(LS("toolbar.toggleRightPanel"))
            }
        }
        .frame(minWidth: 900, minHeight: 500)
        .sheet(isPresented: $showNewTabChooser) {
            NewTabChooserView(terminalViewModel: terminalViewModel)
                .environmentObject(serviceManager)
        }
        .sheet(isPresented: $showConnectionManager) {
            ConnectionManagerView()
                .environmentObject(serviceManager)
        }
        .onReceive(NotificationCenter.default.publisher(for: .showNewTabChooser)) { _ in
            showNewTabChooser = true
        }
    }

    /// Handle files dropped onto the terminal area.
    private func handleFileDrop(providers: [NSItemProvider]) -> Bool {
        for provider in providers {
            if provider.hasItemConformingToTypeIdentifier("public.file-url") {
                provider.loadItem(forTypeIdentifier: "public.file-url", options: nil) { item, _ in
                    if let data = item as? Data,
                       let url = URL(dataRepresentation: data, relativeTo: nil) {
                        // Insert the file path into the active terminal
                        let escapedPath = url.path.replacingOccurrences(of: " ", with: "\\ ")
                        DispatchQueue.main.async {
                            terminalViewModel.sendInput(escapedPath)
                        }
                    }
                }
            }
        }
        return true
    }
}

// MARK: - New Tab Chooser

/// Sheet shown when the user presses "+" to create a new tab.
/// Offers a quick local terminal option and a list of saved SSH profiles.
struct NewTabChooserView: View {
    @ObservedObject var terminalViewModel: TerminalViewModel
    @EnvironmentObject var serviceManager: RemoteServiceManager
    @Environment(\.dismiss) var dismiss

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Text(LS("conn.newSession"))
                    .font(.headline)
                Spacer()
                Button(action: { dismiss() }) {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundColor(.secondary)
                }
                .buttonStyle(.borderless)
            }
            .padding()

            Divider()

            // Quick actions
            VStack(spacing: 8) {
                Button(action: openLocalTerminal) {
                    HStack(spacing: 12) {
                        Image(systemName: "terminal")
                            .font(.title2)
                            .frame(width: 32)
                            .foregroundColor(.accentColor)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(LS("conn.localTerminal"))
                                .font(.body)
                                .fontWeight(.medium)
                            Text(LS("conn.localTerminalDesc"))
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                        Spacer()
                        Image(systemName: "chevron.right")
                            .foregroundColor(.secondary)
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                    .background(Color(nsColor: .controlBackgroundColor))
                    .cornerRadius(8)
                }
                .buttonStyle(.plain)
            }
            .padding()

            // Saved SSH connections
            if !serviceManager.savedProfiles.isEmpty {
                Divider()

                VStack(alignment: .leading, spacing: 4) {
                    Text(LS("conn.savedConnections"))
                        .font(.caption)
                        .fontWeight(.semibold)
                        .foregroundColor(.secondary)
                        .padding(.horizontal, 16)
                        .padding(.top, 8)

                    List {
                        ForEach(serviceManager.savedProfiles) { profile in
                            Button(action: { openSSHTab(profile) }) {
                                HStack(spacing: 10) {
                                    Image(systemName: "network")
                                        .foregroundColor(.green)
                                        .frame(width: 20)
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(profile.name.isEmpty ? profile.host : profile.name)
                                            .font(.body)
                                            .fontWeight(.medium)
                                        Text("\(profile.username)@\(profile.host):\(profile.port)")
                                            .font(.system(size: 11, design: .monospaced))
                                            .foregroundColor(.secondary)
                                    }
                                    Spacer()
                                    Image(systemName: "chevron.right")
                                        .foregroundColor(.secondary)
                                }
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .listStyle(.inset)
                }
            }

            Spacer(minLength: 0)
        }
        .frame(width: 380, height: 420)
    }

    private func openLocalTerminal() {
        terminalViewModel.addNewTab()
        dismiss()
    }

    private func openSSHTab(_ profile: ConnectionProfile) {
        // Build SSH command with correct auth parameters
        var sshCommand = "ssh \(profile.username)@\(profile.host) -p \(profile.port)"
        sshCommand += " -o StrictHostKeyChecking=no"

        if profile.authType == .keyFile, let keyPath = profile.keyFilePath {
            sshCommand += " -i \(keyPath)"
        }

        // Load password ONCE from Keychain (single access, no repeated prompts)
        let password: String? = profile.authType == .password
            ? (try? KeychainService.shared.load(key: "ssh_\(profile.id.uuidString)"))
            : nil

        let title = profile.name.isEmpty ? profile.host : profile.name
        // Creates a per-tab RemoteServiceManager and connects it with pre-loaded password
        terminalViewModel.addNewTab(title: title, shell: "/bin/zsh", isSSH: true, profile: profile, preloadedPassword: password)
        // Send the SSH command to the new terminal after a short delay
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            self.terminalViewModel.sendInput(sshCommand + "\n")
        }

        // For password auth, auto-type the stored password when the prompt appears
        if let password = password, !password.isEmpty {
            // Wait for the password prompt to appear, then type it
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
                self.terminalViewModel.sendInput(password + "\n")
            }
        }

        dismiss()
    }
}


// MARK: - Terminal Container

/// Container for terminal tabs.
struct TerminalContainerView: View {
    @ObservedObject var viewModel: TerminalViewModel

    var body: some View {
        VStack(spacing: 0) {
            // Tab bar
            TerminalTabBar(viewModel: viewModel)
                .frame(height: 36)

            Divider()

            // Terminal content
            if viewModel.tabs.isEmpty {
                emptyState
            } else {
                TerminalView(session: viewModel.currentSession)
                    .layoutPriority(1)
            }

            Divider()

            // Status bar
            StatusBarView(viewModel: viewModel)
                .frame(height: 24)
        }
    }

    private var emptyState: some View {
        VStack(spacing: 16) {
            Image(systemName: "terminal")
                .font(.system(size: 48))
                .foregroundColor(.secondary)
            Text(LS("terminal.noSessions"))
                .font(.title3)
                .foregroundColor(.secondary)
            Button(LS("terminal.newTerminal")) {
                viewModel.addNewTab()
            }
            .buttonStyle(.borderedProminent)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .textBackgroundColor))
    }
}

// MARK: - Terminal Tab Bar

struct TerminalTabBar: View {
    @ObservedObject var viewModel: TerminalViewModel

    var body: some View {
        HStack(spacing: 0) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 1) {
                    ForEach(viewModel.tabs) { tab in
                        TerminalTabItem(
                            tab: tab,
                            isSelected: viewModel.selectedTabId == tab.id,
                            onSelect: { viewModel.selectTab(tab.id) },
                            onClose: { viewModel.closeTab(tab.id) }
                        )
                    }
                }
            }

            Spacer()

            Button(action: {
                NotificationCenter.default.post(name: .showNewTabChooser, object: nil)
            }) {
                Image(systemName: "plus")
                    .font(.caption)
            }
            .buttonStyle(.borderless)
            .padding(.horizontal, 8)
        }
        .background(Color(nsColor: .controlBackgroundColor))
    }
}

struct TerminalTabItem: View {
    let tab: TerminalTab
    let isSelected: Bool
    let onSelect: () -> Void
    let onClose: () -> Void

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: tab.isSSH ? "network" : "terminal")
                .font(.caption2)
                .foregroundColor(tab.isSSH ? .green : .secondary)

            Text(tab.title)
                .font(.caption)
                .lineLimit(1)

            Button(action: onClose) {
                Image(systemName: "xmark")
                    .font(.system(size: 8))
            }
            .buttonStyle(.borderless)
            .opacity(isSelected ? 1 : 0)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(isSelected ? Color(nsColor: .selectedContentBackgroundColor) : Color.clear)
        .cornerRadius(4)
        .onTapGesture(perform: onSelect)
    }
}

// MARK: - Status Bar

struct StatusBarView: View {
    @ObservedObject var viewModel: TerminalViewModel

    var body: some View {
        HStack {
            if let session = viewModel.currentSession {
                Image(systemName: "circle.fill")
                    .font(.system(size: 6))
                    .foregroundColor(.green)
                Text(session.shellPath)
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }

            Spacer()

            Text(String(format: LS("terminal.sessionCount"), viewModel.tabs.count))
                .font(.caption2)
                .foregroundColor(.secondary)
        }
        .padding(.horizontal, 12)
        .background(Color(nsColor: .controlBackgroundColor))
    }
}
