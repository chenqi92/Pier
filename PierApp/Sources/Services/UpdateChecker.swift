import Foundation
import SwiftUI

/// Checks for app updates via the GitHub Releases API.
///
/// Polls `https://api.github.com/repos/{owner}/{repo}/releases/latest`
/// and compares the tag name against the current app version from `VERSION`.
@MainActor
class UpdateChecker: ObservableObject {

    // MARK: - Published State

    /// Whether a newer version is available.
    @Published var updateAvailable = false

    /// The latest version string (e.g. "0.2.0").
    @Published var latestVersion: String?

    /// Direct download URL for the latest DMG asset.
    @Published var downloadURL: URL?

    /// Release notes body (markdown).
    @Published var releaseNotes: String?

    /// Timestamp of the last successful check.
    @Published var lastCheckDate: Date? {
        didSet {
            if let date = lastCheckDate {
                UserDefaults.standard.set(date.timeIntervalSince1970, forKey: Self.lastCheckKey)
            }
        }
    }

    /// Whether an update check is currently in progress.
    @Published var isChecking = false

    /// Human-readable status message after a check.
    @Published var statusMessage: String?

    // MARK: - Configuration

    /// Whether to automatically check for updates on launch.
    @AppStorage("autoCheckForUpdates") var autoCheckForUpdates = true

    /// Check interval in seconds (default: 24 hours).
    @AppStorage("updateCheckInterval") var checkInterval: Double = 86400

    // MARK: - Constants

    private static let owner = "chenqi92"
    private static let repo = "Pier"
    private static let apiURL = "https://api.github.com/repos/\(owner)/\(repo)/releases/latest"
    private static let lastCheckKey = "lastUpdateCheckDate"

    // MARK: - Current Version

    /// The current app version, read from Bundle (Info.plist).
    var currentVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.1.0"
    }

    // MARK: - Init

    init() {
        // Restore last check date
        let ts = UserDefaults.standard.double(forKey: Self.lastCheckKey)
        if ts > 0 {
            lastCheckDate = Date(timeIntervalSince1970: ts)
        }
    }

    /// Start periodic background update checks (call once at app launch).
    func startPeriodicChecks() {
        guard autoCheckForUpdates else { return }

        // Check if enough time has elapsed since the last check
        if let last = lastCheckDate {
            let elapsed = Date().timeIntervalSince(last)
            if elapsed < checkInterval {
                return
            }
        }

        Task {
            await checkForUpdates(silent: true)
        }
    }

    // MARK: - Check for Updates

    /// Perform an update check.
    /// - Parameter silent: If true, don't update `statusMessage` when already up-to-date.
    func checkForUpdates(silent: Bool = false) async {
        guard !isChecking else { return }
        isChecking = true
        statusMessage = nil

        defer { isChecking = false }

        guard let url = URL(string: Self.apiURL) else { return }

        var request = URLRequest(url: url)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("Pier-Terminal/\(currentVersion)", forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = 15

        do {
            let (data, response) = try await URLSession.shared.data(for: request)

            guard let httpResponse = response as? HTTPURLResponse else { return }

            if httpResponse.statusCode == 404 {
                // No releases yet
                if !silent {
                    statusMessage = LS("updater.noReleases")
                }
                lastCheckDate = Date()
                return
            }

            guard httpResponse.statusCode == 200 else {
                if !silent {
                    statusMessage = "HTTP \(httpResponse.statusCode)"
                }
                return
            }

            guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let tagName = json["tag_name"] as? String else {
                return
            }

            // Strip leading "v" from tag (e.g. "v0.2.0" → "0.2.0")
            let remoteVersion = tagName.hasPrefix("v") ? String(tagName.dropFirst()) : tagName

            lastCheckDate = Date()
            latestVersion = remoteVersion
            releaseNotes = json["body"] as? String

            // Find DMG download URL from assets
            if let assets = json["assets"] as? [[String: Any]] {
                for asset in assets {
                    if let name = asset["name"] as? String,
                       name.hasSuffix(".dmg"),
                       let urlStr = asset["browser_download_url"] as? String {
                        downloadURL = URL(string: urlStr)
                        break
                    }
                }
            }

            // Compare versions
            if isNewerVersion(remoteVersion, than: currentVersion) {
                updateAvailable = true
                statusMessage = String(format: LS("updater.newVersionFormat"), remoteVersion)
            } else {
                updateAvailable = false
                if !silent {
                    statusMessage = LS("updater.upToDate")
                }
            }
        } catch {
            if !silent {
                statusMessage = LS("updater.checkFailed")
            }
            print("[UpdateChecker] Error: \(error.localizedDescription)")
        }
    }

    /// Open the download URL in the default browser.
    func openDownloadPage() {
        if let url = downloadURL {
            NSWorkspace.shared.open(url)
        } else {
            // Fallback to GitHub releases page
            if let url = URL(string: "https://github.com/\(Self.owner)/\(Self.repo)/releases/latest") {
                NSWorkspace.shared.open(url)
            }
        }
    }

    // MARK: - Version Comparison

    /// Returns true if `a` is semantically newer than `b`.
    private func isNewerVersion(_ a: String, than b: String) -> Bool {
        let aParts = a.split(separator: ".").compactMap { Int($0) }
        let bParts = b.split(separator: ".").compactMap { Int($0) }

        let maxLen = max(aParts.count, bParts.count)
        for i in 0..<maxLen {
            let av = i < aParts.count ? aParts[i] : 0
            let bv = i < bParts.count ? bParts[i] : 0
            if av > bv { return true }
            if av < bv { return false }
        }
        return false
    }
}
