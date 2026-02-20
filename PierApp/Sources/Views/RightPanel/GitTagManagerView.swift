import SwiftUI

/// Tag management popover: list, create, delete, push tags.
struct GitTagManagerView: View {
    @ObservedObject var gitViewModel: GitViewModel
    @State private var tags: [GitTag] = []
    @State private var newTagName = ""
    @State private var newTagMessage = ""
    @State private var showNewTag = false
    @State private var isLoading = false

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Image(systemName: "tag")
                    .foregroundColor(.orange)
                    .font(.caption)
                Text(LS("git.tags"))
                    .font(.caption)
                    .fontWeight(.medium)
                Spacer()

                Button(action: { showNewTag.toggle() }) {
                    Image(systemName: "plus")
                        .font(.system(size: 10))
                }
                .buttonStyle(.borderless)
                .help(LS("git.newTag"))

                Button(action: refreshTags) {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 10))
                }
                .buttonStyle(.borderless)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)

            Divider()

            // New tag form
            if showNewTag {
                VStack(spacing: 4) {
                    TextField(LS("git.tagName"), text: $newTagName)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: 10))

                    TextField(LS("git.tagMessage"), text: $newTagMessage)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: 10))

                    HStack {
                        Spacer()
                        Button(action: { showNewTag = false; newTagName = ""; newTagMessage = "" }) {
                            Text(LS("sftp.cancel"))
                                .font(.system(size: 9))
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.mini)

                        Button(action: createNewTag) {
                            Text(LS("sftp.create"))
                                .font(.system(size: 9))
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.mini)
                        .disabled(newTagName.isEmpty)
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 4)
            }

            // Tag list
            if isLoading {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if tags.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "tag")
                        .font(.system(size: 24))
                        .foregroundColor(.secondary)
                    Text(LS("git.noTags"))
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(tags) { tag in
                    tagRow(tag)
                }
                .listStyle(.plain)
            }
        }
        .onAppear { refreshTags() }
    }

    // MARK: - Helpers

    private func tagRow(_ tag: GitTag) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "tag.fill")
                .foregroundColor(.orange)
                .font(.system(size: 9))

            VStack(alignment: .leading, spacing: 1) {
                Text(tag.name)
                    .font(.system(size: 10, weight: .medium))
                    .lineLimit(1)

                HStack(spacing: 4) {
                    Text(tag.hash)
                        .font(.system(size: 8, design: .monospaced))
                        .foregroundColor(.secondary)

                    if let msg = tag.message {
                        Text(msg)
                            .font(.system(size: 8))
                            .foregroundColor(.secondary)
                            .lineLimit(1)
                    }
                }
            }

            Spacer()
        }
        .padding(.vertical, 1)
        .contextMenu {
            Button(LS("git.pushTag")) { gitViewModel.pushTag(tag.name) }
            Button(LS("git.copyHash")) {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(tag.hash, forType: .string)
            }
            Divider()
            Button(LS("git.deleteTag"), role: .destructive) {
                gitViewModel.deleteTag(tag.name)
                Task {
                    try? await Task.sleep(nanoseconds: 500_000_000)
                    refreshTags()
                }
            }
        }
    }

    private func createNewTag() {
        guard !newTagName.isEmpty else { return }
        gitViewModel.createTag(newTagName, message: newTagMessage.isEmpty ? nil : newTagMessage)
        newTagName = ""
        newTagMessage = ""
        showNewTag = false
        Task {
            try? await Task.sleep(nanoseconds: 500_000_000)
            refreshTags()
        }
    }

    private func refreshTags() {
        isLoading = true
        Task {
            tags = await gitViewModel.loadTags()
            isLoading = false
        }
    }
}
