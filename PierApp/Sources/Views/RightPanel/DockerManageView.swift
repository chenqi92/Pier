import SwiftUI

/// Docker container/image management panel.
struct DockerManageView: View {
    @StateObject private var viewModel = DockerViewModel()
    var serviceManager: RemoteServiceManager?

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
                    Text(LS("docker.containers")).tag(DockerTab.containers)
                    Text(LS("docker.images")).tag(DockerTab.images)
                    Text(LS("docker.volumes")).tag(DockerTab.volumes)
                    if viewModel.isComposeAvailable {
                        Text(LS("docker.compose")).tag(DockerTab.compose)
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
        .onAppear {
            if let sm = serviceManager {
                viewModel.serviceManager = sm
                viewModel.isRemoteMode = sm.isConnected
                if sm.isConnected {
                    viewModel.checkDockerAvailability()
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
            Text(LS("docker.title"))
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
                        .help(LS("docker.stop"))

                        Button(action: { viewModel.restartContainer(container.id) }) {
                            Image(systemName: "arrow.clockwise")
                                .font(.system(size: 9))
                        }
                        .buttonStyle(.borderless)
                        .help(LS("docker.restart"))
                    } else {
                        Button(action: { viewModel.startContainer(container.id) }) {
                            Image(systemName: "play.fill")
                                .font(.system(size: 9))
                                .foregroundColor(.green)
                        }
                        .buttonStyle(.borderless)
                        .help(LS("docker.start"))
                    }

                    Button(action: { viewModel.viewContainerLogs(container.id) }) {
                        Image(systemName: "doc.text.magnifyingglass")
                            .font(.system(size: 9))
                    }
                    .buttonStyle(.borderless)
                    .help(LS("docker.viewLogs"))
                }
                .padding(.vertical, 2)
                .contextMenu {
                    Button(LS("docker.start")) { viewModel.startContainer(container.id) }
                    Divider()
                    Button(LS("docker.stop")) { viewModel.stopContainer(container.id) }
                    Divider()
                    Button(LS("docker.restart")) { viewModel.restartContainer(container.id) }
                    Divider()
                    Button(LS("docker.viewLogs")) { viewModel.viewContainerLogs(container.id) }
                    Button(LS("docker.execShell")) {
                        NotificationCenter.default.post(
                            name: .dockerExecShell,
                            object: container.id
                        )
                    }
                    Divider()
                    Button(LS("docker.remove"), role: .destructive) {
                        viewModel.removeContainer(container.id)
                    }
                }
            }
        }
        .listStyle(.plain)
        .overlay {
            if viewModel.containers.isEmpty && !viewModel.isLoading {
                Text(LS("docker.noContainers"))
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
    }

    // MARK: - Images

    @State private var pullImageName = ""
    @State private var showImageInspect = false
    @State private var imageInspectContent = ""
    @State private var tagInput = ""
    @State private var tagTargetId = ""
    @State private var showTagSheet = false

    private var imageListView: some View {
        VStack(spacing: 0) {
            // Pull & Prune toolbar
            HStack(spacing: 6) {
                TextField("docker.pullPlaceholder", text: $pullImageName)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 10))
                    .onSubmit {
                        guard !pullImageName.isEmpty else { return }
                        viewModel.pullImage(pullImageName)
                        pullImageName = ""
                    }
                Button(action: {
                    guard !pullImageName.isEmpty else { return }
                    viewModel.pullImage(pullImageName)
                    pullImageName = ""
                }) {
                    Image(systemName: "arrow.down.circle.fill")
                        .font(.system(size: 12))
                }
                .buttonStyle(.borderless)
                .disabled(pullImageName.isEmpty)
                .help("Pull image")

                Divider().frame(height: 14)

                Button(action: { viewModel.pruneImages() }) {
                    Image(systemName: "trash.circle")
                        .font(.system(size: 12))
                        .foregroundColor(.orange)
                }
                .buttonStyle(.borderless)
                .help("Prune dangling images")
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)

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

                        // Inline action buttons
                        Button(action: { viewModel.runImage(image.id) }) {
                            Image(systemName: "play.fill")
                                .font(.system(size: 9))
                        }
                        .buttonStyle(.borderless)
                        .help("Run container")

                        Button(action: { viewModel.removeImage(image.id) }) {
                            Image(systemName: "trash")
                                .font(.system(size: 9))
                                .foregroundColor(.red.opacity(0.7))
                        }
                        .buttonStyle(.borderless)
                        .help("Remove image")
                    }
                    .padding(.vertical, 2)
                    .contextMenu {
                        Button("Run Container") { viewModel.runImage(image.id) }
                        Divider()
                        Button("Inspect") {
                            Task {
                                if let json = await viewModel.inspectImage(image.id) {
                                    imageInspectContent = json
                                    showImageInspect = true
                                }
                            }
                        }
                        Button("History") {
                            Task {
                                if let history = await viewModel.imageHistory(image.id) {
                                    imageInspectContent = history
                                    showImageInspect = true
                                }
                            }
                        }
                        Button("Tag...") {
                            tagTargetId = image.id
                            tagInput = image.repository == "<none>" ? "" : "\(image.repository):\(image.tag)"
                            showTagSheet = true
                        }
                        Divider()
                        Button("Remove") { viewModel.removeImage(image.id) }
                        Button("Force Remove", role: .destructive) { viewModel.forceRemoveImage(image.id) }
                    }
                }
            }
            .listStyle(.plain)
            .overlay {
                if viewModel.images.isEmpty && !viewModel.isLoading {
                    Text("No images")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
        }
        .sheet(isPresented: $showImageInspect) {
            VStack(spacing: 0) {
                HStack {
                    Text("Image Details")
                        .font(.headline)
                    Spacer()
                    Button("Close") { showImageInspect = false }
                        .buttonStyle(.borderless)
                }
                .padding()
                Divider()
                ScrollView {
                    Text(imageInspectContent)
                        .font(.system(size: 10, design: .monospaced))
                        .textSelection(.enabled)
                        .padding()
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .frame(width: 500, height: 400)
        }
        .sheet(isPresented: $showTagSheet) {
            VStack(spacing: 12) {
                Text("Tag Image")
                    .font(.headline)
                TextField("repository:tag", text: $tagInput)
                    .textFieldStyle(.roundedBorder)
                HStack {
                    Button("Cancel") { showTagSheet = false }
                    Spacer()
                    Button("Apply") {
                        if !tagInput.isEmpty {
                            viewModel.tagImage(tagTargetId, newTag: tagInput)
                        }
                        showTagSheet = false
                    }
                    .buttonStyle(.borderedProminent)
                }
            }
            .padding()
            .frame(width: 300)
        }
    }

    // MARK: - Volumes

    @State private var showVolumeInspect = false
    @State private var volumeInspectContent = ""

    private var volumeListView: some View {
        VStack(spacing: 0) {
            // Prune toolbar
            HStack {
                Button(action: { viewModel.pruneVolumes() }) {
                    Label("Prune Unused", systemImage: "trash.circle")
                        .font(.caption)
                        .foregroundColor(.orange)
                }
                .buttonStyle(.bordered)
                .controlSize(.mini)
                Spacer()
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)

            List {
                ForEach(viewModel.volumes) { volume in
                    VStack(alignment: .leading, spacing: 4) {
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

                            // Browse volume files
                            Button(action: {
                                if viewModel.volumeBrowsePath == volume.mountpoint {
                                    // Toggle off
                                    viewModel.volumeBrowsePath = ""
                                    viewModel.volumeFiles = []
                                } else {
                                    viewModel.browseVolume(volume.mountpoint)
                                }
                            }) {
                                Image(systemName: "folder.fill")
                                    .font(.system(size: 9))
                                    .foregroundColor(.blue)
                            }
                            .buttonStyle(.borderless)
                            .help("Browse files")
                        }

                        // File listing panel (collapsible)
                        if viewModel.volumeBrowsePath == volume.mountpoint && !viewModel.volumeFiles.isEmpty {
                            VStack(alignment: .leading, spacing: 1) {
                                HStack {
                                    Text(volume.mountpoint)
                                        .font(.system(size: 8, design: .monospaced))
                                        .foregroundColor(.secondary)
                                    Spacer()
                                }
                                Divider()
                                ForEach(viewModel.volumeFiles, id: \.self) { fileLine in
                                    Text(fileLine)
                                        .font(.system(size: 9, design: .monospaced))
                                        .lineLimit(1)
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                }
                            }
                            .padding(6)
                            .background(Color.black.opacity(0.15))
                            .cornerRadius(4)
                        }

                        if viewModel.isVolumeFilesLoading && viewModel.volumeBrowsePath == volume.mountpoint {
                            ProgressView()
                                .controlSize(.small)
                                .frame(maxWidth: .infinity)
                        }
                    }
                    .padding(.vertical, 2)
                    .contextMenu {
                        Button("Inspect") {
                            Task {
                                if let json = await viewModel.inspectVolume(volume.name) {
                                    volumeInspectContent = json
                                    showVolumeInspect = true
                                }
                            }
                        }
                        Button("Browse Files") {
                            viewModel.browseVolume(volume.mountpoint)
                        }
                        Divider()
                        Button("Remove", role: .destructive) {
                            viewModel.removeVolume(volume.name)
                        }
                    }
                }
            }
            .listStyle(.plain)
            .overlay {
                if viewModel.volumes.isEmpty && !viewModel.isLoading {
                    Text("No volumes")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
        }
        .sheet(isPresented: $showVolumeInspect) {
            VStack(spacing: 0) {
                HStack {
                    Text("Volume Details")
                        .font(.headline)
                    Spacer()
                    Button("Close") { showVolumeInspect = false }
                        .buttonStyle(.borderless)
                }
                .padding()
                Divider()
                ScrollView {
                    Text(volumeInspectContent)
                        .font(.system(size: 10, design: .monospaced))
                        .textSelection(.enabled)
                        .padding()
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .frame(width: 500, height: 400)
        }
    }

    private var dockerUnavailableView: some View {
        VStack(spacing: 16) {
            Image(systemName: "shippingbox.circle")
                .font(.system(size: 36))
                .foregroundColor(.secondary)
            Text(LS("docker.notAvailable"))
                .font(.title3)
                .foregroundColor(.secondary)
            Text(LS("docker.notAvailableDesc"))
                .font(.system(size: 10))
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
            Button(LS("docker.retry")) { viewModel.checkDockerAvailability() }
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
                    Label(LS("docker.composeUp"), systemImage: "play.fill")
                        .font(.caption)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .tint(.green)

                Button(action: { viewModel.composeDown() }) {
                    Label(LS("docker.composeDown"), systemImage: "stop.fill")
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
                        .help(LS("docker.composeRestart"))
                    }
                    .padding(.vertical, 2)
                    .contextMenu {
                        Button(LS("docker.composeRestart")) { viewModel.composeRestart(service: service.name) }
                        Button(LS("docker.viewLogs")) { viewModel.composeLogs(service: service.name) }
                    }
                }
            }
            .listStyle(.plain)
            .overlay {
                if viewModel.composeServices.isEmpty && !viewModel.isLoading {
                    Text(LS("docker.noContainers"))
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
                    Label(LS("docker.createNetwork"), systemImage: "plus")
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
