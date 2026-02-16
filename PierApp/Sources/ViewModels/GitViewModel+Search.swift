import SwiftUI
import Combine

// MARK: - Commit Detail Data

struct GitCommitDetail {
    let hash: String
    let author: String
    let authorEmail: String
    let date: String
    let message: String
    let changedFiles: [GitCommitFileChange]
    let stats: String
}

struct GitCommitFileChange: Identifiable {
    let path: String
    let status: String
    let additions: Int
    let deletions: Int
    var id: String { path }
}

// MARK: - Search Extension

extension GitViewModel {

    /// Load full commit detail for a specific hash.
    func loadCommitDetail(hash: String) async -> GitCommitDetail? {
        // Get commit metadata + message only (no stat)
        guard let info = await runGit([
            "show", hash, "--format=%H%n%an%n%ae%n%aI%n%B", "--no-patch"
        ]) else {
            return nil
        }

        let lines = info.components(separatedBy: "\n")
        guard lines.count >= 5 else { return nil }

        let fullHash = lines[0]
        let author = lines[1]
        let email = lines[2]
        let dateStr = lines[3]
        let message = lines[4...].joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)

        // Get changed files with --numstat for precise counts
        let changedFiles: [GitCommitFileChange]
        if let numstat = await runGit(["diff-tree", "--no-commit-id", "-r", "--numstat", hash]) {
            changedFiles = numstat.split(separator: "\n").compactMap { line in
                let parts = line.split(separator: "\t", maxSplits: 2)
                guard parts.count >= 3 else { return nil }
                return GitCommitFileChange(
                    path: String(parts[2]),
                    status: "",
                    additions: Int(parts[0]) ?? 0,
                    deletions: Int(parts[1]) ?? 0
                )
            }
        } else {
            changedFiles = []
        }

        // Get shortstat summary separately
        let statsLine: String
        if let statOutput = await runGit(["diff-tree", "--no-commit-id", "--shortstat", hash]) {
            statsLine = statOutput.trimmingCharacters(in: .whitespacesAndNewlines)
        } else {
            statsLine = ""
        }

        return GitCommitDetail(
            hash: fullHash,
            author: author,
            authorEmail: email,
            date: dateStr,
            message: message,
            changedFiles: changedFiles,
            stats: statsLine
        )
    }

    /// Search commit history with optional filters.
    func searchHistory(query: String? = nil, author: String? = nil, since: String? = nil, until: String? = nil) async -> [GitCommit] {
        var args = ["log", "--oneline", "-100", "--format=%H\\t%h\\t%s\\t%an\\t%ar"]

        if let query, !query.isEmpty {
            args += ["--grep=\(query)", "-i"]
        }
        if let author, !author.isEmpty {
            args += ["--author=\(author)"]
        }
        if let since, !since.isEmpty {
            args += ["--since=\(since)"]
        }
        if let until, !until.isEmpty {
            args += ["--until=\(until)"]
        }

        guard let output = await runGit(args) else { return [] }

        return output.split(separator: "\n").compactMap { line in
            let parts = line.split(separator: "\t", maxSplits: 4, omittingEmptySubsequences: false)
            guard parts.count >= 5 else { return nil }
            return GitCommit(
                hash: String(parts[0]),
                shortHash: String(parts[1]),
                message: String(parts[2]),
                author: String(parts[3]),
                date: nil,
                relativeDate: String(parts[4])
            )
        }
    }
}
