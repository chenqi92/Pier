import SwiftUI
import Combine

enum DockerTab {
    case containers, images, volumes, compose
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

    private var timer: AnyCancellable?

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
            "{{.ID}}\\t{{.Names}}\\t{{.Image}}\\t{{.Status}}\\t{{.State}}\\t{{.Ports}}"
        ]) else { return }

        containers = output.split(separator: "\n").compactMap { line in
            let parts = line.split(separator: "\t", maxSplits: 5, omittingEmptySubsequences: false)
            guard parts.count >= 5 else { return nil }
            return DockerContainer(
                id: String(parts[0]),
                name: String(parts[1]),
                image: String(parts[2]),
                status: String(parts[3]),
                isRunning: parts[4] == "running",
                ports: parts.count > 5 ? String(parts[5]) : "",
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
            "{{.ID}}\\t{{.Repository}}\\t{{.Tag}}\\t{{.Size}}"
        ]) else { return }

        images = output.split(separator: "\n").compactMap { line in
            let parts = line.split(separator: "\t", maxSplits: 3)
            guard parts.count >= 4 else { return nil }
            return DockerImage(
                id: String(parts[0]),
                repository: String(parts[1]),
                tag: String(parts[2]),
                size: parseDockerSize(String(parts[3])),
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

    // MARK: - Volumes

    private func loadVolumes() async {
        guard let output = await runDockerCommand([
            "volume", "ls", "--format",
            "{{.Name}}\\t{{.Driver}}\\t{{.Mountpoint}}"
        ]) else { return }

        volumes = output.split(separator: "\n").compactMap { line in
            let parts = line.split(separator: "\t", maxSplits: 2)
            guard parts.count >= 2 else { return nil }
            return DockerVolume(
                name: String(parts[0]),
                driver: String(parts[1]),
                mountpoint: parts.count > 2 ? String(parts[2]) : ""
            )
        }
    }

    // MARK: - Helpers

    private func runDockerCommand(_ args: [String]) async -> String? {
        // Route through SSH when connected to remote server
        if let sm = serviceManager, sm.isConnected {
            isRemoteMode = true
            let command = "docker " + args.joined(separator: " ")
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
        guard let output = await runComposeCommand(["ps", "--format", "{{.Service}}\\t{{.Status}}\\t{{.State}}\\t{{.Image}}\\t{{.Ports}}"]) else {
            composeServices = []
            return
        }

        composeServices = output.split(separator: "\n").compactMap { line in
            let parts = line.split(separator: "\t", maxSplits: 4, omittingEmptySubsequences: false)
            guard parts.count >= 3 else { return nil }
            return ComposeService(
                name: String(parts[0]),
                status: String(parts[1]),
                isRunning: parts[2] == "running",
                image: parts.count > 3 ? String(parts[3]) : "",
                ports: parts.count > 4 ? String(parts[4]) : ""
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
}

// MARK: - Notifications

extension Notification.Name {
    static let dockerContainerLogs = Notification.Name("pier.dockerContainerLogs")
}
