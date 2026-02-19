import SwiftUI

/// SSH Connection Manager — save, edit, delete, and connect to server profiles.
struct ConnectionManagerView: View {
    @EnvironmentObject var serviceManager: RemoteServiceManager
    @Environment(\.dismiss) var dismiss

    @State private var editingProfile: ConnectionProfile = .default
    @State private var passwordField: String = ""
    @State private var showingEditor: Bool = false

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Text(LS("conn.title"))
                    .font(.headline)
                Spacer()
                Button(action: addNew) {
                    Image(systemName: "plus.circle.fill")
                        .font(.title3)
                }
                .buttonStyle(.borderless)
                .help(LS("conn.addServer"))

                Button(action: { dismiss() }) {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundColor(.secondary)
                }
                .buttonStyle(.borderless)
            }
            .padding()

            Divider()

            if serviceManager.savedProfiles.isEmpty {
                emptyState
            } else {
                profileList
            }

            // Active tunnels
            if !serviceManager.activeTunnels.isEmpty {
                Divider()
                tunnelStatus
            }
        }
        .frame(width: 440, height: 540)
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
    }

    // MARK: - Empty State

    private var emptyState: some View {
        VStack(spacing: 16) {
            Image(systemName: "server.rack")
                .font(.system(size: 40))
                .foregroundColor(.secondary)
            Text(LS("conn.noServers"))
                .font(.callout)
                .foregroundColor(.secondary)
            Button(LS("conn.addServer")) { addNew() }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Profile List

    private var profileList: some View {
        List {
            ForEach(serviceManager.savedProfiles) { profile in
                HStack(spacing: 10) {
                    // Status indicator
                    Circle()
                        .fill(isProfileConnected(profile) ? Color.green : Color.secondary.opacity(0.3))
                        .frame(width: 8, height: 8)

                    VStack(alignment: .leading, spacing: 2) {
                        Text(profile.name.isEmpty ? profile.host : profile.name)
                            .font(.system(.body, design: .default))
                            .fontWeight(.medium)
                        Text("\(profile.username)@\(profile.host):\(profile.port)")
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundColor(.secondary)
                    }

                    Spacer()

                    // Connect / Disconnect
                    if isProfileConnected(profile) {
                        Button(action: { serviceManager.disconnect() }) {
                            Image(systemName: "bolt.horizontal.circle.fill")
                                .foregroundColor(.red)
                        }
                        .buttonStyle(.borderless)
                        .help(LS("ssh.disconnect"))
                    } else {
                        Button(action: { connectProfile(profile) }) {
                            Image(systemName: "bolt.circle.fill")
                                .foregroundColor(.accentColor)
                        }
                        .buttonStyle(.borderless)
                        .help(LS("conn.connect"))
                        .disabled(serviceManager.isConnecting || serviceManager.isConnected)
                    }
                }
                .padding(.vertical, 4)
                .contextMenu {
                    Button(LS("conn.editServer")) { editProfile(profile) }
                    Divider()
                    Button(LS("conn.deleteServer"), role: .destructive) {
                        serviceManager.deleteProfile(profile)
                    }
                }
            }
        }
        .listStyle(.inset)
    }

    // MARK: - Tunnel Status

    private var tunnelStatus: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Image(systemName: "network")
                    .font(.caption2)
                    .foregroundColor(.green)
                Text(LS("tunnel.active"))
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundColor(.secondary)
            }
            .padding(.horizontal, 12)
            .padding(.top, 6)

            ForEach(serviceManager.activeTunnels) { tunnel in
                HStack(spacing: 6) {
                    Text(tunnel.serviceName)
                        .font(.system(size: 10, weight: .medium))
                    Spacer()
                    Text("127.0.0.1:\(tunnel.localPort) → :\(tunnel.remotePort)")
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundColor(.secondary)
                }
                .padding(.horizontal, 12)
            }
        }
        .padding(.bottom, 8)
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
        serviceManager.connect(profile: profile)
        dismiss()
    }

    private func isProfileConnected(_ profile: ConnectionProfile) -> Bool {
        serviceManager.isConnected && serviceManager.connectedHost == "\(profile.host):\(profile.port)"
    }
}

// MARK: - Profile Editor

struct ProfileEditorView: View {
    @State var profile: ConnectionProfile
    @State var password: String
    var groups: [ServerGroup]
    var onSave: (ConnectionProfile, String) -> Void
    var onCancel: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Text(profile.name.isEmpty ? LS("conn.addServer") : LS("conn.editServer"))
                    .font(.headline)
                Spacer()
            }
            .padding()

            Divider()

            Form {
                TextField(LS("conn.name"), text: $profile.name)
                    .textFieldStyle(.roundedBorder)
                TextField(LS("conn.host"), text: $profile.host)
                    .textFieldStyle(.roundedBorder)
                HStack {
                    Text(LS("conn.port"))
                    TextField("", value: $profile.port, format: .number)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 80)
                }
                TextField(LS("conn.username"), text: $profile.username)
                    .textFieldStyle(.roundedBorder)

                Picker(LS("conn.authType"), selection: $profile.authType) {
                    ForEach(ConnectionProfile.AuthType.allCases, id: \.self) { type in
                        Text(type.displayName).tag(type)
                    }
                }
                .pickerStyle(.segmented)

                if profile.authType == .password {
                    SecureField(LS("conn.password"), text: $password)
                        .textFieldStyle(.roundedBorder)
                } else {
                    HStack {
                        TextField(LS("conn.keyFile"), text: Binding(
                            get: { profile.keyFilePath ?? "" },
                            set: { profile.keyFilePath = $0.isEmpty ? nil : $0 }
                        ))
                        .textFieldStyle(.roundedBorder)

                        Button(LS("conn.browse")) {
                            let panel = NSOpenPanel()
                            panel.canChooseFiles = true
                            panel.canChooseDirectories = false
                            panel.allowedContentTypes = [.data]
                            panel.directoryURL = FileManager.default.homeDirectoryForCurrentUser
                                .appendingPathComponent(".ssh")
                            if panel.runModal() == .OK, let url = panel.url {
                                profile.keyFilePath = url.path
                            }
                        }
                        .controlSize(.small)
                    }
                }

                // Group picker
                if !groups.isEmpty {
                    Picker(LS("server.group"), selection: Binding(
                        get: { profile.groupId },
                        set: { profile.groupId = $0 }
                    )) {
                        Text(LS("server.ungrouped")).tag(nil as UUID?)
                        ForEach(groups) { group in
                            Text(group.name).tag(group.id as UUID?)
                        }
                    }
                }
            }
            .padding(.horizontal)
            .padding(.vertical, 8)

            Divider()

            // Buttons
            HStack {
                Button(LS("conn.cancel")) { onCancel() }
                    .keyboardShortcut(.cancelAction)
                Spacer()
                Button(LS("conn.save")) { onSave(profile, password) }
                    .keyboardShortcut(.defaultAction)
                    .disabled(profile.host.isEmpty || profile.username.isEmpty)
            }
            .padding()
        }
        .frame(width: 420)
        .fixedSize(horizontal: false, vertical: true)
    }
}
