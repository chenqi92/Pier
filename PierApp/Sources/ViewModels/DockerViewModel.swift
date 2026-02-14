import SwiftUI
import Combine

enum DockerTab {
    case containers, images, volumes, compose, networks
}

// MARK: - Data Models

struct DockerContainer: Identifiable {
    let id: String
    let name: String
    let image: String
    let status: String
    let isRunning: Bool
    let ports: String
    let created: Date?
}

struct DockerImage: Identifiable {
    let id: String
    let repository: String
    let tag: String
    let size: UInt64
    let created: Date?

    var formattedSize: String {
        ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file)
    }
}

struct DockerVolume: Identifiable {
    var id: String { name }
    let name: String
    let driver: String
    let mountpoint: String
}

struct ContainerStats: Identifiable {
    let containerId: String
    let name: String
    let cpuPercent: String      // e.g. "12.34%"
    let memoryUsage: String     // e.g. "256MiB / 1GiB"
    let memoryPercent: String   // e.g. "25.00%"
    let networkIO: String       // e.g. "1.5kB / 3.2kB"
    let blockIO: String         // e.g. "0B / 0B"

    var id: String { containerId }

    /// CPU percentage as a double (0.0 - 100.0).
    var cpuValue: Double {
        Double(cpuPercent.replacingOccurrences(of: "%", with: "")) ?? 0
    }

    /// Memory percentage as a double (0.0 - 100.0).
    var memoryValue: Double {
        Double(memoryPercent.replacingOccurrences(of: "%", with: "")) ?? 0
    }
}

struct DockerNetwork: Identifiable {
    let id: String
    let name: String
    let driver: String
    let scope: String
}

// MARK: - ViewModel

@MainActor
class DockerViewModel: ObservableObject {
    @Published var selectedTab: DockerTab = .containers
    @Published var containers: [DockerContainer] = []
    @Published var images: [DockerImage] = []
    @Published var volumes: [DockerVolume] = []
    @Published var isDockerAvailable = false
    @Published var isLoading = false
    @Published var containerLogs: String = ""
    @Published var isRemoteMode = false

    // Docker Compose
    @Published var composeServices: [ComposeService] = []
    @Published var composeFilePath: String?
    @Published var isComposeAvailable = false

    // Resource monitoring
    @Published var containerStats: [String: ContainerStats] = [:]  // keyed by container ID

    // Networks
    @Published var networks: [DockerNetwork] = []

    private var timer: AnyCancellable?
    private var statsTimer: AnyCancellable?

    /// Optional reference to RemoteServiceManager for SSH exec.
    weak var serviceManager: RemoteServiceManager?

    init() {
        checkDockerAvailability()
    }

    /// Convenience init with service manager for remote Docker support.
    convenience init(serviceManager: RemoteServiceManager) {
        self.init()
        self.serviceManager = serviceManager
        self.isRemoteMode = serviceManager.isConnected
    }

    deinit {
        timer?.cancel()
        statsTimer?.cancel()
    }

    func checkDockerAvailability() {
        Task {
            isLoading = true
            let available = await runDockerCommand(["info", "--format", "{{.ServerVersion}}"])
            isDockerAvailable = available != nil
            if isDockerAvailable {
                await loadAll()
            }
            isLoading = false
        }
    }

    func refresh() {
        Task {
            isLoading = true
            await loadAll()
            isLoading = false
        }
    }

    private func loadAll() async {
        await loadContainers()
        await loadImages()
        await loadVolumes()
        await detectComposeFile()
    }

    // MARK: - Containers

    private func loadContainers() async {
        guard let output = await runDockerCommand([
            "ps", "-a", "--format",
            "{{.ID}}|||{{.Names}}|||{{.Image}}|||{{.Status}}|||{{.State}}|||{{.Ports}}"
        ]) else { return }

        containers = output.split(separator: "\n").compactMap { line in
            let parts = String(line).components(separatedBy: "|||")
            guard parts.count >= 5 else { return nil }
            return DockerContainer(
                id: parts[0].trimmingCharacters(in: .whitespaces),
                name: parts[1].trimmingCharacters(in: .whitespaces),
                image: parts[2].trimmingCharacters(in: .whitespaces),
                status: parts[3].trimmingCharacters(in: .whitespaces),
                isRunning: parts[4].trimmingCharacters(in: .whitespaces) == "running",
                ports: parts.count > 5 ? parts[5].trimmingCharacters(in: .whitespaces) : "",
                created: nil
            )
        }
    }

    func startContainer(_ id: String) {
        Task {
            _ = await runDockerCommand(["start", id])
            await loadContainers()
        }
    }

    func stopContainer(_ id: String) {
        Task {
            _ = await runDockerCommand(["stop", id])
            await loadContainers()
        }
    }

    func restartContainer(_ id: String) {
        Task {
            _ = await runDockerCommand(["restart", id])
            await loadContainers()
        }
    }

    func removeContainer(_ id: String) {
        Task {
            _ = await runDockerCommand(["rm", "-f", id])
            await loadContainers()
        }
    }

    func viewContainerLogs(_ id: String) {
        Task {
            if let logs = await runDockerCommand(["logs", "--tail", "500", id]) {
                containerLogs = logs
                NotificationCenter.default.post(
                    name: .dockerContainerLogs,
                    object: ["id": id, "logs": logs]
                )
            }
        }
    }

    // MARK: - Images

    private func loadImages() async {
        guard let output = await runDockerCommand([
            "images", "--format",
            "{{.ID}}|||{{.Repository}}|||{{.Tag}}|||{{.Size}}"
        ]) else { return }

        images = output.split(separator: "\n").compactMap { line in
            let parts = String(line).components(separatedBy: "|||")
            guard parts.count >= 4 else { return nil }
            return DockerImage(
                id: parts[0].trimmingCharacters(in: .whitespaces),
                repository: parts[1].trimmingCharacters(in: .whitespaces),
                tag: parts[2].trimmingCharacters(in: .whitespaces),
                size: parseDockerSize(parts[3].trimmingCharacters(in: .whitespaces)),
                created: nil
            )
        }
    }

    func runImage(_ id: String) {
        Task {
            _ = await runDockerCommand(["run", "-d", id])
            await loadContainers()
        }
    }

    func removeImage(_ id: String) {
        Task {
            _ = await runDockerCommand(["rmi", id])
            await loadImages()
        }
    }

    /// Force remove an image (even if referenced by containers).
    func forceRemoveImage(_ id: String) {
        Task {
            _ = await runDockerCommand(["rmi", "-f", id])
            await loadImages()
        }
    }

    /// Inspect a Docker image.
    func inspectImage(_ id: String) async -> String? {
        await runDockerCommand(["inspect", id])
    }

    /// Tag an image with a new name.
    func tagImage(_ id: String, newTag: String) {
        Task {
            _ = await runDockerCommand(["tag", id, newTag])
            await loadImages()
        }
    }

    /// Pull an image from registry.
    func pullImage(_ name: String) {
        Task {
            isLoading = true
            _ = await runDockerCommand(["pull", name])
            await loadImages()
            isLoading = false
        }
    }

    /// Show image layer history.
    func imageHistory(_ id: String) async -> String? {
        await runDockerCommand(["history", "--no-trunc", id])
    }

    /// Prune all unused (dangling) images.
    func pruneImages() {
        Task {
            isLoading = true
            _ = await runDockerCommand(["image", "prune", "-f"])
            await loadImages()
            isLoading = false
        }
    }

    // MARK: - Volumes

    private func loadVolumes() async {
        guard let output = await runDockerCommand([
            "volume", "ls", "--format",
            "{{.Name}}|||{{.Driver}}|||{{.Mountpoint}}"
        ]) else { return }

        volumes = output.split(separator: "\n").compactMap { line in
            let parts = String(line).components(separatedBy: "|||")
            guard parts.count >= 2 else { return nil }
            return DockerVolume(
                name: parts[0].trimmingCharacters(in: .whitespaces),
                driver: parts[1].trimmingCharacters(in: .whitespaces),
                mountpoint: parts.count > 2 ? parts[2].trimmingCharacters(in: .whitespaces) : ""
            )
        }
    }

    /// Inspect a Docker volume.
    func inspectVolume(_ name: String) async -> String? {
        await runDockerCommand(["volume", "inspect", name])
    }

    /// List files in a volume's mountpoint directory.
    @Published var volumeFiles: [String] = []
    @Published var volumeBrowsePath: String = ""
    @Published var isVolumeFilesLoading = false

    func browseVolume(_ mountpoint: String) {
        Task {
            isVolumeFilesLoading = true
            volumeBrowsePath = mountpoint
            guard let sm = serviceManager, sm.isConnected else {
                isVolumeFilesLoading = false
                return
            }
            let (exitCode, stdout) = await sm.exec("ls -lAh '\(mountpoint.replacingOccurrences(of: "'", with: "'\\''"))' 2>/dev/null")
            if exitCode == 0 {
                volumeFiles = stdout.split(separator: "\n").map(String.init).filter { !$0.isEmpty }
            } else {
                volumeFiles = ["(Cannot access mountpoint)"]
            }
            isVolumeFilesLoading = false
        }
    }

    /// Remove a Docker volume.
    func removeVolume(_ name: String) {
        Task {
            _ = await runDockerCommand(["volume", "rm", name])
            await loadVolumes()
        }
    }

    /// Prune all unused volumes.
    func pruneVolumes() {
        Task {
            isLoading = true
            _ = await runDockerCommand(["volume", "prune", "-f"])
            await loadVolumes()
            isLoading = false
        }
    }

    // MARK: - Helpers

    private func runDockerCommand(_ args: [String]) async -> String? {
        // Route through SSH when connected to remote server
        if let sm = serviceManager, sm.isConnected {
            isRemoteMode = true
            // Shell-quote each argument for safe remote execution
            let quotedArgs = args.map { arg -> String in
                // If the arg contains special shell chars, wrap in single quotes
                if arg.contains(" ") || arg.contains("{") || arg.contains("}") ||
                   arg.contains("\\") || arg.contains("'") || arg.contains("$") ||
                   arg.contains("|") || arg.contains(">") || arg.contains("<") {
                    return "'" + arg.replacingOccurrences(of: "'", with: "'\\''") + "'"
                }
                return arg
            }
            let command = "docker " + quotedArgs.joined(separator: " ")
            let (exitCode, stdout) = await sm.exec(command)
            return exitCode == 0 ? stdout : nil
        }

        // Fallback to local execution
        isRemoteMode = false
        let result = await CommandRunner.shared.run("docker", arguments: args)
        return result.succeeded ? result.output : nil
    }

    private func parseDockerSize(_ str: String) -> UInt64 {
        let cleaned = str.trimmingCharacters(in: .whitespaces)
        let number = cleaned.filter { $0.isNumber || $0 == "." }
        let val = Double(number) ?? 0

        if cleaned.hasSuffix("GB") { return UInt64(val * 1_000_000_000) }
        if cleaned.hasSuffix("MB") { return UInt64(val * 1_000_000) }
        if cleaned.hasSuffix("KB") || cleaned.hasSuffix("kB") { return UInt64(val * 1_000) }
        return UInt64(val)
    }
}

// MARK: - Docker Compose

struct ComposeService: Identifiable {
    var id: String { name }
    let name: String
    let status: String
    let isRunning: Bool
    let image: String
    let ports: String
}

extension DockerViewModel {
    /// Detect compose file in working directory.
    func detectComposeFile() async {
        // Try docker compose config to see if compose is available
        if await runComposeCommand(["config", "--services"]) != nil {
            isComposeAvailable = true
            await loadComposeStatus()
        } else {
            isComposeAvailable = false
            composeServices = []
        }
    }

    func loadComposeStatus() async {
        guard let output = await runComposeCommand(["ps", "--format", "{{.Service}}|||{{.Status}}|||{{.State}}|||{{.Image}}|||{{.Ports}}"]) else {
            composeServices = []
            return
        }

        composeServices = output.split(separator: "\n").compactMap { line in
            let parts = String(line).components(separatedBy: "|||")
            guard parts.count >= 3 else { return nil }
            return ComposeService(
                name: parts[0].trimmingCharacters(in: .whitespaces),
                status: parts[1].trimmingCharacters(in: .whitespaces),
                isRunning: parts[2].trimmingCharacters(in: .whitespaces) == "running",
                image: parts.count > 3 ? parts[3].trimmingCharacters(in: .whitespaces) : "",
                ports: parts.count > 4 ? parts[4].trimmingCharacters(in: .whitespaces) : ""
            )
        }
    }

    func composeUp() {
        Task {
            isLoading = true
            _ = await runComposeCommand(["up", "-d"])
            await loadComposeStatus()
            await loadContainers()
            isLoading = false
        }
    }

    func composeDown() {
        Task {
            isLoading = true
            _ = await runComposeCommand(["down"])
            await loadComposeStatus()
            await loadContainers()
            isLoading = false
        }
    }

    func composeRestart(service: String? = nil) {
        Task {
            isLoading = true
            var args = ["restart"]
            if let svc = service { args.append(svc) }
            _ = await runComposeCommand(args)
            await loadComposeStatus()
            isLoading = false
        }
    }

    func composeLogs(service: String) {
        Task {
            if let logs = await runComposeCommand(["logs", "--tail", "500", service]) {
                containerLogs = logs
                NotificationCenter.default.post(
                    name: .dockerContainerLogs,
                    object: ["id": service, "logs": logs]
                )
            }
        }
    }

    private func runComposeCommand(_ args: [String]) async -> String? {
        let fullArgs = ["compose"] + args
        return await runDockerCommand(fullArgs)
    }

    // MARK: - Resource Monitoring

    func startStatsPolling() {
        statsTimer?.cancel()
        statsTimer = Timer.publish(every: 5, on: .main, in: .common)
            .autoconnect()
            .sink { [weak self] _ in self?.loadStats() }
        loadStats()
    }

    func stopStatsPolling() {
        statsTimer?.cancel()
        statsTimer = nil
    }

    func loadStats() {
        Task {
            guard let output = await runDockerCommand([
                "stats", "--no-stream", "--format",
                "{{.ID}}|{{.Name}}|{{.CPUPerc}}|{{.MemUsage}}|{{.MemPerc}}|{{.NetIO}}|{{.BlockIO}}"
            ]) else { return }

            var newStats: [String: ContainerStats] = [:]
            for line in output.split(separator: "\n") {
                let parts = line.split(separator: "|", omittingEmptySubsequences: false).map(String.init)
                guard parts.count >= 7 else { continue }
                let id = parts[0].trimmingCharacters(in: .whitespaces)
                newStats[id] = ContainerStats(
                    containerId: id,
                    name: parts[1].trimmingCharacters(in: .whitespaces),
                    cpuPercent: parts[2].trimmingCharacters(in: .whitespaces),
                    memoryUsage: parts[3].trimmingCharacters(in: .whitespaces),
                    memoryPercent: parts[4].trimmingCharacters(in: .whitespaces),
                    networkIO: parts[5].trimmingCharacters(in: .whitespaces),
                    blockIO: parts[6].trimmingCharacters(in: .whitespaces)
                )
            }
            containerStats = newStats
        }
    }

    // MARK: - Network Management

    func loadNetworks() async {
        guard let output = await runDockerCommand([
            "network", "ls", "--format",
            "{{.ID}}|{{.Name}}|{{.Driver}}|{{.Scope}}"
        ]) else { return }

        networks = output.split(separator: "\n").compactMap { line in
            let parts = line.split(separator: "|", omittingEmptySubsequences: false).map(String.init)
            guard parts.count >= 4 else { return nil }
            return DockerNetwork(
                id: parts[0].trimmingCharacters(in: .whitespaces),
                name: parts[1].trimmingCharacters(in: .whitespaces),
                driver: parts[2].trimmingCharacters(in: .whitespaces),
                scope: parts[3].trimmingCharacters(in: .whitespaces)
            )
        }
    }

    func inspectNetwork(_ networkId: String) async -> String? {
        await runDockerCommand(["network", "inspect", networkId])
    }

    func createNetwork(name: String, driver: String = "bridge") {
        Task {
            _ = await runDockerCommand(["network", "create", "--driver", driver, name])
            await loadNetworks()
        }
    }

    func removeNetwork(_ networkId: String) {
        Task {
            _ = await runDockerCommand(["network", "rm", networkId])
            await loadNetworks()
        }
    }
}

// MARK: - Notifications

extension Notification.Name {
    static let dockerContainerLogs = Notification.Name("pier.dockerContainerLogs")
}
