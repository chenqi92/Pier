import SwiftUI

/// Left panel container with Files / Servers tab switcher.
struct LeftPanelView: View {
    @ObservedObject var fileViewModel: FileViewModel
    @ObservedObject var serviceManager: RemoteServiceManager
    @ObservedObject var terminalViewModel: TerminalViewModel

    enum Tab: String, CaseIterable {
        case files, servers
        var label: String {
            switch self {
            case .files:   return LS("leftPanel.files")
            case .servers: return LS("leftPanel.servers")
            }
        }
        var icon: String {
            switch self {
            case .files:   return "folder"
            case .servers: return "server.rack"
            }
        }
    }

    @State private var selectedTab: Tab = .files

    var body: some View {
        VStack(spacing: 0) {
            // Tab switcher
            tabBar

            Divider()

            // Content
            switch selectedTab {
            case .files:
                LocalFileView(viewModel: fileViewModel)
            case .servers:
                ServerListPanelView(serviceManager: serviceManager, terminalViewModel: terminalViewModel)
            }
        }
        .background(Color(nsColor: .controlBackgroundColor))
    }

    // MARK: - Tab Bar

    private var tabBar: some View {
        HStack(spacing: 2) {
            ForEach(Tab.allCases, id: \.self) { tab in
                Button(action: { withAnimation(.easeInOut(duration: 0.15)) { selectedTab = tab } }) {
                    HStack(spacing: 4) {
                        Image(systemName: tab.icon)
                            .font(.system(size: 10))
                        Text(tab.label)
                            .font(.system(size: 11, weight: selectedTab == tab ? .semibold : .regular))
                    }
                    .foregroundColor(selectedTab == tab ? .accentColor : .secondary)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(
                        RoundedRectangle(cornerRadius: 6)
                            .fill(selectedTab == tab
                                ? Color.accentColor.opacity(0.12)
                                : Color.clear)
                    )
                }
                .buttonStyle(.borderless)
            }
            Spacer()
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(Color(nsColor: .controlBackgroundColor))
    }
}

// MARK: - Server List Panel

struct ServerListPanelView: View {
    @ObservedObject var serviceManager: RemoteServiceManager
    @ObservedObject var terminalViewModel: TerminalViewModel

    @State private var showingEditor = false
    @State private var editingProfile: ConnectionProfile = .default
    @State private var passwordField = ""
    @State private var expandedGroups: Set<UUID> = []
    @State private var showingGroupNameAlert = false
    @State private var newGroupName = ""
    @State private var renamingGroup: ServerGroup?
    @State private var renameGroupName = ""
    @State private var searchText = ""

    /// Drag state: the profile being dragged
    @State private var draggingProfileId: UUID?

    var body: some View {
        VStack(spacing: 0) {
            // ── Top header (like file browser) ──
            headerBar

            Divider()

            // ── Search bar ──
            searchBar

            // ── Server tree ──
            if filteredProfiles.isEmpty && serviceManager.savedGroups.isEmpty {
                emptyState
            } else {
                serverTree
            }

            // ── Active tunnels ──
            if serviceManager.isConnected && !serviceManager.activeTunnels.isEmpty {
                Divider()
                tunnelStatus
            }
        }
        .sheet(isPresented: $showingEditor) {
            ProfileEditorView(
                profile: editingProfile,
                password: passwordField,
                groups: serviceManager.savedGroups,
                onSave: { updated, password in
                    serviceManager.saveProfile(updated)
                    if !password.isEmpty {
                        serviceManager.savePassword(password, for: updated)
                    }
                    showingEditor = false
                },
                onCancel: { showingEditor = false }
            )
        }
        .alert(LS("server.newGroup"), isPresented: $showingGroupNameAlert) {
            TextField(LS("server.groupName"), text: $newGroupName)
            Button(LS("conn.cancel"), role: .cancel) { newGroupName = "" }
            Button(LS("conn.save")) {
                if !newGroupName.isEmpty {
                    let group = ServerGroup(name: newGroupName)
                    serviceManager.saveGroup(group)
                    expandedGroups.insert(group.id)
                    newGroupName = ""
                }
            }
        }
        .alert(LS("server.renameGroup"), isPresented: Binding(
            get: { renamingGroup != nil },
            set: { if !$0 { renamingGroup = nil } }
        )) {
            TextField(LS("server.groupName"), text: $renameGroupName)
            Button(LS("conn.cancel"), role: .cancel) { renamingGroup = nil }
            Button(LS("conn.save")) {
                if var group = renamingGroup, !renameGroupName.isEmpty {
                    group.name = renameGroupName
                    serviceManager.saveGroup(group)
                    renamingGroup = nil
                }
            }
        }
        .onAppear {
            expandedGroups = Set(serviceManager.savedGroups.map(\.id))
        }
    }

    // MARK: - Computed

    /// Profiles filtered by search text
    private var filteredProfiles: [ConnectionProfile] {
        if searchText.isEmpty {
            return serviceManager.savedProfiles
        }
        let query = searchText.lowercased()
        return serviceManager.savedProfiles.filter {
            $0.name.lowercased().contains(query) ||
            $0.host.lowercased().contains(query) ||
            $0.username.lowercased().contains(query)
        }
    }

    // MARK: - Header Bar (like file browser)

    private var headerBar: some View {
        HStack(spacing: 6) {
            Image(systemName: "server.rack")
                .foregroundColor(.accentColor)
                .font(.system(size: 11))

            Text(LS("leftPanel.servers"))
                .font(.system(size: 11, weight: .medium))
                .lineLimit(1)

            Spacer()

            // Add group button
            Button(action: {
                newGroupName = ""
                showingGroupNameAlert = true
            }) {
                Image(systemName: "folder.badge.plus")
                    .font(.system(size: 11))
            }
            .buttonStyle(.borderless)
            .help(LS("server.newGroup"))

            // Add server button
            Button(action: addNew) {
                Image(systemName: "plus.circle")
                    .font(.system(size: 11))
            }
            .buttonStyle(.borderless)
            .help(LS("conn.addServer"))
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Color(nsColor: .controlBackgroundColor))
    }

    // MARK: - Search Bar

    private var searchBar: some View {
        HStack {
            Image(systemName: "magnifyingglass")
                .foregroundColor(.secondary)
                .font(.system(size: 10))

            TextField(LS("server.searchPlaceholder"), text: $searchText)
                .textFieldStyle(.plain)
                .font(.system(size: 11))

            if !searchText.isEmpty {
                Button(action: { searchText = "" }) {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundColor(.secondary)
                        .font(.system(size: 10))
                }
                .buttonStyle(.borderless)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(Color(nsColor: .textBackgroundColor).opacity(0.5))
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(Color(nsColor: .separatorColor).opacity(0.3))
                .frame(height: 0.5)
        }
    }

    // MARK: - Empty State

    private var emptyState: some View {
        VStack(spacing: 12) {
            if searchText.isEmpty {
                Image(systemName: "server.rack")
                    .font(.system(size: 32))
                    .foregroundColor(.secondary.opacity(0.5))
                Text(LS("conn.noServers"))
                    .font(.system(size: 12))
                    .foregroundColor(.secondary)
                Text(LS("conn.addServerHint"))
                    .font(.system(size: 10))
                    .foregroundColor(.secondary.opacity(0.6))
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 20)
            } else {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 28))
                    .foregroundColor(.secondary.opacity(0.4))
                Text(LS("server.noResults"))
                    .font(.system(size: 12))
                    .foregroundColor(.secondary)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Server Tree

    private var serverTree: some View {
        ScrollView {
            LazyVStack(spacing: 1) {
                // When searching, show flat results
                if !searchText.isEmpty {
                    ForEach(filteredProfiles) { profile in
                        serverRow(profile)
                    }
                } else {
                    // Groups with their servers
                    ForEach(serviceManager.savedGroups) { group in
                        groupSection(group)
                    }

                    // Ungrouped servers
                    let ungrouped = serviceManager.savedProfiles.filter { $0.groupId == nil }
                    if !ungrouped.isEmpty {
                        if !serviceManager.savedGroups.isEmpty {
                            ungroupedHeader
                        }
                        ForEach(ungrouped) { profile in
                            serverRow(profile)
                        }
                    }
                }
            }
            .padding(.vertical, 4)
        }
    }

    private func groupSection(_ group: ServerGroup) -> some View {
        let isExpanded = expandedGroups.contains(group.id)
        let groupProfiles = serviceManager.savedProfiles.filter { $0.groupId == group.id }

        return VStack(spacing: 0) {
            // Group header — also a drop target
            Button(action: {
                withAnimation(.easeInOut(duration: 0.15)) {
                    if isExpanded {
                        expandedGroups.remove(group.id)
                    } else {
                        expandedGroups.insert(group.id)
                    }
                }
            }) {
                HStack(spacing: 6) {
                    Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                        .font(.system(size: 8, weight: .bold))
                        .foregroundColor(.secondary)
                        .frame(width: 10)
                    Image(systemName: "folder.fill")
                        .font(.system(size: 10))
                        .foregroundColor(.accentColor.opacity(0.8))
                    Text(group.name)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(.primary)
                    Text("(\(groupProfiles.count))")
                        .font(.system(size: 9))
                        .foregroundColor(.secondary)
                    Spacer()
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .onDrop(of: [.text], isTargeted: nil) { providers in
                handleDrop(providers: providers, toGroupId: group.id)
            }
            .contextMenu {
                Button(action: {
                    renameGroupName = group.name
                    renamingGroup = group
                }) {
                    Label(LS("server.renameGroup"), systemImage: "pencil")
                }
                Button(action: {
                    editingProfile = .default
                    editingProfile.groupId = group.id
                    passwordField = ""
                    showingEditor = true
                }) {
                    Label(LS("conn.addServer"), systemImage: "plus")
                }
                Divider()
                Button(role: .destructive, action: { serviceManager.deleteGroup(group) }) {
                    Label(LS("server.deleteGroup"), systemImage: "trash")
                }
            }

            // Expanded servers
            if isExpanded {
                ForEach(groupProfiles) { profile in
                    serverRow(profile, indented: true)
                }
            }
        }
    }

    private var ungroupedHeader: some View {
        HStack(spacing: 6) {
            Image(systemName: "tray")
                .font(.system(size: 10))
                .foregroundColor(.secondary)
            Text(LS("server.ungrouped"))
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(.secondary)
            Spacer()
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .onDrop(of: [.text], isTargeted: nil) { providers in
            handleDrop(providers: providers, toGroupId: nil)
        }
    }

    private func serverRow(_ profile: ConnectionProfile, indented: Bool = false) -> some View {
        ServerRowView(
            profile: profile,
            isConnected: isProfileConnected(profile),
            isConnecting: serviceManager.isConnecting,
            anyConnected: serviceManager.isConnected,
            groups: serviceManager.savedGroups,
            onConnect: { connectProfile(profile) },
            onDisconnect: { serviceManager.disconnect() },
            onEdit: { editProfile(profile) },
            onDelete: { serviceManager.deleteProfile(profile) },
            onMoveToGroup: { groupId in serviceManager.moveProfile(profile, toGroup: groupId) }
        )
        .padding(.leading, indented ? 12 : 0)
        .onDrag {
            draggingProfileId = profile.id
            return NSItemProvider(object: profile.id.uuidString as NSString)
        }
    }

    // MARK: - Tunnel Status

    private var tunnelStatus: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 4) {
                Image(systemName: "network")
                    .font(.system(size: 9))
                    .foregroundColor(.green)
                Text(LS("tunnel.active"))
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundColor(.secondary)
            }
            .padding(.horizontal, 10)
            .padding(.top, 6)

            ForEach(serviceManager.activeTunnels) { tunnel in
                HStack(spacing: 4) {
                    Text(tunnel.serviceName)
                        .font(.system(size: 9, weight: .medium))
                    Spacer()
                    Text("127.0.0.1:\(tunnel.localPort) → :\(tunnel.remotePort)")
                        .font(.system(size: 9, design: .monospaced))
                        .foregroundColor(.secondary)
                }
                .padding(.horizontal, 10)
            }
        }
        .padding(.bottom, 6)
    }

    // MARK: - Drag & Drop

    private func handleDrop(providers: [NSItemProvider], toGroupId: UUID?) -> Bool {
        guard let provider = providers.first else { return false }
        provider.loadItem(forTypeIdentifier: "public.text", options: nil) { data, _ in
            guard let data = data as? Data,
                  let idString = String(data: data, encoding: .utf8),
                  let profileId = UUID(uuidString: idString) else { return }
            DispatchQueue.main.async {
                if let profile = serviceManager.savedProfiles.first(where: { $0.id == profileId }) {
                    serviceManager.moveProfile(profile, toGroup: toGroupId)
                }
                draggingProfileId = nil
            }
        }
        return true
    }

    // MARK: - Actions

    private func addNew() {
        editingProfile = .default
        passwordField = ""
        showingEditor = true
    }

    private func editProfile(_ profile: ConnectionProfile) {
        editingProfile = profile
        passwordField = ""
        showingEditor = true
    }

    private func connectProfile(_ profile: ConnectionProfile) {
        // Build SSH arguments
        var args: [String] = []
        args.append("\(profile.username)@\(profile.host)")
        args.append("-p")
        args.append("\(profile.port)")
        args.append("-o")
        args.append("StrictHostKeyChecking=no")

        if profile.authType == .keyFile, let keyPath = profile.keyFilePath {
            args.append("-i")
            args.append(keyPath)
        }

        // Load password from Keychain
        let password: String? = profile.authType == .password
            ? (try? KeychainService.shared.load(key: "ssh_\(profile.id.uuidString)"))
            : nil

        let title = profile.name.isEmpty ? profile.host : profile.name
        terminalViewModel.addNewTab(
            title: title,
            isSSH: true,
            profile: profile,
            preloadedPassword: password,
            sshProgram: "/usr/bin/ssh",
            sshArgs: args
        )

        // Password is auto-typed by TerminalNSView when it detects the SSH prompt
    }

    private func isProfileConnected(_ profile: ConnectionProfile) -> Bool {
        serviceManager.isConnected && serviceManager.connectedHost == "\(profile.host):\(profile.port)"
    }
}

// MARK: - Server Row

struct ServerRowView: View {
    let profile: ConnectionProfile
    let isConnected: Bool
    let isConnecting: Bool
    let anyConnected: Bool
    let groups: [ServerGroup]
    let onConnect: () -> Void
    let onDisconnect: () -> Void
    let onEdit: () -> Void
    let onDelete: () -> Void
    let onMoveToGroup: (UUID?) -> Void

    @State private var isHovered = false

    var body: some View {
        HStack(spacing: 8) {
            // Status dot
            Circle()
                .fill(isConnected ? Color.green : Color.secondary.opacity(0.25))
                .frame(width: 6, height: 6)

            // Server info
            VStack(alignment: .leading, spacing: 1) {
                Text(profile.name.isEmpty ? profile.host : profile.name)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(isConnected ? .primary : .secondary)
                    .lineLimit(1)
                Text("\(profile.username)@\(profile.host):\(profile.port)")
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundColor(.secondary.opacity(0.7))
                    .lineLimit(1)
            }

            Spacer()

            // Action buttons (visible on hover or when connected)
            if isHovered || isConnected {
                if isConnected {
                    Button(action: onDisconnect) {
                        Image(systemName: "bolt.horizontal.circle.fill")
                            .font(.system(size: 14))
                            .foregroundColor(.red.opacity(0.8))
                    }
                    .buttonStyle(.borderless)
                    .help(LS("ssh.disconnect"))
                } else {
                    Button(action: onConnect) {
                        Image(systemName: "bolt.circle.fill")
                            .font(.system(size: 14))
                            .foregroundColor(.accentColor)
                    }
                    .buttonStyle(.borderless)
                    .help(LS("conn.connect"))
                    .disabled(isConnecting || anyConnected)
                }
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(isConnected
                    ? Color.green.opacity(0.06)
                    : (isHovered ? Color(nsColor: .controlBackgroundColor).opacity(0.6) : Color.clear))
        )
        .padding(.horizontal, 4)
        .contentShape(Rectangle())
        .onHover { hovering in
            withAnimation(.easeInOut(duration: 0.12)) { isHovered = hovering }
        }
        .contextMenu {
            Button(action: onConnect) {
                Label(LS("conn.connect"), systemImage: "bolt.circle")
            }
            .disabled(isConnecting || anyConnected)

            Button(action: onEdit) {
                Label(LS("conn.editServer"), systemImage: "pencil")
            }

            // Move to group submenu
            if !groups.isEmpty {
                Menu(LS("server.moveToGroup")) {
                    ForEach(groups) { group in
                        Button(action: { onMoveToGroup(group.id) }) {
                            Label(group.name, systemImage: profile.groupId == group.id ? "checkmark" : "folder")
                        }
                    }
                    Divider()
                    Button(action: { onMoveToGroup(nil) }) {
                        Label(LS("server.ungrouped"), systemImage: profile.groupId == nil ? "checkmark" : "tray")
                    }
                }
            }

            Divider()

            Button(role: .destructive, action: onDelete) {
                Label(LS("conn.deleteServer"), systemImage: "trash")
            }
        }
        .onTapGesture(count: 2) {
            if !isConnected && !isConnecting && !anyConnected {
                onConnect()
            }
        }
    }
}
