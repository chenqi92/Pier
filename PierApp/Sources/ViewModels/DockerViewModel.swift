import SwiftUI
import Combine

enum DockerTab {
    case containers, images, volumes
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

    private var timer: AnyCancellable?

    init() {
        checkDockerAvailability()
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

// MARK: - Notifications

extension Notification.Name {
    static let dockerContainerLogs = Notification.Name("pier.dockerContainerLogs")
}
