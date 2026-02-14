import SwiftUI

/// Docker container/image management panel.
struct DockerManageView: View {
    @StateObject private var viewModel = DockerViewModel()

    var body: some View {
        VStack(spacing: 0) {
            // Toolbar
            dockerToolbar

            Divider()

            if !viewModel.isDockerAvailable {
                dockerUnavailableView
            } else {
                // Tab: Containers / Images / Volumes
                Picker("", selection: $viewModel.selectedTab) {
                    Text("docker.containers").tag(DockerTab.containers)
                    Text("docker.images").tag(DockerTab.images)
                    Text("docker.volumes").tag(DockerTab.volumes)
                    if viewModel.isComposeAvailable {
                        Text("docker.compose").tag(DockerTab.compose)
                    }
                }
                .pickerStyle(.segmented)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)

                Divider()

                switch viewModel.selectedTab {
                case .containers:
                    containerListView
                case .images:
                    imageListView
                case .volumes:
                    volumeListView
                case .compose:
                    composeListView
                case .networks:
                    networkListView
                }
            }
        }
    }

    // MARK: - Toolbar

    private var dockerToolbar: some View {
        HStack {
            Image(systemName: "shippingbox.fill")
                .foregroundColor(.blue)
                .font(.caption)
            Text("docker.title")
                .font(.caption)
                .fontWeight(.medium)
            Spacer()

            if viewModel.isLoading {
                ProgressView()
                    .scaleEffect(0.6)
            }

            Button(action: { viewModel.refresh() }) {
                Image(systemName: "arrow.clockwise")
                    .font(.caption)
            }
            .buttonStyle(.borderless)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
    }

    // MARK: - Containers

    private var containerListView: some View {
        List {
            ForEach(viewModel.containers) { container in
                HStack(spacing: 8) {
                    // Status indicator
                    Circle()
                        .fill(container.isRunning ? Color.green : Color.gray)
                        .frame(width: 8, height: 8)

                    VStack(alignment: .leading, spacing: 2) {
                        Text(container.name)
                            .font(.caption)
                            .fontWeight(.medium)
                            .lineLimit(1)
                        Text(container.image)
                            .font(.system(size: 9))
                            .foregroundColor(.secondary)
                            .lineLimit(1)
                    }

                    Spacer()

                    // Action buttons
                    if container.isRunning {
                        Button(action: { viewModel.stopContainer(container.id) }) {
                            Image(systemName: "stop.fill")
                                .font(.system(size: 9))
                                .foregroundColor(.red)
                        }
                        .buttonStyle(.borderless)
                        .help(String(localized: "docker.stop"))

                        Button(action: { viewModel.restartContainer(container.id) }) {
                            Image(systemName: "arrow.clockwise")
                                .font(.system(size: 9))
                        }
                        .buttonStyle(.borderless)
                        .help(String(localized: "docker.restart"))
                    } else {
                        Button(action: { viewModel.startContainer(container.id) }) {
                            Image(systemName: "play.fill")
                                .font(.system(size: 9))
                                .foregroundColor(.green)
                        }
                        .buttonStyle(.borderless)
                        .help(String(localized: "docker.start"))
                    }

                    Button(action: { viewModel.viewContainerLogs(container.id) }) {
                        Image(systemName: "doc.text.magnifyingglass")
                            .font(.system(size: 9))
                    }
                    .buttonStyle(.borderless)
                    .help(String(localized: "docker.viewLogs"))
                }
                .padding(.vertical, 2)
                .contextMenu {
                    Button("docker.start") { viewModel.startContainer(container.id) }
                    Divider()
                    Button("docker.stop") { viewModel.stopContainer(container.id) }
                    Divider()
                    Button("docker.restart") { viewModel.restartContainer(container.id) }
                    Divider()
                    Button("docker.viewLogs") { viewModel.viewContainerLogs(container.id) }
                    Button("docker.execShell") {
                        NotificationCenter.default.post(
                            name: .dockerExecShell,
                            object: container.id
                        )
                    }
                    Divider()
                    Button("docker.remove", role: .destructive) {
                        viewModel.removeContainer(container.id)
                    }
                }
            }
        }
        .listStyle(.plain)
        .overlay {
            if viewModel.containers.isEmpty && !viewModel.isLoading {
                Text("docker.noContainers")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
    }

    // MARK: - Images

    private var imageListView: some View {
        List {
            ForEach(viewModel.images) { image in
                HStack(spacing: 8) {
                    Image(systemName: "square.stack.3d.up.fill")
                        .foregroundColor(.purple)
                        .font(.caption)

                    VStack(alignment: .leading, spacing: 2) {
                        Text(image.repository)
                            .font(.caption)
                            .fontWeight(.medium)
                            .lineLimit(1)
                        HStack(spacing: 4) {
                            Text(image.tag)
                                .font(.system(size: 9))
                                .padding(.horizontal, 4)
                                .padding(.vertical, 1)
                                .background(Color.blue.opacity(0.15))
                                .cornerRadius(3)
                            Text(image.formattedSize)
                                .font(.system(size: 9))
                                .foregroundColor(.secondary)
                        }
                    }

                    Spacer()
                }
                .padding(.vertical, 2)
                .contextMenu {
                    Button("docker.runContainer") { viewModel.runImage(image.id) }
                    Divider()
                    Button("docker.remove", role: .destructive) { viewModel.removeImage(image.id) }
                }
            }
        }
        .listStyle(.plain)
    }

    // MARK: - Volumes

    private var volumeListView: some View {
        List {
            ForEach(viewModel.volumes) { volume in
                HStack(spacing: 8) {
                    Image(systemName: "externaldrive.fill")
                        .foregroundColor(.orange)
                        .font(.caption)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(volume.name)
                            .font(.caption)
                            .fontWeight(.medium)
                            .lineLimit(1)
                        Text(volume.driver)
                            .font(.system(size: 9))
                            .foregroundColor(.secondary)
                    }
                    Spacer()
                }
                .padding(.vertical, 2)
            }
        }
        .listStyle(.plain)
    }

    // MARK: - Unavailable

    private var dockerUnavailableView: some View {
        VStack(spacing: 16) {
            Image(systemName: "shippingbox.circle")
                .font(.system(size: 36))
                .foregroundColor(.secondary)
            Text("docker.notAvailable")
                .font(.title3)
                .foregroundColor(.secondary)
            Text("docker.notAvailableDesc")
                .font(.system(size: 10))
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
            Button("docker.retry") { viewModel.checkDockerAvailability() }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Compose

    private var composeListView: some View {
        VStack(spacing: 0) {
            // Action bar
            HStack(spacing: 8) {
                Button(action: { viewModel.composeUp() }) {
                    Label("docker.composeUp", systemImage: "play.fill")
                        .font(.caption)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .tint(.green)

                Button(action: { viewModel.composeDown() }) {
                    Label("docker.composeDown", systemImage: "stop.fill")
                        .font(.caption)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .tint(.red)

                Spacer()

                Button(action: {
                    Task { await viewModel.loadComposeStatus() }
                }) {
                    Image(systemName: "arrow.clockwise")
                        .font(.caption)
                }
                .buttonStyle(.borderless)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)

            Divider()

            List {
                ForEach(viewModel.composeServices) { service in
                    HStack(spacing: 8) {
                        Circle()
                            .fill(service.isRunning ? Color.green : Color.gray)
                            .frame(width: 8, height: 8)

                        VStack(alignment: .leading, spacing: 2) {
                            Text(service.name)
                                .font(.caption)
                                .fontWeight(.medium)
                            if !service.image.isEmpty {
                                Text(service.image)
                                    .font(.system(size: 9))
                                    .foregroundColor(.secondary)
                                    .lineLimit(1)
                            }
                        }

                        Spacer()

                        Text(service.status)
                            .font(.system(size: 9))
                            .foregroundColor(.secondary)
                            .lineLimit(1)

                        Button(action: { viewModel.composeRestart(service: service.name) }) {
                            Image(systemName: "arrow.clockwise")
                                .font(.system(size: 9))
                        }
                        .buttonStyle(.borderless)
                        .help(String(localized: "docker.composeRestart"))
                    }
                    .padding(.vertical, 2)
                    .contextMenu {
                        Button("docker.composeRestart") { viewModel.composeRestart(service: service.name) }
                        Button("docker.viewLogs") { viewModel.composeLogs(service: service.name) }
                    }
                }
            }
            .listStyle(.plain)
            .overlay {
                if viewModel.composeServices.isEmpty && !viewModel.isLoading {
                    Text("docker.noContainers")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
        }
    }

    // MARK: - Networks

    private var networkListView: some View {
        VStack(spacing: 0) {
            HStack {
                Button(action: {
                    viewModel.createNetwork(name: "pier-network-\(Int.random(in: 1000...9999))")
                }) {
                    Label("docker.createNetwork", systemImage: "plus")
                        .font(.caption)
                }
                .buttonStyle(.bordered)
                .controlSize(.mini)
                Spacer()
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)

            List(viewModel.networks) { network in
                HStack {
                    Image(systemName: "network")
                        .font(.system(size: 9))
                        .foregroundColor(.blue)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(network.name)
                            .font(.system(size: 10))
                        Text("\(network.driver) · \(network.scope)")
                            .font(.system(size: 8))
                            .foregroundColor(.secondary)
                    }
                    Spacer()

                    // Don't allow removal of default networks
                    if !["bridge", "host", "none"].contains(network.name) {
                        Button(role: .destructive, action: {
                            viewModel.removeNetwork(network.id)
                        }) {
                            Image(systemName: "trash")
                                .font(.system(size: 9))
                        }
                        .buttonStyle(.borderless)
                    }
                }
            }
            .listStyle(.plain)
        }
        .onAppear {
            Task { await viewModel.loadNetworks() }
        }
    }
}

// MARK: - Notification

extension Notification.Name {
    static let dockerExecShell = Notification.Name("pier.dockerExecShell")
}
