import Foundation
import Security

/// Secure credential storage using macOS Keychain.
///
/// Thread-safe: all mutable state is protected by `cacheLock`.
class KeychainService {

    static let shared = KeychainService()
    private let serviceName = "com.kkape.pier"

    /// In-memory cache to avoid repeated Keychain prompts.
    /// Key: Keychain account key, Value: (cachedValue, timestamp)
    private var cache: [String: (value: String?, timestamp: Date)] = [:]
    private let cacheLock = NSLock()
    private let cacheTTL: TimeInterval = 600 // 10 minutes

    // MARK: - Save

    func save(key: String, value: String) throws {
        guard let data = value.data(using: .utf8) else {
            throw KeychainError.encodingFailed
        }

        // Delete existing item first
        try? delete(key: key)

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: serviceName,
            kSecAttrAccount as String: key,
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlocked,
        ]

        let status = SecItemAdd(query as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw KeychainError.saveFailed(status)
        }

        // Update cache
        cacheLock.lock()
        cache[key] = (value: value, timestamp: Date())
        cacheLock.unlock()
    }

    // MARK: - Load

    func load(key: String) throws -> String? {
        // Check in-memory cache first
        cacheLock.lock()
        let cached = cache[key]
        cacheLock.unlock()
        if let cached, Date().timeIntervalSince(cached.timestamp) < cacheTTL {
            return cached.value
        }

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: serviceName,
            kSecAttrAccount as String: key,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]

        var item: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &item)

        switch status {
        case errSecSuccess:
            guard let data = item as? Data,
                  let value = String(data: data, encoding: .utf8) else {
                throw KeychainError.decodingFailed
            }
            // Cache the loaded value
            cacheLock.lock()
            cache[key] = (value: value, timestamp: Date())
            cacheLock.unlock()
            return value
        case errSecItemNotFound:
            // Cache the "not found" result too
            cacheLock.lock()
            cache[key] = (value: nil, timestamp: Date())
            cacheLock.unlock()
            return nil
        default:
            throw KeychainError.loadFailed(status)
        }
    }

    // MARK: - Delete

    func delete(key: String) throws {
        // Invalidate cache
        cacheLock.lock()
        cache.removeValue(forKey: key)
        cacheLock.unlock()

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: serviceName,
            kSecAttrAccount as String: key,
        ]

        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainError.deleteFailed(status)
        }
    }

    // MARK: - SSH Key Management

    /// Save an SSH private key securely.
    func saveSSHKey(name: String, privateKey: String, passphrase: String? = nil) throws {
        try save(key: "ssh_key_\(name)", value: privateKey)
        if let passphrase = passphrase {
            try save(key: "ssh_passphrase_\(name)", value: passphrase)
        }
    }

    /// Load an SSH private key.
    func loadSSHKey(name: String) throws -> (privateKey: String, passphrase: String?)? {
        guard let key = try load(key: "ssh_key_\(name)") else { return nil }
        let passphrase = try load(key: "ssh_passphrase_\(name)")
        return (key, passphrase)
    }

    /// Save a server password.
    func saveServerPassword(host: String, username: String, password: String) throws {
        let key = "server_\(username)@\(host)"
        try save(key: key, value: password)
    }

    /// Load a server password.
    func loadServerPassword(host: String, username: String) throws -> String? {
        let key = "server_\(username)@\(host)"
        return try load(key: key)
    }
}

// MARK: - Errors

enum KeychainError: LocalizedError {
    case encodingFailed
    case decodingFailed
    case saveFailed(OSStatus)
    case loadFailed(OSStatus)
    case deleteFailed(OSStatus)

    var errorDescription: String? {
        switch self {
        case .encodingFailed: return "Failed to encode data"
        case .decodingFailed: return "Failed to decode data"
        case .saveFailed(let s): return "Keychain save failed: \(s)"
        case .loadFailed(let s): return "Keychain load failed: \(s)"
        case .deleteFailed(let s): return "Keychain delete failed: \(s)"
        }
    }
}
