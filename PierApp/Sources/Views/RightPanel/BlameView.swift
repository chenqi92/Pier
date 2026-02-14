import SwiftUI

/// Displays git blame annotations for a file.
struct BlameView: View {
    let blameLines: [BlameLine]
    let filePath: String

    // Color map for authors
    private var authorColors: [String: Color] {
        let palette: [Color] = [.blue, .green, .orange, .purple, .pink, .cyan, .mint, .indigo, .teal, .yellow]
        var map: [String: Color] = [:]
        var idx = 0
        for line in blameLines {
            if map[line.author] == nil {
                map[line.author] = palette[idx % palette.count]
                idx += 1
            }
        }
        return map
    }

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Image(systemName: "person.text.rectangle")
                    .foregroundColor(.purple)
                    .font(.caption)
                Text(LS("git.blame"))
                    .font(.caption)
                    .fontWeight(.medium)
                Text("—")
                    .foregroundColor(.secondary)
                    .font(.caption)
                Text((filePath as NSString).lastPathComponent)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundColor(.secondary)
                Spacer()
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(Color(nsColor: .controlBackgroundColor))

            Divider()

            if blameLines.isEmpty {
                Text(LS("git.blameEmpty"))
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView([.horizontal, .vertical]) {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(blameLines) { line in
                            blameLineRow(line)
                        }
                    }
                }
                .textSelection(.enabled)
            }
        }
    }

    private func blameLineRow(_ line: BlameLine) -> some View {
        let colors = authorColors

        return HStack(spacing: 0) {
            // Line number
            Text(String(format: "%4d", line.lineNumber))
                .font(.system(size: 10, design: .monospaced))
                .foregroundColor(.secondary)
                .frame(width: 40, alignment: .trailing)
                .padding(.trailing, 4)

            // Blame annotation
            HStack(spacing: 4) {
                Text(line.shortHash)
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundColor(.secondary)

                Text(line.author)
                    .font(.system(size: 9, weight: .medium))
                    .foregroundColor(colors[line.author] ?? .secondary)
                    .lineLimit(1)
                    .frame(width: 80, alignment: .leading)

                Text(line.date)
                    .font(.system(size: 9))
                    .foregroundColor(.secondary)
            }
            .frame(width: 220, alignment: .leading)
            .padding(.horizontal, 4)
            .background(
                RoundedRectangle(cornerRadius: 2)
                    .fill((colors[line.author] ?? .gray).opacity(0.08))
            )

            // Separator
            Rectangle()
                .fill(Color(nsColor: .separatorColor))
                .frame(width: 1)
                .padding(.horizontal, 4)

            // Code content
            Text(line.content)
                .font(.system(size: 11, design: .monospaced))
                .lineLimit(1)
        }
        .padding(.vertical, 1)
        .padding(.horizontal, 4)
        .background(line.lineNumber % 2 == 0
            ? Color.clear
            : Color(nsColor: .controlBackgroundColor).opacity(0.15))
        .help("\(line.commitHash)\n\(line.author) • \(line.date)")
    }
}
