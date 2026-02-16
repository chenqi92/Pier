import SwiftUI

/// Remote management popover: list, add, remove, edit, fetch remotes.
struct GitRemoteManagerView: View {
    @ObservedObject var gitViewModel: GitViewModel
    @State private var remotes: [GitRemote] = []
    @State private var showAddRemote = false
    @State private var newRemoteName = ""
    @State private var newRemoteURL = ""
    @State private var isLoading = false

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Image(systemName: "network")
                    .foregroundColor(.blue)
                    .font(.caption)
                Text(LS("git.remotes"))
                    .font(.caption)
                    .fontWeight(.medium)
                Spacer()

                Button(action: { showAddRemote.toggle() }) {
                    Image(systemName: "plus")
                        .font(.system(size: 10))
                }
                .buttonStyle(.borderless)
                .help(LS("git.addRemote"))

                Button(action: { gitViewModel.fetchRemote(nil) }) {
                    Image(systemName: "arrow.down.circle")
                        .font(.system(size: 10))
                }
                .buttonStyle(.borderless)
                .help(LS("git.fetchRemote"))

                Button(action: refreshRemotes) {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 10))
                }
                .buttonStyle(.borderless)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)

            Divider()

            // Add remote form
            if showAddRemote {
                VStack(spacing: 4) {
                    TextField(LS("git.remoteName"), text: $newRemoteName)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: 10))

                    TextField(LS("git.remoteURL"), text: $newRemoteURL)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: 10))

                    HStack {
                        Spacer()
                        Button(action: { showAddRemote = false; newRemoteName = ""; newRemoteURL = "" }) {
                            Text(LS("sftp.cancel"))
                                .font(.system(size: 9))
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.mini)

                        Button(action: addNewRemote) {
                            Text(LS("git.addRemote"))
                                .font(.system(size: 9))
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.mini)
                        .disabled(newRemoteName.isEmpty || newRemoteURL.isEmpty)
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 4)
            }

            // Remote list
            if isLoading {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if remotes.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "network")
                        .font(.system(size: 24))
                        .foregroundColor(.secondary)
                    Text("No remotes configured")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(remotes) { remote in
                    remoteRow(remote)
                }
                .listStyle(.plain)
            }
        }
        .onAppear { refreshRemotes() }
    }

    // MARK: - Helpers

    private func remoteRow(_ remote: GitRemote) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                Image(systemName: "network")
                    .foregroundColor(.blue)
                    .font(.system(size: 9))

                Text(remote.name)
                    .font(.system(size: 10, weight: .semibold))

                Spacer()
            }

            Text(remote.fetchURL)
                .font(.system(size: 9, design: .monospaced))
                .foregroundColor(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .padding(.vertical, 2)
        .contextMenu {
            Button(LS("git.fetchRemote")) { gitViewModel.fetchRemote(remote.name) }
            Divider()
            Button("Copy URL") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(remote.fetchURL, forType: .string)
            }
            Divider()
            Button(LS("git.removeRemote"), role: .destructive) {
                gitViewModel.removeRemote(remote.name)
                Task {
                    try? await Task.sleep(nanoseconds: 500_000_000)
                    refreshRemotes()
                }
            }
        }
    }

    private func addNewRemote() {
        guard !newRemoteName.isEmpty, !newRemoteURL.isEmpty else { return }
        gitViewModel.addRemote(newRemoteName, url: newRemoteURL)
        newRemoteName = ""
        newRemoteURL = ""
        showAddRemote = false
        Task {
            try? await Task.sleep(nanoseconds: 500_000_000)
            refreshRemotes()
        }
    }

    private func refreshRemotes() {
        isLoading = true
        Task {
            remotes = await gitViewModel.loadRemotes()
            isLoading = false
        }
    }
}
