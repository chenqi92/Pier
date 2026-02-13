import SwiftUI
import UniformTypeIdentifiers

/// Left panel: Local file system browser with tree view.
struct LocalFileView: View {
    @ObservedObject var viewModel: FileViewModel
    @State private var searchText = ""
    @State private var isSearching = false

    var body: some View {
        VStack(spacing: 0) {
            // Header with current path
            headerBar

            Divider()

            // Search field
            searchBar

            // File tree
            if viewModel.isLoading {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                fileTreeList
            }
        }
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.5))
    }

    // MARK: - Header

    private var headerBar: some View {
        HStack {
            Image(systemName: "folder.fill")
                .foregroundColor(.accentColor)

            Text(viewModel.currentPath.lastPathComponent)
                .font(.caption)
                .fontWeight(.medium)
                .lineLimit(1)

            Spacer()

            Menu {
                Button("Home") { viewModel.navigateTo(FileManager.default.homeDirectoryForCurrentUser.path) }
                Button("Desktop") { viewModel.navigateTo(NSHomeDirectory() + "/Desktop") }
                Button("Projects") { viewModel.navigateTo(NSHomeDirectory() + "/Projects") }
                Divider()
                Button("Choose Folder...") { viewModel.openFolderPicker() }
            } label: {
                Image(systemName: "ellipsis.circle")
                    .font(.caption)
            }
            .menuStyle(.borderlessButton)

            Button(action: { viewModel.refresh() }) {
                Image(systemName: "arrow.clockwise")
                    .font(.caption)
            }
            .buttonStyle(.borderless)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    // MARK: - Search

    private var searchBar: some View {
        HStack {
            Image(systemName: "magnifyingglass")
                .foregroundColor(.secondary)
                .font(.caption)

            TextField("Search files...", text: $searchText)
                .textFieldStyle(.plain)
                .font(.caption)
                .onChange(of: searchText) { _, newValue in
                    viewModel.filterFiles(query: newValue)
                }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(Color(nsColor: .textBackgroundColor))
    }

    // MARK: - File Tree

    private var fileTreeList: some View {
        List(viewModel.displayedFiles, children: \.children) { item in
            FileTreeRow(item: item)
                .onTapGesture {
                    viewModel.handleTap(item)
                }
                .contextMenu {
                    fileContextMenu(for: item)
                }
                .onDrag {
                    NSItemProvider(contentsOf: URL(fileURLWithPath: item.path))
                        ?? NSItemProvider()
                }
        }
        .listStyle(.sidebar)
    }

    // MARK: - Context Menu

    @ViewBuilder
    private func fileContextMenu(for item: FileItem) -> some View {
        Button("Open in Terminal") {
            if item.isDirectory {
                NotificationCenter.default.post(
                    name: .openPathInTerminal,
                    object: item.path
                )
            }
        }

        Button("Reveal in Finder") {
            NSWorkspace.shared.selectFile(item.path, inFileViewerRootedAtPath: "")
        }

        Divider()

        Button("Copy Path") {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(item.path, forType: .string)
        }

        Button("Copy Name") {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(item.name, forType: .string)
        }

        Divider()

        if !item.isDirectory && item.name.hasSuffix(".md") {
            Button("Preview Markdown") {
                NotificationCenter.default.post(
                    name: .previewMarkdown,
                    object: item.path
                )
            }
        }

        Divider()

        Button("Delete", role: .destructive) {
            viewModel.deleteFile(item)
        }
    }
}

// MARK: - File Tree Row

struct FileTreeRow: View {
    let item: FileItem

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: item.iconName)
                .foregroundColor(item.iconColor)
                .font(.caption)
                .frame(width: 16)

            Text(item.name)
                .font(.system(.caption, design: .default))
                .lineLimit(1)

            Spacer()

            if !item.isDirectory {
                Text(item.formattedSize)
                    .font(.system(size: 9))
                    .foregroundColor(.secondary)
            }
        }
        .padding(.vertical, 1)
    }
}

// MARK: - Notification Names

extension Notification.Name {
    static let openPathInTerminal = Notification.Name("pier.openPathInTerminal")
    static let previewMarkdown = Notification.Name("pier.previewMarkdown")
}
