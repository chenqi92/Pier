import SwiftUI
import Combine

/// ViewModel for terminal session management (multi-tab).
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

        // Start with one default tab
        addNewTab()
    }

    var currentSession: TerminalSessionInfo? {
        guard let id = selectedTabId else { return nil }
        return sessions[id]
    }

    /// The active tab's per-tab RemoteServiceManager (nil for local tabs).
    var activeServiceManager: RemoteServiceManager? {
        currentSession?.remoteServiceManager
    }

    // MARK: - Tab Management

    func addNewTab(title: String = "Terminal", shell: String = "/bin/zsh", isSSH: Bool = false, profile: ConnectionProfile? = nil, preloadedPassword: String? = nil) {
        let tab = TerminalTab(title: title, isSSH: isSSH, shellPath: shell)
        let session = TerminalSessionInfo(shellPath: shell, isSSH: isSSH, title: title)

        // If SSH profile provided, create a per-tab service manager
        if let profile = profile {
            Task { @MainActor in
                let sm = RemoteServiceManager()
                session.remoteServiceManager = sm
                session.connectedProfile = profile
                sm.connect(profile: profile, preloadedPassword: preloadedPassword)
            }
        }

        tabs.append(tab)
        sessions[tab.id] = session
        selectedTabId = tab.id
    }

    func selectTab(_ id: UUID) {
        selectedTabId = id
        // Notify that active service manager changed
        objectWillChange.send()
    }

    func closeTab(_ id: UUID) {
        // Notify TerminalNSView to destroy the cached PTY
        NotificationCenter.default.post(name: .terminalTabClosed, object: id)

        // Disconnect per-tab SSH if any
        if let session = sessions[id], let sm = session.remoteServiceManager {
            Task { @MainActor in
                sm.disconnect()
            }
            session.remoteServiceManager = nil
        }

        tabs.removeAll { $0.id == id }
        sessions.removeValue(forKey: id)

        if selectedTabId == id {
            selectedTabId = tabs.last?.id
        }
    }

    // MARK: - Terminal Input

    func sendInput(_ text: String) {
        guard let id = selectedTabId else { return }
        NotificationCenter.default.post(
            name: .terminalInput,
            object: ["sessionId": id, "text": text]
        )
    }
}

extension Notification.Name {
    static let terminalInput = Notification.Name("pier.terminalInput")
    static let terminalSSHDetected = Notification.Name("pier.terminalSSHDetected")
    static let terminalTabClosed = Notification.Name("pier.terminalTabClosed")
}
