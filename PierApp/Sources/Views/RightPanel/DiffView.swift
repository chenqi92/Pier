import SwiftUI

// MARK: - Diff Data Model

enum DiffLineType {
    case context
    case addition
    case deletion
    case header
}

struct DiffLine: Identifiable {
    let id: Int
    let text: String
    let type: DiffLineType
    let oldLineNumber: Int?
    let newLineNumber: Int?
}

enum DiffDisplayMode {
    case inline
    case sideBySide
}

// MARK: - Diff View

/// Unified diff visualization with inline and side-by-side modes.
struct DiffView: View {
    let diffText: String
    @State private var displayMode: DiffDisplayMode = .inline
    @State private var parsedLines: [DiffLine] = []
    @State private var fileName: String = ""

    var body: some View {
        VStack(spacing: 0) {
            // Header
            diffHeader

            Divider()

            // Content
            if parsedLines.isEmpty {
                emptyState
            } else {
                switch displayMode {
                case .inline:
                    inlineDiffView
                case .sideBySide:
                    sideBySideDiffView
                }
            }
        }
        .onAppear { parseDiff() }
        .onChange(of: diffText) { _, _ in parseDiff() }
    }

    // MARK: - Header

    private var diffHeader: some View {
        HStack {
            Image(systemName: "doc.text.fill.viewfinder")
                .foregroundColor(.orange)
                .font(.caption)

            if !fileName.isEmpty {
                Text(fileName)
                    .font(.system(size: 11, weight: .medium, design: .monospaced))
                    .lineLimit(1)
            } else {
                Text(LS("diff.title"))
                    .font(.caption)
                    .fontWeight(.medium)
            }

            Spacer()

            // Stats
            let additions = parsedLines.filter { $0.type == .addition }.count
            let deletions = parsedLines.filter { $0.type == .deletion }.count
            if additions + deletions > 0 {
                Text("+\(additions)")
                    .font(.system(size: 10, weight: .semibold, design: .monospaced))
                    .foregroundColor(.green)
                Text("-\(deletions)")
                    .font(.system(size: 10, weight: .semibold, design: .monospaced))
                    .foregroundColor(.red)
            }

            // Toggle mode
            Picker("", selection: $displayMode) {
                Image(systemName: "list.bullet").tag(DiffDisplayMode.inline)
                Image(systemName: "rectangle.split.2x1").tag(DiffDisplayMode.sideBySide)
            }
            .pickerStyle(.segmented)
            .frame(width: 60)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
    }

    // MARK: - Inline Diff

    private var inlineDiffView: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(parsedLines) { line in
                    inlineLineView(line)
                }
            }
        }
        .font(.system(size: 11, design: .monospaced))
        .background(Color(red: 0.08, green: 0.08, blue: 0.10))
    }

    private func inlineLineView(_ line: DiffLine) -> some View {
        HStack(spacing: 0) {
            // Old line number
            Text(line.oldLineNumber.map { "\($0)" } ?? "")
                .frame(width: 36, alignment: .trailing)
                .foregroundColor(.secondary)
                .font(.system(size: 9, design: .monospaced))

            // New line number
            Text(line.newLineNumber.map { "\($0)" } ?? "")
                .frame(width: 36, alignment: .trailing)
                .foregroundColor(.secondary)
                .font(.system(size: 9, design: .monospaced))

            // Gutter indicator
            Text(gutterChar(line.type))
                .frame(width: 16)
                .foregroundColor(lineColor(line.type))
                .font(.system(size: 11, weight: .bold, design: .monospaced))

            // Content
            Text(line.text)
                .foregroundColor(lineColor(line.type))
                .textSelection(.enabled)

            Spacer(minLength: 0)
        }
        .padding(.vertical, 0.5)
        .background(lineBackground(line.type))
    }

    // MARK: - Side by Side Diff

    private var sideBySideDiffView: some View {
        let (leftLines, rightLines) = splitSideBySide()

        return ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(0..<max(leftLines.count, rightLines.count), id: \.self) { index in
                    HStack(spacing: 0) {
                        // Left (old)
                        if index < leftLines.count {
                            sideLineView(leftLines[index], isLeft: true)
                        } else {
                            Color.clear.frame(maxWidth: .infinity, minHeight: 16)
                        }

                        Divider()

                        // Right (new)
                        if index < rightLines.count {
                            sideLineView(rightLines[index], isLeft: false)
                        } else {
                            Color.clear.frame(maxWidth: .infinity, minHeight: 16)
                        }
                    }
                }
            }
        }
        .font(.system(size: 11, design: .monospaced))
        .background(Color(red: 0.08, green: 0.08, blue: 0.10))
    }

    private func sideLineView(_ line: DiffLine, isLeft: Bool) -> some View {
        HStack(spacing: 0) {
            let num = isLeft ? line.oldLineNumber : line.newLineNumber
            Text(num.map { "\($0)" } ?? "")
                .frame(width: 30, alignment: .trailing)
                .foregroundColor(.secondary)
                .font(.system(size: 9, design: .monospaced))

            Text(" ")

            Text(line.text)
                .foregroundColor(lineColor(line.type))
                .textSelection(.enabled)
                .lineLimit(1)

            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 0.5)
        .background(lineBackground(line.type))
    }

    // MARK: - Empty State

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "doc.text.fill.viewfinder")
                .font(.system(size: 36))
                .foregroundColor(.secondary)
            Text(LS("diff.empty"))
                .font(.caption)
                .foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Diff Parsing

    private func parseDiff() {
        var lines: [DiffLine] = []
        var oldLine = 0
        var newLine = 0
        var lineId = 0

        // Extract filename from diff header
        for rawLine in diffText.split(separator: "\n", omittingEmptySubsequences: false).prefix(5) {
            if rawLine.hasPrefix("+++ b/") {
                fileName = String(rawLine.dropFirst(6))
                break
            } else if rawLine.hasPrefix("+++ ") {
                fileName = String(rawLine.dropFirst(4))
                break
            }
        }

        for rawLine in diffText.split(separator: "\n", omittingEmptySubsequences: false) {
            let text = String(rawLine)

            if text.hasPrefix("@@") {
                // Parse hunk header: @@ -oldStart,count +newStart,count @@
                let parts = text.split(separator: " ")
                if parts.count >= 3 {
                    let oldPart = parts[1].dropFirst() // remove "-"
                    let newPart = parts[2].dropFirst() // remove "+"
                    oldLine = Int(oldPart.split(separator: ",").first ?? "0") ?? 0
                    newLine = Int(newPart.split(separator: ",").first ?? "0") ?? 0
                }
                lines.append(DiffLine(id: lineId, text: text, type: .header, oldLineNumber: nil, newLineNumber: nil))
            } else if text.hasPrefix("+") && !text.hasPrefix("+++") {
                lines.append(DiffLine(id: lineId, text: String(text.dropFirst()), type: .addition, oldLineNumber: nil, newLineNumber: newLine))
                newLine += 1
            } else if text.hasPrefix("-") && !text.hasPrefix("---") {
                lines.append(DiffLine(id: lineId, text: String(text.dropFirst()), type: .deletion, oldLineNumber: oldLine, newLineNumber: nil))
                oldLine += 1
            } else if text.hasPrefix(" ") {
                lines.append(DiffLine(id: lineId, text: String(text.dropFirst()), type: .context, oldLineNumber: oldLine, newLineNumber: newLine))
                oldLine += 1
                newLine += 1
            } else if !text.hasPrefix("diff ") && !text.hasPrefix("index ") && !text.hasPrefix("---") && !text.hasPrefix("+++") {
                // Other lines (binary, etc.)
                lines.append(DiffLine(id: lineId, text: text, type: .context, oldLineNumber: nil, newLineNumber: nil))
            }

            lineId += 1
        }

        parsedLines = lines
    }

    /// Split parsed lines into left (deletions + context) and right (additions + context)
    /// for side-by-side display.
    private func splitSideBySide() -> ([DiffLine], [DiffLine]) {
        var left: [DiffLine] = []
        var right: [DiffLine] = []

        for line in parsedLines {
            switch line.type {
            case .header:
                left.append(line)
                right.append(line)
            case .context:
                left.append(line)
                right.append(line)
            case .deletion:
                left.append(line)
            case .addition:
                right.append(line)
            }
        }

        return (left, right)
    }

    // MARK: - Styling Helpers

    private func gutterChar(_ type: DiffLineType) -> String {
        switch type {
        case .addition: return "+"
        case .deletion: return "-"
        case .header:   return "@"
        case .context:  return " "
        }
    }

    private func lineColor(_ type: DiffLineType) -> Color {
        switch type {
        case .addition: return .green
        case .deletion: return .red
        case .header:   return .cyan
        case .context:  return Color(nsColor: .labelColor)
        }
    }

    private func lineBackground(_ type: DiffLineType) -> Color {
        switch type {
        case .addition: return Color.green.opacity(0.08)
        case .deletion: return Color.red.opacity(0.08)
        case .header:   return Color.cyan.opacity(0.05)
        case .context:  return .clear
        }
    }
}
