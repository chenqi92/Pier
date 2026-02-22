import SwiftUI

/// File item model for the local file browser tree.
class FileItem: Identifiable, ObservableObject, @unchecked Sendable {
    let id = UUID()
    let name: String
    let path: String
    let isDirectory: Bool
    let size: UInt64
    let modifiedDate: Date?
    let permissions: String
    let ownerName: String
    let childCount: Int?
    @Published var children: [FileItem]?
    @Published var isExpanded = false
    var childrenLoaded = false

    var isDir: Bool { isDirectory }

    init(name: String, path: String, isDirectory: Bool, size: UInt64 = 0, modifiedDate: Date? = nil, permissions: String = "", ownerName: String = "", childCount: Int? = nil, children: [FileItem]? = nil) {
        self.name = name
        self.path = path
        self.isDirectory = isDirectory
        self.size = size
        self.modifiedDate = modifiedDate
        self.permissions = permissions
        self.ownerName = ownerName
        self.childCount = childCount
        self.children = isDirectory ? (children ?? []) : nil
    }

    /// Icon name based on file type.
    var iconName: String {
        if isDirectory {
            return "folder.fill"
        }
        let ext = (name as NSString).pathExtension.lowercased()
        switch ext {
        case "swift": return "swift"
        case "rs": return "chevron.left.forwardslash.chevron.right"
        case "py": return "chevron.left.forwardslash.chevron.right"
        case "js", "ts", "jsx", "tsx": return "chevron.left.forwardslash.chevron.right"
        case "json": return "curlybraces"
        case "md": return "doc.text"
        case "txt": return "doc.plaintext"
        case "png", "jpg", "jpeg", "gif", "svg": return "photo"
        case "mp4", "mov", "avi": return "film"
        case "zip", "tar", "gz": return "doc.zipper"
        case "toml", "yaml", "yml": return "gearshape"
        case "sh", "zsh", "bash": return "terminal"
        case "html", "css": return "globe"
        default: return "doc"
        }
    }

    /// Icon color based on file type.
    var iconColor: Color {
        if isDirectory { return .accentColor }
        let ext = (name as NSString).pathExtension.lowercased()
        switch ext {
        case "swift": return .orange
        case "rs": return .brown
        case "py": return .yellow
        case "js", "ts": return .yellow
        case "md": return .blue
        case "json": return .green
        case "html": return .red
        case "css": return .cyan
        default: return .secondary
        }
    }

    /// Shared formatter to avoid repeated allocations.
    private static let sizeFormatter: ByteCountFormatter = {
        let f = ByteCountFormatter()
        f.allowedUnits = [.useBytes, .useKB, .useMB, .useGB]
        f.countStyle = .file
        return f
    }()

    /// Shared relative date formatter.
    private static let relativeDateFormatter: RelativeDateTimeFormatter = {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .abbreviated
        return f
    }()

    /// Human-readable file size.
    var formattedSize: String {
        Self.sizeFormatter.string(fromByteCount: Int64(size))
    }

    /// Relative date string (e.g. "2 min ago").
    var formattedDate: String {
        guard let date = modifiedDate else { return "" }
        return Self.relativeDateFormatter.localizedString(for: date, relativeTo: Date())
    }

    /// Format POSIX permissions as Unix-style string (e.g. "rwxr-xr-x").
    static func formatPermissions(_ posix: UInt16) -> String {
        let chars: [(UInt16, Character)] = [
            (0o400, "r"), (0o200, "w"), (0o100, "x"),
            (0o040, "r"), (0o020, "w"), (0o010, "x"),
            (0o004, "r"), (0o002, "w"), (0o001, "x")
        ]
        return String(chars.map { posix & $0.0 != 0 ? $0.1 : "-" })
    }
}
