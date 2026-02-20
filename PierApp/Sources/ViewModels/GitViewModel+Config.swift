import SwiftUI
import Combine

// MARK: - Data Models

struct GitConfigEntry: Identifiable {
    let key: String
    let value: String
    let scope: GitConfigScope
    var id: String { "\(scope.rawValue):\(key)" }
}

enum GitConfigScope: String, CaseIterable {
    case local = "local"
    case global = "global"
    case system = "system"

    var flag: String {
        switch self {
        case .local: return "--local"
        case .global: return "--global"
        case .system: return "--system"
        }
    }

    var displayName: String {
        switch self {
        case .local: return LS("gitConfig.local")
        case .global: return LS("gitConfig.global")
        case .system: return LS("gitConfig.systemScope")
        }
    }
}

// MARK: - Config Extension

extension GitViewModel {

    /// Load git config entries for the specified scope.
    func loadGitConfig(scope: GitConfigScope) async -> [GitConfigEntry] {
        guard let output = await runGit(["config", scope.flag, "--list"]) else {
            return []
        }

        return output.split(separator: "\n").compactMap { line in
            let parts = line.split(separator: "=", maxSplits: 1)
            guard parts.count >= 2 else { return nil }
            return GitConfigEntry(
                key: String(parts[0]),
                value: String(parts[1]),
                scope: scope
            )
        }.sorted { $0.key < $1.key }
    }

    /// Set a git config value.
    func setGitConfig(key: String, value: String, scope: GitConfigScope) {
        Task {
            let result = await runGitFull(["config", scope.flag, key, value])
            if result.succeeded {
                setOperationStatus(.success(message: "Set \(key)"))
            } else {
                setOperationStatus(.failure(message: "Failed to set \(key)", detail: result.stderr))
            }
        }
    }

    /// Remove a git config entry.
    func unsetGitConfig(key: String, scope: GitConfigScope) {
        Task {
            let result = await runGitFull(["config", scope.flag, "--unset", key])
            if result.succeeded {
                setOperationStatus(.success(message: "Removed \(key)"))
            } else {
                setOperationStatus(.failure(message: "Failed to remove \(key)", detail: result.stderr))
            }
        }
    }
}
