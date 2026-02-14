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
    /// Each tab has its own manager; falls back to an empty one (never the global shared one).
    private var activeServiceManager: RemoteServiceManager {
        terminalViewModel.activeServiceManager ?? RemoteServiceManager()
    }

    @State private var showLeftPanel = true
    @State private var showRightPanel = true
    @State private var leftPanelWidth: CGFloat = 250
    @State private var rightPanelWidth: CGFloat = 480
    @State private var showNewTabChooser = false
    @State private var showAuthFailedDialog = false
    @State private var retryPassword = ""
    @State private var authFailedSessionId: UUID?

    var body: some View {
        HSplitView {
            // ── Left Panel: Files + Servers ──
            if showLeftPanel {
                LeftPanelView(fileViewModel: fileViewModel, serviceManager: serviceManager, terminalViewModel: terminalViewModel)
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
                    .frame(minWidth: 320, idealWidth: rightPanelWidth, maxWidth: 600)
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
        .onReceive(NotificationCenter.default.publisher(for: .showNewTabChooser)) { _ in
            showNewTabChooser = true
        }
        .onReceive(NotificationCenter.default.publisher(for: .terminalSSHAuthFailed)) { notification in
            guard let sessionId = notification.object as? UUID else { return }
            authFailedSessionId = sessionId
            retryPassword = ""
            showAuthFailedDialog = true
        }
        .alert(LS("ssh.authFailed"), isPresented: $showAuthFailedDialog) {
            SecureField(LS("conn.password"), text: $retryPassword)
            Button(LS("conn.cancel"), role: .cancel) {
                retryPassword = ""
                authFailedSessionId = nil
            }
            Button(LS("ssh.retry")) {
                guard let sessionId = authFailedSessionId, !retryPassword.isEmpty else { return }
                // Send the new password to the terminal
                if let session = terminalViewModel.sessions[sessionId] {
                    // Update Keychain with new password
                    if let profile = session.connectedProfile {
                        try? KeychainService.shared.save(key: "ssh_\(profile.id.uuidString)", value: retryPassword)
                    }
                    // Store for auto-input on next prompt
                    session.pendingSSHPassword = retryPassword
                }
                // Type into terminal directly
                terminalViewModel.sendInput(retryPassword + "\n")
                retryPassword = ""
                authFailedSessionId = nil
            }
        } message: {
            Text(LS("ssh.authFailedMessage"))
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
        // Build SSH arguments for direct PTY creation
        var args: [String] = []
        args.append("\(profile.username)@\(profile.host)")
        args.append("-p")
        args.append("\(profile.port)")
        args.append("-o")
        args.append("StrictHostKeyChecking=no")

        if profile.authType == .keyFile, let keyPath = profile.keyFilePath {
            args.append("-i")
            args.append(keyPath)
        }

        // Load password ONCE from Keychain (single access, no repeated prompts)
        let password: String? = profile.authType == .password
            ? (try? KeychainService.shared.load(key: "ssh_\(profile.id.uuidString)"))
            : nil

        let title = profile.name.isEmpty ? profile.host : profile.name
        // Creates a per-tab RemoteServiceManager and connects it with pre-loaded password
        terminalViewModel.addNewTab(
            title: title,
            isSSH: true,
            profile: profile,
            preloadedPassword: password,
            sshProgram: "/usr/bin/ssh",
            sshArgs: args
        )

        // Password is auto-typed by TerminalNSView when it detects the SSH prompt

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
                HStack(spacing: 2) {
                    ForEach(viewModel.tabs) { tab in
                        TerminalTabItem(
                            tab: tab,
                            isSelected: viewModel.selectedTabId == tab.id,
                            onSelect: { viewModel.selectTab(tab.id) },
                            onClose: { viewModel.closeTab(tab.id) }
                        )
                    }
                }
                .padding(.horizontal, 6)
            }

            Spacer()

            Button(action: {
                NotificationCenter.default.post(name: .showNewTabChooser, object: nil)
            }) {
                Image(systemName: "plus")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(.secondary)
                    .frame(width: 24, height: 24)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.borderless)
            .padding(.trailing, 8)
        }
        .padding(.vertical, 2)
        .background(
            Color(nsColor: .controlBackgroundColor).opacity(0.6)
        )
        .overlay(alignment: .bottom) {
            // Subtle bottom border
            Rectangle()
                .fill(Color(nsColor: .separatorColor).opacity(0.5))
                .frame(height: 0.5)
        }
    }
}

struct TerminalTabItem: View {
    let tab: TerminalTab
    let isSelected: Bool
    let onSelect: () -> Void
    let onClose: () -> Void
    @State private var isHovered = false

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: tab.isSSH ? "network" : "terminal")
                .font(.system(size: 10))
                .foregroundColor(tab.isSSH ? .green : (isSelected ? .accentColor : .secondary))

            Text(tab.title)
                .font(.system(size: 11, weight: isSelected ? .medium : .regular))
                .foregroundColor(isSelected ? .primary : .secondary)
                .lineLimit(1)

            Button(action: onClose) {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 10))
                    .foregroundColor(.secondary.opacity(0.6))
            }
            .buttonStyle(.borderless)
            .opacity(isSelected || isHovered ? 1 : 0)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(isSelected
                    ? Color.accentColor.opacity(0.12)
                    : (isHovered ? Color(nsColor: .controlBackgroundColor).opacity(0.8) : Color.clear)
                )
        )
        .overlay(alignment: .bottom) {
            // Active indicator stripe
            if isSelected {
                RoundedRectangle(cornerRadius: 1)
                    .fill(Color.accentColor)
                    .frame(height: 2)
                    .padding(.horizontal, 8)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture(perform: onSelect)
        .onHover { hovering in
            withAnimation(.easeInOut(duration: 0.15)) {
                isHovered = hovering
            }
        }
    }
}

// MARK: - Status Bar

struct StatusBarView: View {
    @ObservedObject var viewModel: TerminalViewModel

    var body: some View {
        HStack(spacing: 6) {
            if let session = viewModel.currentSession {
                Circle()
                    .fill(Color.green)
                    .frame(width: 5, height: 5)
                Text(session.shellPath)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundColor(.secondary)
            }

            Spacer()

            Text(String(format: LS("terminal.sessionCount"), viewModel.tabs.count))
                .font(.system(size: 10))
                .foregroundColor(.secondary.opacity(0.7))
        }
        .padding(.horizontal, 12)
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.6))
        .overlay(alignment: .top) {
            Rectangle()
                .fill(Color(nsColor: .separatorColor).opacity(0.3))
                .frame(height: 0.5)
        }
    }
}
