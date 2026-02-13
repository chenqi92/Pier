import SwiftUI
import Combine

// MARK: - Data Models

struct RedisKeyInfo: Identifiable {
    let key: String
    let type: String
    let ttl: Int       // -1 = no expiry, -2 = key not found
    var value: String?

    var id: String { key }

    var ttlDisplay: String {
        switch ttl {
        case -1: return "∞"
        case -2: return "N/A"
        default: return "\(ttl)s"
        }
    }
}

struct RedisServerInfo {
    let version: String
    let connectedClients: Int
    let usedMemory: String
    let uptimeDays: Int
    let dbSize: Int
}

// MARK: - ViewModel

@MainActor
class RedisViewModel: ObservableObject {
    @Published var isConnected = false
    @Published var isLoading = false
    @Published var keys: [RedisKeyInfo] = []
    @Published var selectedKey: RedisKeyInfo?
    @Published var searchPattern: String = "*"
    @Published var serverInfo: RedisServerInfo?
    @Published var errorMessage: String?
    @Published var commandInput: String = ""
    @Published var commandOutput: String = ""

    /// Port to connect to (default: tunneled Redis port 16379).
    var redisPort: UInt16 = 16379

    // MARK: - Connection

    func connect() {
        isLoading = true
        errorMessage = nil

        Task {
            let result = await runRedisCommand(["PING"])
            if result?.trimmingCharacters(in: .whitespacesAndNewlines) == "PONG" {
                isConnected = true
                await loadServerInfo()
                await scanKeys()
            } else {
                errorMessage = String(localized: "redis.connectFailed")
            }
            isLoading = false
        }
    }

    func disconnect() {
        isConnected = false
        keys = []
        selectedKey = nil
        serverInfo = nil
    }

    // MARK: - Key Operations

    func scanKeys() async {
        guard isConnected else { return }
        isLoading = true

        let pattern = searchPattern.isEmpty ? "*" : searchPattern
        guard let output = await runRedisCommand(["--scan", "--pattern", pattern, "--count", "200"]) else {
            isLoading = false
            return
        }

        let keyNames = output.split(separator: "\n")
            .map(String.init)
            .filter { !$0.isEmpty }

        // Load type and TTL for each key (batch)
        var loadedKeys: [RedisKeyInfo] = []
        for name in keyNames.prefix(200) {
            let type = await runRedisCommand(["TYPE", name])?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "unknown"
            let ttlStr = await runRedisCommand(["TTL", name])?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "-2"
            let ttl = Int(ttlStr) ?? -2
            loadedKeys.append(RedisKeyInfo(key: name, type: type, ttl: ttl))
        }

        keys = loadedKeys.sorted(by: { $0.key < $1.key })
        isLoading = false
    }

    func getKeyValue(_ key: String) {
        Task {
            guard let info = keys.first(where: { $0.key == key }) else { return }

            var value: String?
            switch info.type {
            case "string":
                value = await runRedisCommand(["GET", key])
            case "list":
                value = await runRedisCommand(["LRANGE", key, "0", "99"])
            case "set":
                value = await runRedisCommand(["SMEMBERS", key])
            case "zset":
                value = await runRedisCommand(["ZRANGE", key, "0", "99", "WITHSCORES"])
            case "hash":
                value = await runRedisCommand(["HGETALL", key])
            default:
                value = "(unsupported type: \(info.type))"
            }

            if let idx = keys.firstIndex(where: { $0.key == key }) {
                keys[idx].value = value?.trimmingCharacters(in: .whitespacesAndNewlines)
                selectedKey = keys[idx]
            }
        }
    }

    func deleteKey(_ key: String) {
        Task {
            _ = await runRedisCommand(["DEL", key])
            keys.removeAll { $0.key == key }
            if selectedKey?.key == key { selectedKey = nil }
        }
    }

    func setKeyExpiry(_ key: String, seconds: Int) {
        Task {
            _ = await runRedisCommand(["EXPIRE", key, String(seconds)])
            // Refresh the key info
            if let idx = keys.firstIndex(where: { $0.key == key }) {
                let ttlStr = await runRedisCommand(["TTL", key])?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "-2"
                keys[idx] = RedisKeyInfo(key: key, type: keys[idx].type, ttl: Int(ttlStr) ?? -2, value: keys[idx].value)
                selectedKey = keys[idx]
            }
        }
    }

    // MARK: - Raw Command

    func executeRawCommand() {
        guard !commandInput.isEmpty else { return }

        Task {
            let args = commandInput.split(separator: " ").map(String.init)
            let output = await runRedisCommand(args) ?? "(error)"
            commandOutput += "> \(commandInput)\n\(output)\n"
            commandInput = ""
        }
    }

    // MARK: - Server Info

    func loadServerInfo() async {
        guard let output = await runRedisCommand(["INFO", "server"]) else { return }
        guard let memOutput = await runRedisCommand(["INFO", "memory"]) else { return }
        guard let clientOutput = await runRedisCommand(["INFO", "clients"]) else { return }
        guard let dbSizeOutput = await runRedisCommand(["DBSIZE"]) else { return }

        let infoLines = (output + memOutput + clientOutput).split(separator: "\n")

        func extractValue(_ prefix: String) -> String {
            infoLines.first { $0.hasPrefix(prefix) }
                .map { String($0.dropFirst(prefix.count)) }?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        }

        let version = extractValue("redis_version:")
        let clients = Int(extractValue("connected_clients:")) ?? 0
        let memory = extractValue("used_memory_human:")
        let uptime = Int(extractValue("uptime_in_days:")) ?? 0
        let dbSize = Int(dbSizeOutput.filter(\.isNumber)) ?? 0

        serverInfo = RedisServerInfo(
            version: version,
            connectedClients: clients,
            usedMemory: memory,
            uptimeDays: uptime,
            dbSize: dbSize
        )
    }

    func refreshKeys() {
        Task { await scanKeys() }
    }

    // MARK: - Helpers

    private func runRedisCommand(_ args: [String]) async -> String? {
        let allArgs = ["-h", "127.0.0.1", "-p", String(redisPort)] + args
        let result = await CommandRunner.shared.run("redis-cli", arguments: allArgs)
        return result.succeeded ? result.output : nil
    }
}
