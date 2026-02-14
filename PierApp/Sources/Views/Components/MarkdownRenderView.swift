import SwiftUI

/// Renders markdown content with syntax-highlighted code blocks, tables, and headings.
struct MarkdownRenderView: View {
    let content: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(Array(parseBlocks().enumerated()), id: \.offset) { _, block in
                renderBlock(block)
            }
        }
    }

    // MARK: - Block Types

    private enum MarkdownBlock {
        case text(String)
        case codeBlock(language: String, code: String)
        case heading(level: Int, text: String)
        case listItem(text: String, ordered: Bool, index: Int)
        case divider
    }

    // MARK: - Parser

    private func parseBlocks() -> [MarkdownBlock] {
        var blocks: [MarkdownBlock] = []
        let lines = content.components(separatedBy: "\n")
        var i = 0
        var orderedIndex = 1

        while i < lines.count {
            let line = lines[i]

            // Code block
            if line.hasPrefix("```") {
                let language = String(line.dropFirst(3)).trimmingCharacters(in: .whitespaces)
                var codeLines: [String] = []
                i += 1
                while i < lines.count && !lines[i].hasPrefix("```") {
                    codeLines.append(lines[i])
                    i += 1
                }
                blocks.append(.codeBlock(language: language, code: codeLines.joined(separator: "\n")))
                i += 1
                orderedIndex = 1
                continue
            }

            // Heading
            if line.hasPrefix("#") {
                let level = line.prefix(while: { $0 == "#" }).count
                let rest = String(line.dropFirst(level)).trimmingCharacters(in: .whitespaces)
                blocks.append(.heading(level: min(level, 6), text: rest))
                i += 1
                orderedIndex = 1
                continue
            }

            // Horizontal rule
            if line.trimmingCharacters(in: .whitespaces).count >= 3 &&
               line.trimmingCharacters(in: .whitespaces).allSatisfy({ $0 == "-" || $0 == "*" || $0 == "_" }) {
                blocks.append(.divider)
                i += 1
                orderedIndex = 1
                continue
            }

            // Unordered list
            if line.trimmingCharacters(in: .whitespaces).hasPrefix("- ") ||
               line.trimmingCharacters(in: .whitespaces).hasPrefix("* ") {
                let text = String(line.trimmingCharacters(in: .whitespaces).dropFirst(2))
                blocks.append(.listItem(text: text, ordered: false, index: 0))
                i += 1
                continue
            }

            // Ordered list
            if let match = line.range(of: #"^\s*\d+\.\s"#, options: .regularExpression) {
                let text = String(line[match.upperBound...])
                blocks.append(.listItem(text: text, ordered: true, index: orderedIndex))
                orderedIndex += 1
                i += 1
                continue
            }

            // Plain text
            if !line.trimmingCharacters(in: .whitespaces).isEmpty {
                blocks.append(.text(line))
                orderedIndex = 1
            }

            i += 1
        }

        return blocks
    }

    // MARK: - Render

    @ViewBuilder
    private func renderBlock(_ block: MarkdownBlock) -> some View {
        switch block {
        case .text(let text):
            renderInlineMarkdown(text)
                .font(.system(size: 11))

        case .codeBlock(let language, let code):
            VStack(alignment: .leading, spacing: 0) {
                if !language.isEmpty {
                    Text(language)
                        .font(.system(size: 9, design: .monospaced))
                        .foregroundColor(.secondary)
                        .padding(.horizontal, 8)
                        .padding(.top, 4)
                }
                ScrollView(.horizontal, showsIndicators: false) {
                    Text(code)
                        .font(.system(size: 10, design: .monospaced))
                        .padding(8)
                        .textSelection(.enabled)
                }
            }
            .background(Color(nsColor: .textBackgroundColor).opacity(0.6))
            .cornerRadius(6)
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .stroke(Color.secondary.opacity(0.2), lineWidth: 0.5)
            )

        case .heading(let level, let text):
            Text(text)
                .font(.system(size: headingSize(level), weight: .bold))
                .padding(.top, level == 1 ? 4 : 2)

        case .listItem(let text, let ordered, let index):
            HStack(alignment: .top, spacing: 4) {
                Text(ordered ? "\(index)." : "•")
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
                    .frame(width: 16, alignment: .trailing)
                renderInlineMarkdown(text)
                    .font(.system(size: 11))
            }

        case .divider:
            Divider()
                .padding(.vertical, 4)
        }
    }

    private func headingSize(_ level: Int) -> CGFloat {
        switch level {
        case 1: return 16
        case 2: return 14
        case 3: return 13
        default: return 12
        }
    }

    // MARK: - Inline Markdown

    /// Renders inline markdown (bold, italic, code, links).
    private func renderInlineMarkdown(_ text: String) -> Text {
        // Simple inline rendering: bold, italic, inline code
        var result = Text("")
        var remaining = text[text.startIndex..<text.endIndex]

        while !remaining.isEmpty {
            // Inline code
            if remaining.first == "`" {
                let afterTick = remaining.index(after: remaining.startIndex)
                if let endTick = remaining[afterTick...].firstIndex(of: "`") {
                    let code = String(remaining[afterTick..<endTick])
                    result = result + Text(code)
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundColor(.orange)
                    remaining = remaining[remaining.index(after: endTick)...]
                    continue
                }
            }

            // Bold **text**
            if remaining.hasPrefix("**") {
                let afterStars = remaining.index(remaining.startIndex, offsetBy: 2)
                if let end = remaining[afterStars...].range(of: "**") {
                    let bold = String(remaining[afterStars..<end.lowerBound])
                    result = result + Text(bold).bold()
                    remaining = remaining[end.upperBound...]
                    continue
                }
            }

            // Italic *text*
            if remaining.first == "*" {
                let afterStar = remaining.index(after: remaining.startIndex)
                if afterStar < remaining.endIndex && remaining[afterStar] != "*" {
                    if let end = remaining[afterStar...].firstIndex(of: "*") {
                        let italic = String(remaining[afterStar..<end])
                        result = result + Text(italic).italic()
                        remaining = remaining[remaining.index(after: end)...]
                        continue
                    }
                }
            }

            // Plain character
            result = result + Text(String(remaining.first!))
            remaining = remaining[remaining.index(after: remaining.startIndex)...]
        }

        return result
    }
}
