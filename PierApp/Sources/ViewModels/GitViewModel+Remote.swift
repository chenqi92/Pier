import SwiftUI
import Combine

// MARK: - Data Models

struct GitRemote: Identifiable {
    let name: String
    let fetchURL: String
    let pushURL: String
    var id: String { name }
}

// MARK: - Remote Management Extension

extension GitViewModel {

    /// Load all configured remotes.
    func loadRemotes() async -> [GitRemote] {
        guard let output = await runGit(["remote", "-v"]) else {
            return []
        }

        // Parse: origin  https://github.com/user/repo.git (fetch)
        //        origin  https://github.com/user/repo.git (push)
        var remoteMap: [String: (fetch: String, push: String)] = [:]

        for line in output.split(separator: "\n") {
            let parts = line.split(separator: "\t", maxSplits: 1)
            guard parts.count >= 2 else { continue }
            let name = String(parts[0])
            let rest = String(parts[1])

            if rest.hasSuffix("(fetch)") {
                let url = rest.replacingOccurrences(of: " (fetch)", with: "")
                remoteMap[name, default: (fetch: "", push: "")].fetch = url
            } else if rest.hasSuffix("(push)") {
                let url = rest.replacingOccurrences(of: " (push)", with: "")
                remoteMap[name, default: (fetch: "", push: "")].push = url
            }
        }

        return remoteMap.map { name, urls in
            GitRemote(name: name, fetchURL: urls.fetch, pushURL: urls.push)
        }.sorted { $0.name < $1.name }
    }

    /// Add a new remote.
    func addRemote(_ name: String, url: String) {
        Task {
            let result = await runGitFull(["remote", "add", name, url])
            if result.succeeded {
                setOperationStatus(.success(message: String(format: LS("git.addRemoteSuccess"), name)))
            } else {
                setOperationStatus(.failure(message: LS("git.remoteOperationFailed"), detail: result.stderr))
            }
        }
    }

    /// Remove a remote.
    func removeRemote(_ name: String) {
        Task {
            let result = await runGitFull(["remote", "remove", name])
            if result.succeeded {
                setOperationStatus(.success(message: String(format: LS("git.removeRemoteSuccess"), name)))
            } else {
                setOperationStatus(.failure(message: LS("git.remoteOperationFailed"), detail: result.stderr))
            }
        }
    }

    /// Change the URL for a remote.
    func editRemote(_ name: String, newURL: String) {
        Task {
            let result = await runGitFull(["remote", "set-url", name, newURL])
            if result.succeeded {
                setOperationStatus(.success(message: "Updated remote \(name)"))
            } else {
                setOperationStatus(.failure(message: LS("git.remoteOperationFailed"), detail: result.stderr))
            }
        }
    }

    /// Fetch from a specific remote (or all if name is nil).
    func fetchRemote(_ name: String? = nil) {
        Task {
            setOperationStatus(.running(description: "Fetching..."))
            var args = ["fetch"]
            if let name {
                args.append(name)
            } else {
                args.append("--all")
            }

            let result = await runGitFull(args)
            if result.succeeded {
                setOperationStatus(.success(message: LS("git.fetchSuccess")))
                await loadBranch()
            } else {
                setOperationStatus(.failure(message: LS("git.remoteOperationFailed"), detail: result.stderr))
            }
        }
    }
}
