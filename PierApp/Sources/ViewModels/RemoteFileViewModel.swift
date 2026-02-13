import SwiftUI
import Combine

/// ViewModel for remote SFTP file browsing.
class RemoteFileViewModel: ObservableObject {
    @Published var isConnected = false
    @Published var currentRemotePath = "/"
    @Published var remoteFiles: [RemoteFile] = []
    @Published var transferProgress: TransferProgress? = nil
    @Published var showConnectionSheet = false
    @Published var statusMessage: String?

    // MARK: - Connection

    func connect(profile: ServerProfile) {
        // SFTP connection requires Rust SSH/SFTP FFI — not yet implemented.
        // Show honest status instead of faking success.
        statusMessage = "SSH/SFTP connection not yet implemented. Pending Rust FFI integration."
    }

    func disconnect() {
        isConnected = false
        remoteFiles = []
        currentRemotePath = "/"
    }

    // MARK: - Navigation

    func navigateTo(_ path: String) {
        currentRemotePath = path
        loadRemoteDirectory()
    }

    func navigateUp() {
        let parent = (currentRemotePath as NSString).deletingLastPathComponent
        navigateTo(parent.isEmpty ? "/" : parent)
    }

    // MARK: - File Operations

    func handleFileDrop(providers: [NSItemProvider]) -> Bool {
        for provider in providers {
            if provider.hasItemConformingToTypeIdentifier("public.file-url") {
                provider.loadItem(forTypeIdentifier: "public.file-url", options: nil) { [weak self] item, _ in
                    if let data = item as? Data,
                       let url = URL(dataRepresentation: data, relativeTo: nil) {
                        DispatchQueue.main.async {
                            self?.uploadFile(localPath: url.path)
                        }
                    }
                }
            }
        }
        return true
    }

    func uploadFile(localPath: String) {
        statusMessage = "SFTP upload not yet implemented."
    }

    func downloadFile(remotePath: String, localPath: String) {
        statusMessage = "SFTP download not yet implemented."
    }

    // MARK: - Private

    private func loadRemoteDirectory() {
        // Will use Rust SFTP FFI when implemented
        statusMessage = "Remote directory listing requires SFTP connection."
    }
}
