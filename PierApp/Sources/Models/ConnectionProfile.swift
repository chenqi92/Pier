import Foundation

/// SSH connection profile for saved server configurations.
struct ConnectionProfile: Codable, Identifiable, Hashable {
    var id: UUID
    var name: String
    var host: String
    var port: UInt16
    var username: String
    var authType: AuthType
    var keyFilePath: String?
    var agentForwarding: Bool = false
    var lastConnected: Date?

    enum AuthType: String, Codable, CaseIterable {
        case password = "password"
        case keyFile = "keyFile"

        var displayName: String {
            switch self {
            case .password: return String(localized: "conn.authPassword")
            case .keyFile:  return String(localized: "conn.authKeyFile")
            }
        }
    }

    static var `default`: ConnectionProfile {
        ConnectionProfile(
            id: UUID(),
            name: "",
            host: "",
            port: 22,
            username: "root",
            authType: .password,
            keyFilePath: nil,
            agentForwarding: false,
            lastConnected: nil
        )
    }
}


// MARK: - Persistence

extension ConnectionProfile {
    private static var storageURL: URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let dir = appSupport.appendingPathComponent("Pier", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("connections.json")
    }

    static func loadAll() -> [ConnectionProfile] {
        guard let data = try? Data(contentsOf: storageURL),
              let profiles = try? JSONDecoder().decode([ConnectionProfile].self, from: data) else {
            return []
        }
        return profiles
    }

    static func saveAll(_ profiles: [ConnectionProfile]) {
        guard let data = try? JSONEncoder().encode(profiles) else { return }
        try? data.write(to: storageURL, options: .atomic)
    }
}

// MARK: - Service Tunnel

/// Represents an active SSH port forward (tunnel).
struct ServiceTunnel: Identifiable, Hashable {
    let serviceName: String
    let localPort: UInt16
    let remoteHost: String
    let remotePort: UInt16
    var id: String { serviceName }

    /// Default tunnel mappings for detected services.
    static let defaultMappings: [String: (localPort: UInt16, remotePort: UInt16)] = [
        "MySQL":      (13306, 3306),
        "Redis":      (16379, 6379),
        "PostgreSQL": (15432, 5432),
    ]
}
