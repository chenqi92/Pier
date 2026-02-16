import SwiftUI
import Combine

// MARK: - Data Models

struct GitSubmodule: Identifiable {
    let name: String
    let path: String
    let url: String
    let status: SubmoduleStatus
    let commitHash: String
    var id: String { path }
}

enum SubmoduleStatus {
    case upToDate
    case modified
    case uninitialized

    var icon: String {
        switch self {
        case .upToDate: return "checkmark.circle.fill"
        case .modified: return "exclamationmark.circle.fill"
        case .uninitialized: return "circle.dashed"
        }
    }

    var color: Color {
        switch self {
        case .upToDate: return .green
        case .modified: return .orange
        case .uninitialized: return .secondary
        }
    }
}

// MARK: - Submodule Extension

extension GitViewModel {

    /// Load all submodules and their status.
    func loadSubmodules() async -> [GitSubmodule] {
        guard let output = await runGit(["submodule", "status"]) else {
            return []
        }

        var submodules: [GitSubmodule] = []
        let configOutput = await runGit(["config", "--file", ".gitmodules", "--list"]) ?? ""

        // Parse submodule URLs from .gitmodules
        var urlMap: [String: String] = [:]
        for line in configOutput.split(separator: "\n") {
            let parts = line.split(separator: "=", maxSplits: 1)
            if parts.count == 2 {
                let key = String(parts[0])
                let value = String(parts[1])
                // submodule.name.url = https://...
                if key.hasSuffix(".url") {
                    let name = key
                        .replacingOccurrences(of: "submodule.", with: "")
                        .replacingOccurrences(of: ".url", with: "")
                    urlMap[name] = value
                }
            }
        }

        for line in output.split(separator: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else { continue }

            // Format: [ +-U]hash path (description)
            let statusChar = trimmed.first ?? " "
            let rest = trimmed.dropFirst()
            let parts = rest.split(separator: " ", maxSplits: 1)
            guard parts.count >= 2 else { continue }

            let hash = String(parts[0])
            let pathParts = parts[1].split(separator: " ", maxSplits: 1)
            let path = String(pathParts[0])

            let status: SubmoduleStatus
            switch statusChar {
            case "+": status = .modified
            case "-": status = .uninitialized
            default:  status = .upToDate
            }

            submodules.append(GitSubmodule(
                name: path,
                path: path,
                url: urlMap[path] ?? "",
                status: status,
                commitHash: hash
            ))
        }

        return submodules
    }

    /// Initialize all submodules.
    func initSubmodules() {
        Task {
            setOperationStatus(.running(description: "Initializing submodules..."))
            let result = await runGitFull(["submodule", "init"])
            if result.succeeded {
                setOperationStatus(.success(message: "Submodules initialized"))
            } else {
                setOperationStatus(.failure(message: "Submodule init failed", detail: result.stderr))
            }
        }
    }

    /// Update all submodules.
    func updateSubmodules(recursive: Bool = true) {
        Task {
            setOperationStatus(.running(description: "Updating submodules..."))
            var args = ["submodule", "update", "--init"]
            if recursive { args.append("--recursive") }

            let result = await runGitFull(args)
            if result.succeeded {
                setOperationStatus(.success(message: "Submodules updated"))
            } else {
                setOperationStatus(.failure(message: "Submodule update failed", detail: result.stderr))
            }
        }
    }

    /// Sync submodule URLs.
    func syncSubmodules() {
        Task {
            setOperationStatus(.running(description: "Syncing submodules..."))
            let result = await runGitFull(["submodule", "sync"])
            if result.succeeded {
                setOperationStatus(.success(message: "Submodules synced"))
            } else {
                setOperationStatus(.failure(message: "Submodule sync failed", detail: result.stderr))
            }
        }
    }
}
