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
                    Text("Containers").tag(DockerTab.containers)
                    Text("Images").tag(DockerTab.images)
                    Text("Volumes").tag(DockerTab.volumes)
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
            Text("Docker")
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
                        .help("Stop")

                        Button(action: { viewModel.restartContainer(container.id) }) {
                            Image(systemName: "arrow.clockwise")
                                .font(.system(size: 9))
                        }
                        .buttonStyle(.borderless)
                        .help("Restart")
                    } else {
                        Button(action: { viewModel.startContainer(container.id) }) {
                            Image(systemName: "play.fill")
                                .font(.system(size: 9))
                                .foregroundColor(.green)
                        }
                        .buttonStyle(.borderless)
                        .help("Start")
                    }

                    Button(action: { viewModel.viewContainerLogs(container.id) }) {
                        Image(systemName: "doc.text.magnifyingglass")
                            .font(.system(size: 9))
                    }
                    .buttonStyle(.borderless)
                    .help("View Logs")
                }
                .padding(.vertical, 2)
                .contextMenu {
                    Button("Start") { viewModel.startContainer(container.id) }
                        .disabled(container.isRunning)
                    Button("Stop") { viewModel.stopContainer(container.id) }
                        .disabled(!container.isRunning)
                    Button("Restart") { viewModel.restartContainer(container.id) }
                    Divider()
                    Button("View Logs") { viewModel.viewContainerLogs(container.id) }
                    Button("Exec Shell") {
                        NotificationCenter.default.post(
                            name: .dockerExecShell,
                            object: container.id
                        )
                    }
                    Divider()
                    Button("Remove", role: .destructive) {
                        viewModel.removeContainer(container.id)
                    }
                }
            }
        }
        .listStyle(.plain)
        .overlay {
            if viewModel.containers.isEmpty && !viewModel.isLoading {
                Text("No containers")
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
                    Button("Run Container") { viewModel.runImage(image.id) }
                    Divider()
                    Button("Remove", role: .destructive) { viewModel.removeImage(image.id) }
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
            Text("Docker Not Available")
                .font(.caption)
                .foregroundColor(.secondary)
            Text("Make sure Docker Desktop\nis running")
                .font(.system(size: 10))
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
            Button("Retry") { viewModel.checkDockerAvailability() }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Notification

extension Notification.Name {
    static let dockerExecShell = Notification.Name("pier.dockerExecShell")
}
