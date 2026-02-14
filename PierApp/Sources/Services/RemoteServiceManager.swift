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
class RemoteServiceManager: ObservableObject, Identifiable {

    let id = UUID()

    // MARK: - Published State

    @Published var isConnected: Bool = false
    @Published var isConnecting: Bool = false
    @Published var isDetecting: Bool = false
    @Published var connectionStatus: String = ""
    @Published var detectedServices: [DetectedService] = []
    @Published var connectedHost: String = ""
    @Published var errorMessage: String?
    @Published var activeTunnels: [ServiceTunnel] = []
    @Published var savedProfiles: [ConnectionProfile] = []
    @Published var savedGroups: [ServerGroup] = []

    /// Persisted right-panel tab selection per terminal tab.
    @Published var lastSelectedPanelMode: RightPanelMode = .markdown

    // MARK: - Private

    /// Opaque handle to the Rust SSH session.
    private var sshHandle: OpaquePointer?
    /// Currently connected profile ID (if any).
    private var currentProfileId: UUID?

    // MARK: - Init

    init() {
        savedProfiles = ConnectionProfile.loadAll()
        savedGroups = ServerGroup.loadAll()
    }

    // MARK: - Connection

    /// Connect using a saved profile.
    /// - Parameters:
    ///   - profile: The connection profile.
    ///   - preloadedPassword: Optional pre-loaded password to avoid extra Keychain access.
    func connect(profile: ConnectionProfile, preloadedPassword: String? = nil, keychainDenied: Bool = false) {
        currentProfileId = profile.id
        if profile.authType == .keyFile, let keyPath = profile.keyFilePath {
            connectWithKey(host: profile.host, port: profile.port, username: profile.username, keyPath: keyPath)
        } else {
            // Use pre-loaded password if provided; skip Keychain if denied earlier
            let password: String
            if let pwd = preloadedPassword {
                password = pwd
            } else if keychainDenied {
                // Keychain was denied — don't attempt SSH with empty password
                // (would block for SSH timeout). Wait for SSH auth success in terminal.
                connectionStatus = ""
                return
            } else {
                password = (try? KeychainService.shared.load(key: "ssh_\(profile.id.uuidString)")) ?? ""
            }
            connect(host: profile.host, port: profile.port, username: profile.username, password: password)
        }
    }

    /// Retry connection with a specific password (e.g. after user typed it in terminal).
    func retryConnect(profile: ConnectionProfile, password: String) {
        // Disconnect any failed / partial connection first
        if sshHandle != nil { disconnect() }
        currentProfileId = profile.id
        connect(host: profile.host, port: profile.port, username: profile.username, password: password)
    }

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
        // Stop all port forwards first
        stopAllTunnels()

        guard let handle = sshHandle else { return }
        pier_ssh_disconnect(handle)
        sshHandle = nil
        isConnected = false
        detectedServices = []
        connectedHost = ""
        connectionStatus = String(localized: "ssh.disconnected")
        currentProfileId = nil
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
                    self.autoEstablishTunnels()
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

    // MARK: - Port Forwarding / Tunnels

    /// Auto-establish tunnels for running services that have default port mappings.
    private func autoEstablishTunnels() {
        guard let handle = sshHandle else { return }

        for service in detectedServices where service.isRunning {
            guard let mapping = ServiceTunnel.defaultMappings[service.name] else { continue }

            let result = "127.0.0.1".withCString { hostC in
                pier_ssh_forward_port(handle, mapping.localPort, hostC, mapping.remotePort)
            }

            if result == 0 {
                let tunnel = ServiceTunnel(
                    serviceName: service.name,
                    localPort: mapping.localPort,
                    remoteHost: "127.0.0.1",
                    remotePort: mapping.remotePort
                )
                activeTunnels.append(tunnel)
            }
        }
    }

    /// Stop all active tunnels.
    func stopAllTunnels() {
        guard let handle = sshHandle else {
            activeTunnels.removeAll()
            return
        }
        for tunnel in activeTunnels {
            pier_ssh_stop_forward(handle, tunnel.localPort)
        }
        activeTunnels.removeAll()
    }

    /// Stop a single tunnel by service name.
    func stopTunnel(for serviceName: String) {
        guard let handle = sshHandle,
              let idx = activeTunnels.firstIndex(where: { $0.serviceName == serviceName }) else { return }
        let tunnel = activeTunnels[idx]
        pier_ssh_stop_forward(handle, tunnel.localPort)
        activeTunnels.remove(at: idx)
    }

    // MARK: - Profile Management

    func saveProfile(_ profile: ConnectionProfile) {
        if let idx = savedProfiles.firstIndex(where: { $0.id == profile.id }) {
            savedProfiles[idx] = profile
        } else {
            savedProfiles.append(profile)
        }
        ConnectionProfile.saveAll(savedProfiles)
    }

    func deleteProfile(_ profile: ConnectionProfile) {
        savedProfiles.removeAll { $0.id == profile.id }
        ConnectionProfile.saveAll(savedProfiles)
        try? KeychainService.shared.delete(key: "ssh_\(profile.id.uuidString)")
    }

    func savePassword(_ password: String, for profile: ConnectionProfile) {
        try? KeychainService.shared.save(key: "ssh_\(profile.id.uuidString)", value: password)
    }

    // MARK: - Group Management

    func saveGroup(_ group: ServerGroup) {
        if let idx = savedGroups.firstIndex(where: { $0.id == group.id }) {
            savedGroups[idx] = group
        } else {
            var g = group
            g.order = savedGroups.count
            savedGroups.append(g)
        }
        ServerGroup.saveAll(savedGroups)
    }

    func deleteGroup(_ group: ServerGroup) {
        // Move all servers in this group to ungrouped
        for i in savedProfiles.indices where savedProfiles[i].groupId == group.id {
            savedProfiles[i].groupId = nil
        }
        ConnectionProfile.saveAll(savedProfiles)
        savedGroups.removeAll { $0.id == group.id }
        ServerGroup.saveAll(savedGroups)
    }

    func moveProfile(_ profile: ConnectionProfile, toGroup groupId: UUID?) {
        if let idx = savedProfiles.firstIndex(where: { $0.id == profile.id }) {
            savedProfiles[idx].groupId = groupId
            ConnectionProfile.saveAll(savedProfiles)
        }
    }

    // MARK: - Remote Execution

    /// Execute a command on the remote server with a timeout.
    ///
    /// Uses a fire-and-forget pattern for the blocking FFI call so the
    /// timeout actually works even when `pier_ssh_exec` blocks indefinitely.
    func exec(_ command: String, timeout: TimeInterval = 30) async -> (exitCode: Int, stdout: String) {
        guard let handle = sshHandle else {
            return (-1, "Not connected")
        }

        return await withCheckedContinuation { continuation in
            let guard_ = ContinuationGuard()

            // Fire-and-forget: blocking FFI runs in a fully detached task.
            // If it finishes after the timeout, the result is simply discarded.
            Task.detached {
                let resultPtr = command.withCString { cmdC in
                    pier_ssh_exec(handle, cmdC)
                }

                guard let resultPtr else {
                    if await guard_.tryResume() {
                        continuation.resume(returning: (-1, "Exec failed"))
                    }
                    return
                }

                let jsonString = String(cString: resultPtr)
                pier_string_free(resultPtr)

                var parsed: (Int, String) = (-1, jsonString)
                if let data = jsonString.data(using: .utf8),
                   let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                    let exitCode: Int
                    if let code = json["exit_code"] as? Int {
                        exitCode = code
                    } else if let codeStr = json["exit_code"] as? String, let code = Int(codeStr) {
                        exitCode = code
                    } else {
                        exitCode = -1
                    }
                    parsed = (exitCode, json["stdout"] as? String ?? "")
                }

                if await guard_.tryResume() {
                    continuation.resume(returning: parsed)
                }
            }

            // Timeout: if FFI hasn't finished, resume with error
            Task {
                try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                if await guard_.tryResume() {
                    continuation.resume(returning: (-1, "Command timed out"))
                }
            }
        }
    }

    // MARK: - Panel Mode Filtering

    /// Available panel modes based on connection status and detected services.
    var availablePanelModes: [RightPanelMode] {
        var modes: [RightPanelMode] = [.markdown, .git]  // Always available (local)

        if isConnected {
            modes.append(.monitor)  // Server monitor always available when connected
            modes.append(.sftp)     // SFTP always available when connected
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

// MARK: - Continuation Guard (thread-safe single-resume)

/// Ensures a `CheckedContinuation` is resumed exactly once when racing
/// a blocking FFI call against a timeout.
private actor ContinuationGuard {
    private var resumed = false

    /// Returns `true` if this is the first call (caller should resume).
    /// Returns `false` if already resumed (caller should discard).
    func tryResume() -> Bool {
        if resumed { return false }
        resumed = true
        return true
    }
}
