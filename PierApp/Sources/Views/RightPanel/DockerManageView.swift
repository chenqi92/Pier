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

            // Operation feedback banner
            if viewModel.showOperationFeedback {
                HStack(spacing: 6) {
                    Image(systemName: viewModel.operationIsError ? "xmark.circle.fill" : "checkmark.circle.fill")
                        .foregroundColor(viewModel.operationIsError ? .red : .green)
                        .font(.caption)
                    Text(viewModel.operationMessage)
                        .font(.system(size: 10))
                        .lineLimit(2)
                    Spacer()
                    Button(action: { viewModel.showOperationFeedback = false }) {
                        Image(systemName: "xmark")
                            .font(.system(size: 8))
                            .foregroundColor(.secondary)
                    }
                    .buttonStyle(.borderless)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(viewModel.operationIsError ? Color.red.opacity(0.1) : Color.green.opacity(0.1))
                .transition(.move(edge: .top).combined(with: .opacity))
                .animation(.easeInOut(duration: 0.3), value: viewModel.showOperationFeedback)
            }

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
        // Container logs sheet
        .sheet(isPresented: $viewModel.showContainerLogs) {
            containerLogsSheet
        }
        // Container inspect sheet
        .sheet(isPresented: $viewModel.showContainerInspect) {
            containerInspectSheet
        }
    }

    // MARK: - Container Logs Sheet

    private var containerLogsSheet: some View {
        VStack(spacing: 0) {
            HStack {
                Image(systemName: "doc.text")
                    .foregroundColor(.blue)
                Text("Logs: \(viewModel.logsContainerName)")
                    .font(.headline)
                Spacer()
                Button("Close") { viewModel.showContainerLogs = false }
                    .buttonStyle(.borderless)
            }
            .padding()
            Divider()
            ScrollView {
                Text(viewModel.containerLogs)
                    .font(.system(size: 10, design: .monospaced))
                    .textSelection(.enabled)
                    .padding(8)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .frame(width: 600, height: 450)
    }

    // MARK: - Container Inspect Sheet

    private var containerInspectSheet: some View {
        VStack(spacing: 0) {
            HStack {
                Image(systemName: "magnifyingglass")
                    .foregroundColor(.blue)
                Text("Container Details")
                    .font(.headline)
                Spacer()
                Button("Close") { viewModel.showContainerInspect = false }
                    .buttonStyle(.borderless)
            }
            .padding()
            Divider()
            ScrollView {
                Text(viewModel.containerInspectContent)
                    .font(.system(size: 10, design: .monospaced))
                    .textSelection(.enabled)
                    .padding(8)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .frame(width: 600, height: 450)
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
                    Button("Inspect") { viewModel.inspectContainer(container.id) }
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

    // Run container configuration
    @State private var showRunDialog = false
    @State private var runImageName = ""       // image name:tag
    @State private var runContainerName = ""
    @State private var runPorts: [(host: String, container: String)] = [("", "")]
    @State private var runEnvVars: [(key: String, value: String)] = [("", "")]
    @State private var runVolumes: [(host: String, container: String)] = [("", "")]
    @State private var runRestartPolicy = "no"
    @State private var runCommand = ""

    private func openRunDialog(imageRef: String) {
        runImageName = imageRef
        runContainerName = ""
        runPorts = [("", "")]
        runEnvVars = [("", "")]
        runVolumes = [("", "")]
        runRestartPolicy = "no"
        runCommand = ""
        showRunDialog = true
    }

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
                        Button(action: {
                            let ref = image.repository == "<none>" ? image.id : "\(image.repository):\(image.tag)"
                            openRunDialog(imageRef: ref)
                        }) {
                            Image(systemName: "play.fill")
                                .font(.system(size: 9))
                                .foregroundColor(.green)
                        }
                        .buttonStyle(.borderless)
                        .help("Run container...")

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
                        Button("Run Container...") {
                            let ref = image.repository == "<none>" ? image.id : "\(image.repository):\(image.tag)"
                            openRunDialog(imageRef: ref)
                        }
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
        // Run container dialog
        .sheet(isPresented: $showRunDialog) {
            runContainerDialog
        }
    }

    // MARK: - Run Container Dialog

    private var runContainerDialog: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Image(systemName: "play.circle.fill")
                    .foregroundColor(.green)
                    .font(.title3)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Run Container")
                        .font(.headline)
                    Text(runImageName)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundColor(.secondary)
                }
                Spacer()
            }
            .padding()

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    // Container name
                    dialogSection(title: "Container Name", icon: "tag") {
                        TextField("e.g. my-app", text: $runContainerName)
                            .textFieldStyle(.roundedBorder)
                            .font(.system(size: 11))
                    }

                    // Port mappings
                    dialogSection(title: "Port Mappings", icon: "network") {
                        ForEach(runPorts.indices, id: \.self) { i in
                            HStack(spacing: 4) {
                                TextField("Host", text: Binding(
                                    get: { runPorts[i].host },
                                    set: { runPorts[i].host = $0 }
                                ))
                                .textFieldStyle(.roundedBorder)
                                .font(.system(size: 10))
                                .frame(width: 70)
                                Text(":")
                                    .foregroundColor(.secondary)
                                TextField("Container", text: Binding(
                                    get: { runPorts[i].container },
                                    set: { runPorts[i].container = $0 }
                                ))
                                .textFieldStyle(.roundedBorder)
                                .font(.system(size: 10))
                                .frame(width: 70)
                                if runPorts.count > 1 {
                                    Button(action: { runPorts.remove(at: i) }) {
                                        Image(systemName: "minus.circle.fill")
                                            .foregroundColor(.red)
                                            .font(.system(size: 11))
                                    }
                                    .buttonStyle(.borderless)
                                }
                            }
                        }
                        Button(action: { runPorts.append(("", "")) }) {
                            Label("Add Port", systemImage: "plus.circle")
                                .font(.system(size: 10))
                        }
                        .buttonStyle(.borderless)
                    }

                    // Environment variables
                    dialogSection(title: "Environment Variables", icon: "list.bullet.rectangle") {
                        ForEach(runEnvVars.indices, id: \.self) { i in
                            HStack(spacing: 4) {
                                TextField("KEY", text: Binding(
                                    get: { runEnvVars[i].key },
                                    set: { runEnvVars[i].key = $0 }
                                ))
                                .textFieldStyle(.roundedBorder)
                                .font(.system(size: 10))
                                Text("=")
                                    .foregroundColor(.secondary)
                                TextField("value", text: Binding(
                                    get: { runEnvVars[i].value },
                                    set: { runEnvVars[i].value = $0 }
                                ))
                                .textFieldStyle(.roundedBorder)
                                .font(.system(size: 10))
                                if runEnvVars.count > 1 {
                                    Button(action: { runEnvVars.remove(at: i) }) {
                                        Image(systemName: "minus.circle.fill")
                                            .foregroundColor(.red)
                                            .font(.system(size: 11))
                                    }
                                    .buttonStyle(.borderless)
                                }
                            }
                        }
                        Button(action: { runEnvVars.append(("", "")) }) {
                            Label("Add Variable", systemImage: "plus.circle")
                                .font(.system(size: 10))
                        }
                        .buttonStyle(.borderless)
                    }

                    // Volume mounts
                    dialogSection(title: "Volume Mounts", icon: "externaldrive") {
                        ForEach(runVolumes.indices, id: \.self) { i in
                            HStack(spacing: 4) {
                                TextField("Host path", text: Binding(
                                    get: { runVolumes[i].host },
                                    set: { runVolumes[i].host = $0 }
                                ))
                                .textFieldStyle(.roundedBorder)
                                .font(.system(size: 10))
                                Text("→")
                                    .foregroundColor(.secondary)
                                TextField("Container path", text: Binding(
                                    get: { runVolumes[i].container },
                                    set: { runVolumes[i].container = $0 }
                                ))
                                .textFieldStyle(.roundedBorder)
                                .font(.system(size: 10))
                                if runVolumes.count > 1 {
                                    Button(action: { runVolumes.remove(at: i) }) {
                                        Image(systemName: "minus.circle.fill")
                                            .foregroundColor(.red)
                                            .font(.system(size: 11))
                                    }
                                    .buttonStyle(.borderless)
                                }
                            }
                        }
                        Button(action: { runVolumes.append(("", "")) }) {
                            Label("Add Volume", systemImage: "plus.circle")
                                .font(.system(size: 10))
                        }
                        .buttonStyle(.borderless)
                    }

                    // Restart policy
                    dialogSection(title: "Restart Policy", icon: "arrow.counterclockwise") {
                        Picker("", selection: $runRestartPolicy) {
                            Text("No").tag("no")
                            Text("Always").tag("always")
                            Text("On Failure").tag("on-failure")
                            Text("Unless Stopped").tag("unless-stopped")
                        }
                        .pickerStyle(.segmented)
                        .font(.system(size: 10))
                    }

                    // Command override
                    dialogSection(title: "Command (optional)", icon: "terminal") {
                        TextField("e.g. /bin/sh", text: $runCommand)
                            .textFieldStyle(.roundedBorder)
                            .font(.system(size: 11, design: .monospaced))
                    }
                }
                .padding()
            }

            Divider()

            // Footer buttons
            HStack {
                Button("Cancel") {
                    showRunDialog = false
                }

                Spacer()

                Button(action: {
                    viewModel.runImageWithConfig(
                        image: runImageName,
                        containerName: runContainerName,
                        ports: runPorts.filter { !$0.host.isEmpty || !$0.container.isEmpty },
                        envVars: runEnvVars.filter { !$0.key.isEmpty },
                        volumes: runVolumes.filter { !$0.host.isEmpty || !$0.container.isEmpty },
                        restartPolicy: runRestartPolicy,
                        command: runCommand
                    )
                    showRunDialog = false
                }) {
                    Label("Create & Run", systemImage: "play.fill")
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.regular)
            }
            .padding()
        }
        .frame(width: 450, height: 550)
    }

    private func dialogSection<Content: View>(title: String, icon: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 4) {
                Image(systemName: icon)
                    .font(.system(size: 10))
                    .foregroundColor(.blue)
                Text(title)
                    .font(.system(size: 11, weight: .semibold))
            }
            content()
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
