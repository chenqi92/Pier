import Foundation
import CPierCore

/// Swift wrapper for the Rust pier-core FFI functions.
/// This provides a safe Swift API over the raw C functions.
enum PierBridge {

    // MARK: - Initialization

    /// Initialize the Rust core engine.
    static func initialize() {
        pier_init()
    }

    // MARK: - Terminal

    /// Create a new terminal session.
    static func createTerminal(cols: UInt16, rows: UInt16, shell: String = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh") -> OpaquePointer? {
        return shell.withCString { shellPtr in
            pier_terminal_create(cols, rows, shellPtr)
        }
    }

    /// Destroy a terminal session.
    static func destroyTerminal(_ handle: OpaquePointer) {
        pier_terminal_destroy(handle)
    }

    /// Write input to a terminal session.
    static func writeToTerminal(_ handle: OpaquePointer, data: Data) -> Bool {
        return data.withUnsafeBytes { bufferPtr in
            guard let baseAddr = bufferPtr.baseAddress else { return false }
            return pier_terminal_write(
                handle,
                baseAddr.assumingMemoryBound(to: UInt8.self),
                UInt(data.count)
            ) == 0
        }
    }

    /// Read output from a terminal session.
    static func readFromTerminal(_ handle: OpaquePointer) -> Data? {
        var buffer = [UInt8](repeating: 0, count: 65536)
        let bytesRead = pier_terminal_read(handle, &buffer, UInt(buffer.count))

        guard bytesRead > 0 else { return nil }
        return Data(buffer[0..<Int(bytesRead)])
    }

    /// Resize a terminal session.
    static func resizeTerminal(_ handle: OpaquePointer, cols: UInt16, rows: UInt16) -> Bool {
        return pier_terminal_resize(handle, cols, rows) == 0
    }

    /// Get the PTY file descriptor for a terminal session.
    static func terminalFd(_ handle: OpaquePointer) -> Int32 {
        return pier_terminal_fd(handle)
    }

    // MARK: - File Search

    /// Search files matching a pattern.
    static func searchFiles(root: String, pattern: String, maxResults: Int = 100) -> [[String: Any]] {
        return root.withCString { rootPtr in
            pattern.withCString { patternPtr in
                guard let resultPtr = pier_search_files(rootPtr, patternPtr, UInt(maxResults)) else {
                    return []
                }
                defer { pier_string_free(resultPtr) }

                let jsonString = String(cString: resultPtr)
                guard let data = jsonString.data(using: .utf8),
                      let json = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
                    return []
                }
                return json
            }
        }
    }

    /// List directory contents.
    static func listDirectory(path: String) -> [[String: Any]] {
        return path.withCString { pathPtr in
            guard let resultPtr = pier_list_directory(pathPtr) else {
                return []
            }
            defer { pier_string_free(resultPtr) }

            let jsonString = String(cString: resultPtr)
            guard let data = jsonString.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
                return []
            }
            return json
        }
    }
}
