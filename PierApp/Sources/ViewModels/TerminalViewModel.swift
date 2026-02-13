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

    // MARK: - Tab Management

    func addNewTab(title: String = "Terminal", shell: String = "/bin/zsh", isSSH: Bool = false) {
        let tab = TerminalTab(title: title, isSSH: isSSH, shellPath: shell)
        let session = TerminalSessionInfo(shellPath: shell, isSSH: isSSH, title: title)

        tabs.append(tab)
        sessions[tab.id] = session
        selectedTabId = tab.id
    }

    func selectTab(_ id: UUID) {
        selectedTabId = id
    }

    func closeTab(_ id: UUID) {
        tabs.removeAll { $0.id == id }
        sessions.removeValue(forKey: id)

        if selectedTabId == id {
            selectedTabId = tabs.last?.id
        }
    }

    // MARK: - Terminal Input

    func sendInput(_ text: String) {
        // This would forward to the active terminal's PTY via Rust FFI
        // For now, post notification that the terminal view can consume
        guard let id = selectedTabId else { return }
        NotificationCenter.default.post(
            name: .terminalInput,
            object: ["sessionId": id, "text": text]
        )
    }
}

extension Notification.Name {
    static let terminalInput = Notification.Name("pier.terminalInput")
}
