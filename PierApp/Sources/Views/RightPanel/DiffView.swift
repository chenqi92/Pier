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

// MARK: - Diff Window Controller

/// Opens a resizable native macOS window for diff viewing.
final class DiffWindowController {
    private static var currentWindow: NSWindow?

    static func show(diffText: String) {
        currentWindow?.close()

        let contentView = NSHostingView(rootView: DiffView(diffText: diffText))
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1000, height: 700),
            styleMask: [.titled, .closable, .resizable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.contentView = contentView
        window.minSize = NSSize(width: 600, height: 400)
        window.title = LS("diff.title")
        window.center()
        window.makeKeyAndOrderFront(nil)
        window.isReleasedWhenClosed = false
        currentWindow = window
    }
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
            diffHeader
            Divider()

            if parsedLines.isEmpty {
                emptyState
            } else {
                switch displayMode {
                case .inline:
                    inlineDiffView
                case .sideBySide:
                    SyncedSideBySideDiffView(parsedLines: parsedLines)
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
        GeometryReader { geo in
            ScrollView([.horizontal, .vertical]) {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(parsedLines) { line in
                        inlineLineView(line)
                    }
                }
                .frame(minWidth: geo.size.width)
            }
        }
        .font(.system(size: 11, design: .monospaced))
        .background(Color(nsColor: .textBackgroundColor))
    }

    private func inlineLineView(_ line: DiffLine) -> some View {
        HStack(spacing: 0) {
            Text(line.oldLineNumber.map { "\($0)" } ?? "")
                .frame(width: 40, alignment: .trailing)
                .foregroundColor(.secondary)
                .font(.system(size: 9, design: .monospaced))

            Text(line.newLineNumber.map { "\($0)" } ?? "")
                .frame(width: 40, alignment: .trailing)
                .foregroundColor(.secondary)
                .font(.system(size: 9, design: .monospaced))

            Text(gutterChar(line.type))
                .frame(width: 16)
                .foregroundColor(lineColor(line.type))
                .font(.system(size: 11, weight: .bold, design: .monospaced))

            Text(line.text.isEmpty ? " " : line.text)
                .foregroundColor(lineColor(line.type))
                .textSelection(.enabled)
                .fixedSize(horizontal: true, vertical: false)

            Spacer(minLength: 40)
        }
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
                let parts = text.split(separator: " ")
                if parts.count >= 3 {
                    let oldPart = parts[1].dropFirst()
                    let newPart = parts[2].dropFirst()
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
                lines.append(DiffLine(id: lineId, text: text, type: .context, oldLineNumber: nil, newLineNumber: nil))
            }

            lineId += 1
        }

        parsedLines = lines
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

// MARK: - Synced Side-by-Side Diff View (NSView-based for native scroll sync)

/// This entire side-by-side diff view is implemented in AppKit for native
/// scroll bar support and synchronized scrolling between left and right panes.
struct SyncedSideBySideDiffView: NSViewRepresentable {
    let parsedLines: [DiffLine]

    func makeCoordinator() -> SideBySideCoordinator {
        SideBySideCoordinator()
    }

    func makeNSView(context: Context) -> SideBySideContainerView {
        let container = SideBySideContainerView(coordinator: context.coordinator)
        let (left, right) = splitSideBySide()
        container.update(leftLines: left, rightLines: right)
        return container
    }

    func updateNSView(_ container: SideBySideContainerView, context: Context) {
        let (left, right) = splitSideBySide()
        container.update(leftLines: left, rightLines: right)
    }

    private func splitSideBySide() -> ([DiffLine], [DiffLine]) {
        var left: [DiffLine] = []
        var right: [DiffLine] = []
        var pendingDeletions: [DiffLine] = []
        var pendingAdditions: [DiffLine] = []
        var blankId = -1

        func makeBlank() -> DiffLine {
            blankId -= 1
            return DiffLine(id: blankId, text: "", type: .context, oldLineNumber: nil, newLineNumber: nil)
        }

        func flushPending() {
            let maxCount = max(pendingDeletions.count, pendingAdditions.count)
            for i in 0..<maxCount {
                left.append(i < pendingDeletions.count ? pendingDeletions[i] : makeBlank())
                right.append(i < pendingAdditions.count ? pendingAdditions[i] : makeBlank())
            }
            pendingDeletions.removeAll()
            pendingAdditions.removeAll()
        }

        for line in parsedLines {
            switch line.type {
            case .header, .context:
                flushPending()
                left.append(line)
                right.append(line)
            case .deletion:
                if !pendingAdditions.isEmpty { flushPending() }
                pendingDeletions.append(line)
            case .addition:
                pendingAdditions.append(line)
            }
        }
        flushPending()

        return (left, right)
    }
}

/// Coordinator that observes scroll changes and synchronizes both panes.
class SideBySideCoordinator: NSObject {
    weak var leftScrollView: NSScrollView?
    weak var rightScrollView: NSScrollView?
    private var isSyncing = false

    func startObserving() {
        guard let leftClip = leftScrollView?.contentView,
              let rightClip = rightScrollView?.contentView else { return }

        leftClip.postsBoundsChangedNotifications = true
        rightClip.postsBoundsChangedNotifications = true

        NotificationCenter.default.addObserver(
            self, selector: #selector(leftDidScroll(_:)),
            name: NSView.boundsDidChangeNotification, object: leftClip
        )
        NotificationCenter.default.addObserver(
            self, selector: #selector(rightDidScroll(_:)),
            name: NSView.boundsDidChangeNotification, object: rightClip
        )
    }

    @objc private func leftDidScroll(_ notification: Notification) {
        guard !isSyncing, let left = leftScrollView, let right = rightScrollView else { return }
        isSyncing = true
        let origin = left.contentView.bounds.origin
        right.contentView.scroll(to: origin)
        right.reflectScrolledClipView(right.contentView)
        isSyncing = false
    }

    @objc private func rightDidScroll(_ notification: Notification) {
        guard !isSyncing, let left = leftScrollView, let right = rightScrollView else { return }
        isSyncing = true
        let origin = right.contentView.bounds.origin
        left.contentView.scroll(to: origin)
        left.reflectScrolledClipView(left.contentView)
        isSyncing = false
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }
}

/// Container NSView hosting left and right scroll panes with a draggable divider.
class SideBySideContainerView: NSView {
    let leftScrollView = NSScrollView()
    let rightScrollView = NSScrollView()
    let dividerView = NSView()
    let dividerHitView = NSView() // wider invisible area for dragging
    let coordinator: SideBySideCoordinator

    private let leftDocView = DiffDocumentView()
    private let rightDocView = DiffDocumentView()

    private var dividerFraction: CGFloat = 0.5
    private let dividerWidth: CGFloat = 1
    private let dividerHitWidth: CGFloat = 8

    init(coordinator: SideBySideCoordinator) {
        self.coordinator = coordinator
        super.init(frame: .zero)
        setupViews()
    }

    required init?(coder: NSCoder) { fatalError() }

    private func setupViews() {
        // Left scroll view
        leftScrollView.hasVerticalScroller = true
        leftScrollView.hasHorizontalScroller = true
        leftScrollView.autohidesScrollers = false
        leftScrollView.borderType = .noBorder
        leftScrollView.backgroundColor = .textBackgroundColor
        leftScrollView.drawsBackground = true
        leftScrollView.documentView = leftDocView
        addSubview(leftScrollView)

        // Right scroll view
        rightScrollView.hasVerticalScroller = true
        rightScrollView.hasHorizontalScroller = true
        rightScrollView.autohidesScrollers = false
        rightScrollView.borderType = .noBorder
        rightScrollView.backgroundColor = .textBackgroundColor
        rightScrollView.drawsBackground = true
        rightScrollView.documentView = rightDocView
        addSubview(rightScrollView)

        // Visible thin divider
        dividerView.wantsLayer = true
        dividerView.layer?.backgroundColor = NSColor.separatorColor.cgColor
        addSubview(dividerView)

        // wider invisible drag area on top of divider
        dividerHitView.wantsLayer = true
        addSubview(dividerHitView)

        // Set up drag gesture on hit area
        let panGesture = NSPanGestureRecognizer(target: self, action: #selector(handleDividerDrag(_:)))
        dividerHitView.addGestureRecognizer(panGesture)

        // Set up tracking area for cursor change
        let trackingArea = NSTrackingArea(
            rect: .zero,
            options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        dividerHitView.addTrackingArea(trackingArea)

        // Link coordinator
        coordinator.leftScrollView = leftScrollView
        coordinator.rightScrollView = rightScrollView
        coordinator.startObserving()
    }

    override func mouseEntered(with event: NSEvent) {
        NSCursor.resizeLeftRight.push()
    }

    override func mouseExited(with event: NSEvent) {
        NSCursor.pop()
    }

    @objc private func handleDividerDrag(_ gesture: NSPanGestureRecognizer) {
        let location = gesture.location(in: self)
        let newFrac = location.x / bounds.width
        dividerFraction = max(0.2, min(0.8, newFrac))
        needsLayout = true
    }

    override var isFlipped: Bool { true }

    override func layout() {
        super.layout()

        let totalW = bounds.width
        let totalH = bounds.height
        let leftW = (totalW - dividerHitWidth) * dividerFraction
        let rightX = leftW + dividerHitWidth
        let rightW = totalW - rightX

        leftScrollView.frame = NSRect(x: 0, y: 0, width: leftW, height: totalH)
        rightScrollView.frame = NSRect(x: rightX, y: 0, width: rightW, height: totalH)

        // Thin visible divider centered in hit area
        let dividerX = leftW + (dividerHitWidth - dividerWidth) / 2
        dividerView.frame = NSRect(x: dividerX, y: 0, width: dividerWidth, height: totalH)

        // Hit area
        dividerHitView.frame = NSRect(x: leftW, y: 0, width: dividerHitWidth, height: totalH)
    }

    func update(leftLines: [DiffLine], rightLines: [DiffLine]) {
        leftDocView.update(lines: leftLines, isLeft: true)
        rightDocView.update(lines: rightLines, isLeft: false)
    }
}

/// Custom flipped NSView that hosts an NSTextView for diff display with text selection support.
class DiffDocumentView: NSView {
    private var lines: [DiffLine] = []
    private var isLeft: Bool = true

    private let lineHeight: CGFloat = 18
    private let gutterWidth: CGFloat = 44
    private let textFont = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
    private let numFont = NSFont.monospacedSystemFont(ofSize: 9, weight: .regular)

    private let textView = NSTextView()
    private let gutterView = DiffGutterView()

    override var isFlipped: Bool { true }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setupTextView()
    }

    required init?(coder: NSCoder) { fatalError() }

    private func setupTextView() {
        // Gutter (line numbers only)
        gutterView.frame = NSRect(x: 0, y: 0, width: gutterWidth, height: 0)
        addSubview(gutterView)

        // Text view — selectable, not editable
        textView.isEditable = false
        textView.isSelectable = true
        textView.isRichText = false
        textView.backgroundColor = .clear
        textView.drawsBackground = false
        textView.textContainerInset = NSSize(width: 0, height: 0)
        textView.textContainer?.lineFragmentPadding = 4
        textView.textContainer?.widthTracksTextView = false
        textView.textContainer?.containerSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.isHorizontallyResizable = true
        textView.isVerticallyResizable = true
        textView.autoresizingMask = []
        addSubview(textView)
    }

    func update(lines: [DiffLine], isLeft: Bool) {
        self.lines = lines
        self.isLeft = isLeft

        // Build attributed string with per-line coloring
        let storage = NSMutableAttributedString()
        let paraStyle = NSMutableParagraphStyle()
        paraStyle.minimumLineHeight = lineHeight
        paraStyle.maximumLineHeight = lineHeight

        for (i, line) in lines.enumerated() {
            let text = (line.text.isEmpty ? " " : line.text) + (i < lines.count - 1 ? "\n" : "")
            let attrs: [NSAttributedString.Key: Any] = [
                .font: textFont,
                .foregroundColor: fgColor(line.type),
                .backgroundColor: bgColor(line.type),
                .paragraphStyle: paraStyle
            ]
            storage.append(NSAttributedString(string: text, attributes: attrs))
        }

        textView.textStorage?.setAttributedString(storage)

        // Measure content size
        textView.layoutManager?.ensureLayout(for: textView.textContainer!)
        let usedRect = textView.layoutManager?.usedRect(for: textView.textContainer!) ?? .zero
        let totalW = gutterWidth + max(usedRect.width, 200) + 40
        let totalH = max(usedRect.height, CGFloat(lines.count) * lineHeight) + 10

        frame = NSRect(x: 0, y: 0, width: totalW, height: totalH)
        textView.frame = NSRect(x: gutterWidth, y: 0, width: totalW - gutterWidth, height: totalH)

        // Update gutter
        gutterView.update(lines: lines, isLeft: isLeft, lineHeight: lineHeight, font: numFont)
        gutterView.frame = NSRect(x: 0, y: 0, width: gutterWidth, height: totalH)
    }

    private func bgColor(_ type: DiffLineType) -> NSColor {
        switch type {
        case .addition: return NSColor.systemGreen.withAlphaComponent(0.08)
        case .deletion: return NSColor.systemRed.withAlphaComponent(0.08)
        case .header:   return NSColor.systemCyan.withAlphaComponent(0.05)
        case .context:  return .clear
        }
    }

    private func fgColor(_ type: DiffLineType) -> NSColor {
        switch type {
        case .addition: return .systemGreen
        case .deletion: return .systemRed
        case .header:   return .systemCyan
        case .context:  return .labelColor
        }
    }
}

/// Gutter view that draws line numbers next to the text view.
class DiffGutterView: NSView {
    private var lines: [DiffLine] = []
    private var isLeft = true
    private var lineHeight: CGFloat = 18
    private var numFont = NSFont.monospacedSystemFont(ofSize: 9, weight: .regular)

    override var isFlipped: Bool { true }

    func update(lines: [DiffLine], isLeft: Bool, lineHeight: CGFloat, font: NSFont) {
        self.lines = lines
        self.isLeft = isLeft
        self.lineHeight = lineHeight
        self.numFont = font
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)

        let numAttrs: [NSAttributedString.Key: Any] = [
            .font: numFont,
            .foregroundColor: NSColor.secondaryLabelColor
        ]

        for (i, line) in lines.enumerated() {
            let y = CGFloat(i) * lineHeight
            let rowRect = NSRect(x: 0, y: y, width: bounds.width, height: lineHeight)
            guard dirtyRect.intersects(rowRect) else { continue }

            // Background (match text area)
            let bg = bgColor(line.type)
            if bg != .clear {
                bg.setFill()
                rowRect.fill()
            }

            let num = isLeft ? line.oldLineNumber : line.newLineNumber
            if let num = num {
                let numStr = "\(num)"
                let numSize = (numStr as NSString).size(withAttributes: numAttrs)
                let numX = bounds.width - numSize.width - 4
                let numY = y + (lineHeight - numSize.height) / 2
                (numStr as NSString).draw(at: NSPoint(x: numX, y: numY), withAttributes: numAttrs)
            }
        }
    }

    private func bgColor(_ type: DiffLineType) -> NSColor {
        switch type {
        case .addition: return NSColor.systemGreen.withAlphaComponent(0.08)
        case .deletion: return NSColor.systemRed.withAlphaComponent(0.08)
        case .header:   return NSColor.systemCyan.withAlphaComponent(0.05)
        case .context:  return .clear
        }
    }
}
