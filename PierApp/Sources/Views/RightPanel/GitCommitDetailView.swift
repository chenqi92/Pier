import SwiftUI

/// Commit detail view: shows full commit info + changed file list.
struct GitCommitDetailView: View {
    let detail: GitCommitDetail
    let onShowDiff: (String, String) -> Void  // (hash, filePath)
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text(detail.message.components(separatedBy: "\n").first ?? "")
                        .font(.system(size: 12, weight: .semibold))
                        .lineLimit(2)

                    HStack(spacing: 8) {
                        // Hash
                        HStack(spacing: 3) {
                            Image(systemName: "number")
                                .font(.system(size: 8))
                            Text(String(detail.hash.prefix(10)))
                                .font(.system(size: 9, design: .monospaced))
                        }
                        .foregroundColor(.orange)

                        // Author
                        HStack(spacing: 3) {
                            Image(systemName: "person.fill")
                                .font(.system(size: 8))
                            Text(detail.author)
                                .font(.system(size: 9))
                        }
                        .foregroundColor(.secondary)

                        // Date
                        HStack(spacing: 3) {
                            Image(systemName: "clock")
                                .font(.system(size: 8))
                            Text(formatDate(detail.date))
                                .font(.system(size: 9))
                        }
                        .foregroundColor(.secondary)
                    }
                }

                Spacer()

                Button(action: {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(detail.hash, forType: .string)
                }) {
                    Image(systemName: "doc.on.doc")
                        .font(.system(size: 10))
                }
                .buttonStyle(.borderless)
                .help(LS("git.copyHash"))
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)

            Divider()

            // Full message (if multi-line)
            let messageLines = detail.message.components(separatedBy: "\n")
            if messageLines.count > 1 {
                ScrollView {
                    Text(messageLines.dropFirst().joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines))
                        .font(.system(size: 10))
                        .foregroundColor(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 4)
                }
                .frame(maxHeight: 60)

                Divider()
            }

            // Stats summary
            if !detail.stats.isEmpty {
                HStack {
                    Text(detail.stats)
                        .font(.system(size: 9))
                        .foregroundColor(.secondary)
                    Spacer()
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 4)
                .background(Color(nsColor: .controlBackgroundColor))

                Divider()
            }

            // Changed files list
            List(detail.changedFiles) { file in
                HStack(spacing: 6) {
                    Image(systemName: "doc.text")
                        .foregroundColor(.secondary)
                        .font(.system(size: 9))

                    Text(file.path)
                        .font(.system(size: 10))
                        .lineLimit(1)
                        .truncationMode(.head)

                    Spacer()

                    if file.additions > 0 {
                        Text("+\(file.additions)")
                            .font(.system(size: 8, design: .monospaced))
                            .foregroundColor(.green)
                    }

                    if file.deletions > 0 {
                        Text("-\(file.deletions)")
                            .font(.system(size: 8, design: .monospaced))
                            .foregroundColor(.red)
                    }
                }
                .contentShape(Rectangle())
                .onTapGesture {
                    onShowDiff(detail.hash, file.path)
                }
            }
            .listStyle(.plain)
        }
    }

    // MARK: - Helpers

    private static let isoFormatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    private static let displayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .short
        return f
    }()

    private func formatDate(_ isoDate: String) -> String {
        if let date = Self.isoFormatter.date(from: isoDate) {
            return Self.displayFormatter.string(from: date)
        }
        return isoDate
    }
}
