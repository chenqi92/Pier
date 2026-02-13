import SwiftUI
import AppKit
import CPierCore

/// Terminal view using NSViewRepresentable to bridge AppKit rendering.
/// Renders terminal cell grid using Core Text for maximum performance.
struct TerminalView: NSViewRepresentable {
    let session: TerminalSessionInfo?

    func makeNSView(context: Context) -> TerminalNSView {
        let view = TerminalNSView()
        return view
    }

    func updateNSView(_ nsView: TerminalNSView, context: Context) {
        // Start or switch terminal when session changes (fixes B2)
        nsView.updateSession(session)
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
    private var screenBuffer: [[Character]] = []
    private var cursorX: Int = 0
    private var cursorY: Int = 0
    private var currentSessionId: UUID?

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

        // Clean up previous terminal
        stopTerminal()

        // Start new terminal for this session
        startTerminal(shell: session.shellPath)
    }

    private func stopTerminal() {
        readTimer?.invalidate()
        readTimer = nil
        if let handle = terminalHandle {
            pier_terminal_destroy(handle)
            terminalHandle = nil
        }
        screenBuffer = []
        cursorX = 0
        cursorY = 0
    }

    func startTerminal(shell: String = "/bin/zsh") {
        let cols = UInt16(bounds.width / cellWidth)
        let rows = UInt16(bounds.height / cellHeight)

        terminalHandle = shell.withCString { shellPtr in
            pier_terminal_create(cols, rows, shellPtr)
        }

        if terminalHandle != nil {
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
            needsDisplay = true
        }
    }

    private func processTerminalOutput(_ bytes: [UInt8]) {
        // Simple line-based rendering for MVP
        // In production, this would use the VT emulator from Rust
        if let text = String(bytes: bytes, encoding: .utf8) {
            for char in text {
                switch char {
                case "\n":
                    cursorY += 1
                    cursorX = 0
                    if cursorY >= screenBuffer.count {
                        screenBuffer.append(Array(repeating: " ", count: Int(bounds.width / cellWidth)))
                    }
                case "\r":
                    cursorX = 0
                case "\u{8}": // backspace
                    if cursorX > 0 { cursorX -= 1 }
                default:
                    while cursorY >= screenBuffer.count {
                        screenBuffer.append(Array(repeating: " ", count: Int(bounds.width / cellWidth)))
                    }
                    if cursorX < screenBuffer[cursorY].count {
                        screenBuffer[cursorY][cursorX] = char
                        cursorX += 1
                    }
                }
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

        let attrs: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: theme.foreground,
        ]

        // Render screen buffer
        for (row, line) in screenBuffer.enumerated() {
            let y = bounds.height - CGFloat(row + 1) * cellHeight
            let text = String(line)
            let attrString = NSAttributedString(string: text, attributes: attrs)
            attrString.draw(at: NSPoint(x: 2, y: y))
        }

        // Render cursor
        if cursorVisible {
            let cursorRect = NSRect(
                x: CGFloat(cursorX) * cellWidth + 2,
                y: bounds.height - CGFloat(cursorY + 1) * cellHeight,
                width: cellWidth,
                height: cellHeight
            )
            context.setFillColor(theme.cursor.cgColor)
            context.fill(cursorRect)
        }
    }

    // MARK: - Input Handling

    override var acceptsFirstResponder: Bool { true }

    override func keyDown(with event: NSEvent) {
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
                bytes = Array(chars.utf8)
            }
        }

        if !bytes.isEmpty {
            pier_terminal_write(handle, bytes, UInt(bytes.count))
        }
    }

    // MARK: - Resize

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        if let handle = terminalHandle {
            let cols = UInt16(newSize.width / cellWidth)
            let rows = UInt16(newSize.height / cellHeight)
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
