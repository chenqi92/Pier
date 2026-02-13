import Foundation

/// Represents an SSH server connection profile.
struct ServerProfile: Identifiable, Codable {
    var id = UUID()
    var name: String
    var host: String
    var port: Int = 22
    var username: String
    var authMethod: AuthMethod = .password

    enum AuthMethod: String, Codable, CaseIterable {
        case password = "Password"
        case keyFile = "Key File"
        case agent = "SSH Agent"
    }
}

/// Represents a terminal tab session.
struct TerminalTab: Identifiable {
    let id = UUID()
    var title: String
    var isSSH: Bool = false
    var serverProfile: ServerProfile? = nil
    var shellPath: String = "/bin/zsh"
}

/// Info about a terminal session for rendering.
class TerminalSessionInfo: Identifiable, ObservableObject {
    let id = UUID()
    var shellPath: String
    var isSSH: Bool
    @Published var title: String

    init(shellPath: String = "/bin/zsh", isSSH: Bool = false, title: String = "Local") {
        self.shellPath = shellPath
        self.isSSH = isSSH
        self.title = title
    }
}

/// Remote file entry from SFTP.
struct RemoteFile: Identifiable {
    let id = UUID()
    let name: String
    let path: String
    let isDir: Bool
    let size: UInt64
    let modified: Date?
}

/// Transfer progress info.
struct TransferProgress {
    let fileName: String
    let fraction: Double
    let totalBytes: UInt64
    let transferredBytes: UInt64

    var description: String {
        let pct = Int(fraction * 100)
        return "\(fileName) — \(pct)%"
    }
}
