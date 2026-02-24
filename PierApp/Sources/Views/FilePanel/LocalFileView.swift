import SwiftUI
import UniformTypeIdentifiers

/// Left panel: Local file system browser with flat directory listing.
/// Uses a "navigate-into" interaction model — single-click to enter directories.
struct LocalFileView: View {
    @ObservedObject var viewModel: FileViewModel
    @State private var searchText = ""
    @State private var isSearching = false

    var body: some View {
        VStack(spacing: 0) {
            // Header with navigation controls
            headerBar

            Divider()

            // Clickable breadcrumb path
            breadcrumbBar

            Divider()

            // Search field
            searchBar

            // Flat file list (no tree expand/collapse)
            if viewModel.isLoading {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                fileList
            }
        }
        .background(Color(nsColor: .windowBackgroundColor))
    }

    // MARK: - Header

    private var headerBar: some View {
        HStack {
            // Back / up button
            Button(action: { viewModel.navigateUp() }) {
                Image(systemName: "chevron.left")
                    .font(.system(size: 10, weight: .semibold))
            }
            .buttonStyle(.borderless)
            .disabled(viewModel.currentPath.path == "/")
            .help(LS("files.goUp"))

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
        .background(Color(nsColor: .controlBackgroundColor))
    }

    // MARK: - Breadcrumb Path

    /// Clickable breadcrumb showing each path component for quick navigation.
    private var breadcrumbBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 2) {
                let segments = pathSegments()

                ForEach(Array(segments.enumerated()), id: \.offset) { index, segment in
                    if index > 0 {
                        Image(systemName: "chevron.right")
                            .font(.system(size: 7, weight: .semibold))
                            .foregroundColor(.secondary.opacity(0.5))
                    }

                    Button(action: {
                        viewModel.navigateTo(segment.path)
                    }) {
                        Text(segment.name)
                            .font(.system(size: 10))
                            .foregroundColor(index == segments.count - 1 ? .primary : .accentColor)
                            .lineLimit(1)
                    }
                    .buttonStyle(.borderless)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 5)
        }
        .background(Color(nsColor: .textBackgroundColor).opacity(0.5))
    }

    /// Break the current path into (name, fullPath) segments for breadcrumb.
    private func pathSegments() -> [(name: String, path: String)] {
        let currentPathStr = viewModel.currentPath.path
        let home = FileManager.default.homeDirectoryForCurrentUser.path

        var segments: [(name: String, path: String)] = []

        // If path is under home, start with "~"
        if currentPathStr.hasPrefix(home) {
            segments.append((name: "~", path: home))
            let relative = String(currentPathStr.dropFirst(home.count))
            let parts = relative.split(separator: "/", omittingEmptySubsequences: true)
            var accumulated = home
            for part in parts {
                accumulated += "/\(part)"
                segments.append((name: String(part), path: accumulated))
            }
        } else {
            // Absolute path from root
            segments.append((name: "/", path: "/"))
            let parts = currentPathStr.split(separator: "/", omittingEmptySubsequences: true)
            var accumulated = ""
            for part in parts {
                accumulated += "/\(part)"
                segments.append((name: String(part), path: accumulated))
            }
        }

        return segments
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
        .background(Color(nsColor: .textBackgroundColor))
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(Color(nsColor: .separatorColor))
                .frame(height: 0.5)
        }
    }

    // MARK: - Flat File List

    /// Flat list of the current directory contents — no tree expand/collapse.
    /// Single-click on directory = navigate into it.
    /// Single-click on file = handle tap (preview, etc.).
    private var fileList: some View {
        List {
            ForEach(viewModel.displayedFiles) { item in
                FileTreeRow(item: item)
                    .contentShape(Rectangle())
                    .onTapGesture {
                        if item.isDirectory {
                            viewModel.navigateTo(item.path)
                        } else {
                            viewModel.handleTap(item)
                        }
                    }
                    .contextMenu {
                        LocalFileView.fileContextMenu(for: item, viewModel: viewModel)
                    }
                    .onDrag {
                        // Use NSURL as item — automatically registers public.file-url
                        let url = NSURL(fileURLWithPath: item.path)
                        return NSItemProvider(object: url)
                    }
            }
        }
        .listStyle(.inset)
        .scrollContentBackground(.hidden)
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

            // Modified date (relative)
            if !item.formattedDate.isEmpty {
                Text(item.formattedDate)
                    .font(.system(size: 9))
                    .foregroundColor(.secondary)
                    .frame(minWidth: 40, alignment: .trailing)
            }

            // Size for files, child count for directories
            if item.isDirectory {
                if let count = item.childCount {
                    Text("\(count)")
                        .font(.system(size: 9))
                        .foregroundColor(.secondary)
                        .frame(width: 30, alignment: .trailing)
                }
            } else {
                Text(item.formattedSize)
                    .font(.system(size: 9))
                    .foregroundColor(.secondary)
                    .frame(minWidth: 35, alignment: .trailing)
            }

            // Permissions
            if !item.permissions.isEmpty {
                Text(item.permissions)
                    .font(.system(size: 8, design: .monospaced))
                    .foregroundColor(.secondary.opacity(0.6))
                    .frame(width: 62, alignment: .trailing)
            }
        }
        .padding(.vertical, 1)
    }
}

// MARK: - Notification Names

extension Notification.Name {
    static let openPathInTerminal = Notification.Name("pier.openPathInTerminal")
    static let previewMarkdown = Notification.Name("pier.previewMarkdown")
    static let localDirectoryChanged = Notification.Name("pier.localDirectoryChanged")
    static let requestCurrentDirectory = Notification.Name("pier.requestCurrentDirectory")
}
