import SwiftUI
import Combine

/// ViewModel for terminal session management (multi-tab).
@MainActor
class TerminalViewModel: ObservableObject {
    @Published var tabs: [TerminalTab] = []
    @Published var selectedTabId: UUID?
    @Published var sessions: [UUID: TerminalSessionInfo] = [:]

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

    func addNewTab(title: String = "Terminal", shell: String = "/bin/zsh", isSSH: Bool = false, profile: ConnectionProfile? = nil, preloadedPassword: String? = nil, sshProgram: String? = nil, sshArgs: [String]? = nil) {
        let tab = TerminalTab(title: title, isSSH: isSSH, shellPath: shell)
        let session = TerminalSessionInfo(shellPath: shell, isSSH: isSSH, title: title)
        session.sshProgram = sshProgram
        session.sshArgs = sshArgs

        // Create RemoteServiceManager synchronously so it's immediately
        // available for SwiftUI observation (right panel binding)
        let sm = RemoteServiceManager()
        session.remoteServiceManager = sm

        tabs.append(tab)
        sessions[tab.id] = session
        selectedTabId = tab.id

        // If SSH profile provided, connect the per-tab service manager (async)
        if let profile = profile {
            session.connectedProfile = profile
            Task { @MainActor in
                sm.connect(profile: profile, preloadedPassword: preloadedPassword)
            }
        }
    }

    func selectTab(_ id: UUID) {
        selectedTabId = id
        // Notify that active service manager changed
        objectWillChange.send()
    }

    func closeTab(_ id: UUID) {
        // Notify TerminalNSView to destroy the cached PTY
        NotificationCenter.default.post(name: .terminalTabClosed, object: id)

        // Disconnect per-tab SSH service manager
        if let session = sessions[id] {
            Task { @MainActor in
                session.remoteServiceManager?.disconnect()
            }
        }

        tabs.removeAll { $0.id == id }
        sessions.removeValue(forKey: id)

        if selectedTabId == id {
            selectedTabId = tabs.last?.id
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
        // Check if the session's PTY is ready by looking for a response
        let delivered = UnsafeMutablePointer<Bool>.allocate(capacity: 1)
        delivered.pointee = false

        NotificationCenter.default.post(
            name: .terminalInput,
            object: ["sessionId": sessionId, "text": text, "deliveryFlag": delivered]
        )

        let wasDelivered = delivered.pointee
        delivered.deallocate()

        if !wasDelivered && retriesLeft > 0 {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
                self?.sendInputToSession(sessionId, text: text, retriesLeft: retriesLeft - 1)
            }
        }
    }
}

extension Notification.Name {
    static let terminalInput = Notification.Name("pier.terminalInput")
    static let terminalSSHDetected = Notification.Name("pier.terminalSSHDetected")
    static let terminalSSHExited = Notification.Name("pier.terminalSSHExited")
    static let terminalTabClosed = Notification.Name("pier.terminalTabClosed")
}
