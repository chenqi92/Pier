import SwiftUI

/// SSH key management view for generating, viewing, and managing SSH keys.
struct SSHKeyManagerView: View {
    @State private var keys: [SSHKeyEntry] = []
    @State private var isGeneratingKey = false
    @State private var newKeyName = "id_ed25519"
    @State private var newKeyType = "ed25519"
    @State private var newKeyComment = ""
    @State private var showPassphraseField = false
    @State private var passphrase = ""
    @State private var selectedKey: SSHKeyEntry?
    @State private var publicKeyContent = ""
    @State private var errorMessage: String?

    struct SSHKeyEntry: Identifiable {
        let name: String
        let path: String
        let type: String        // rsa, ed25519, ecdsa
        let hasPublicKey: Bool
        let fingerprint: String

        var id: String { path }
    }

    var body: some View {
        VStack(spacing: 0) {
            headerView
            Divider()

            HSplitView {
                keyListSidebar
                    .frame(minWidth: 180, maxWidth: 240)

                keyDetailPanel
            }
        }
    }

    // MARK: - Header

    private var headerView: some View {
        HStack {
            Image(systemName: "key.fill")
                .foregroundColor(.orange)
                .font(.caption)
            Text("ssh.keyManager")
                .font(.caption)
                .fontWeight(.medium)
            Spacer()

            Button(action: { isGeneratingKey = true }) {
                Label("ssh.generateKey", systemImage: "plus")
                    .font(.caption)
            }
            .buttonStyle(.bordered)
            .controlSize(.mini)

            Button(action: { loadKeys() }) {
                Image(systemName: "arrow.clockwise")
                    .font(.caption)
            }
            .buttonStyle(.borderless)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .sheet(isPresented: $isGeneratingKey) {
            generateKeySheet
        }
    }

    // MARK: - Key List

    private var keyListSidebar: some View {
        List(keys, selection: Binding(
            get: { selectedKey?.id },
            set: { id in
                selectedKey = keys.first(where: { $0.id == id })
                if let key = selectedKey {
                    loadPublicKey(key)
                }
            }
        )) { key in
            HStack {
                Image(systemName: "key")
                    .font(.system(size: 9))
                    .foregroundColor(keyTypeColor(key.type))
                VStack(alignment: .leading, spacing: 1) {
                    Text(key.name)
                        .font(.system(size: 10))
                    Text(key.type.uppercased())
                        .font(.system(size: 8))
                        .foregroundColor(.secondary)
                }
            }
        }
        .listStyle(.sidebar)
        .onAppear { loadKeys() }
    }

    // MARK: - Key Detail

    private var keyDetailPanel: some View {
        Group {
            if let key = selectedKey {
                VStack(alignment: .leading, spacing: 12) {
                    // Key info
                    GroupBox("ssh.keyInfo") {
                        VStack(alignment: .leading, spacing: 6) {
                            infoRow("ssh.keyName", value: key.name)
                            infoRow("ssh.keyType", value: key.type.uppercased())
                            infoRow("ssh.keyPath", value: key.path)
                            infoRow("ssh.fingerprint", value: key.fingerprint)
                        }
                        .padding(8)
                    }

                    // Public key
                    if key.hasPublicKey {
                        GroupBox("ssh.publicKey") {
                            VStack(alignment: .leading, spacing: 4) {
                                ScrollView {
                                    Text(publicKeyContent)
                                        .font(.system(size: 9, design: .monospaced))
                                        .textSelection(.enabled)
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                }
                                .frame(maxHeight: 80)

                                HStack {
                                    Button(action: { copyPublicKey() }) {
                                        Label("ssh.copyPublicKey", systemImage: "doc.on.doc")
                                            .font(.system(size: 9))
                                    }
                                    .buttonStyle(.bordered)
                                    .controlSize(.mini)
                                    Spacer()
                                }
                            }
                            .padding(8)
                        }
                    }

                    Spacer()

                    // Delete button
                    HStack {
                        Spacer()
                        Button(role: .destructive, action: { deleteKey(key) }) {
                            Label("ssh.deleteKey", systemImage: "trash")
                                .font(.system(size: 9))
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.mini)
                    }
                }
                .padding(12)
            } else {
                VStack(spacing: 12) {
                    Image(systemName: "key.fill")
                        .font(.system(size: 30))
                        .foregroundColor(.secondary)
                    Text("ssh.selectKey")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }

    private func infoRow(_ label: LocalizedStringKey, value: String) -> some View {
        HStack(alignment: .top) {
            Text(label)
                .font(.system(size: 9, weight: .semibold))
                .foregroundColor(.secondary)
                .frame(width: 70, alignment: .trailing)
            Text(value)
                .font(.system(size: 9, design: .monospaced))
                .textSelection(.enabled)
        }
    }

    // MARK: - Generate Key Sheet

    private var generateKeySheet: some View {
        VStack(spacing: 16) {
            Text("ssh.generateNewKey")
                .font(.headline)

            Form {
                Picker("ssh.keyType", selection: $newKeyType) {
                    Text("Ed25519").tag("ed25519")
                    Text("RSA 4096").tag("rsa")
                    Text("ECDSA").tag("ecdsa")
                }

                TextField("ssh.keyName", text: $newKeyName)
                TextField("ssh.comment", text: $newKeyComment)

                Toggle("ssh.usePassphrase", isOn: $showPassphraseField)
                if showPassphraseField {
                    SecureField("ssh.passphrase", text: $passphrase)
                }
            }
            .formStyle(.grouped)

            if let error = errorMessage {
                Text(error)
                    .font(.caption)
                    .foregroundColor(.red)
            }

            HStack {
                Button("cancel") { isGeneratingKey = false }
                    .keyboardShortcut(.escape)
                Spacer()
                Button("ssh.generate") { generateKey() }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.return)
            }
        }
        .padding(20)
        .frame(width: 380)
    }

    // MARK: - Actions

    private func loadKeys() {
        let sshDir = NSHomeDirectory() + "/.ssh"
        guard let contents = try? FileManager.default.contentsOfDirectory(atPath: sshDir) else { return }

        let keyFiles = contents.filter { name in
            !name.hasPrefix(".") && !name.hasSuffix(".pub") &&
            !["known_hosts", "config", "authorized_keys", "known_hosts.old"].contains(name)
        }

        keys = keyFiles.compactMap { name in
            let path = sshDir + "/" + name
            let pubPath = path + ".pub"
            let hasPub = FileManager.default.fileExists(atPath: pubPath)

            // Detect key type
            let type: String
            if name.contains("ed25519") { type = "ed25519" }
            else if name.contains("ecdsa") { type = "ecdsa" }
            else if name.contains("rsa") { type = "rsa" }
            else { type = "unknown" }

            // Get fingerprint
            let fp = getFingerprint(path)

            return SSHKeyEntry(name: name, path: path, type: type, hasPublicKey: hasPub, fingerprint: fp)
        }
    }

    private func loadPublicKey(_ key: SSHKeyEntry) {
        let pubPath = key.path + ".pub"
        publicKeyContent = (try? String(contentsOfFile: pubPath, encoding: .utf8)) ?? ""
    }

    private func copyPublicKey() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(publicKeyContent, forType: .string)
    }

    private func deleteKey(_ key: SSHKeyEntry) {
        try? FileManager.default.removeItem(atPath: key.path)
        try? FileManager.default.removeItem(atPath: key.path + ".pub")
        selectedKey = nil
        loadKeys()
    }

    private func generateKey() {
        Task {
            let sshDir = NSHomeDirectory() + "/.ssh"
            let keyPath = sshDir + "/" + newKeyName

            var args = ["-t", newKeyType, "-f", keyPath]
            if newKeyType == "rsa" {
                args += ["-b", "4096"]
            }
            if !newKeyComment.isEmpty {
                args += ["-C", newKeyComment]
            }
            args += ["-N", showPassphraseField ? passphrase : ""]

            let result = await CommandRunner.shared.run("ssh-keygen", arguments: args)
            if result.succeeded {
                isGeneratingKey = false
                loadKeys()
            } else {
                errorMessage = result.output
            }
        }
    }

    private func getFingerprint(_ keyPath: String) -> String {
        // Synchronous for simplicity — runs quickly
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ssh-keygen")
        process.arguments = ["-lf", keyPath]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        try? process.run()
        process.waitUntilExit()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        let output = String(data: data, encoding: .utf8) ?? ""
        // Format: 2048 SHA256:xxx comment (RSA)
        return output.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func keyTypeColor(_ type: String) -> Color {
        switch type {
        case "ed25519": return .green
        case "rsa": return .blue
        case "ecdsa": return .orange
        default: return .secondary
        }
    }
}
