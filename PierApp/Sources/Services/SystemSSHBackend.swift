import Foundation

/// SSH backend implementation using the system `/usr/bin/ssh` client
/// with ControlMaster multiplexing.
///
/// This is a thin adapter that wraps `SSHControlMaster` and conforms
/// to the `SSHBackend` protocol. All actual SSH operations are delegated
/// to the underlying `SSHControlMaster` instance.
///
/// ## Architecture
///
/// ```
/// RemoteServiceManager → SSHBackend (protocol)
///                           ↓
///                     SystemSSHBackend (this class)
///                           ↓
///                     SSHControlMaster (/usr/bin/ssh)
/// ```
///
/// ## Future Migration
///
/// To switch to libssh2, create a new `LibSSHBackend` conforming to
/// `SSHBackend` and swap it in `RemoteServiceManager.connectViaBackend()`.
@MainActor
final class SystemSSHBackend: SSHBackend {

    private let controlMaster: SSHControlMaster

    /// The underlying host, port, username (exposed for logging/debugging).
    var host: String { controlMaster.host }
    var port: UInt16 { controlMaster.port }
    var username: String { controlMaster.username }

    init(host: String, port: UInt16, username: String) {
        controlMaster = SSHControlMaster(host: host, port: port, username: username)
    }

    // MARK: - SSHBackend Conformance

    var isConnected: Bool {
        get async {
            await controlMaster.isConnected
        }
    }

    func waitForSocket(maxWait: TimeInterval) async -> Bool {
        await controlMaster.waitForSocket(maxWait: maxWait)
    }

    func exec(_ command: String, timeout: TimeInterval) async -> (exitCode: Int, stdout: String) {
        await controlMaster.exec(command, timeout: timeout)
    }

    func startPortForward(localPort: UInt16, remoteHost: String, remotePort: UInt16) async -> Bool {
        await controlMaster.startPortForward(localPort: localPort, remoteHost: remoteHost, remotePort: remotePort)
    }

    func stopPortForward(localPort: UInt16, remoteHost: String, remotePort: UInt16) async -> Bool {
        await controlMaster.stopPortForward(localPort: localPort, remoteHost: remoteHost, remotePort: remotePort)
    }

    func detectAllServices() async -> [DetectedServiceInfo] {
        await controlMaster.detectAllServices()
    }

    func cleanup() {
        controlMaster.cleanup()
    }
}
