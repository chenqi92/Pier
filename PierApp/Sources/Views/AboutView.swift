import SwiftUI

/// Custom About window for Pier Terminal.
struct AboutView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject var updateChecker: UpdateChecker

    private var appVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.1.0"
    }

    private var buildNumber: String {
        Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "1"
    }

    var body: some View {
        VStack(spacing: 16) {
            // App icon
            if let icon = NSApp.applicationIconImage {
                Image(nsImage: icon)
                    .resizable()
                    .frame(width: 96, height: 96)
            }

            // App name
            Text("Pier Terminal")
                .font(.system(size: 20, weight: .bold))

            // Version
            Text(LS("about.version") + " \(appVersion) (\(buildNumber))")
                .font(.system(size: 12))
                .foregroundColor(.secondary)

            // Description
            Text(LS("about.description"))
                .font(.system(size: 12))
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 280)

            Divider()
                .frame(width: 200)

            // Check for updates button
            Button {
                Task {
                    await updateChecker.checkForUpdates()
                }
            } label: {
                HStack(spacing: 6) {
                    if updateChecker.isChecking {
                        ProgressView()
                            .controlSize(.small)
                    } else {
                        Image(systemName: "arrow.triangle.2.circlepath")
                            .font(.system(size: 11))
                    }
                    Text(LS("updater.checkForUpdates"))
                        .font(.system(size: 11))
                }
            }
            .disabled(updateChecker.isChecking)

            // Update status
            if let status = updateChecker.statusMessage {
                HStack(spacing: 4) {
                    if updateChecker.updateAvailable {
                        Image(systemName: "arrow.down.circle.fill")
                            .foregroundColor(.green)
                            .font(.system(size: 10))
                        Text(status)
                            .font(.system(size: 11))
                            .foregroundColor(.primary)
                        Button(LS("updater.download")) {
                            updateChecker.openDownloadPage()
                        }
                        .font(.system(size: 11))
                    } else {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundColor(.green)
                            .font(.system(size: 10))
                        Text(status)
                            .font(.system(size: 11))
                            .foregroundColor(.secondary)
                    }
                }
            }

            // Copyright
            Text(LS("about.copyright"))
                .font(.system(size: 10))
                .foregroundColor(.secondary)

            // Links
            HStack(spacing: 16) {
                Link(destination: URL(string: "https://github.com/chenqi92/Pier")!) {
                    HStack(spacing: 4) {
                        Image(systemName: "link")
                            .font(.system(size: 10))
                        Text("GitHub")
                            .font(.system(size: 11))
                    }
                }

                Link(destination: URL(string: "https://kkape.com")!) {
                    HStack(spacing: 4) {
                        Image(systemName: "globe")
                            .font(.system(size: 10))
                        Text(LS("about.website"))
                            .font(.system(size: 11))
                    }
                }
            }

            Spacer()
                .frame(height: 4)

            // Close button
            Button(LS("common.ok")) {
                dismiss()
            }
            .keyboardShortcut(.defaultAction)
        }
        .padding(24)
        .frame(width: 340, height: 480)
    }
}
