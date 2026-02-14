import SwiftUI
import Charts

/// Real-time server monitoring dashboard.
struct ServerMonitorView: View {
    @StateObject private var viewModel = ServerMonitorViewModel()
    var serviceManager: RemoteServiceManager?

    var body: some View {
        ScrollView {
            VStack(spacing: 12) {
                // ── System Info Header ──
                systemInfoHeader

                // ── CPU & Load ──
                cpuSection

                // ── Memory ──
                memorySection

                // ── Network ──
                networkSection

                // ── GPU (if available) ──
                if viewModel.hasGPU {
                    gpuSection
                }

                // ── Disk Usage ──
                diskSection

                // ── Top Processes ──
                processesSection
            }
            .padding(10)
        }
        .onAppear {
            if let sm = serviceManager {
                viewModel.serviceManager = sm
                if sm.isConnected {
                    viewModel.startMonitoring()
                }
            }
        }
        .onChange(of: serviceManager?.isConnected) { _, connected in
            if connected == true {
                viewModel.serviceManager = serviceManager
                viewModel.startMonitoring()
            } else {
                viewModel.stopMonitoring()
            }
        }
        .onDisappear {
            viewModel.stopMonitoring()
        }
    }

    // MARK: - System Info

    private var systemInfoHeader: some View {
        VStack(spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: "server.rack")
                    .font(.system(size: 14))
                    .foregroundColor(.blue)
                Text(viewModel.hostname.isEmpty ? "Server" : viewModel.hostname)
                    .font(.system(size: 12, weight: .bold))
                Spacer()
                if viewModel.isLoading {
                    ProgressView()
                        .controlSize(.small)
                }
            }
            HStack(spacing: 12) {
                infoChip(icon: "memorychip", label: viewModel.kernelVersion)
                infoChip(icon: "clock", label: viewModel.uptime)
                infoChip(icon: "list.number", label: "\(viewModel.processCount) procs")
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(10)
        .background(Color.blue.opacity(0.06))
        .cornerRadius(8)
    }

    private func infoChip(icon: String, label: String) -> some View {
        HStack(spacing: 3) {
            Image(systemName: icon)
                .font(.system(size: 8))
                .foregroundColor(.secondary)
            Text(label)
                .font(.system(size: 9))
                .foregroundColor(.secondary)
                .lineLimit(1)
        }
    }

    // MARK: - CPU

    private var cpuSection: some View {
        MonitorCard(title: "CPU", icon: "cpu", color: .orange) {
            VStack(spacing: 6) {
                HStack {
                    GaugeRing(value: viewModel.currentCPU, maxValue: 100, color: cpuColor(viewModel.currentCPU))
                        .frame(width: 50, height: 50)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(String(format: "%.1f%%", viewModel.currentCPU))
                            .font(.system(size: 18, weight: .bold, design: .rounded))
                            .foregroundColor(cpuColor(viewModel.currentCPU))
                        Text("Load: \(viewModel.currentLoadAvg)")
                            .font(.system(size: 9, design: .monospaced))
                            .foregroundColor(.secondary)
                    }
                    Spacer()
                }

                // CPU history chart
                if viewModel.snapshots.count > 1 {
                    Chart(viewModel.snapshots) { s in
                        AreaMark(
                            x: .value("Time", s.timestamp),
                            y: .value("CPU", s.cpuUsage)
                        )
                        .foregroundStyle(
                            LinearGradient(
                                colors: [.orange.opacity(0.4), .orange.opacity(0.05)],
                                startPoint: .top, endPoint: .bottom
                            )
                        )
                        LineMark(
                            x: .value("Time", s.timestamp),
                            y: .value("CPU", s.cpuUsage)
                        )
                        .foregroundStyle(.orange)
                        .lineStyle(StrokeStyle(lineWidth: 1.5))
                    }
                    .chartYScale(domain: 0...100)
                    .chartYAxis {
                        AxisMarks(values: [0, 25, 50, 75, 100]) { value in
                            AxisGridLine(stroke: StrokeStyle(lineWidth: 0.3))
                            AxisValueLabel {
                                Text("\(value.as(Int.self) ?? 0)%")
                                    .font(.system(size: 7))
                            }
                        }
                    }
                    .chartXAxis(.hidden)
                    .frame(height: 70)
                }
            }
        }
    }

    // MARK: - Memory

    private var memorySection: some View {
        MonitorCard(title: "Memory", icon: "memorychip", color: .purple) {
            VStack(spacing: 6) {
                if let last = viewModel.snapshots.last {
                    HStack {
                        GaugeRing(value: viewModel.memoryUsagePercent, maxValue: 100, color: memColor(viewModel.memoryUsagePercent))
                            .frame(width: 50, height: 50)
                        VStack(alignment: .leading, spacing: 4) {
                            HStack(alignment: .firstTextBaseline, spacing: 2) {
                                Text(viewModel.formattedMB(last.memoryUsed))
                                    .font(.system(size: 16, weight: .bold, design: .rounded))
                                Text("/ \(viewModel.formattedMB(last.memoryTotal))")
                                    .font(.system(size: 10))
                                    .foregroundColor(.secondary)
                            }
                            if last.swapTotal > 0 {
                                Text("Swap: \(viewModel.formattedMB(last.swapUsed)) / \(viewModel.formattedMB(last.swapTotal))")
                                    .font(.system(size: 9))
                                    .foregroundColor(.secondary)
                            }
                        }
                        Spacer()
                    }
                }

                // Memory history chart
                if viewModel.snapshots.count > 1 {
                    Chart(viewModel.snapshots) { s in
                        AreaMark(
                            x: .value("Time", s.timestamp),
                            y: .value("Mem", s.memoryUsed)
                        )
                        .foregroundStyle(
                            LinearGradient(
                                colors: [.purple.opacity(0.4), .purple.opacity(0.05)],
                                startPoint: .top, endPoint: .bottom
                            )
                        )
                        LineMark(
                            x: .value("Time", s.timestamp),
                            y: .value("Mem", s.memoryUsed)
                        )
                        .foregroundStyle(.purple)
                        .lineStyle(StrokeStyle(lineWidth: 1.5))
                    }
                    .chartYScale(domain: 0...(viewModel.snapshots.last?.memoryTotal ?? 1))
                    .chartYAxis {
                        AxisMarks(position: .leading) { value in
                            AxisGridLine(stroke: StrokeStyle(lineWidth: 0.3))
                            AxisValueLabel {
                                Text(viewModel.formattedMB(value.as(Double.self) ?? 0))
                                    .font(.system(size: 7))
                            }
                        }
                    }
                    .chartXAxis(.hidden)
                    .frame(height: 70)
                }
            }
        }
    }

    // MARK: - Network

    private var networkSection: some View {
        MonitorCard(title: "Network", icon: "network", color: .cyan) {
            VStack(spacing: 6) {
                HStack(spacing: 16) {
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 3) {
                            Image(systemName: "arrow.down")
                                .font(.system(size: 8, weight: .bold))
                                .foregroundColor(.green)
                            Text("RX")
                                .font(.system(size: 9, weight: .semibold))
                                .foregroundColor(.secondary)
                        }
                        Text(viewModel.formattedBytes(viewModel.networkRxRate))
                            .font(.system(size: 14, weight: .bold, design: .rounded))
                            .foregroundColor(.green)
                    }
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 3) {
                            Image(systemName: "arrow.up")
                                .font(.system(size: 8, weight: .bold))
                                .foregroundColor(.blue)
                            Text("TX")
                                .font(.system(size: 9, weight: .semibold))
                                .foregroundColor(.secondary)
                        }
                        Text(viewModel.formattedBytes(viewModel.networkTxRate))
                            .font(.system(size: 14, weight: .bold, design: .rounded))
                            .foregroundColor(.blue)
                    }
                    Spacer()
                }
            }
        }
    }

    // MARK: - GPU

    private var gpuSection: some View {
        MonitorCard(title: "GPU", icon: "display", color: .green) {
            VStack(spacing: 6) {
                ForEach(viewModel.gpuInfos) { gpu in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(gpu.name)
                            .font(.system(size: 10, weight: .semibold))
                        HStack(spacing: 12) {
                            gpuStat(icon: "thermometer", label: gpu.temperature, color: .red)
                            gpuStat(icon: "gauge.high", label: gpu.utilization, color: .orange)
                            gpuStat(icon: "memorychip", label: "\(gpu.memoryUsed)/\(gpu.memoryTotal)", color: .purple)
                            gpuStat(icon: "wind", label: gpu.fanSpeed, color: .cyan)
                        }
                    }
                }
            }
        }
    }

    private func gpuStat(icon: String, label: String, color: Color) -> some View {
        HStack(spacing: 2) {
            Image(systemName: icon)
                .font(.system(size: 8))
                .foregroundColor(color)
            Text(label)
                .font(.system(size: 9, design: .monospaced))
        }
    }

    // MARK: - Disk

    private var diskSection: some View {
        MonitorCard(title: "Storage", icon: "internaldrive", color: .orange) {
            VStack(spacing: 6) {
                ForEach(viewModel.disks) { disk in
                    VStack(alignment: .leading, spacing: 3) {
                        HStack {
                            Text(disk.mountpoint)
                                .font(.system(size: 10, weight: .medium))
                                .lineLimit(1)
                            Spacer()
                            Text("\(disk.used) / \(disk.size)")
                                .font(.system(size: 9))
                                .foregroundColor(.secondary)
                        }
                        GeometryReader { geo in
                            ZStack(alignment: .leading) {
                                RoundedRectangle(cornerRadius: 3)
                                    .fill(Color.gray.opacity(0.15))
                                    .frame(height: 6)
                                RoundedRectangle(cornerRadius: 3)
                                    .fill(diskColor(disk.usagePercent))
                                    .frame(width: max(0, geo.size.width * disk.usagePercent / 100), height: 6)
                            }
                        }
                        .frame(height: 6)
                        Text(String(format: "%.1f%% used  •  %@ free", disk.usagePercent, disk.available))
                            .font(.system(size: 8))
                            .foregroundColor(.secondary)
                    }
                    .padding(.vertical, 2)
                }
            }
        }
    }

    // MARK: - Processes

    private var processesSection: some View {
        MonitorCard(title: "Top Processes", icon: "list.bullet.rectangle", color: .teal) {
            VStack(spacing: 0) {
                // Header
                HStack {
                    Text("COMMAND").frame(maxWidth: .infinity, alignment: .leading)
                    Text("CPU%").frame(width: 40, alignment: .trailing)
                    Text("MEM%").frame(width: 40, alignment: .trailing)
                    Text("USER").frame(width: 45, alignment: .trailing)
                }
                .font(.system(size: 8, weight: .semibold))
                .foregroundColor(.secondary)
                .padding(.bottom, 3)

                ForEach(viewModel.topProcesses) { proc in
                    HStack {
                        Text(proc.command)
                            .lineLimit(1)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        Text(String(format: "%.1f", proc.cpu))
                            .frame(width: 40, alignment: .trailing)
                            .foregroundColor(proc.cpu > 50 ? .red : .primary)
                        Text(String(format: "%.1f", proc.memory))
                            .frame(width: 40, alignment: .trailing)
                        Text(proc.user)
                            .frame(width: 45, alignment: .trailing)
                            .foregroundColor(.secondary)
                    }
                    .font(.system(size: 9, design: .monospaced))
                }
            }
        }
    }

    // MARK: - Color Helpers

    private func cpuColor(_ val: Double) -> Color {
        if val > 80 { return .red }
        if val > 50 { return .orange }
        return .green
    }

    private func memColor(_ val: Double) -> Color {
        if val > 85 { return .red }
        if val > 60 { return .orange }
        return .purple
    }

    private func diskColor(_ val: Double) -> Color {
        if val > 90 { return .red }
        if val > 70 { return .orange }
        return .blue
    }
}

// MARK: - Monitor Card

/// Reusable card container for monitor sections.
struct MonitorCard<Content: View>: View {
    let title: String
    let icon: String
    let color: Color
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 4) {
                Image(systemName: icon)
                    .font(.system(size: 10))
                    .foregroundColor(color)
                Text(title)
                    .font(.system(size: 11, weight: .semibold))
            }
            content()
        }
        .padding(10)
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.6))
        .cornerRadius(8)
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(color.opacity(0.15), lineWidth: 1)
        )
    }
}

// MARK: - Gauge Ring

/// Circular progress gauge ring.
struct GaugeRing: View {
    let value: Double
    let maxValue: Double
    let color: Color

    private var progress: Double { min(value / maxValue, 1.0) }

    var body: some View {
        ZStack {
            // Background ring
            Circle()
                .stroke(color.opacity(0.12), lineWidth: 5)
            // Progress ring
            Circle()
                .trim(from: 0, to: progress)
                .stroke(
                    AngularGradient(
                        gradient: Gradient(colors: [color.opacity(0.6), color]),
                        center: .center
                    ),
                    style: StrokeStyle(lineWidth: 5, lineCap: .round)
                )
                .rotationEffect(.degrees(-90))
                .animation(.easeInOut(duration: 0.5), value: progress)
            // Center text
            Text(String(format: "%.0f%%", value))
                .font(.system(size: 10, weight: .bold, design: .rounded))
                .foregroundColor(color)
        }
    }
}
