import SwiftUI

/// File item model for the local file browser tree.
class FileItem: Identifiable, ObservableObject {
    let id = UUID()
    let name: String
    let path: String
    let isDirectory: Bool
    let size: UInt64
    let modifiedDate: Date?
    @Published var children: [FileItem]?

    var isDir: Bool { isDirectory }

    init(name: String, path: String, isDirectory: Bool, size: UInt64 = 0, modifiedDate: Date? = nil, children: [FileItem]? = nil) {
        self.name = name
        self.path = path
        self.isDirectory = isDirectory
        self.size = size
        self.modifiedDate = modifiedDate
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

    /// Human-readable file size.
    var formattedSize: String {
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useBytes, .useKB, .useMB, .useGB]
        formatter.countStyle = .file
        return formatter.string(fromByteCount: Int64(size))
    }
}
