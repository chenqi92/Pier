import SwiftUI

/// Submodule management view: list, init, update, sync submodules.
struct GitSubmoduleView: View {
    @ObservedObject var gitViewModel: GitViewModel
    @State private var submodules: [GitSubmodule] = []
    @State private var isLoading = false

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Image(systemName: "square.stack.3d.up")
                    .foregroundColor(.cyan)
                    .font(.caption)
                Text("Submodules")
                    .font(.caption)
                    .fontWeight(.medium)
                Spacer()

                Button(action: { gitViewModel.initSubmodules() }) {
                    Text("Init")
                        .font(.system(size: 9))
                }
                .buttonStyle(.bordered)
                .controlSize(.mini)

                Button(action: { gitViewModel.updateSubmodules() }) {
                    Text("Update")
                        .font(.system(size: 9))
                }
                .buttonStyle(.bordered)
                .controlSize(.mini)

                Button(action: { gitViewModel.syncSubmodules() }) {
                    Text("Sync")
                        .font(.system(size: 9))
                }
                .buttonStyle(.bordered)
                .controlSize(.mini)

                Button(action: refresh) {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 10))
                }
                .buttonStyle(.borderless)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)

            Divider()

            if isLoading {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if submodules.isEmpty {
                VStack(spacing: 12) {
                    Image(systemName: "square.stack.3d.up")
                        .font(.system(size: 30))
                        .foregroundColor(.secondary)
                    Text("No submodules")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(submodules) { submodule in
                    submoduleRow(submodule)
                }
                .listStyle(.plain)
            }
        }
        .onAppear { refresh() }
    }

    // MARK: - Row

    private func submoduleRow(_ submodule: GitSubmodule) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Image(systemName: submodule.status.icon)
                    .foregroundColor(submodule.status.color)
                    .font(.system(size: 10))

                Text(submodule.path)
                    .font(.system(size: 10, weight: .medium))
                    .lineLimit(1)

                Spacer()

                Text(String(submodule.commitHash.prefix(7)))
                    .font(.system(size: 8, design: .monospaced))
                    .foregroundColor(.secondary)
            }

            if !submodule.url.isEmpty {
                Text(submodule.url)
                    .font(.system(size: 9))
                    .foregroundColor(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
        }
        .padding(.vertical, 2)
        .contextMenu {
            Button("Copy Path") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(submodule.path, forType: .string)
            }
            if !submodule.url.isEmpty {
                Button("Copy URL") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(submodule.url, forType: .string)
                }
            }
        }
    }

    private func refresh() {
        isLoading = true
        Task {
            submodules = await gitViewModel.loadSubmodules()
            isLoading = false
        }
    }
}
