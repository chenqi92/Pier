import Foundation
import CPierCore

/// A service detected on a remote server via SSH.
struct DetectedService: Codable, Identifiable {
    let name: String
    let version: String
    let status: String   // "running" / "stopped" / "installed"
    let port: UInt16

    var id: String { name }

    var isRunning: Bool { status == "running" }
    var isStopped: Bool { status == "stopped" }

    /// Map service name to the corresponding right panel mode.
    var panelMode: RightPanelMode? {
        switch name {
        case "mysql", "postgresql": return .database
        case "redis":               return .redis
        case "docker":              return .docker
        default:                    return nil
        }
    }

    /// SF Symbol icon for the service status.
    var statusIcon: String {
        switch status {
        case "running":   return "circle.fill"
        case "stopped":   return "circle"
        case "installed": return "circle.dashed"
        default:          return "questionmark.circle"
        }
    }

    /// Color name for the service status.
    var statusColorName: String {
        switch status {
        case "running": return "green"
        case "stopped": return "orange"
        default:        return "gray"
        }
    }
}

/// Manages SSH connections and detected remote services.
///
/// When connected to a server, this manager probes for installed services
/// (MySQL, Redis, PostgreSQL, Docker) and publishes the results so the
/// right panel can dynamically show only the available tool tabs.
@MainActor
class RemoteServiceManager: ObservableObject {

    // MARK: - Published State

    @Published var isConnected: Bool = false
    @Published var isConnecting: Bool = false
    @Published var isDetecting: Bool = false
    @Published var connectionStatus: String = ""
    @Published var detectedServices: [DetectedService] = []
    @Published var connectedHost: String = ""
    @Published var errorMessage: String?

    // MARK: - Private

    /// Opaque handle to the Rust SSH session.
    private var sshHandle: OpaquePointer?

    // MARK: - Connection

    /// Connect to a remote server and detect services.
    func connect(host: String, port: UInt16, username: String, password: String) {
        guard !isConnecting else { return }

        isConnecting = true
        connectionStatus = String(localized: "ssh.connecting")
        errorMessage = nil
        detectedServices = []

        Task.detached { [weak self] in
            // SSH connect (blocking in Rust via tokio runtime)
            let handle = host.withCString { hostC in
                username.withCString { userC in
                    password.withCString { passC in
                        pier_ssh_connect(hostC, port, userC, 0, passC)
                    }
                }
            }

            await MainActor.run {
                guard let self else { return }
                if let handle {
                    self.sshHandle = handle
                    self.isConnected = true
                    self.isConnecting = false
                    self.connectedHost = "\(host):\(port)"
                    self.connectionStatus = String(localized: "ssh.connected")
                    self.detectServices()
                } else {
                    self.isConnected = false
                    self.isConnecting = false
                    self.connectionStatus = String(localized: "ssh.disconnected")
                    self.errorMessage = String(localized: "ssh.connectFailed")
                }
            }
        }
    }

    /// Connect using a key file.
    func connectWithKey(host: String, port: UInt16, username: String, keyPath: String) {
        guard !isConnecting else { return }

        isConnecting = true
        connectionStatus = String(localized: "ssh.connecting")
        errorMessage = nil
        detectedServices = []

        Task.detached { [weak self] in
            let handle = host.withCString { hostC in
                username.withCString { userC in
                    keyPath.withCString { keyC in
                        pier_ssh_connect(hostC, port, userC, 1, keyC)
                    }
                }
            }

            await MainActor.run {
                guard let self else { return }
                if let handle {
                    self.sshHandle = handle
                    self.isConnected = true
                    self.isConnecting = false
                    self.connectedHost = "\(host):\(port)"
                    self.connectionStatus = String(localized: "ssh.connected")
                    self.detectServices()
                } else {
                    self.isConnected = false
                    self.isConnecting = false
                    self.connectionStatus = String(localized: "ssh.disconnected")
                    self.errorMessage = String(localized: "ssh.connectFailed")
                }
            }
        }
    }

    /// Disconnect from the remote server.
    func disconnect() {
        guard let handle = sshHandle else { return }

        pier_ssh_disconnect(handle)
        sshHandle = nil
        isConnected = false
        detectedServices = []
        connectedHost = ""
        connectionStatus = String(localized: "ssh.disconnected")
    }

    // MARK: - Service Detection

    /// Probe the remote server for installed services.
    private func detectServices() {
        guard let handle = sshHandle else { return }

        isDetecting = true
        connectionStatus = String(localized: "ssh.detectingServices")

        Task.detached { [weak self] in
            let jsonPtr = pier_ssh_detect_services(handle)

            await MainActor.run {
                guard let self else { return }
                self.isDetecting = false

                guard let jsonPtr else {
                    self.connectionStatus = String(localized: "ssh.connected")
                    return
                }

                let jsonString = String(cString: jsonPtr)
                pier_string_free(jsonPtr)

                if let data = jsonString.data(using: .utf8),
                   let services = try? JSONDecoder().decode([DetectedService].self, from: data) {
                    self.detectedServices = services
                    let runningCount = services.filter(\.isRunning).count
                    self.connectionStatus = String(localized: "ssh.servicesDetected \(services.count) \(runningCount)")
                } else {
                    self.connectionStatus = String(localized: "ssh.connected")
                }
            }
        }
    }

    /// Re-detect services (e.g., after user starts/stops a service).
    func refreshServices() {
        detectServices()
    }

    // MARK: - Remote Execution

    /// Execute a command on the remote server.
    func exec(_ command: String) async -> (exitCode: Int, stdout: String) {
        guard let handle = sshHandle else {
            return (-1, "Not connected")
        }

        return await Task.detached {
            let resultPtr = command.withCString { cmdC in
                pier_ssh_exec(handle, cmdC)
            }

            guard let resultPtr else {
                return (-1, "Exec failed")
            }

            let jsonString = String(cString: resultPtr)
            pier_string_free(resultPtr)

            if let data = jsonString.data(using: .utf8),
               let json = try? JSONDecoder().decode([String: String].self, from: data),
               let exitCodeStr = json["exit_code"],
               let exitCode = Int(exitCodeStr) {
                return (exitCode, json["stdout"] ?? "")
            }

            return (-1, jsonString)
        }.value
    }

    // MARK: - Panel Mode Filtering

    /// Available panel modes based on connection status and detected services.
    var availablePanelModes: [RightPanelMode] {
        var modes: [RightPanelMode] = [.markdown, .git]  // Always available (local)

        if isConnected {
            modes.append(.sftp)  // SFTP always available when connected
            modes.append(.logViewer)  // Log viewer always available when connected

            for service in detectedServices {
                if let mode = service.panelMode, !modes.contains(mode) {
                    modes.append(mode)
                }
            }
        }

        return modes
    }

    // MARK: - Cleanup

    deinit {
        if let handle = sshHandle {
            pier_ssh_disconnect(handle)
        }
    }
}
