import Foundation

/// Manages SSH ControlMaster socket lifecycle and command execution.
///
/// Instead of maintaining an independent SSH connection via Rust FFI,
/// this class piggybacks on the terminal's SSH ControlMaster socket
/// to execute commands, detect services, and manage port forwards.
@MainActor
class SSHControlMaster: ObservableObject {

    let host: String
    let port: UInt16
    let username: String

    /// ControlPath pattern — must match the terminal SSH args exactly.
    var socketPath: String {
        "/tmp/pier-ssh-\(username)@\(host):\(port)"
    }

    /// SSH base arguments for multiplexed commands.
    private var sshBaseArgs: [String] {
        [
            "-o", "ControlPath=\(socketPath)",
            "-o", "StrictHostKeyChecking=no",
            "-o", "BatchMode=yes",  // Never prompt for passwords in multiplexed connections
            "-p", "\(port)",
            "\(username)@\(host)",
        ]
    }

    init(host: String, port: UInt16, username: String) {
        self.host = host
        self.port = port
        self.username = username
    }

    // MARK: - Connection Check

    /// Check if the ControlMaster socket is alive.
    var isConnected: Bool {
        get async {
            // Quick check: does the socket file exist?
            guard FileManager.default.fileExists(atPath: socketPath) else {
                return false
            }
            // Verify the socket is actually functional
            let args = [
                "-o", "ControlPath=\(socketPath)",
                "-O", "check",
                "-p", "\(port)",
                "\(username)@\(host)",
            ]
            let (exitCode, _) = await runProcess("/usr/bin/ssh", arguments: args, timeout: 5)
            return exitCode == 0
        }
    }

    /// Wait for the ControlMaster socket to become available.
    /// The terminal SSH process creates the socket after successful authentication.
    ///
    /// If the socket doesn't appear within `spawnDelay`, this method will attempt to
    /// create a ControlMaster connection independently (for manually-typed SSH commands
    /// that don't include ControlMaster options).
    ///
    /// - Parameters:
    ///   - maxWait: Maximum time to wait in seconds
    ///   - checkInterval: Time between checks in seconds
    ///   - spawnDelay: Seconds to wait before attempting to spawn our own ControlMaster
    /// - Returns: true if socket became available, false if timed out
    func waitForSocket(maxWait: TimeInterval = 60, checkInterval: TimeInterval = 0.5, spawnDelay: TimeInterval = 5) async -> Bool {
        let deadline = Date().addingTimeInterval(maxWait)
        let spawnAfter = Date().addingTimeInterval(spawnDelay)
        var didSpawn = false

        while Date() < deadline {
            if await isConnected {
                return true
            }

            // If socket hasn't appeared after spawnDelay, try to create it ourselves.
            // This handles the case where the user typed `ssh` manually without ControlMaster args.
            if !didSpawn && Date() >= spawnAfter {
                didSpawn = true
                spawnControlMaster()
            }

            try? await Task.sleep(nanoseconds: UInt64(checkInterval * 1_000_000_000))
        }

        return false
    }

    /// Spawn a background SSH process to create a ControlMaster socket.
    /// Uses `-N -f` to fork into the background without executing a remote command.
    /// Requires passwordless auth (SSH keys or agent) since `-o BatchMode=yes` is set.
    private func spawnControlMaster() {
        let args = [
            "-o", "ControlMaster=auto",
            "-o", "ControlPath=\(socketPath)",
            "-o", "ControlPersist=600",
            "-o", "StrictHostKeyChecking=no",
            "-o", "BatchMode=yes",
            "-o", "ConnectTimeout=10",
            "-p", "\(port)",
            "-N", "-f",  // No command, fork to background
            "\(username)@\(host)",
        ]
        print("[SSHControlMaster] Spawning background ControlMaster: ssh \(args.joined(separator: " "))")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
        process.arguments = args
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try? process.run()
        // Process runs async in the background — we don't wait for it.
        // The socket will appear when SSH connects successfully.
    }

    // MARK: - Command Execution

    /// Execute a remote command via the ControlMaster socket.
    /// - Parameters:
    ///   - command: Shell command to execute on the remote server
    ///   - timeout: Maximum execution time in seconds
    /// - Returns: Tuple of (exit code, stdout output)
    func exec(_ command: String, timeout: TimeInterval = 30) async -> (exitCode: Int, stdout: String) {
        var args = sshBaseArgs
        args.append(command)

        return await runProcess("/usr/bin/ssh", arguments: args, timeout: timeout)
    }

    // MARK: - Port Forwarding

    /// Start local port forwarding via the ControlMaster connection.
    /// Uses `ssh -O forward` to dynamically add a forward to the existing master.
    func startPortForward(localPort: UInt16, remoteHost: String, remotePort: UInt16) async -> Bool {
        let args = [
            "-o", "ControlPath=\(socketPath)",
            "-O", "forward",
            "-L", "\(localPort):\(remoteHost):\(remotePort)",
            "-p", "\(port)",
            "\(username)@\(host)",
        ]
        let (exitCode, _) = await runProcess("/usr/bin/ssh", arguments: args, timeout: 10)
        if exitCode == 0 {
            print("[SSHControlMaster] Port forward started: 127.0.0.1:\(localPort) → \(remoteHost):\(remotePort)")
        }
        return exitCode == 0
    }

    /// Stop a local port forward.
    func stopPortForward(localPort: UInt16, remoteHost: String, remotePort: UInt16) async -> Bool {
        let args = [
            "-o", "ControlPath=\(socketPath)",
            "-O", "cancel",
            "-L", "\(localPort):\(remoteHost):\(remotePort)",
            "-p", "\(port)",
            "\(username)@\(host)",
        ]
        let (exitCode, _) = await runProcess("/usr/bin/ssh", arguments: args, timeout: 10)
        return exitCode == 0
    }

    // MARK: - File Transfer (SCP via ControlMaster)

    /// SCP progress info parsed from stderr output.
    struct SCPProgress {
        let percent: Int
        let speed: String      // e.g. "1.2MB/s"
        let eta: String         // e.g. "00:05"
    }

    /// Upload a local file to the remote server via scp with progress reporting.
    func uploadFile(
        localPath: String,
        remotePath: String,
        onProgress: (@Sendable (SCPProgress) -> Void)? = nil
    ) async -> (success: Bool, error: String?) {
        let escapedRemote = remotePath.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: " ", with: "\\ ")
        let args = [
            "-o", "ControlPath=\(socketPath)",
            "-o", "StrictHostKeyChecking=no",
            "-o", "BatchMode=yes",
            "-P", "\(port)",
            "-r",
            localPath,
            "\(username)@\(host):\(escapedRemote)",
        ]
        return await runSCPWithProgress("/usr/bin/scp", arguments: args, timeout: 300, onProgress: onProgress)
    }

    /// Download a file from the remote server to local via scp with progress reporting.
    func downloadFile(
        remotePath: String,
        localPath: String,
        onProgress: (@Sendable (SCPProgress) -> Void)? = nil
    ) async -> (success: Bool, error: String?) {
        let escapedRemote = remotePath.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: " ", with: "\\ ")
        let args = [
            "-o", "ControlPath=\(socketPath)",
            "-o", "StrictHostKeyChecking=no",
            "-o", "BatchMode=yes",
            "-P", "\(port)",
            "-r",
            "\(username)@\(host):\(escapedRemote)",
            localPath,
        ]
        return await runSCPWithProgress("/usr/bin/scp", arguments: args, timeout: 300, onProgress: onProgress)
    }

    /// Run SCP process with real-time stderr progress parsing.
    /// SCP outputs progress to stderr in format: `filename  XX%  XXXKB  XXX.XKB/s  XX:XX\r`
    private func runSCPWithProgress(
        _ executablePath: String,
        arguments: [String],
        timeout: TimeInterval,
        onProgress: (@Sendable (SCPProgress) -> Void)?
    ) async -> (success: Bool, error: String?) {
        await withCheckedContinuation { continuation in
            let guard_ = SingleResumeContinuationGuard()

            let process = Process()
            process.executableURL = URL(fileURLWithPath: executablePath)
            process.arguments = arguments

            let stdoutPipe = Pipe()
            let stderrPipe = Pipe()
            process.standardOutput = stdoutPipe
            process.standardError = stderrPipe

            // Stream stderr to parse progress in real time
            var stderrBuffer = ""
            if onProgress != nil {
                stderrPipe.fileHandleForReading.readabilityHandler = { handle in
                    let data = handle.availableData
                    guard !data.isEmpty else { return }
                    guard let chunk = String(data: data, encoding: .utf8) else { return }
                    stderrBuffer += chunk

                    // SCP uses \r to overwrite progress lines.
                    // Split on \r to get the latest progress update.
                    let parts = stderrBuffer.split(separator: "\r", omittingEmptySubsequences: true)
                    if let lastLine = parts.last {
                        if let progress = Self.parseSCPProgress(String(lastLine)) {
                            onProgress?(progress)
                        }
                    }
                    // Keep only the last part (incomplete line) in buffer
                    if stderrBuffer.hasSuffix("\r") || stderrBuffer.hasSuffix("\n") {
                        stderrBuffer = ""
                    } else if let last = parts.last {
                        stderrBuffer = String(last)
                    }
                }
            }

            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    try process.run()
                } catch {
                    stderrPipe.fileHandleForReading.readabilityHandler = nil
                    Task { @MainActor in
                        if guard_.tryResume() {
                            continuation.resume(returning: (false, "Failed to launch: \(error.localizedDescription)"))
                        }
                    }
                    return
                }

                // Read stdout concurrently (in case scp writes anything)
                var stdoutData = Data()
                let readGroup = DispatchGroup()
                readGroup.enter()
                DispatchQueue.global(qos: .userInitiated).async {
                    stdoutData = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
                    readGroup.leave()
                }

                // If no progress handler, also read stderr concurrently
                var stderrData = Data()
                if onProgress == nil {
                    readGroup.enter()
                    DispatchQueue.global(qos: .userInitiated).async {
                        stderrData = stderrPipe.fileHandleForReading.readDataToEndOfFile()
                        readGroup.leave()
                    }
                }

                readGroup.wait()
                process.waitUntilExit()

                // Clean up handler
                stderrPipe.fileHandleForReading.readabilityHandler = nil

                // If using progress handler, read remaining stderr
                if onProgress != nil {
                    stderrData = stderrPipe.fileHandleForReading.availableData
                }

                let exitCode = Int(process.terminationStatus)
                let stdoutStr = String(data: stdoutData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                let stderrStr = String(data: stderrData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? stderrBuffer

                Task { @MainActor in
                    if guard_.tryResume() {
                        if exitCode == 0 {
                            continuation.resume(returning: (true, nil))
                        } else {
                            let errorMsg = stderrStr.isEmpty ? stdoutStr : stderrStr
                            continuation.resume(returning: (false, errorMsg.isEmpty ? "SCP failed with exit code \(exitCode)" : errorMsg))
                        }
                    }
                }
            }

            // Timeout
            Task {
                try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                if guard_.tryResume() {
                    if process.isRunning { process.terminate() }
                    stderrPipe.fileHandleForReading.readabilityHandler = nil
                    continuation.resume(returning: (false, "Transfer timed out after \(Int(timeout))s"))
                }
            }
        }
    }

    /// Parse SCP progress line.
    /// Format: `filename                          XX%  XXXKB  XXX.XKB/s  XX:XX`
    nonisolated static func parseSCPProgress(_ line: String) -> SCPProgress? {
        // Match pattern:  XX%  (size)  (speed)  (eta)
        // Example: "test.zip     42%  128KB  1.2MB/s   00:03"
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        // Use regex to find: percentage, speed, ETA
        // SCP format: <filename> <spaces> <percent>% <size> <speed> <eta>
        let pattern = #"(\d{1,3})%\s+[\d.]+\w+\s+([\d.]+\w+/s)\s+(\d+:\d+|--:--)"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: trimmed, range: NSRange(trimmed.startIndex..., in: trimmed)) else {
            return nil
        }

        let percentStr = String(trimmed[Range(match.range(at: 1), in: trimmed)!])
        let speed = String(trimmed[Range(match.range(at: 2), in: trimmed)!])
        let eta = String(trimmed[Range(match.range(at: 3), in: trimmed)!])

        guard let percent = Int(percentStr) else { return nil }
        return SCPProgress(percent: percent, speed: speed, eta: eta)
    }

    // MARK: - Cleanup

    /// Gracefully close the ControlMaster connection.
    func cleanup() {
        let args = [
            "-o", "ControlPath=\(socketPath)",
            "-O", "exit",
            "-p", "\(port)",
            "\(username)@\(host)",
        ]
        // Fire and forget — don't block on cleanup
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
        process.arguments = args
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try? process.run()
    }

    // MARK: - Private

    /// Run a subprocess and capture its output.
    private func runProcess(
        _ executablePath: String,
        arguments: [String],
        timeout: TimeInterval
    ) async -> (exitCode: Int, stdout: String) {
        await withCheckedContinuation { continuation in
            let guard_ = SingleResumeContinuationGuard()

            let process = Process()
            process.executableURL = URL(fileURLWithPath: executablePath)
            process.arguments = arguments

            let stdoutPipe = Pipe()
            let stderrPipe = Pipe()
            process.standardOutput = stdoutPipe
            process.standardError = stderrPipe

            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    try process.run()
                } catch {
                    Task { @MainActor in
                        if guard_.tryResume() {
                            continuation.resume(returning: (-1, "Failed to launch: \(error.localizedDescription)"))
                        }
                    }
                    return
                }

                // CRITICAL: Read stdout/stderr CONCURRENTLY and BEFORE waitUntilExit().
                // macOS pipe buffer is only 64KB. If the process output exceeds this,
                // the process blocks on write, and waitUntilExit() would deadlock.
                var stdoutData = Data()
                var stderrData = Data()
                let readGroup = DispatchGroup()

                readGroup.enter()
                DispatchQueue.global(qos: .userInitiated).async {
                    stdoutData = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
                    readGroup.leave()
                }
                readGroup.enter()
                DispatchQueue.global(qos: .userInitiated).async {
                    stderrData = stderrPipe.fileHandleForReading.readDataToEndOfFile()
                    readGroup.leave()
                }

                // Wait for both reads to complete (they finish when process closes pipes)
                readGroup.wait()
                process.waitUntilExit()

                let stdoutStr = String(data: stdoutData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                let stderrStr = String(data: stderrData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                let exitCode = Int(process.terminationStatus)
                let output = stdoutStr.isEmpty ? stderrStr : (exitCode != 0 && !stderrStr.isEmpty ? stdoutStr + "\n" + stderrStr : stdoutStr)

                Task { @MainActor in
                    if guard_.tryResume() {
                        continuation.resume(returning: (exitCode, output))
                    }
                }
            }

            // Timeout — kill the process if it exceeds the limit
            Task {
                try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                if guard_.tryResume() {
                    // Terminate the hung process
                    if process.isRunning {
                        process.terminate()
                    }
                    // Read any partial output collected before timeout
                    let partialData = stdoutPipe.fileHandleForReading.availableData
                    let partialOutput = String(data: partialData, encoding: .utf8)?
                        .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                    continuation.resume(returning: (-1, partialOutput))
                }
            }
        }
    }
}

// MARK: - Service Detection (migrated from Rust service_detector.rs)

extension SSHControlMaster {

    /// Detect all known services on the remote server.
    func detectAllServices() async -> [DetectedServiceInfo] {
        async let mysql = detectMySQL()
        async let redis = detectRedis()
        async let docker = detectDocker()
        async let postgres = detectPostgreSQL()

        var services: [DetectedServiceInfo] = []
        if let s = await mysql { services.append(s) }
        if let s = await redis { services.append(s) }
        if let s = await docker { services.append(s) }
        if let s = await postgres { services.append(s) }

        return services
    }

    private func detectMySQL() async -> DetectedServiceInfo? {
        // First try native mysql CLI on the host
        let (code, _) = await exec("which mysql 2>/dev/null || which mysqld 2>/dev/null", timeout: 10)

        if code == 0 {
            // Native mysql found
            let (_, versionOut) = await exec("mysql --version 2>/dev/null", timeout: 10)
            let version = Self.parseVersion(versionOut)

            let status = await checkServiceStatus([
                "systemctl is-active mysql 2>/dev/null || systemctl is-active mysqld 2>/dev/null || systemctl is-active mariadb 2>/dev/null",
                "pgrep -x mysqld >/dev/null 2>&1 && echo active",
            ])

            return DetectedServiceInfo(name: "mysql", version: version, status: status, port: 3306)
        }

        // Fallback: check for MySQL running in Docker containers
        let (dockerCode, dockerOut) = await exec(
            "docker ps --filter 'ancestor=mysql' --filter 'ancestor=mariadb' --format '{{.ID}}|{{.Image}}|{{.Ports}}' 2>/dev/null || " +
            "docker ps --format '{{.ID}}|{{.Image}}|{{.Ports}}' 2>/dev/null | grep -i mysql",
            timeout: 15
        )
        guard dockerCode == 0, !dockerOut.isEmpty else { return nil }

        // Parse the first matching container
        let firstLine = dockerOut.components(separatedBy: "\n").first ?? ""
        let parts = firstLine.components(separatedBy: "|")
        guard parts.count >= 2 else { return nil }

        let containerId = parts[0].trimmingCharacters(in: .whitespaces)
        let image = parts[1].trimmingCharacters(in: .whitespaces)

        // Get version from container
        let (_, versionOut) = await exec("docker exec \(containerId) mysql --version 2>/dev/null", timeout: 10)
        let version = versionOut.isEmpty ? Self.parseVersion(image) : Self.parseVersion(versionOut)

        // Parse exposed port (e.g., "0.0.0.0:3306->3306/tcp")
        var mysqlPort: UInt16 = 3306
        if parts.count >= 3 {
            let portsStr = parts[2]
            // Match patterns like "0.0.0.0:3306->3306/tcp" or ":::3306->3306/tcp"
            if let range = portsStr.range(of: #"(\d+)->3306"#, options: .regularExpression) {
                let portStr = portsStr[range].components(separatedBy: "->").first ?? ""
                if let p = UInt16(portStr) { mysqlPort = p }
            }
        }

        return DetectedServiceInfo(name: "mysql", version: version, status: "running", port: mysqlPort)
    }

    private func detectRedis() async -> DetectedServiceInfo? {
        let (code, _) = await exec("which redis-server 2>/dev/null || which redis-cli 2>/dev/null", timeout: 10)
        guard code == 0 else { return nil }

        let (_, versionOut) = await exec("redis-cli --version 2>/dev/null", timeout: 10)
        let version = Self.parseVersion(versionOut)

        let (pingCode, pingOut) = await exec("redis-cli ping 2>/dev/null", timeout: 10)
        let status: String
        if pingCode == 0 && pingOut.contains("PONG") {
            status = "running"
        } else {
            status = await checkServiceStatus([
                "systemctl is-active redis 2>/dev/null || systemctl is-active redis-server 2>/dev/null",
                "pgrep -x redis-server >/dev/null 2>&1 && echo active",
            ])
        }

        return DetectedServiceInfo(name: "redis", version: version, status: status, port: 6379)
    }

    private func detectDocker() async -> DetectedServiceInfo? {
        let (code, _) = await exec("which docker 2>/dev/null", timeout: 10)
        guard code == 0 else { return nil }

        let (_, versionOut) = await exec("docker --version 2>/dev/null", timeout: 10)
        let version = Self.parseVersion(versionOut)

        let (infoCode, _) = await exec("docker info >/dev/null 2>&1", timeout: 15)
        let status: String
        if infoCode == 0 {
            status = "running"
        } else {
            status = await checkServiceStatus(["systemctl is-active docker 2>/dev/null"])
        }

        return DetectedServiceInfo(name: "docker", version: version, status: status, port: 0)
    }

    private func detectPostgreSQL() async -> DetectedServiceInfo? {
        let (code, _) = await exec("which psql 2>/dev/null", timeout: 10)
        guard code == 0 else { return nil }

        let (_, versionOut) = await exec("psql --version 2>/dev/null", timeout: 10)
        let version = Self.parseVersion(versionOut)

        let status = await checkServiceStatus([
            "systemctl is-active postgresql 2>/dev/null",
            "pgrep -x postgres >/dev/null 2>&1 && echo active",
        ])

        return DetectedServiceInfo(name: "postgresql", version: version, status: status, port: 5432)
    }

    private func checkServiceStatus(_ commands: [String]) async -> String {
        for cmd in commands {
            let (code, output) = await exec(cmd, timeout: 10)
            if code == 0 && output.contains("active") {
                return "running"
            }
        }
        return "stopped"
    }

    /// Extract version string from command output (e.g. "8.0.35" from "mysql Ver 8.0.35 ...").
    static func parseVersion(_ output: String) -> String {
        for word in output.split(separator: " ") {
            let trimmed = word.trimmingCharacters(in: CharacterSet(charactersIn: ",;"))
            if let first = trimmed.first, first.isNumber, trimmed.contains(".") {
                return trimmed
            }
        }
        return output.components(separatedBy: "\n").first ?? "unknown"
    }
}

/// Lightweight service info returned by SSHControlMaster detection.
/// Maps directly to the existing `DetectedService` struct used by the UI.
struct DetectedServiceInfo: Identifiable {
    var id: String { "\(name)_\(port)" }
    let name: String
    let version: String
    let status: String   // "running" / "stopped"
    let port: UInt16

    var isRunning: Bool { status == "running" || status == "active" }
}

/// Thread-safe single-resume guard for continuations.
/// Ensures a `CheckedContinuation` is resumed exactly once when racing
/// a blocking call against a timeout.
private final class SingleResumeContinuationGuard: @unchecked Sendable {
    private let lock = NSLock()
    private var resumed = false

    func tryResume() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if resumed { return false }
        resumed = true
        return true
    }
}
