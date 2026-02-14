import SwiftUI
import AppKit
import CPierCore

/// Terminal view using NSViewRepresentable to bridge AppKit rendering.
/// Renders terminal cell grid using Core Text for maximum performance.
struct TerminalView: NSViewRepresentable {
    let session: TerminalSessionInfo?

    func makeNSView(context: Context) -> TerminalScrollView {
        let scrollView = TerminalScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.borderType = .noBorder
        scrollView.drawsBackground = false

        let terminalView = TerminalNSView()
        scrollView.documentView = terminalView

        return scrollView
    }

    func updateNSView(_ scrollView: TerminalScrollView, context: Context) {
        guard let terminalView = scrollView.documentView as? TerminalNSView else { return }
        terminalView.updateSession(session)
    }
}

/// Custom NSScrollView that forwards keyboard events to the terminal document view
/// instead of consuming them for scroll behavior.
class TerminalScrollView: NSScrollView {

    override func keyDown(with event: NSEvent) {
        // Forward all keyboard events to the terminal view
        if let terminalView = documentView as? TerminalNSView {
            terminalView.keyDown(with: event)
        } else {
            super.keyDown(with: event)
        }
    }

    override func mouseDown(with event: NSEvent) {
        // Ensure terminal view gets first responder on click
        if let terminalView = documentView as? TerminalNSView {
            window?.makeFirstResponder(terminalView)
        }
        super.mouseDown(with: event)
    }
}


/// AppKit NSView for high-performance terminal rendering.
class TerminalNSView: NSView {
    var session: TerminalSessionInfo?

    // Terminal display configuration
    private var fontSize: CGFloat = 13
    private var fontFamily = "SF Mono"
    private var cellWidth: CGFloat = 8
    private var cellHeight: CGFloat = 16
    private var cursorVisible = true

    // Theme (replaces hardcoded colors)
    var theme: TerminalTheme = .defaultDark {
        didSet { applyTheme() }
    }

    // PTY handle from Rust
    private var terminalHandle: OpaquePointer?
    private var readTimer: Timer?
    private var blinkTimer: Timer?
    private var currentSessionId: UUID?

    // Screen buffer (visible area)
    private var screenBuffer: [[Character]] = []
    private var cursorX: Int = 0
    private var cursorY: Int = 0

    // Scrollback buffer (max 10,000 lines)
    private let maxScrollback = 10_000
    private var scrollbackBuffer: [[Character]] = []

    // Text selection
    private var selectionStart: (row: Int, col: Int)?
    private var selectionEnd: (row: Int, col: Int)?
    private var isSelecting = false

    // URL detection
    private var detectedURLs: [(range: NSRange, url: URL, row: Int, startCol: Int, endCol: Int)] = []

    // MARK: - Lifecycle

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setupView()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setupView()
    }

    private func setupView() {
        wantsLayer = true
        layer?.backgroundColor = theme.background.cgColor

        // Calculate cell dimensions from font
        let font = NSFont(name: fontFamily, size: fontSize)
            ?? NSFont.monospacedSystemFont(ofSize: fontSize, weight: .regular)
        let attrs: [NSAttributedString.Key: Any] = [.font: font]
        let charSize = ("M" as NSString).size(withAttributes: attrs)
        cellWidth = ceil(charSize.width)
        cellHeight = ceil(charSize.height + 2)

        // Cursor blink timer (0.6s interval)
        blinkTimer = Timer.scheduledTimer(withTimeInterval: 0.6, repeats: true) { [weak self] _ in
            self?.cursorVisible.toggle()
            self?.setNeedsDisplay(self?.bounds ?? .zero)
        }
    }

    /// Apply the current theme colors to the view.
    func applyTheme() {
        layer?.backgroundColor = theme.background.cgColor
        needsDisplay = true
    }

    /// Called by updateNSView when the session changes.
    func updateSession(_ session: TerminalSessionInfo?) {
        guard let session = session else { return }
        // Only restart if session changes
        if currentSessionId == session.id { return }
        currentSessionId = session.id
        pendingSession = session

        // Clean up previous terminal
        stopTerminal()

        // Only start terminal if we already have a window (proper bounds)
        if window != nil && bounds.width > 1 && bounds.height > 1 {
            startTerminalForPendingSession()
        }
        // Otherwise, viewDidMoveToWindow will start it
    }

    /// Stored session waiting for view to be attached to window
    private var pendingSession: TerminalSessionInfo?

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard window != nil else { return }

        // Make ourselves first responder now that we have a window
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            self.window?.makeFirstResponder(self)
        }

        // Start terminal if we have a pending session and no running terminal
        if terminalHandle == nil {
            startTerminalForPendingSession()
        }
    }

    private func startTerminalForPendingSession() {
        guard let session = pendingSession else { return }
        startTerminal(shell: session.shellPath)
        pendingSession = nil
    }

    private func stopTerminal() {
        readTimer?.invalidate()
        readTimer = nil
        if let handle = terminalHandle {
            pier_terminal_destroy(handle)
            terminalHandle = nil
        }
        screenBuffer = []
        scrollbackBuffer = []
        cursorX = 0
        cursorY = 0
    }

    func startTerminal(shell: String = "/bin/zsh") {
        // Use the scroll view's visible area for size, not document view bounds
        let visibleSize = enclosingScrollView?.contentView.bounds.size ?? bounds.size
        let cols = max(UInt16(80), UInt16(visibleSize.width / cellWidth))
        let rows = max(UInt16(24), UInt16(visibleSize.height / cellHeight))

        terminalHandle = shell.withCString { shellPtr in
            pier_terminal_create(cols, rows, shellPtr)
        }

        if terminalHandle != nil {
            // Initialize screen buffer to match PTY size
            let colsInt = Int(cols)
            let rowsInt = Int(rows)
            screenBuffer = Array(repeating: Array(repeating: Character(" "), count: colsInt), count: rowsInt)
            startReadLoop()
        }
    }


    private func startReadLoop() {
        readTimer = Timer.scheduledTimer(withTimeInterval: 0.016, repeats: true) { [weak self] _ in
            self?.readTerminalOutput()
        }
    }

    private func readTerminalOutput() {
        guard let handle = terminalHandle else { return }

        var buffer = [UInt8](repeating: 0, count: 65536)
        let bytesRead = pier_terminal_read(handle, &buffer, UInt(buffer.count))

        if bytesRead > 0 {
            let data = Array(buffer[0..<Int(bytesRead)])
            processTerminalOutput(data)
            updateDocumentSize()
            detectURLsInBuffer()
            needsDisplay = true
        }
    }

    // MARK: - Terminal Output Processing

    private var visibleRows: Int {
        max(1, Int(enclosingScrollView?.contentView.bounds.height ?? bounds.height) / Int(cellHeight))
    }

    /// State for the ANSI escape sequence parser
    private enum AnsiState {
        case normal
        case escape       // Just saw ESC (0x1B)
        case csi          // In CSI sequence (ESC [)
        case osc          // In OSC sequence (ESC ])
        case oscEsc       // In OSC, just saw ESC (waiting for \)
    }

    private var ansiState: AnsiState = .normal
    private var csiParams: String = ""

    private func processTerminalOutput(_ bytes: [UInt8]) {
        let cols = max(1, Int(bounds.width / cellWidth))

        for byte in bytes {
            let char = Character(UnicodeScalar(byte))

            switch ansiState {
            case .normal:
                switch byte {
                case 0x1B: // ESC
                    ansiState = .escape
                case 0x0A: // LF (\n)
                    cursorY += 1
                    cursorX = 0
                    if cursorY >= visibleRows {
                        let overflow = screenBuffer.first ?? []
                        scrollbackBuffer.append(overflow)
                        screenBuffer.removeFirst()
                        cursorY = screenBuffer.count
                        if scrollbackBuffer.count > maxScrollback {
                            scrollbackBuffer.removeFirst(scrollbackBuffer.count - maxScrollback)
                        }
                    }
                    if cursorY >= screenBuffer.count {
                        screenBuffer.append(Array(repeating: " ", count: cols))
                    }
                case 0x0D: // CR (\r)
                    cursorX = 0
                case 0x08: // BS (backspace)
                    if cursorX > 0 { cursorX -= 1 }
                case 0x09: // TAB
                    cursorX = min(((cursorX / 8) + 1) * 8, cols - 1)
                case 0x07: // BEL
                    break // Ignore bell
                case 0x00...0x06, 0x0B, 0x0C, 0x0E...0x1A, 0x1C...0x1F:
                    break // Ignore other control characters
                default:
                    // Printable character
                    while cursorY >= screenBuffer.count {
                        screenBuffer.append(Array(repeating: " ", count: cols))
                    }
                    if cursorX >= cols {
                        // Line wrap
                        cursorX = 0
                        cursorY += 1
                        if cursorY >= visibleRows {
                            let overflow = screenBuffer.first ?? []
                            scrollbackBuffer.append(overflow)
                            screenBuffer.removeFirst()
                            cursorY = screenBuffer.count
                        }
                        if cursorY >= screenBuffer.count {
                            screenBuffer.append(Array(repeating: " ", count: cols))
                        }
                    }
                    if cursorY < screenBuffer.count && cursorX < screenBuffer[cursorY].count {
                        screenBuffer[cursorY][cursorX] = char
                        cursorX += 1
                    }
                }

            case .escape:
                switch byte {
                case 0x5B: // '[' -> CSI sequence
                    ansiState = .csi
                    csiParams = ""
                case 0x5D: // ']' -> OSC sequence
                    ansiState = .osc
                case 0x28, 0x29: // '(', ')' -> character set designation, skip next byte
                    ansiState = .normal // simplified: just reset
                default:
                    // Single-character escape sequence, ignore and return to normal
                    ansiState = .normal
                }

            case .csi:
                if byte >= 0x30 && byte <= 0x3F {
                    // Parameter bytes (0-9, ;, <, =, >, ?)
                    csiParams.append(char)
                } else if byte >= 0x20 && byte <= 0x2F {
                    // Intermediate bytes (space through /)
                    csiParams.append(char)
                } else if byte >= 0x40 && byte <= 0x7E {
                    // Final byte — execute CSI command
                    handleCSI(finalByte: byte, params: csiParams)
                    ansiState = .normal
                } else {
                    // Invalid, reset
                    ansiState = .normal
                }

            case .osc:
                if byte == 0x07 {
                    // BEL terminates OSC
                    ansiState = .normal
                } else if byte == 0x1B {
                    ansiState = .oscEsc
                }
                // Otherwise just consume the byte

            case .oscEsc:
                // Expecting '\' (0x5C) to terminate OSC
                ansiState = .normal
            }
        }
    }

    private func handleCSI(finalByte: UInt8, params: String) {
        let cols = max(1, Int(bounds.width / cellWidth))
        let parts = params.split(separator: ";").map { Int($0) ?? 0 }
        let p1 = parts.first ?? 0
        let p2 = parts.count > 1 ? parts[1] : 0

        switch finalByte {
        case 0x41: // 'A' — Cursor Up
            let n = max(1, p1)
            cursorY = max(0, cursorY - n)

        case 0x42: // 'B' — Cursor Down
            let n = max(1, p1)
            cursorY = min(visibleRows - 1, cursorY + n)

        case 0x43: // 'C' — Cursor Forward
            let n = max(1, p1)
            cursorX = min(cols - 1, cursorX + n)

        case 0x44: // 'D' — Cursor Back
            let n = max(1, p1)
            cursorX = max(0, cursorX - n)

        case 0x48, 0x66: // 'H'/'f' — Cursor Position
            let row = max(1, p1) - 1
            let col = max(1, p2) - 1
            cursorY = min(visibleRows - 1, row)
            cursorX = min(cols - 1, col)

        case 0x4A: // 'J' — Erase in Display
            switch p1 {
            case 0: // Clear from cursor to end
                if cursorY < screenBuffer.count {
                    for x in cursorX..<min(cols, screenBuffer[cursorY].count) {
                        screenBuffer[cursorY][x] = " "
                    }
                    for y in (cursorY + 1)..<screenBuffer.count {
                        screenBuffer[y] = Array(repeating: " ", count: cols)
                    }
                }
            case 1: // Clear from start to cursor
                for y in 0..<cursorY {
                    if y < screenBuffer.count {
                        screenBuffer[y] = Array(repeating: " ", count: cols)
                    }
                }
                if cursorY < screenBuffer.count {
                    for x in 0...min(cursorX, screenBuffer[cursorY].count - 1) {
                        screenBuffer[cursorY][x] = " "
                    }
                }
            case 2, 3: // Clear entire screen
                for y in 0..<screenBuffer.count {
                    screenBuffer[y] = Array(repeating: " ", count: cols)
                }
            default:
                break
            }

        case 0x4B: // 'K' — Erase in Line
            guard cursorY < screenBuffer.count else { break }
            switch p1 {
            case 0: // Clear from cursor to end of line
                for x in cursorX..<min(cols, screenBuffer[cursorY].count) {
                    screenBuffer[cursorY][x] = " "
                }
            case 1: // Clear from start to cursor
                for x in 0...min(cursorX, screenBuffer[cursorY].count - 1) {
                    screenBuffer[cursorY][x] = " "
                }
            case 2: // Clear entire line
                screenBuffer[cursorY] = Array(repeating: " ", count: cols)
            default:
                break
            }

        case 0x6D: // 'm' — SGR (Select Graphic Rendition)
            break // Ignore color/style codes for now

        case 0x68, 0x6C: // 'h'/'l' — Set/Reset Mode (e.g., ?2004h for bracketed paste)
            break // Ignore mode set/reset

        default:
            break // Ignore unknown CSI sequences
        }
    }


    private func updateDocumentSize() {
        let totalLines = scrollbackBuffer.count + screenBuffer.count
        let requiredHeight = max(
            enclosingScrollView?.contentView.bounds.height ?? bounds.height,
            CGFloat(totalLines) * cellHeight
        )
        let width = enclosingScrollView?.contentView.bounds.width ?? bounds.width
        setFrameSize(NSSize(width: width, height: requiredHeight))

        // Auto-scroll to bottom
        if let scrollView = enclosingScrollView {
            let clipBounds = scrollView.contentView.bounds
            let docHeight = frame.height
            let isNearBottom = (clipBounds.origin.y + clipBounds.height) >= (docHeight - cellHeight * 3)
            if isNearBottom || !isSelecting {
                scroll(NSPoint(x: 0, y: max(0, frame.height - clipBounds.height)))
            }
        }
    }

    // MARK: - URL Detection

    private func detectURLsInBuffer() {
        detectedURLs.removeAll()
        let allLines = scrollbackBuffer + screenBuffer

        guard let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue) else { return }

        for (row, line) in allLines.enumerated() {
            let text = String(line)
            let range = NSRange(text.startIndex..., in: text)
            let matches = detector.matches(in: text, range: range)
            for match in matches {
                guard let url = match.url else { continue }
                let startCol = match.range.location
                let endCol = match.range.location + match.range.length
                detectedURLs.append((range: match.range, url: url, row: row, startCol: startCol, endCol: endCol))
            }
        }
    }

    // MARK: - Rendering

    override func draw(_ dirtyRect: NSRect) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }

        // Background
        context.setFillColor(theme.background.cgColor)
        context.fill(bounds)

        let font = NSFont(name: fontFamily, size: fontSize)
            ?? NSFont.monospacedSystemFont(ofSize: fontSize, weight: .regular)

        let normalAttrs: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: theme.foreground,
        ]

        let urlAttrs: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: NSColor.systemBlue,
            .underlineStyle: NSUnderlineStyle.single.rawValue,
        ]

        let allLines = scrollbackBuffer + screenBuffer
        let totalLines = allLines.count

        // Calculate visible range from scroll position
        let clipBounds = enclosingScrollView?.contentView.bounds ?? bounds
        let firstVisibleRow = max(0, Int(clipBounds.origin.y / cellHeight) - 1)
        let lastVisibleRow = min(totalLines, firstVisibleRow + Int(clipBounds.height / cellHeight) + 2)

        // Render visible lines
        for row in firstVisibleRow..<lastVisibleRow {
            guard row < allLines.count else { break }
            let line = allLines[row]
            let y = frame.height - CGFloat(row + 1) * cellHeight

            // Check if this row has URLs
            let rowURLs = detectedURLs.filter { $0.row == row }

            // Render selection highlight
            if let start = selectionStart, let end = selectionEnd {
                let (sRow, sCol) = normalizeSelection(start: start, end: end).start
                let (eRow, eCol) = normalizeSelection(start: start, end: end).end
                if row >= sRow && row <= eRow {
                    let startCol = (row == sRow) ? sCol : 0
                    let endCol = (row == eRow) ? eCol : line.count
                    let selRect = NSRect(
                        x: CGFloat(startCol) * cellWidth + 2,
                        y: y,
                        width: CGFloat(endCol - startCol) * cellWidth,
                        height: cellHeight
                    )
                    context.setFillColor(theme.selection.cgColor)
                    context.fill(selRect)
                }
            }

            // Render text character by character for URL styling
            if !rowURLs.isEmpty {
                for (col, char) in line.enumerated() {
                    let isURL = rowURLs.contains { col >= $0.startCol && col < $0.endCol }
                    let attrs = isURL ? urlAttrs : normalAttrs
                    let str = NSAttributedString(string: String(char), attributes: attrs)
                    str.draw(at: NSPoint(x: CGFloat(col) * cellWidth + 2, y: y))
                }
            } else {
                let text = String(line)
                let attrString = NSAttributedString(string: text, attributes: normalAttrs)
                attrString.draw(at: NSPoint(x: 2, y: y))
            }
        }

        // Render cursor (only in screen area, not scrollback)
        if cursorVisible {
            let cursorAbsRow = scrollbackBuffer.count + cursorY
            let cursorRect = NSRect(
                x: CGFloat(cursorX) * cellWidth + 2,
                y: frame.height - CGFloat(cursorAbsRow + 1) * cellHeight,
                width: cellWidth,
                height: cellHeight
            )
            context.setFillColor(theme.cursor.cgColor)
            context.fill(cursorRect)
        }
    }

    // MARK: - Text Selection

    private func cellPosition(for point: NSPoint) -> (row: Int, col: Int) {
        let row = Int((frame.height - point.y) / cellHeight)
        let col = max(0, Int((point.x - 2) / cellWidth))
        return (row, col)
    }

    private func normalizeSelection(start: (row: Int, col: Int), end: (row: Int, col: Int))
        -> (start: (row: Int, col: Int), end: (row: Int, col: Int))
    {
        if start.row < end.row || (start.row == end.row && start.col <= end.col) {
            return (start, end)
        }
        return (end, start)
    }

    override func mouseDown(with event: NSEvent) {
        // Ensure we're first responder on click
        window?.makeFirstResponder(self)

        let point = convert(event.locationInWindow, from: nil)

        // ⌘+click on URL
        if event.modifierFlags.contains(.command) {
            let pos = cellPosition(for: point)
            if let urlMatch = detectedURLs.first(where: { $0.row == pos.row && pos.col >= $0.startCol && pos.col < $0.endCol }) {
                NSWorkspace.shared.open(urlMatch.url)
                return
            }
        }

        selectionStart = cellPosition(for: point)
        selectionEnd = selectionStart
        isSelecting = true
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        guard isSelecting else { return }
        let point = convert(event.locationInWindow, from: nil)
        selectionEnd = cellPosition(for: point)
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        isSelecting = false
    }

    /// Get the selected text as a string.
    private func selectedText() -> String? {
        guard let start = selectionStart, let end = selectionEnd else { return nil }
        let normalized = normalizeSelection(start: start, end: end)
        let sRow = normalized.start.row
        let sCol = normalized.start.col
        let eRow = normalized.end.row
        let eCol = normalized.end.col

        let allLines = scrollbackBuffer + screenBuffer
        var result = ""

        for row in sRow..<min(eRow + 1, allLines.count) {
            let line = allLines[row]
            let startCol = (row == sRow) ? min(sCol, line.count) : 0
            let endCol = (row == eRow) ? min(eCol, line.count) : line.count

            if startCol < endCol {
                let slice = line[startCol..<endCol]
                result += String(slice)
            }
            if row < eRow {
                result += "\n"
            }
        }

        return result.isEmpty ? nil : result
    }

    // MARK: - Input Handling

    override var acceptsFirstResponder: Bool { true }

    override func keyDown(with event: NSEvent) {
        // ⌘C: copy selection
        if event.modifierFlags.contains(.command) && event.charactersIgnoringModifiers == "c" {
            if let text = selectedText() {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(text, forType: .string)
                return
            }
        }

        // ⌘V: paste
        if event.modifierFlags.contains(.command) && event.charactersIgnoringModifiers == "v" {
            if let text = NSPasteboard.general.string(forType: .string) {
                let bytes = Array(text.utf8)
                if let handle = terminalHandle, !bytes.isEmpty {
                    pier_terminal_write(handle, bytes, UInt(bytes.count))
                }
                return
            }
        }

        guard let handle = terminalHandle else { return }

        var bytes: [UInt8] = []

        if let chars = event.characters {
            // Handle special keys
            switch event.keyCode {
            case 36: // Return
                bytes = [0x0D]
            case 51: // Backspace
                bytes = [0x7F]
            case 53: // Escape
                bytes = [0x1B]
            case 123: // Left arrow
                bytes = [0x1B, 0x5B, 0x44]
            case 124: // Right arrow
                bytes = [0x1B, 0x5B, 0x43]
            case 125: // Down arrow
                bytes = [0x1B, 0x5B, 0x42]
            case 126: // Up arrow
                bytes = [0x1B, 0x5B, 0x41]
            case 48: // Tab
                bytes = [0x09]
            default:
                // Ctrl+key shortcuts
                if event.modifierFlags.contains(.control) {
                    let lower = chars.lowercased()
                    if let ch = lower.first, ch >= "a" && ch <= "z" {
                        bytes = [UInt8(ch.asciiValue! - 96)]  // Ctrl+A = 0x01, etc.
                    }
                } else {
                    bytes = Array(chars.utf8)
                }
            }
        }

        if !bytes.isEmpty {
            // Clear selection on typing
            selectionStart = nil
            selectionEnd = nil
            pier_terminal_write(handle, bytes, UInt(bytes.count))
        }
    }

    // MARK: - Scroll

    override func scrollWheel(with event: NSEvent) {
        super.scrollWheel(with: event)
    }

    // MARK: - Resize

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        if let handle = terminalHandle {
            let cols = max(UInt16(1), UInt16(newSize.width / cellWidth))
            let rows = max(UInt16(1), UInt16((enclosingScrollView?.contentView.bounds.height ?? newSize.height) / cellHeight))
            pier_terminal_resize(handle, cols, rows)
        }
    }

    // MARK: - Cleanup

    deinit {
        readTimer?.invalidate()
        blinkTimer?.invalidate()
        if let handle = terminalHandle {
            pier_terminal_destroy(handle)
        }
    }
}
