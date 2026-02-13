import Foundation

/// Host key verification status.
enum HostKeyVerification {
    case trusted          // Key matches known_hosts
    case unknown          // Host not in known_hosts
    case mismatch         // Key changed (possible MITM)
}

/// Entry in known_hosts file.
struct KnownHostEntry {
    let hostPattern: String
    let keyType: String
    let keyData: String

    func matches(host: String, port: Int) -> Bool {
        let target = port == 22 ? host : "[\(host)]:\(port)"
        if hostPattern == target || hostPattern == host { return true }
        // Handle hashed entries (SHA-1)
        if hostPattern.hasPrefix("|1|") { return false } // Can't match hashed without hashing
        return false
    }
}

/// Manages SSH known hosts verification.
class SSHKnownHosts {
    static let shared = SSHKnownHosts()

    private var entries: [KnownHostEntry] = []
    private let knownHostsPath: String

    init() {
        knownHostsPath = NSHomeDirectory() + "/.ssh/known_hosts"
        loadKnownHosts()
    }

    /// Reload the known_hosts file.
    func loadKnownHosts() {
        entries.removeAll()

        guard let content = try? String(contentsOfFile: knownHostsPath, encoding: .utf8) else { return }

        for line in content.split(separator: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty, !trimmed.hasPrefix("#") else { continue }

            let parts = trimmed.split(separator: " ", maxSplits: 2)
            guard parts.count >= 3 else { continue }

            entries.append(KnownHostEntry(
                hostPattern: String(parts[0]),
                keyType: String(parts[1]),
                keyData: String(parts[2])
            ))
        }
    }

    /// Verify a host key against known_hosts.
    func verify(host: String, port: Int, keyType: String, keyData: String) -> HostKeyVerification {
        let matching = entries.filter { $0.matches(host: host, port: port) && $0.keyType == keyType }

        if matching.isEmpty {
            return .unknown
        }

        if matching.contains(where: { $0.keyData == keyData }) {
            return .trusted
        }

        return .mismatch
    }

    /// Add a host key to known_hosts.
    func addHostKey(host: String, port: Int, keyType: String, keyData: String) {
        let hostStr = port == 22 ? host : "[\(host)]:\(port)"
        let entry = "\(hostStr) \(keyType) \(keyData)\n"

        // Ensure .ssh directory exists
        let sshDir = NSHomeDirectory() + "/.ssh"
        try? FileManager.default.createDirectory(atPath: sshDir, withIntermediateDirectories: true)

        // Append to known_hosts
        if let fileHandle = FileHandle(forWritingAtPath: knownHostsPath) {
            fileHandle.seekToEndOfFile()
            fileHandle.write(entry.data(using: .utf8)!)
            fileHandle.closeFile()
        } else {
            try? entry.write(toFile: knownHostsPath, atomically: true, encoding: .utf8)
        }

        // Reload
        entries.append(KnownHostEntry(hostPattern: hostStr, keyType: keyType, keyData: keyData))
    }

    /// Remove all entries for a host (used when user accepts new key for changed host).
    func removeHostKey(host: String, port: Int) {
        entries.removeAll { $0.matches(host: host, port: port) }

        // Rewrite file
        let content = entries.map { "\($0.hostPattern) \($0.keyType) \($0.keyData)" }.joined(separator: "\n")
        try? (content + "\n").write(toFile: knownHostsPath, atomically: true, encoding: .utf8)
    }

    /// Get the fingerprint display string for a key.
    static func fingerprint(keyData: String) -> String {
        guard let data = Data(base64Encoded: keyData) else { return "unknown" }
        let hash = data.withUnsafeBytes { bytes -> String in
            var digest = [UInt8](repeating: 0, count: 32)
            CC_SHA256(bytes.baseAddress, CC_LONG(data.count), &digest)
            return digest.map { String(format: "%02x", $0) }.joined(separator: ":")
        }
        return "SHA256:\(hash.prefix(47))"
    }
}

// Import CommonCrypto for fingerprint hashing
import CommonCrypto
