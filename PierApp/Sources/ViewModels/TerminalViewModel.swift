import SwiftUI
import Combine

/// ViewModel for terminal session management (multi-tab).
@MainActor
class TerminalViewModel: ObservableObject {
    @Published var tabs: [TerminalTab] = []
    @Published var selectedTabId: UUID?
    @Published var sessions: [UUID: TerminalSessionInfo] = [:]
    /// Root split node per tab (for split pane support).
    @Published var splitNodes: [UUID: SplitNode] = [:]

    private var cancellables = Set<AnyCancellable>()

    init() {
        // Listen for "New Tab" requests
        NotificationCenter.default.publisher(for: .newTerminalTab)
            .sink { [weak self] _ in self?.addNewTab() }
            .store(in: &cancellables)

        // Listen for SSH session exit (e.g., user typed 'exit' on remote)
        NotificationCenter.default.publisher(for: .terminalSSHExited)
            .sink { [weak self] notification in
                guard let self = self,
                      let sessionId = notification.object as? UUID,
                      let session = self.sessions[sessionId] else { return }
                // Disconnect the per-tab service manager on main actor
                Task { @MainActor in
                    session.remoteServiceManager?.disconnect()
                }
                session.connectedProfile = nil
                session.isSSH = false
                // Update the tab's isSSH flag
                if let idx = self.tabs.firstIndex(where: { $0.id == sessionId }) {
                    self.tabs[idx].isSSH = false
                }
                self.objectWillChange.send()
            }
            .store(in: &cancellables)

        // Listen for SSH auth success (user typed password manually in terminal)
        // Retry the per-tab service manager connection using key-based auth.
        NotificationCenter.default.publisher(for: .terminalSSHAuthSuccess)
            .sink { [weak self] notification in
                guard let self = self,
                      let sessionId = notification.object as? UUID,
                      let session = self.sessions[sessionId],
                      let sm = session.remoteServiceManager,
                      !sm.isConnected && !sm.isConnecting,
                      let profile = session.connectedProfile else { return }
                // Retry with key-based auth (no password available)
                Task { @MainActor in
                    let home = NSHomeDirectory()
                    let keyFiles = [
                        "\(home)/.ssh/id_rsa",
                        "\(home)/.ssh/id_ed25519",
                        "\(home)/.ssh/id_ecdsa",
                    ]
                    for keyPath in keyFiles {
                        if FileManager.default.fileExists(atPath: keyPath) {
                            sm.connectWithKey(host: profile.host, port: profile.port, username: profile.username, keyPath: keyPath)
                            return
                        }
                    }
                    // No key files found — show password prompt pattern in right panel
                    // The terminalSSHDetected handler in RightPanelView will handle this
                }
            }
            .store(in: &cancellables)

        // Listen for split/close from NSView right-click menu
        NotificationCenter.default.publisher(for: .terminalSplitH)
            .sink { [weak self] notification in
                guard let self = self, let sessionId = notification.object as? UUID else { return }
                self.splitBySessionId(sessionId, direction: .horizontal)
            }
            .store(in: &cancellables)

        NotificationCenter.default.publisher(for: .terminalSplitV)
            .sink { [weak self] notification in
                guard let self = self, let sessionId = notification.object as? UUID else { return }
                self.splitBySessionId(sessionId, direction: .vertical)
            }
            .store(in: &cancellables)

        NotificationCenter.default.publisher(for: .terminalClosePane)
            .sink { [weak self] notification in
                guard let self = self, let sessionId = notification.object as? UUID else { return }
                self.closePaneBySessionId(sessionId)
            }
            .store(in: &cancellables)

        // Start with one default tab
        addNewTab()
    }

    var currentSession: TerminalSessionInfo? {
        guard let id = selectedTabId else { return nil }
        return sessions[id]
    }

    /// The active tab's per-tab RemoteServiceManager.
    /// Each tab always has its own instance (disconnected for local tabs).
    var activeServiceManager: RemoteServiceManager? {
        currentSession?.remoteServiceManager
    }

    // MARK: - Tab Management

    func addNewTab(title: String = "Terminal", shell: String = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh", isSSH: Bool = false, profile: ConnectionProfile? = nil, preloadedPassword: String? = nil, sshProgram: String? = nil, sshArgs: [String]? = nil) {
        let tab = TerminalTab(title: title, isSSH: isSSH, shellPath: shell)
        let session = TerminalSessionInfo(shellPath: shell, isSSH: isSSH, title: title)
        session.sshProgram = sshProgram
        session.sshArgs = sshArgs
        session.pendingSSHPassword = preloadedPassword

        // Create RemoteServiceManager synchronously so it's immediately
        // available for SwiftUI observation (right panel binding)
        let sm = RemoteServiceManager()
        session.remoteServiceManager = sm

        tabs.append(tab)
        sessions[tab.id] = session
        selectedTabId = tab.id

        // Create root split node for this tab
        splitNodes[tab.id] = SplitNode(session: session)

        // Auto-assign color for SSH tabs based on host name hash
        if isSSH {
            let hash = abs(title.hashValue)
            let colorIdx = hash % TerminalTab.colorPalette.count
            if let idx = tabs.firstIndex(where: { $0.id == tab.id }) {
                tabs[idx].colorTag = colorIdx
            }
        }

        // If SSH profile provided, connect the per-tab service manager (async)
        if let profile = profile {
            session.connectedProfile = profile
            let keychainDenied = (preloadedPassword == nil && profile.authType == .password)
            Task { @MainActor in
                sm.connect(profile: profile, preloadedPassword: preloadedPassword, keychainDenied: keychainDenied)
            }
        }
    }

    /// Set the color tag for a tab.
    func setTabColor(_ tabId: UUID, color: Int?) {
        if let idx = tabs.firstIndex(where: { $0.id == tabId }) {
            tabs[idx].colorTag = color
            objectWillChange.send()
        }
    }

    func selectTab(_ id: UUID) {
        selectedTabId = id
        // Notify that active service manager changed
        objectWillChange.send()
    }

    func closeTab(_ id: UUID) {
        // 1. Compute new selectedTabId FIRST, before mutating any @Published state.
        //    This prevents SwiftUI from re-rendering during intermediate inconsistent states
        //    (e.g. selectedTabId pointing to a removed splitNode → Index out of range).
        let newSelectedId: UUID?
        if selectedTabId == id {
            // Select the tab before this one, or the first remaining tab
            if let idx = tabs.firstIndex(where: { $0.id == id }) {
                let remaining = tabs.filter { $0.id != id }
                if idx > 0 && idx - 1 < remaining.count {
                    newSelectedId = remaining[idx - 1].id
                } else {
                    newSelectedId = remaining.first?.id
                }
            } else {
                newSelectedId = nil
            }
        } else {
            newSelectedId = selectedTabId
        }

        // 2. Notify TerminalNSView to destroy cached PTYs (before removing state)
        NotificationCenter.default.post(name: .terminalTabClosed, object: id)
        if let root = splitNodes[id] {
            for s in root.allSessions where s.id != id {
                NotificationCenter.default.post(name: .terminalTabClosed, object: s.id)
            }
        }

        // 3. Disconnect per-tab SSH service manager
        if let session = sessions[id] {
            Task { @MainActor in
                session.remoteServiceManager?.disconnect()
            }
        }

        // 4. Remove all state atomically (single @Published batch)
        splitNodes.removeValue(forKey: id)
        tabs.removeAll { $0.id == id }
        sessions.removeValue(forKey: id)
        selectedTabId = newSelectedId
    }

    // MARK: - Split Pane

    /// Split a pane horizontally (side by side).
    func splitHorizontal(tabId: UUID, nodeId: UUID) {
        performSplit(tabId: tabId, nodeId: nodeId, direction: .horizontal)
    }

    /// Split a pane vertically (top and bottom).
    func splitVertical(tabId: UUID, nodeId: UUID) {
        performSplit(tabId: tabId, nodeId: nodeId, direction: .vertical)
    }

    private func performSplit(tabId: UUID, nodeId: UUID, direction: SplitDirection) {
        guard let root = splitNodes[tabId] else { return }
        // Find the target node in the tree
        guard let target = findNode(nodeId, in: root) else { return }
        // Create a new session for the new pane
        let newSession = TerminalSessionInfo(isSSH: false, title: "Terminal")
        let sm = RemoteServiceManager()
        newSession.remoteServiceManager = sm
        target.split(direction: direction, newSession: newSession)
        objectWillChange.send()
    }

    /// Close a specific split pane.
    func closePane(tabId: UUID, nodeId: UUID) {
        guard let root = splitNodes[tabId] else { return }
        // Notify terminal to clean up PTY for sessions in the closed pane
        if let target = findNode(nodeId, in: root) {
            for s in target.allSessions {
                NotificationCenter.default.post(name: .terminalTabClosed, object: s.id)
            }
        }
        root.removeChild(nodeId)
        objectWillChange.send()
    }

    private func findNode(_ id: UUID, in node: SplitNode) -> SplitNode? {
        if node.id == id { return node }
        if case .branch(_, let children) = node.content {
            for child in children {
                if let found = findNode(id, in: child) { return found }
            }
        }
        return nil
    }

    /// Find a SplitNode that contains the given session ID.
    private func findNodeBySession(_ sessionId: UUID, in node: SplitNode) -> SplitNode? {
        if case .leaf(let s) = node.content, s.id == sessionId { return node }
        if case .branch(_, let children) = node.content {
            for child in children {
                if let found = findNodeBySession(sessionId, in: child) { return found }
            }
        }
        return nil
    }

    /// Split by session ID (from NSView right-click menu notification).
    func splitBySessionId(_ sessionId: UUID, direction: SplitDirection) {
        for (tabId, root) in splitNodes {
            if let node = findNodeBySession(sessionId, in: root) {
                performSplit(tabId: tabId, nodeId: node.id, direction: direction)
                return
            }
        }
    }

    /// Close pane by session ID (from NSView right-click menu notification).
    func closePaneBySessionId(_ sessionId: UUID) {
        for (tabId, root) in splitNodes {
            if let node = findNodeBySession(sessionId, in: root) {
                closePane(tabId: tabId, nodeId: node.id)
                return
            }
        }
    }

    // MARK: - Terminal Input

    func sendInput(_ text: String) {
        guard let tabId = selectedTabId,
              let session = sessions[tabId] else { return }
        NotificationCenter.default.post(
            name: .terminalInput,
            object: ["sessionId": session.id, "text": text]
        )
    }

    /// Send input to a specific session, retrying until it's delivered.
    /// Used after creating a new tab, since the PTY needs a layout pass to initialize.
    func sendInputToSession(_ sessionId: UUID, text: String, retriesLeft: Int = 15) {
        let delivered = DeliveryFlag()

        NotificationCenter.default.post(
            name: .terminalInput,
            object: ["sessionId": sessionId, "text": text, "deliveryFlag": delivered]
        )

        if !delivered.value && retriesLeft > 0 {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
                self?.sendInputToSession(sessionId, text: text, retriesLeft: retriesLeft - 1)
            }
        }
    }
}

/// Pass-by-reference Bool wrapper for notification-based delivery confirmation.
/// Replaces UnsafeMutablePointer<Bool> — safer, no manual allocate/deallocate.
@objc class DeliveryFlag: NSObject {
    @objc dynamic var value = false
}

extension Notification.Name {
    static let terminalInput = Notification.Name("pier.terminalInput")
    static let terminalSSHDetected = Notification.Name("pier.terminalSSHDetected")
    static let terminalSSHExited = Notification.Name("pier.terminalSSHExited")
    static let terminalSSHAuthFailed = Notification.Name("pier.terminalSSHAuthFailed")
    static let terminalSSHAuthSuccess = Notification.Name("pier.terminalSSHAuthSuccess")
    static let terminalTabClosed = Notification.Name("pier.terminalTabClosed")
}
