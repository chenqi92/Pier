import SwiftUI

/// Redis Client view — key browser, value inspector, raw command, server info.
struct RedisClientView: View {
    @StateObject private var viewModel = RedisViewModel()

    var body: some View {
        VStack(spacing: 0) {
            if !viewModel.isConnected {
                connectPrompt
            } else {
                connectedContent
            }
        }
    }

    // MARK: - Connect Prompt

    private var connectPrompt: some View {
        VStack(spacing: 16) {
            Image(systemName: "server.rack")
                .font(.system(size: 40))
                .foregroundColor(.secondary)

            if let error = viewModel.errorMessage {
                Text(error)
                    .font(.caption)
                    .foregroundColor(.red)
            }

            Text("redis.connectPrompt")
                .font(.callout)
                .foregroundColor(.secondary)

            HStack(spacing: 8) {
                Text("redis.port")
                    .font(.caption)
                TextField("", value: $viewModel.redisPort, format: .number)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 80)
            }

            Button("redis.connect") { viewModel.connect() }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .disabled(viewModel.isLoading)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Connected Content

    private var connectedContent: some View {
        HSplitView {
            // Left: Key list
            VStack(spacing: 0) {
                // Search bar
                HStack(spacing: 4) {
                    Image(systemName: "magnifyingglass")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    TextField("redis.searchKeys", text: $viewModel.searchPattern)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: 11))
                        .onSubmit { viewModel.refreshKeys() }
                    Button(action: { viewModel.refreshKeys() }) {
                        Image(systemName: "arrow.clockwise")
                            .font(.caption)
                    }
                    .buttonStyle(.borderless)
                    Button(action: { viewModel.disconnect() }) {
                        Image(systemName: "xmark.circle")
                            .font(.caption)
                            .foregroundColor(.red)
                    }
                    .buttonStyle(.borderless)
                }
                .padding(6)

                Divider()

                // Key count badge
                HStack {
                    Text("redis.keyCount \(viewModel.keys.count)")
                        .font(.system(size: 10))
                        .foregroundColor(.secondary)
                    Spacer()
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 3)

                // Key list
                if viewModel.isLoading {
                    ProgressView()
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    List(viewModel.keys, selection: Binding(
                        get: { viewModel.selectedKey?.key },
                        set: { key in
                            if let k = key { viewModel.getKeyValue(k) }
                        }
                    )) { keyInfo in
                        HStack(spacing: 6) {
                            Text(keyInfo.type)
                                .font(.system(size: 8, weight: .bold, design: .monospaced))
                                .padding(.horizontal, 4)
                                .padding(.vertical, 1)
                                .background(typeColor(keyInfo.type).opacity(0.2))
                                .foregroundColor(typeColor(keyInfo.type))
                                .cornerRadius(3)

                            Text(keyInfo.key)
                                .font(.system(size: 11, design: .monospaced))
                                .lineLimit(1)

                            Spacer()

                            Text(keyInfo.ttlDisplay)
                                .font(.system(size: 9, design: .monospaced))
                                .foregroundColor(.secondary)
                        }
                        .padding(.vertical, 1)
                        .tag(keyInfo.key)
                        .contextMenu {
                            Button("redis.copyKey") {
                                NSPasteboard.general.clearContents()
                                NSPasteboard.general.setString(keyInfo.key, forType: .string)
                            }
                            Divider()
                            Button("redis.deleteKey", role: .destructive) {
                                viewModel.deleteKey(keyInfo.key)
                            }
                        }
                    }
                    .listStyle(.plain)
                }
            }
            .frame(minWidth: 180, idealWidth: 220)

            // Right: Value inspector + server info + raw command
            VStack(spacing: 0) {
                if let key = viewModel.selectedKey {
                    keyDetailView(key)
                } else {
                    serverInfoView
                }

                Divider()

                // Raw command input
                rawCommandSection
            }
            .frame(minWidth: 220)
        }
    }

    // MARK: - Key Detail

    private func keyDetailView(_ key: RedisKeyInfo) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            // Key header
            HStack {
                Text(key.key)
                    .font(.system(size: 12, weight: .semibold, design: .monospaced))
                    .lineLimit(1)
                Spacer()
                Text(key.type)
                    .font(.system(size: 10, weight: .medium))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(typeColor(key.type).opacity(0.2))
                    .foregroundColor(typeColor(key.type))
                    .cornerRadius(4)
                Text("TTL: \(key.ttlDisplay)")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundColor(.secondary)
            }
            .padding(8)

            Divider()

            // Value
            ScrollView {
                Text(key.value ?? "...")
                    .font(.system(size: 11, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(8)
            }
            .frame(maxHeight: .infinity)
        }
    }

    // MARK: - Server Info

    private var serverInfoView: some View {
        VStack(spacing: 12) {
            if let info = viewModel.serverInfo {
                HStack {
                    Image(systemName: "server.rack")
                        .font(.title3)
                        .foregroundColor(.accentColor)
                    Text("Redis \(info.version)")
                        .font(.headline)
                }
                .padding(.top, 16)

                LazyVGrid(columns: [
                    GridItem(.flexible()), GridItem(.flexible())
                ], spacing: 8) {
                    infoCard(icon: "person.2", title: "redis.clients", value: "\(info.connectedClients)")
                    infoCard(icon: "memorychip", title: "redis.memory", value: info.usedMemory)
                    infoCard(icon: "clock", title: "redis.uptime", value: "\(info.uptimeDays)d")
                    infoCard(icon: "key", title: "redis.dbSize", value: "\(info.dbSize)")
                }
                .padding()
            } else {
                Text("redis.selectKey")
                    .font(.callout)
                    .foregroundColor(.secondary)
            }
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func infoCard(icon: String, title: LocalizedStringKey, value: String) -> some View {
        VStack(spacing: 4) {
            Image(systemName: icon)
                .font(.caption)
                .foregroundColor(.secondary)
            Text(value)
                .font(.system(size: 14, weight: .semibold, design: .monospaced))
            Text(title)
                .font(.system(size: 9))
                .foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(8)
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.5))
        .cornerRadius(6)
    }

    // MARK: - Raw Command

    private var rawCommandSection: some View {
        VStack(spacing: 0) {
            // Output area
            if !viewModel.commandOutput.isEmpty {
                ScrollView {
                    Text(viewModel.commandOutput)
                        .font(.system(size: 10, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(6)
                }
                .frame(height: 100)
                .background(Color(nsColor: .textBackgroundColor).opacity(0.3))
            }

            // Input
            HStack(spacing: 4) {
                Text(">")
                    .font(.system(size: 11, weight: .bold, design: .monospaced))
                    .foregroundColor(.accentColor)
                TextField("redis.rawCommand", text: $viewModel.commandInput)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 11, design: .monospaced))
                    .onSubmit { viewModel.executeRawCommand() }
            }
            .padding(6)
        }
    }

    // MARK: - Helpers

    private func typeColor(_ type: String) -> Color {
        switch type {
        case "string": return .green
        case "list":   return .blue
        case "set":    return .orange
        case "zset":   return .purple
        case "hash":   return .pink
        default:       return .gray
        }
    }
}
