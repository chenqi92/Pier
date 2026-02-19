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
    /// Optional group membership
    var groupId: UUID?

    enum AuthType: String, Codable, CaseIterable {
        case password = "password"
        case keyFile = "keyFile"

        var displayName: String {
            switch self {
            case .password: return LS("conn.authPassword")
            case .keyFile:  return LS("conn.authKeyFile")
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
            lastConnected: nil,
            groupId: nil
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

// MARK: - Server Group

/// A named group for organizing servers in a tree structure.
struct ServerGroup: Codable, Identifiable, Hashable {
    var id: UUID = UUID()
    var name: String
    var order: Int = 0

    static var storageURL: URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let dir = appSupport.appendingPathComponent("Pier", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("server_groups.json")
    }

    static func loadAll() -> [ServerGroup] {
        guard let data = try? Data(contentsOf: storageURL),
              let groups = try? JSONDecoder().decode([ServerGroup].self, from: data) else {
            return []
        }
        return groups.sorted { $0.order < $1.order }
    }

    static func saveAll(_ groups: [ServerGroup]) {
        guard let data = try? JSONEncoder().encode(groups) else { return }
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
