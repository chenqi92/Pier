import SwiftUI
import Combine

// MARK: - Data Models

struct GitTag: Identifiable {
    let name: String
    let hash: String
    let message: String?
    var id: String { name }
}

// MARK: - Tag Management Extension

extension GitViewModel {

    /// Load all tags.
    func loadTags() async -> [GitTag] {
        guard let output = await runGit([
            "tag", "-l", "--format=%(refname:short)\t%(objectname:short)\t%(subject)"
        ]) else {
            return []
        }

        return output.split(separator: "\n").compactMap { line in
            let parts = line.split(separator: "\t", maxSplits: 2, omittingEmptySubsequences: false).map(String.init)
            guard parts.count >= 2 else { return nil }
            return GitTag(
                name: parts[0],
                hash: parts[1],
                message: parts.count > 2 && !parts[2].isEmpty ? parts[2] : nil
            )
        }
    }

    /// Create a new tag at HEAD.
    func createTag(_ name: String, message: String? = nil) {
        Task {
            var args = ["tag"]
            if let message, !message.isEmpty {
                args += ["-a", name, "-m", message]
            } else {
                args.append(name)
            }

            let result = await runGitFull(args)
            if result.succeeded {
                setOperationStatus(.success(message: String(format: LS("git.createTagSuccess"), name)))
            } else {
                setOperationStatus(.failure(message: LS("git.tagOperationFailed"), detail: result.stderr))
            }
        }
    }

    /// Delete a tag locally.
    func deleteTag(_ name: String) {
        Task {
            let result = await runGitFull(["tag", "-d", name])
            if result.succeeded {
                setOperationStatus(.success(message: String(format: LS("git.deleteTagSuccess"), name)))
            } else {
                setOperationStatus(.failure(message: LS("git.tagOperationFailed"), detail: result.stderr))
            }
        }
    }

    /// Push a tag to origin.
    func pushTag(_ name: String) {
        Task {
            setOperationStatus(.running(description: "Pushing tag \(name)..."))
            let result = await runGitFull(["push", "origin", name])
            if result.succeeded {
                setOperationStatus(.success(message: String(format: LS("git.pushTagSuccess"), name)))
            } else {
                setOperationStatus(.failure(message: LS("git.tagOperationFailed"), detail: result.stderr))
            }
        }
    }
}
