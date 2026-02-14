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
                .font(.system(size: 11))

            Text(viewModel.currentPath.lastPathComponent)
                .font(.system(size: 11))
                .fontWeight(.medium)
                .lineLimit(1)

            Spacer()

            Menu {
                Button(LS("files.home")) { viewModel.navigateTo(FileManager.default.homeDirectoryForCurrentUser.path) }
                Button(LS("files.desktop")) { viewModel.navigateTo(NSHomeDirectory() + "/Desktop") }
                Button(LS("files.projects")) { viewModel.navigateTo(NSHomeDirectory() + "/Projects") }
                Divider()
                Button(LS("files.chooseFolder")) { viewModel.openFolderPicker() }
            } label: {
                Image(systemName: "ellipsis.circle")
                    .font(.system(size: 11))
            }
            .menuStyle(.borderlessButton)

            Button(action: { viewModel.refresh() }) {
                Image(systemName: "arrow.clockwise")
                    .font(.system(size: 11))
            }
            .buttonStyle(.borderless)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.3))
    }

    // MARK: - Search

    private var searchBar: some View {
        HStack {
            Image(systemName: "magnifyingglass")
                .foregroundColor(.secondary)
                .font(.system(size: 10))

            TextField(LS("files.searchPlaceholder"), text: $searchText)
                .textFieldStyle(.plain)
                .font(.system(size: 11))
                .onChange(of: searchText) { _, newValue in
                    viewModel.filterFiles(query: newValue)
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

    // MARK: - File Tree

    private var fileTreeList: some View {
        List {
            ForEach(viewModel.displayedFiles) { item in
                FileTreeNode(item: item, viewModel: viewModel)
            }
        }
        .listStyle(.sidebar)
        .transaction { transaction in
            // Disable the default SwiftUI "drop-in" animation for tree expand/collapse
            transaction.animation = nil
        }
    }

    // MARK: - Context Menu

    @ViewBuilder
    static func fileContextMenu(for item: FileItem, viewModel: FileViewModel) -> some View {
        Button(LS("files.openInTerminal")) {
            if item.isDirectory {
                NotificationCenter.default.post(
                    name: .openPathInTerminal,
                    object: item.path
                )
            }
        }

        Button(LS("files.revealInFinder")) {
            NSWorkspace.shared.selectFile(item.path, inFileViewerRootedAtPath: "")
        }

        Divider()

        Button(LS("files.copyPath")) {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(item.path, forType: .string)
        }

        Button(LS("files.copyName")) {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(item.name, forType: .string)
        }

        Divider()

        if !item.isDirectory && item.name.hasSuffix(".md") {
            Button(LS("files.previewMarkdown")) {
                NotificationCenter.default.post(
                    name: .previewMarkdown,
                    object: item.path
                )
            }
        }

        Divider()

        Button(LS("files.delete"), role: .destructive) {
            viewModel.deleteFile(item)
        }
    }
}

// MARK: - File Tree Node (Recursive DisclosureGroup)

/// A single node in the file tree. Directories use `DisclosureGroup` for
/// programmatic expand/collapse; files are plain rows.
struct FileTreeNode: View {
    @ObservedObject var item: FileItem
    @ObservedObject var viewModel: FileViewModel

    var body: some View {
        if item.isDirectory {
            DisclosureGroup(isExpanded: $item.isExpanded) {
                if let children = item.children, !children.isEmpty {
                    ForEach(children) { child in
                        FileTreeNode(item: child, viewModel: viewModel)
                    }
                }
            } label: {
                FileTreeRow(item: item)
                    .contentShape(Rectangle())
                    .onTapGesture(count: 2) {
                        // Double-click: toggle expand/collapse
                        item.isExpanded.toggle()
                        viewModel.ensureChildrenLoaded(for: item)
                    }
                    .onTapGesture(count: 1) {
                        viewModel.handleTap(item)
                    }
            }
            .onAppear {
                viewModel.ensureChildrenLoaded(for: item)
            }
            .contextMenu {
                LocalFileView.fileContextMenu(for: item, viewModel: viewModel)
            }
            .onDrag {
                NSItemProvider(contentsOf: URL(fileURLWithPath: item.path))
                    ?? NSItemProvider()
            }
        } else {
            FileTreeRow(item: item)
                .contentShape(Rectangle())
                .onTapGesture {
                    viewModel.handleTap(item)
                }
                .contextMenu {
                    LocalFileView.fileContextMenu(for: item, viewModel: viewModel)
                }
                .onDrag {
                    NSItemProvider(contentsOf: URL(fileURLWithPath: item.path))
                        ?? NSItemProvider()
                }
        }
    }
}

// MARK: - File Tree Row

struct FileTreeRow: View {
    let item: FileItem

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: item.iconName)
                .foregroundColor(item.iconColor)
                .font(.system(size: 11))
                .frame(width: 14)

            Text(item.name)
                .font(.system(size: 11))
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
