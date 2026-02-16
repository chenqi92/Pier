import SwiftUI
import Combine

// MARK: - Data Models

struct RebaseTodoItem: Identifiable {
    let id = UUID()
    let hash: String
    let message: String
    var action: RebaseAction
}

enum RebaseAction: String, CaseIterable {
    case pick = "pick"
    case reword = "reword"
    case squash = "squash"
    case fixup = "fixup"
    case drop = "drop"

    var icon: String {
        switch self {
        case .pick: return "checkmark.circle"
        case .reword: return "pencil.circle"
        case .squash: return "arrow.triangle.merge"
        case .fixup: return "arrow.up.and.down.circle"
        case .drop: return "trash.circle"
        }
    }

    var color: Color {
        switch self {
        case .pick: return .green
        case .reword: return .blue
        case .squash: return .orange
        case .fixup: return .purple
        case .drop: return .red
        }
    }
}

// MARK: - Rebase Extension

extension GitViewModel {

    /// Load commits for interactive rebase planning (last N commits from HEAD).
    func loadRebaseTodoItems(count: Int = 20) async -> [RebaseTodoItem] {
        guard let output = await runGit([
            "log", "--oneline", "-\(count)", "--format=%H\t%s"
        ]) else {
            return []
        }

        return output.split(separator: "\n").compactMap { line in
            let parts = line.split(separator: "\t", maxSplits: 1)
            guard parts.count >= 2 else { return nil }
            return RebaseTodoItem(
                hash: String(parts[0]),
                message: String(parts[1]),
                action: .pick
            )
        }.reversed()  // git log is newest-first; rebase todo needs oldest-first
    }

    /// Execute interactive rebase by writing a todo file and running git rebase.
    func executeRebase(items: [RebaseTodoItem], onto: String) {
        Task {
            // Create a temporary script that outputs our desired todo
            let todoContent = items
                .filter { $0.action != .drop }
                .map { "\($0.action.rawValue) \(String($0.hash.prefix(7))) \($0.message)" }
                .joined(separator: "\n")

            let tempDir = FileManager.default.temporaryDirectory
            let todoScript = tempDir.appendingPathComponent("pier-rebase-todo.sh")
            let todoFile = tempDir.appendingPathComponent("pier-rebase-todo.txt")

            // Write the todo content
            try? todoContent.write(to: todoFile, atomically: true, encoding: .utf8)

            // Write a script that outputs our todo file to replace the editor
            let script = """
            #!/bin/sh
            cat "\(todoFile.path)" > "$1"
            """
            try? script.write(to: todoScript, atomically: true, encoding: .utf8)

            // Make script executable
            _ = await CommandRunner.shared.run("chmod", arguments: ["+x", todoScript.path])

            setOperationStatus(.running(description: "Rebasing..."))

            let result = await CommandRunner.shared.run(
                "git",
                arguments: ["rebase", "-i", onto],
                currentDirectory: repoPath,
                environment: ["GIT_SEQUENCE_EDITOR": todoScript.path]
            )

            // Clean up temp files
            try? FileManager.default.removeItem(at: todoScript)
            try? FileManager.default.removeItem(at: todoFile)

            if result.succeeded {
                setOperationStatus(.success(message: "Rebase completed"))
                await loadHistory()
                await loadBranch()
            } else {
                setOperationStatus(.failure(message: "Rebase failed", detail: result.stderr))
            }
        }
    }

    /// Abort an in-progress rebase.
    func abortRebase() {
        Task {
            let result = await runGitFull(["rebase", "--abort"])
            if result.succeeded {
                setOperationStatus(.success(message: "Rebase aborted"))
                await loadStatus()
            } else {
                setOperationStatus(.failure(message: "Failed to abort rebase", detail: result.stderr))
            }
        }
    }

    /// Continue a paused rebase.
    func continueRebase() {
        Task {
            let result = await runGitFull(["rebase", "--continue"])
            if result.succeeded {
                setOperationStatus(.success(message: "Rebase continued"))
                await loadHistory()
            } else {
                setOperationStatus(.failure(message: "Rebase continue failed", detail: result.stderr))
            }
        }
    }

    /// Check if a rebase is in progress.
    func isRebaseInProgress() async -> Bool {
        let gitDir = (repoPath as NSString).appendingPathComponent(".git/rebase-merge")
        let gitDir2 = (repoPath as NSString).appendingPathComponent(".git/rebase-apply")
        return FileManager.default.fileExists(atPath: gitDir)
            || FileManager.default.fileExists(atPath: gitDir2)
    }
}
