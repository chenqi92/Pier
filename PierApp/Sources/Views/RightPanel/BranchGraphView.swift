import SwiftUI

/// Visualizes git branch/commit graph from `git log --graph`.
struct BranchGraphView: View {
    let graphEntries: [GraphEntry]

    /// A single entry in the graph (one commit line).
    struct GraphEntry: Identifiable {
        let id = UUID()
        let graphChars: String   // The visual graph glyphs (*, |, /, \)
        let hash: String
        let message: String
        let refs: [String]       // Branch/tag names
        let column: Int          // Which column the * is in
    }

    /// Fixed set of branch colors.
    private static let branchColors: [Color] = [
        .green, .blue, .orange, .purple, .red, .cyan, .yellow, .pink, .mint, .teal
    ]

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Image(systemName: "point.3.connected.trianglepath.dotted")
                    .foregroundColor(.green)
                    .font(.caption)
                Text("git.branchGraph")
                    .font(.caption)
                    .fontWeight(.medium)
                Spacer()
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)

            Divider()

            if graphEntries.isEmpty {
                VStack(spacing: 12) {
                    Image(systemName: "point.3.connected.trianglepath.dotted")
                        .font(.system(size: 30))
                        .foregroundColor(.secondary)
                    Text("git.noGraph")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView([.horizontal, .vertical]) {
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(graphEntries) { entry in
                            graphRow(entry)
                        }
                    }
                    .padding(8)
                }
            }
        }
    }

    // MARK: - Row

    private func graphRow(_ entry: GraphEntry) -> some View {
        HStack(alignment: .center, spacing: 0) {
            // Graph glyphs
            graphGlyphs(entry.graphChars, column: entry.column)
                .frame(width: max(CGFloat(entry.graphChars.count) * 8, 24), alignment: .leading)

            // Commit hash
            Text(String(entry.hash.prefix(7)))
                .font(.system(size: 9, design: .monospaced))
                .foregroundColor(.secondary)
                .frame(width: 56, alignment: .leading)

            // Refs (branch/tag labels)
            ForEach(Array(entry.refs.enumerated()), id: \.offset) { idx, ref in
                Text(ref)
                    .font(.system(size: 8, weight: .medium))
                    .padding(.horizontal, 4)
                    .padding(.vertical, 1)
                    .background(
                        RoundedRectangle(cornerRadius: 3)
                            .fill(Self.branchColors[idx % Self.branchColors.count].opacity(0.2))
                    )
                    .foregroundColor(Self.branchColors[idx % Self.branchColors.count])
            }

            // Message
            Text(entry.message)
                .font(.system(size: 10))
                .lineLimit(1)
                .padding(.leading, entry.refs.isEmpty ? 0 : 4)

            Spacer()
        }
        .padding(.vertical, 1)
    }

    // MARK: - Graph Glyphs

    private func graphGlyphs(_ chars: String, column: Int) -> some View {
        HStack(spacing: 0) {
            ForEach(Array(chars.enumerated()), id: \.offset) { idx, ch in
                glyphView(ch, isCommit: idx == column)
                    .frame(width: 8)
            }
        }
    }

    private func glyphView(_ ch: Character, isCommit: Bool) -> some View {
        Group {
            switch ch {
            case "*":
                Circle()
                    .fill(Color.green)
                    .frame(width: 6, height: 6)
            case "|":
                Rectangle()
                    .fill(Color.secondary.opacity(0.4))
                    .frame(width: 1, height: 14)
            case "/":
                Path { path in
                    path.move(to: CGPoint(x: 0, y: 14))
                    path.addLine(to: CGPoint(x: 8, y: 0))
                }
                .stroke(Color.secondary.opacity(0.4), lineWidth: 1)
                .frame(width: 8, height: 14)
            case "\\":
                Path { path in
                    path.move(to: CGPoint(x: 0, y: 0))
                    path.addLine(to: CGPoint(x: 8, y: 14))
                }
                .stroke(Color.secondary.opacity(0.4), lineWidth: 1)
                .frame(width: 8, height: 14)
            default:
                Color.clear
                    .frame(width: 8, height: 14)
            }
        }
    }
}

// MARK: - Parser (in GitViewModel)

extension GitViewModel {
    /// Parse `git log --graph` output into GraphEntry array.
    static func parseGraphOutput(_ output: String) -> [BranchGraphView.GraphEntry] {
        var entries: [BranchGraphView.GraphEntry] = []
        let lines = output.components(separatedBy: "\n")

        for line in lines {
            guard !line.isEmpty else { continue }

            // Find the commit marker (*)
            var graphPart = ""
            var remaining = line[line.startIndex...]
            var column = 0
            var foundStar = false

            // Scan graph characters
            for (idx, ch) in line.enumerated() {
                if ch == "*" {
                    column = idx
                    foundStar = true
                    graphPart = String(line.prefix(idx + 1))
                    remaining = line[line.index(line.startIndex, offsetBy: idx + 1)...]
                    break
                }
                if ch == "|" || ch == "/" || ch == "\\" || ch == " " || ch == "_" {
                    continue
                } else {
                    break
                }
            }

            guard foundStar else { continue }

            // Parse the rest: hash, refs, message
            let rest = remaining.trimmingCharacters(in: .whitespaces)

            // Format: HASH (refs) message  OR  HASH message
            let parts = rest.split(separator: " ", maxSplits: 1).map(String.init)
            guard let hash = parts.first else { continue }

            var refs: [String] = []
            var message = parts.count > 1 ? parts[1] : ""

            // Extract refs like (HEAD -> main, origin/main)
            if message.hasPrefix("(") {
                if let closeParen = message.firstIndex(of: ")") {
                    let refStr = String(message[message.index(after: message.startIndex)..<closeParen])
                    refs = refStr.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
                    // Remove "HEAD -> " prefix
                    refs = refs.map { $0.replacingOccurrences(of: "HEAD -> ", with: "→") }
                    message = String(message[message.index(after: closeParen)...]).trimmingCharacters(in: .whitespaces)
                }
            }

            entries.append(BranchGraphView.GraphEntry(
                graphChars: graphPart,
                hash: hash,
                message: message,
                refs: refs,
                column: column
            ))
        }

        return entries
    }
}
