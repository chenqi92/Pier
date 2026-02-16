import SwiftUI
import Combine

// MARK: - Data Models

struct GitBranch: Identifiable {
    let name: String
    let isRemote: Bool
    let isCurrent: Bool
    let trackingBranch: String?
    var id: String { (isRemote ? "remote/" : "") + name }
}

// MARK: - Branch Management Extension

extension GitViewModel {

    /// Load all local and remote branches.
    func loadBranches() async -> [GitBranch] {
        guard let output = await runGit(["branch", "-a", "--format=%(HEAD) %(refname:short) %(upstream:short)"]) else {
            return []
        }

        return output.split(separator: "\n").compactMap { line in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            let isCurrent = trimmed.hasPrefix("*")
            let parts = trimmed.dropFirst(isCurrent ? 2 : 0)
                .split(separator: " ", maxSplits: 1)
                .map(String.init)

            guard let name = parts.first else { return nil }

            // Skip HEAD pointer lines like "remotes/origin/HEAD -> origin/main"
            if name.contains("HEAD") { return nil }

            let isRemote = name.hasPrefix("remotes/") || name.hasPrefix("origin/")
            let cleanName = isRemote
                ? name.replacingOccurrences(of: "remotes/", with: "")
                : name
            let tracking = parts.count > 1 ? parts[1] : nil

            return GitBranch(
                name: cleanName,
                isRemote: isRemote,
                isCurrent: isCurrent,
                trackingBranch: tracking
            )
        }
    }

    /// Switch to a different branch.
    func switchBranch(_ name: String) {
        Task {
            let result = await runGitFull(["checkout", name])
            if result.succeeded {
                setOperationStatus(.success(message: String(format: LS("git.switchBranchSuccess"), name)))
                await loadBranch()
                await loadStatus()
            } else {
                setOperationStatus(.failure(message: LS("git.branchOperationFailed"), detail: result.stderr))
            }
        }
    }

    /// Create a new branch from the current HEAD.
    func createBranch(_ name: String, switchTo: Bool = true) {
        Task {
            let args = switchTo ? ["checkout", "-b", name] : ["branch", name]
            let result = await runGitFull(args)
            if result.succeeded {
                setOperationStatus(.success(message: String(format: LS("git.createBranchSuccess"), name)))
                if switchTo { await loadBranch() }
            } else {
                setOperationStatus(.failure(message: LS("git.branchOperationFailed"), detail: result.stderr))
            }
        }
    }

    /// Delete a local branch.
    func deleteBranch(_ name: String, force: Bool = false) {
        Task {
            let flag = force ? "-D" : "-d"
            let result = await runGitFull(["branch", flag, name])
            if result.succeeded {
                setOperationStatus(.success(message: String(format: LS("git.deleteBranchSuccess"), name)))
            } else {
                setOperationStatus(.failure(message: LS("git.branchOperationFailed"), detail: result.stderr))
            }
        }
    }

    /// Merge a branch into the current branch.
    func mergeBranch(_ name: String) {
        Task {
            setOperationStatus(.running(description: "Merging \(name)..."))
            let result = await runGitFull(["merge", name])
            if result.succeeded {
                setOperationStatus(.success(message: String(format: LS("git.mergeBranchSuccess"), name)))
                await loadBranch()
                await loadStatus()
                await loadHistory()
                detectConflicts()
            } else {
                setOperationStatus(.failure(message: LS("git.branchOperationFailed"), detail: result.stderr))
                detectConflicts()
            }
        }
    }
}
