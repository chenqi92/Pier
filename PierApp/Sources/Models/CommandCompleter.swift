import Foundation

/// Provides command and path auto-completion for the terminal.
actor CommandCompleter {
    /// Cached list of executable command names from $PATH.
    private var commandCache: [String] = []
    private var isLoaded = false

    /// Completion result.
    struct Completion: Identifiable {
        let id = UUID()
        let label: String
        let insertText: String
        let kind: CompletionKind
    }

    enum CompletionKind {
        case command
        case path
        case argument
    }

    // MARK: - Public API

    /// Load available commands from PATH.
    func loadCommands() async {
        guard !isLoaded else { return }
        var commands = Set<String>()

        let pathEnv = ProcessInfo.processInfo.environment["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin:/usr/local/bin"
        let dirs = pathEnv.split(separator: ":").map(String.init)

        for dir in dirs {
            guard let contents = try? FileManager.default.contentsOfDirectory(atPath: dir) else { continue }
            for item in contents {
                let fullPath = (dir as NSString).appendingPathComponent(item)
                if FileManager.default.isExecutableFile(atPath: fullPath) {
                    commands.insert(item)
                }
            }
        }

        commandCache = commands.sorted()
        isLoaded = true
    }

    /// Get completions for the current input line.
    func complete(input: String) async -> [Completion] {
        if !isLoaded { await loadCommands() }

        let trimmed = input.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return [] }

        let parts = trimmed.split(separator: " ", omittingEmptySubsequences: false).map(String.init)

        // Single word → command completion
        if parts.count <= 1 {
            return completeCommand(prefix: trimmed)
        }

        // Last part after first command → path or argument completion
        let lastPart = parts.last ?? ""

        if lastPart.hasPrefix("/") || lastPart.hasPrefix("~") || lastPart.hasPrefix("./") || lastPart.hasPrefix("../") {
            return completePath(partial: lastPart)
        }

        // Check for built-in argument completions
        let command = parts[0]
        if let argCompletions = completeArguments(command: command, prefix: lastPart), !argCompletions.isEmpty {
            return argCompletions
        }

        // Default to path completion
        return completePath(partial: lastPart)
    }

    // MARK: - Command Completion

    private func completeCommand(prefix: String) -> [Completion] {
        let lower = prefix.lowercased()
        return commandCache
            .filter { $0.lowercased().hasPrefix(lower) }
            .prefix(20)
            .map { Completion(label: $0, insertText: $0, kind: .command) }
    }

    // MARK: - Path Completion

    private func completePath(partial: String) -> [Completion] {
        let expanded: String
        if partial.hasPrefix("~") {
            expanded = (partial as NSString).expandingTildeInPath
        } else {
            expanded = partial
        }

        let directory: String
        let prefix: String

        if expanded.hasSuffix("/") {
            directory = expanded
            prefix = ""
        } else {
            directory = (expanded as NSString).deletingLastPathComponent
            prefix = (expanded as NSString).lastPathComponent
        }

        guard let contents = try? FileManager.default.contentsOfDirectory(atPath: directory.isEmpty ? "." : directory) else {
            return []
        }

        let lower = prefix.lowercased()
        return contents
            .filter { lower.isEmpty || $0.lowercased().hasPrefix(lower) }
            .filter { !$0.hasPrefix(".") } // Hide hidden files unless typing .
            .sorted()
            .prefix(20)
            .map { item in
                let fullPath = (directory as NSString).appendingPathComponent(item)
                var isDir: ObjCBool = false
                FileManager.default.fileExists(atPath: fullPath, isDirectory: &isDir)
                let suffix = isDir.boolValue ? "/" : ""
                return Completion(
                    label: item + suffix,
                    insertText: item + suffix,
                    kind: .path
                )
            }
    }

    // MARK: - Argument Completion

    private func completeArguments(command: String, prefix: String) -> [Completion]? {
        let lower = prefix.lowercased()

        let builtinArgs: [String: [String]] = [
            "git": ["add", "commit", "push", "pull", "fetch", "branch", "checkout",
                    "merge", "rebase", "status", "log", "diff", "stash", "clone",
                    "init", "remote", "tag", "reset", "cherry-pick", "blame"],
            "docker": ["run", "build", "ps", "images", "pull", "push", "exec",
                       "logs", "stop", "start", "restart", "rm", "rmi",
                       "compose", "network", "volume", "inspect"],
            "ssh": ["-i", "-p", "-L", "-D", "-N", "-f", "-v", "-o", "-A"],
            "kubectl": ["get", "describe", "apply", "delete", "logs", "exec",
                        "port-forward", "config", "create", "scale"],
            "npm": ["install", "run", "test", "build", "start", "publish", "init",
                    "update", "audit", "cache"],
            "cargo": ["build", "run", "test", "check", "clippy", "fmt", "doc",
                      "publish", "new", "init", "update", "bench"],
        ]

        guard let args = builtinArgs[command] else { return nil }

        return args
            .filter { lower.isEmpty || $0.lowercased().hasPrefix(lower) }
            .map { Completion(label: $0, insertText: $0, kind: .argument) }
    }
}
