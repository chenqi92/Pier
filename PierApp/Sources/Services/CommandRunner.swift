import Foundation

/// Unified, secure command runner for external CLI tools.
///
/// Resolves executable paths once and caches them. Runs processes
/// fully asynchronously using `terminationHandler` to avoid blocking
/// the main thread. Also fixes B5 (MainActor blocking).
actor CommandRunner {

    static let shared = CommandRunner()

    // Cached executable paths
    private var pathCache: [String: String] = [:]

    /// Known search paths for CLI tools on macOS.
    private let searchPaths = [
        "/opt/homebrew/bin",
        "/usr/local/bin",
        "/usr/bin",
        "/bin",
    ]

    // MARK: - Path Resolution

    /// Resolve the absolute path of a CLI tool by name.
    /// Searches common macOS paths and caches the result.
    func resolveExecutable(_ name: String) -> String? {
        if let cached = pathCache[name] {
            return cached
        }

        let fm = FileManager.default
        for dir in searchPaths {
            let fullPath = "\(dir)/\(name)"
            if fm.isExecutableFile(atPath: fullPath) {
                pathCache[name] = fullPath
                return fullPath
            }
        }

        return nil
    }

    // MARK: - Execution

    /// Run a command asynchronously with optional environment variables.
    ///
    /// - Parameters:
    ///   - executable: The tool name (e.g. "docker", "git", "mysql").
    ///   - arguments: Command-line arguments.
    ///   - currentDirectory: Working directory for the process.
    ///   - environment: Additional environment variables (merged with inherited).
    ///   - timeout: Maximum seconds to wait before killing the process (default: 60).
    /// - Returns: A `CommandResult` with stdout, stderr, and exit code.
    func run(
        _ executable: String,
        arguments: [String],
        currentDirectory: String? = nil,
        environment: [String: String]? = nil,
        timeout: TimeInterval = 60
    ) async -> CommandResult {
        guard let path = resolveExecutable(executable) else {
            return CommandResult(
                stdout: "",
                stderr: "\(executable) not found in search paths",
                exitCode: -1
            )
        }

        return await runProcess(
            executablePath: path,
            arguments: arguments,
            currentDirectory: currentDirectory,
            environment: environment,
            timeout: timeout
        )
    }

    /// Run a command at a specific executable path (when path is already known).
    private func runProcess(
        executablePath: String,
        arguments: [String],
        currentDirectory: String?,
        environment: [String: String]?,
        timeout: TimeInterval
    ) async -> CommandResult {
        await withCheckedContinuation { continuation in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: executablePath)
            process.arguments = arguments

            if let dir = currentDirectory {
                process.currentDirectoryURL = URL(fileURLWithPath: dir)
            }

            // Merge additional env vars with inherited environment
            if let env = environment {
                var processEnv = ProcessInfo.processInfo.environment
                for (key, val) in env {
                    processEnv[key] = val
                }
                process.environment = processEnv
            }

            let stdoutPipe = Pipe()
            let stderrPipe = Pipe()
            process.standardOutput = stdoutPipe
            process.standardError = stderrPipe

            // Track whether the continuation has resumed to prevent double-resume
            let resumed = NSLock()
            var hasResumed = false

            // Timeout: kill the process if it runs too long
            let timeoutWork = DispatchWorkItem { [weak process] in
                guard let process, process.isRunning else { return }
                process.terminate()
                // Give a brief moment for SIGTERM, then SIGKILL
                DispatchQueue.global().asyncAfter(deadline: .now() + 2) { [weak process] in
                    guard let process, process.isRunning else { return }
                    process.interrupt() // SIGINT as final fallback
                }
            }
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: timeoutWork)

            // Use terminationHandler for fully async execution (fixes B5)
            process.terminationHandler = { proc in
                timeoutWork.cancel()

                let stdoutData = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
                let stderrData = stderrPipe.fileHandleForReading.readDataToEndOfFile()

                let stdout = String(data: stdoutData, encoding: .utf8)?
                    .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                var stderr = String(data: stderrData, encoding: .utf8)?
                    .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

                // Detect timeout-based termination
                let exitCode = proc.terminationStatus
                if proc.terminationReason == .uncaughtSignal || exitCode == 15 /* SIGTERM */ {
                    stderr = "Process timed out after \(Int(timeout))s and was terminated. " + stderr
                }

                resumed.lock()
                guard !hasResumed else {
                    resumed.unlock()
                    return
                }
                hasResumed = true
                resumed.unlock()

                continuation.resume(returning: CommandResult(
                    stdout: stdout,
                    stderr: stderr,
                    exitCode: exitCode
                ))
            }

            do {
                try process.run()
            } catch {
                timeoutWork.cancel()

                resumed.lock()
                guard !hasResumed else {
                    resumed.unlock()
                    return
                }
                hasResumed = true
                resumed.unlock()

                continuation.resume(returning: CommandResult(
                    stdout: "",
                    stderr: error.localizedDescription,
                    exitCode: -1
                ))
            }
        }
    }
}

// MARK: - Result Type

struct CommandResult: Sendable {
    let stdout: String
    let stderr: String
    let exitCode: Int32

    var succeeded: Bool { exitCode == 0 }

    /// Parse stdout as non-empty trimmed string, or nil.
    var output: String? {
        stdout.isEmpty ? nil : stdout
    }
}
