import Foundation

// Note: `DetectedServiceInfo` is defined in SSHControlMaster.swift
// and shared across all backends.

// MARK: - SSH Backend Protocol

/// Abstract interface for SSH backend implementations.
///
/// All SSH operations (command execution, port forwarding, service detection)
/// are performed through this protocol. The current implementation uses the
/// system `/usr/bin/ssh` via `SystemSSHBackend`. Future implementations
/// (e.g. libssh2) can conform to this protocol without changing consumers.
///
/// Usage:
/// ```
/// let backend: any SSHBackend = SystemSSHBackend(host: "server", port: 22, username: "root")
/// await backend.waitForSocket(maxWait: 30)
/// let (exitCode, output) = await backend.exec("uname -a")
/// ```
@MainActor
protocol SSHBackend: AnyObject {

    /// Check if the backend connection is ready.
    var isConnected: Bool { get async }

    /// Wait for the connection to become available.
    /// - Parameter maxWait: Maximum time to wait in seconds.
    /// - Returns: `true` if connection is ready, `false` if timed out.
    func waitForSocket(maxWait: TimeInterval) async -> Bool

    /// Execute a command on the remote server.
    /// - Parameters:
    ///   - command: Shell command to execute.
    ///   - timeout: Maximum execution time in seconds.
    /// - Returns: Tuple of (exit code, stdout output). Exit code -1 indicates timeout or failure.
    func exec(_ command: String, timeout: TimeInterval) async -> (exitCode: Int, stdout: String)

    /// Start local port forwarding.
    /// - Parameters:
    ///   - localPort: Local port to listen on.
    ///   - remoteHost: Remote host to forward to (usually "127.0.0.1").
    ///   - remotePort: Remote port to forward to.
    /// - Returns: `true` if forwarding was established successfully.
    func startPortForward(localPort: UInt16, remoteHost: String, remotePort: UInt16) async -> Bool

    /// Stop a previously established port forward.
    func stopPortForward(localPort: UInt16, remoteHost: String, remotePort: UInt16) async -> Bool

    /// Detect all known services on the remote server.
    func detectAllServices() async -> [DetectedServiceInfo]

    /// Upload a local file to the remote server via SCP.
    /// - Parameters:
    ///   - localPath: Absolute path to the local file.
    ///   - remotePath: Destination path on the remote server.
    /// - Returns: Tuple of (success, error message if failed).
    func uploadFile(localPath: String, remotePath: String) async -> (success: Bool, error: String?)

    /// Download a file from the remote server to local via SCP.
    /// - Parameters:
    ///   - remotePath: Path on the remote server.
    ///   - localPath: Destination path on the local machine.
    /// - Returns: Tuple of (success, error message if failed).
    func downloadFile(remotePath: String, localPath: String) async -> (success: Bool, error: String?)

    /// Clean up and release resources.
    func cleanup()
}

// MARK: - Default Implementations

extension SSHBackend {

    /// Convenience overload with default timeout.
    func exec(_ command: String) async -> (exitCode: Int, stdout: String) {
        await exec(command, timeout: 30)
    }
}
