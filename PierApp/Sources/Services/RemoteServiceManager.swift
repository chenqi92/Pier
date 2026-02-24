import Foundation

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
/// Uses SSH ControlMaster multiplexing: the terminal PTY establishes the
/// SSH connection with ControlMaster=auto, and this manager piggybacks
/// on the same TCP connection via the control socket to execute commands
/// and detect services.
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

    /// SSH backend for executing commands via the terminal's connection.
    /// Currently uses `SystemSSHBackend` (system /usr/bin/ssh + ControlMaster).
    /// Future: can be swapped to `LibSSHBackend` etc.
    private var backend: (any SSHBackend)?
    /// Currently connected profile ID (if any).
    private var currentProfileId: UUID?
    /// Task that polls for ControlMaster socket readiness.
    private var socketWaitTask: Task<Void, Never>?

    // MARK: - Init

    init() {
        savedProfiles = ConnectionProfile.loadAll()
        savedGroups = ServerGroup.loadAll()
    }

    // MARK: - Connection (via ControlMaster)

    /// Connect using a saved profile.
    /// - Parameters:
    ///   - profile: The connection profile.
    ///   - preloadedPassword: Optional pre-loaded password (unused in new arch, kept for API compat).
    func connect(profile: ConnectionProfile, preloadedPassword: String? = nil, keychainDenied: Bool = false) {
        currentProfileId = profile.id
        connectViaControlMaster(host: profile.host, port: profile.port, username: profile.username)
    }

    /// Retry connection with a specific password (e.g. after user typed it in terminal).
    func retryConnect(profile: ConnectionProfile, password: String) {
        if backend != nil { disconnect() }
        currentProfileId = profile.id
        connectViaControlMaster(host: profile.host, port: profile.port, username: profile.username)
    }

    /// Connect to a remote server by waiting for the ControlMaster socket.
    /// The terminal SSH process creates the socket after successful authentication.
    func connect(host: String, port: UInt16, username: String, password: String = "") {
        connectViaControlMaster(host: host, port: port, username: username)
    }

    /// Connect using a key file (same as connect — the terminal handles auth).
    func connectWithKey(host: String, port: UInt16, username: String, keyPath: String) {
        connectViaControlMaster(host: host, port: port, username: username)
    }

    /// Core connection method: create SSH backend and wait for the connection.
    private func connectViaControlMaster(host: String, port: UInt16, username: String) {
        guard !isConnecting else { return }

        // Cancel any previous wait task
        socketWaitTask?.cancel()

        isConnecting = true
        connectionStatus = String(localized: "ssh.connecting")
        errorMessage = nil
        detectedServices = []

        let sshBackend = SystemSSHBackend(host: host, port: port, username: username)
        backend = sshBackend

        socketWaitTask = Task { [weak self] in
            // Wait up to 60 seconds for the terminal to establish the connection
            let connected = await sshBackend.waitForSocket(maxWait: 60)

            guard !Task.isCancelled else { return }
            guard let self = self else { return }

            if connected {
                self.isConnected = true
                self.isConnecting = false
                self.connectedHost = "\(host):\(port)"
                self.connectionStatus = String(localized: "ssh.connected")
                await self.detectServices()
            } else {
                self.isConnected = false
                self.isConnecting = false
                self.connectionStatus = String(localized: "ssh.disconnected")
                self.errorMessage = String(localized: "ssh.connectFailed")
            }
        }
    }

    /// Disconnect from the remote server.
    func disconnect() {
        socketWaitTask?.cancel()
        socketWaitTask = nil

        // Stop all port forwards
        stopAllTunnels()

        isConnected = false
        detectedServices = []
        connectedHost = ""
        connectionStatus = String(localized: "ssh.disconnected")
        currentProfileId = nil
        // Note: we do NOT call backend.cleanup() — the terminal still owns the SSH connection.
        // The ControlPersist setting keeps the socket alive.
        backend = nil
    }

    // MARK: - Service Detection

    /// Probe the remote server for installed services via ControlMaster.
    private func detectServices() async {
        guard let be = backend else { return }

        isDetecting = true
        connectionStatus = String(localized: "ssh.detectingServices")

        let serviceInfos = await be.detectAllServices()

        guard !Task.isCancelled else { return }

        let services = serviceInfos.map { info in
            DetectedService(name: info.name, version: info.version, status: info.status, port: info.port)
        }

        self.detectedServices = services
        let runningCount = services.filter(\.isRunning).count
        self.connectionStatus = String(localized: "ssh.servicesDetected \(services.count) \(runningCount)")
        self.isDetecting = false

        // Auto-establish port tunnels
        await autoEstablishTunnels()
    }

    /// Re-detect services (e.g., after user starts/stops a service).
    func refreshServices() {
        Task { await detectServices() }
    }

    // MARK: - Port Forwarding (via ControlMaster)

    /// Auto-establish tunnels for running services that have default port mappings.
    private func autoEstablishTunnels() async {
        guard let be = backend else { return }
        let services = detectedServices.filter(\.isRunning)

        for service in services {
            guard let mapping = ServiceTunnel.defaultMappings[service.name] else { continue }

            let success = await be.startPortForward(
                localPort: mapping.localPort,
                remoteHost: "127.0.0.1",
                remotePort: mapping.remotePort
            )

            if success {
                activeTunnels.append(ServiceTunnel(
                    serviceName: service.name,
                    localPort: mapping.localPort,
                    remoteHost: "127.0.0.1",
                    remotePort: mapping.remotePort
                ))
            }
        }
    }

    /// Stop all active tunnels.
    func stopAllTunnels() {
        guard let be = backend else {
            activeTunnels.removeAll()
            return
        }
        for tunnel in activeTunnels {
            Task {
                _ = await be.stopPortForward(
                    localPort: tunnel.localPort,
                    remoteHost: tunnel.remoteHost,
                    remotePort: tunnel.remotePort
                )
            }
        }
        activeTunnels.removeAll()
    }

    /// Stop a single tunnel by service name.
    func stopTunnel(for serviceName: String) {
        guard let be = backend,
              let idx = activeTunnels.firstIndex(where: { $0.serviceName == serviceName }) else { return }
        let tunnel = activeTunnels[idx]
        Task {
            _ = await be.stopPortForward(
                localPort: tunnel.localPort,
                remoteHost: tunnel.remoteHost,
                remotePort: tunnel.remotePort
            )
        }
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

    // MARK: - Remote Execution (via ControlMaster)

    /// Execute a command on the remote server with a timeout.
    func exec(_ command: String, timeout: TimeInterval = 30) async -> (exitCode: Int, stdout: String) {
        guard let be = backend, isConnected else {
            return (-1, "Not connected")
        }
        return await be.exec(command, timeout: timeout)
    }

    /// Upload a local file to the remote server via SCP.
    func uploadFile(localPath: String, remotePath: String, onProgress: (@Sendable (SSHControlMaster.SCPProgress) -> Void)? = nil) async -> (success: Bool, error: String?) {
        guard let be = backend, isConnected else {
            return (false, "Not connected")
        }
        return await be.uploadFile(localPath: localPath, remotePath: remotePath, onProgress: onProgress)
    }

    /// Download a file from the remote server to local via SCP.
    func downloadFile(remotePath: String, localPath: String, onProgress: (@Sendable (SSHControlMaster.SCPProgress) -> Void)? = nil) async -> (success: Bool, error: String?) {
        guard let be = backend, isConnected else {
            return (false, "Not connected")
        }
        return await be.downloadFile(remotePath: remotePath, localPath: localPath, onProgress: onProgress)
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
}
