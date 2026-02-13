import SwiftUI
import Combine

/// ViewModel for remote SFTP file browsing.
class RemoteFileViewModel: ObservableObject {
    @Published var isConnected = false
    @Published var currentRemotePath = "/"
    @Published var remoteFiles: [RemoteFile] = []
    @Published var transferProgress: TransferProgress? = nil
    @Published var showConnectionSheet = false

    // MARK: - Connection

    func connect(profile: ServerProfile) {
        // TODO: Implement SSH connection via Rust FFI
        // This will create an SSH session and then init SFTP over it
        isConnected = true
        currentRemotePath = "/home/\(profile.username)"
        loadRemoteDirectory()
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
        let fileName = (localPath as NSString).lastPathComponent
        let remotePath = "\(currentRemotePath)/\(fileName)"

        // Simulate upload progress (real implementation via Rust SFTP)
        transferProgress = TransferProgress(
            fileName: fileName,
            fraction: 0,
            totalBytes: 0,
            transferredBytes: 0
        )

        // TODO: Actual upload via Rust FFI
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
            self?.transferProgress = nil
            self?.loadRemoteDirectory()
        }
    }

    func downloadFile(remotePath: String, localPath: String) {
        let fileName = (remotePath as NSString).lastPathComponent

        transferProgress = TransferProgress(
            fileName: fileName,
            fraction: 0,
            totalBytes: 0,
            transferredBytes: 0
        )

        // TODO: Actual download via Rust FFI
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
            self?.transferProgress = nil
        }
    }

    // MARK: - Private

    private func loadRemoteDirectory() {
        // TODO: Use Rust SFTP to list remote directory
        // For now, show placeholder data when "connected"
        if isConnected {
            remoteFiles = [
                RemoteFile(name: "Documents", path: "\(currentRemotePath)/Documents", isDir: true, size: 0, modified: nil),
                RemoteFile(name: "config.yml", path: "\(currentRemotePath)/config.yml", isDir: false, size: 1024, modified: nil),
            ]
        }
    }
}
