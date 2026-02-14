import SwiftUI
import Combine

// MARK: - Data Models

struct ServerSnapshot: Identifiable {
    let id = UUID()
    let timestamp: Date
    let cpuUsage: Double        // 0-100
    let memoryUsed: Double      // MB
    let memoryTotal: Double     // MB
    let swapUsed: Double        // MB
    let swapTotal: Double       // MB
    let networkRxBytes: UInt64  // cumulative bytes received
    let networkTxBytes: UInt64  // cumulative bytes sent
    let loadAvg1: Double
    let loadAvg5: Double
    let loadAvg15: Double
}

struct DiskInfo: Identifiable {
    var id: String { mountpoint }
    let filesystem: String
    let size: String
    let used: String
    let available: String
    let usagePercent: Double  // 0-100
    let mountpoint: String
}

struct ServerProcessInfo: Identifiable {
    var id: String { "\(pid)-\(command)" }
    let user: String
    let pid: String
    let cpu: Double
    let memory: Double
    let command: String
}

struct GPUInfo: Identifiable {
    var id: String { name }
    let name: String
    let temperature: String
    let utilization: String
    let memoryUsed: String
    let memoryTotal: String
    let fanSpeed: String
}

// MARK: - ViewModel

@MainActor
class ServerMonitorViewModel: ObservableObject {
    // Published state
    @Published var snapshots: [ServerSnapshot] = []
    @Published var disks: [DiskInfo] = []
    @Published var topProcesses: [ServerProcessInfo] = []
    @Published var gpuInfos: [GPUInfo] = []
    @Published var hasGPU = false
    @Published var isLoading = false
    @Published var hostname = ""
    @Published var kernelVersion = ""
    @Published var uptime = ""
    @Published var processCount = 0

    // Computed network rates (bytes/sec)
    @Published var networkRxRate: Double = 0
    @Published var networkTxRate: Double = 0

    weak var serviceManager: RemoteServiceManager?
    private var pollingTimer: Timer?
    private let maxSnapshots = 60  // ~3 min of history at 3s intervals
    private var lastNetworkRx: UInt64 = 0
    private var lastNetworkTx: UInt64 = 0
    private var lastSnapshotTime: Date?

    var memoryUsagePercent: Double {
        guard let last = snapshots.last, last.memoryTotal > 0 else { return 0 }
        return (last.memoryUsed / last.memoryTotal) * 100
    }

    var currentCPU: Double { snapshots.last?.cpuUsage ?? 0 }
    var currentLoadAvg: String {
        guard let s = snapshots.last else { return "—" }
        return String(format: "%.2f  %.2f  %.2f", s.loadAvg1, s.loadAvg5, s.loadAvg15)
    }

    // MARK: - Lifecycle

    func startMonitoring() {
        guard pollingTimer == nil else { return }
        isLoading = true
        // Initial full load
        Task {
            await loadSystemInfo()
            await pollStats()
            await loadDisks()
            await loadTopProcesses()
            await loadGPU()
            isLoading = false
        }
        // Periodic polling every 3 seconds
        pollingTimer = Timer.scheduledTimer(withTimeInterval: 3.0, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                await self?.pollStats()
            }
        }
        // Refresh disks/processes less frequently (every 15s)
        Timer.scheduledTimer(withTimeInterval: 15.0, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                await self?.loadDisks()
                await self?.loadTopProcesses()
            }
        }
    }

    func stopMonitoring() {
        pollingTimer?.invalidate()
        pollingTimer = nil
    }

    // MARK: - System Info (once)

    private func loadSystemInfo() async {
        guard let sm = serviceManager, sm.isConnected else { return }
        let (_, out) = await sm.exec("hostname; uname -r; uptime -p 2>/dev/null || uptime")
        let lines = out.split(separator: "\n").map(String.init)
        if lines.count >= 1 { hostname = lines[0].trimmingCharacters(in: .whitespaces) }
        if lines.count >= 2 { kernelVersion = lines[1].trimmingCharacters(in: .whitespaces) }
        if lines.count >= 3 { uptime = lines[2].trimmingCharacters(in: .whitespaces) }
    }

    // MARK: - Polling (every 3s)

    private func pollStats() async {
        guard let sm = serviceManager, sm.isConnected else { return }

        // Combined command for efficiency: CPU, memory, load, network in one SSH exec
        let cmd = """
        cat /proc/stat | head -1; \
        free -m | grep -E 'Mem:|Swap:'; \
        cat /proc/loadavg; \
        cat /proc/net/dev | tail -n +3
        """
        let (ec, out) = await sm.exec(cmd)
        guard ec == 0 else { return }

        let lines = out.split(separator: "\n").map(String.init)
        var cpuUsage: Double = 0
        var memUsed: Double = 0, memTotal: Double = 0
        var swapUsed: Double = 0, swapTotal: Double = 0
        var loadAvg1: Double = 0, loadAvg5: Double = 0, loadAvg15: Double = 0
        var totalRx: UInt64 = 0, totalTx: UInt64 = 0

        for line in lines {
            if line.hasPrefix("cpu ") {
                // Parse /proc/stat cpu line
                let parts = line.split(separator: " ").dropFirst().compactMap { Double($0) }
                if parts.count >= 4 {
                    let idle = parts[3]
                    let total = parts.reduce(0, +)
                    cpuUsage = total > 0 ? ((total - idle) / total) * 100 : 0
                }
            } else if line.contains("Mem:") {
                let parts = line.split(separator: " ").compactMap { Double($0) }
                if parts.count >= 2 { memTotal = parts[0]; memUsed = parts[1] }
            } else if line.contains("Swap:") {
                let parts = line.split(separator: " ").compactMap { Double($0) }
                if parts.count >= 2 { swapTotal = parts[0]; swapUsed = parts[1] }
            } else if line.first?.isNumber == true && line.contains(".") {
                // /proc/loadavg
                let parts = line.split(separator: " ")
                if parts.count >= 3 {
                    loadAvg1 = Double(parts[0]) ?? 0
                    loadAvg5 = Double(parts[1]) ?? 0
                    loadAvg15 = Double(parts[2]) ?? 0
                }
                if parts.count >= 4 {
                    let procParts = parts[3].split(separator: "/")
                    if procParts.count >= 2 { processCount = Int(procParts[1]) ?? 0 }
                }
            } else if line.contains(":") && !line.hasPrefix("cpu") {
                // Network interface line from /proc/net/dev
                let colonIdx = line.firstIndex(of: ":")!
                let data = line[line.index(after: colonIdx)...]
                let parts = data.split(separator: " ").compactMap { UInt64($0) }
                if parts.count >= 9 {
                    totalRx += parts[0]  // bytes received
                    totalTx += parts[8]  // bytes sent
                }
            }
        }

        // Calculate network rates
        let now = Date()
        if let lastTime = lastSnapshotTime {
            let dt = now.timeIntervalSince(lastTime)
            if dt > 0 {
                networkRxRate = Double(totalRx &- lastNetworkRx) / dt
                networkTxRate = Double(totalTx &- lastNetworkTx) / dt
            }
        }
        lastNetworkRx = totalRx
        lastNetworkTx = totalTx
        lastSnapshotTime = now

        let snapshot = ServerSnapshot(
            timestamp: now,
            cpuUsage: cpuUsage,
            memoryUsed: memUsed,
            memoryTotal: memTotal,
            swapUsed: swapUsed,
            swapTotal: swapTotal,
            networkRxBytes: totalRx,
            networkTxBytes: totalTx,
            loadAvg1: loadAvg1,
            loadAvg5: loadAvg5,
            loadAvg15: loadAvg15
        )

        snapshots.append(snapshot)
        if snapshots.count > maxSnapshots {
            snapshots.removeFirst(snapshots.count - maxSnapshots)
        }
    }

    // MARK: - Disk (every 15s)

    private func loadDisks() async {
        guard let sm = serviceManager, sm.isConnected else { return }
        let (ec, out) = await sm.exec("df -h --output=source,size,used,avail,pcent,target 2>/dev/null | grep '^/'")
        guard ec == 0 else { return }

        disks = out.split(separator: "\n").compactMap { line in
            let parts = line.split(separator: " ", maxSplits: 5)
            guard parts.count >= 6 else { return nil }
            let pct = Double(parts[4].replacingOccurrences(of: "%", with: "")) ?? 0
            return DiskInfo(
                filesystem: String(parts[0]),
                size: String(parts[1]),
                used: String(parts[2]),
                available: String(parts[3]),
                usagePercent: pct,
                mountpoint: String(parts[5])
            )
        }
    }

    // MARK: - Processes (every 15s)

    private func loadTopProcesses() async {
        guard let sm = serviceManager, sm.isConnected else { return }
        let (ec, out) = await sm.exec("ps aux --sort=-%cpu 2>/dev/null | head -11 | tail -10")
        guard ec == 0 else { return }

        topProcesses = out.split(separator: "\n").prefix(10).compactMap { line in
            let parts = line.split(separator: " ", maxSplits: 10, omittingEmptySubsequences: true)
            guard parts.count >= 11 else { return nil }
            return ServerProcessInfo(
                user: String(parts[0]),
                pid: String(parts[1]),
                cpu: Double(parts[2]) ?? 0,
                memory: Double(parts[3]) ?? 0,
                command: String(parts[10])
            )
        }
    }

    // MARK: - GPU (once + refresh)

    private func loadGPU() async {
        guard let sm = serviceManager, sm.isConnected else { return }
        let (ec, out) = await sm.exec("nvidia-smi --query-gpu=name,temperature.gpu,utilization.gpu,memory.used,memory.total,fan.speed --format=csv,noheader,nounits 2>/dev/null")
        guard ec == 0, !out.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            hasGPU = false
            return
        }
        hasGPU = true
        gpuInfos = out.split(separator: "\n").compactMap { line in
            let parts = line.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
            guard parts.count >= 5 else { return nil }
            return GPUInfo(
                name: parts[0],
                temperature: "\(parts[1])°C",
                utilization: "\(parts[2])%",
                memoryUsed: "\(parts[3]) MiB",
                memoryTotal: "\(parts[4]) MiB",
                fanSpeed: parts.count > 5 ? "\(parts[5])%" : "N/A"
            )
        }
    }

    // MARK: - Helpers

    func formattedBytes(_ bytes: Double) -> String {
        if bytes >= 1_000_000_000 { return String(format: "%.1f GB/s", bytes / 1_000_000_000) }
        if bytes >= 1_000_000 { return String(format: "%.1f MB/s", bytes / 1_000_000) }
        if bytes >= 1_000 { return String(format: "%.1f KB/s", bytes / 1_000) }
        return String(format: "%.0f B/s", bytes)
    }

    func formattedMB(_ mb: Double) -> String {
        if mb >= 1024 { return String(format: "%.1f GB", mb / 1024) }
        return String(format: "%.0f MB", mb)
    }
}
