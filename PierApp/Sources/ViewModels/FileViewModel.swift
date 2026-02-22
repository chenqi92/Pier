import SwiftUI
import Combine

/// ViewModel for the local file browser panel.
@MainActor
class FileViewModel: ObservableObject {
    @Published var rootFiles: [FileItem] = []
    @Published var displayedFiles: [FileItem] = []
    @Published var currentPath: URL
    @Published var isLoading = false
    @Published var errorMessage: String?

    private var allFiles: [FileItem] = []
    private var fileMonitor: DispatchSourceFileSystemObject?
    private var monitoredFD: CInt = -1

    init() {
        let home = FileManager.default.homeDirectoryForCurrentUser
        self.currentPath = home
        loadDirectory(at: home.path)
        // Notify GitViewModel of the initial directory so it can detect git repos on startup
        NotificationCenter.default.post(
            name: .localDirectoryChanged,
            object: home.path
        )
        // Respond to "request current directory" from GitPanelView by re-broadcasting
        NotificationCenter.default.addObserver(
            forName: .requestCurrentDirectory,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            let path = MainActor.assumeIsolated { self.currentPath.path }
            NotificationCenter.default.post(
                name: .localDirectoryChanged,
                object: path
            )
        }
    }

    // MARK: - Navigation

    func navigateTo(_ path: String) {
        currentPath = URL(fileURLWithPath: path)
        loadDirectory(at: path)
        NotificationCenter.default.post(
            name: .localDirectoryChanged,
            object: path
        )
    }

    /// Navigate to the parent directory of the current path.
    func navigateUp() {
        let parent = currentPath.deletingLastPathComponent()
        navigateTo(parent.path)
    }

    func refresh() {
        loadDirectory(at: currentPath.path)
    }

    func handleTap(_ item: FileItem) {
        if item.isDirectory {
            // Lazy-load children
            if item.children?.isEmpty == true {
                loadChildren(for: item)
            }
        } else {
            // Notify to open file (e.g., markdown preview)
            let ext = (item.name as NSString).pathExtension.lowercased()
            if ext == "md" {
                NotificationCenter.default.post(name: .previewMarkdown, object: item.path)
            } else {
                NSWorkspace.shared.open(URL(fileURLWithPath: item.path))
            }
        }
    }

    func openFolderPicker() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.message = "Choose a directory to browse"

        if panel.runModal() == .OK, let url = panel.url {
            navigateTo(url.path)
        }
    }

    func deleteFile(_ item: FileItem) {
        do {
            try FileManager.default.trashItem(at: URL(fileURLWithPath: item.path), resultingItemURL: nil)
            refresh()
        } catch {
            errorMessage = "Failed to delete \(item.name): \(error.localizedDescription)"
        }
    }

    // MARK: - Search / Filter

    func filterFiles(query: String) {
        if query.isEmpty {
            displayedFiles = allFiles
        } else {
            displayedFiles = filterRecursive(items: allFiles, query: query.lowercased())
        }
    }

    private func filterRecursive(items: [FileItem], query: String) -> [FileItem] {
        var results: [FileItem] = []
        for item in items {
            let nameMatch = item.name.lowercased().contains(query)
            if nameMatch {
                results.append(item)
            }
            if let children = item.children {
                let childResults = filterRecursive(items: children, query: query)
                results.append(contentsOf: childResults)
            }
        }
        return results
    }

    // MARK: - File Loading

    private func loadDirectory(at path: String) {
        isLoading = true
        stopMonitoring()

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            // Only load 1 level deep — children are lazy-loaded on expand
            let items = self?.buildFileTree(at: path, depth: 0, maxDepth: 1) ?? []

            DispatchQueue.main.async {
                self?.allFiles = items
                self?.displayedFiles = items
                self?.isLoading = false
                self?.startMonitoring(path: path)
            }
        }
    }

    /// Called by the view when a directory row appears on screen.
    /// Lazily loads ONE level of children so they're ready when the user expands.
    func ensureChildrenLoaded(for item: FileItem) {
        guard item.isDirectory, !item.childrenLoaded else { return }
        item.childrenLoaded = true  // Mark immediately to prevent duplicate loads
        loadChildren(for: item)
    }

    private func loadChildren(for item: FileItem) {
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            // Load 1 level of children
            let children = self?.buildFileTree(at: item.path, depth: 0, maxDepth: 1) ?? []

            DispatchQueue.main.async {
                item.children = children
                // Force parent list refresh
                self?.objectWillChange.send()
            }
        }
    }

    nonisolated private func buildFileTree(at path: String, depth: Int, maxDepth: Int) -> [FileItem] {
        let fm = FileManager.default
        guard let contents = try? fm.contentsOfDirectory(atPath: path) else {
            return []
        }

        var items: [FileItem] = []

        for name in contents.sorted(by: { $0.lowercased() < $1.lowercased() }) {
            // Skip hidden files
            if name.hasPrefix(".") { continue }

            let fullPath = (path as NSString).appendingPathComponent(name)
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: fullPath, isDirectory: &isDir) else { continue }

            let attrs = try? fm.attributesOfItem(atPath: fullPath)
            let size = (attrs?[.size] as? UInt64) ?? 0
            let modified = attrs?[.modificationDate] as? Date
            let posixPerms = attrs?[.posixPermissions] as? UInt16
            let permString = posixPerms.map { FileItem.formatPermissions($0) } ?? ""
            let owner = (attrs?[.ownerAccountName] as? String) ?? ""

            var children: [FileItem]? = nil
            var childCount: Int? = nil
            if isDir.boolValue {
                if depth < maxDepth {
                    children = buildFileTree(at: fullPath, depth: depth + 1, maxDepth: maxDepth)
                }
                // Count visible (non-hidden) items for directory badge
                childCount = (try? fm.contentsOfDirectory(atPath: fullPath)
                    .filter { !$0.hasPrefix(".") }.count) ?? 0
            }

            let item = FileItem(
                name: name,
                path: fullPath,
                isDirectory: isDir.boolValue,
                size: size,
                modifiedDate: modified,
                permissions: permString,
                ownerName: owner,
                childCount: childCount,
                children: children
            )

            items.append(item)
        }

        // Sort: directories first, then alphabetically
        items.sort { a, b in
            if a.isDirectory != b.isDirectory {
                return a.isDirectory
            }
            return a.name.lowercased() < b.name.lowercased()
        }

        return items
    }

    // MARK: - File System Monitoring

    private func startMonitoring(path: String) {
        let fd = open(path, O_EVTONLY)
        guard fd >= 0 else { return }
        monitoredFD = fd

        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd,
            eventMask: [.write, .rename, .delete],
            queue: .main
        )

        source.setEventHandler { [weak self] in
            self?.refresh()
        }

        source.setCancelHandler {
            close(fd)
        }

        fileMonitor = source
        source.resume()
    }

    private func stopMonitoring() {
        fileMonitor?.cancel()
        fileMonitor = nil
    }

    nonisolated deinit {
        // DispatchSource cancel is thread-safe
        fileMonitor?.cancel()
    }
}
