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

        // Set initial frame so document view matches visible area
        DispatchQueue.main.async {
            let visibleSize = scrollView.contentView.bounds.size
            if visibleSize.width > 1 && visibleSize.height > 1 {
                terminalView.frame = CGRect(origin: .zero, size: visibleSize)
            }
        }

        return scrollView
    }

    func updateNSView(_ scrollView: TerminalScrollView, context: Context) {
        guard let terminalView = scrollView.documentView as? TerminalNSView else { return }
        terminalView.updateSession(session)
    }
}

/// Custom NSScrollView that forwards keyboard events to the terminal document view
/// instead of consuming them for scroll behavior.
/// Also observes viewport size changes to trigger PTY resize when panels are dragged.
class TerminalScrollView: NSScrollView {

    private var boundsObserver: NSObjectProtocol?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setupBoundsObservation()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setupBoundsObservation()
    }

    private func setupBoundsObservation() {
        // Observe clip view bounds changes so we can resize the PTY
        // when the user drags panel dividers
        contentView.postsBoundsChangedNotifications = true
        boundsObserver = NotificationCenter.default.addObserver(
            forName: NSView.boundsDidChangeNotification,
            object: contentView,
            queue: .main
        ) { [weak self] _ in
            self?.handleViewportResize()
        }
    }

    deinit {
        if let observer = boundsObserver {
            NotificationCenter.default.removeObserver(observer)
        }
    }

    /// When the scroll view itself is resized (HSplitView divider dragged),
    /// update the document view to match the new visible area.
    override func resizeSubviews(withOldSize oldSize: NSSize) {
        super.resizeSubviews(withOldSize: oldSize)
        handleViewportResize()
    }

    private func handleViewportResize() {
        guard let terminalView = documentView as? TerminalNSView else { return }
        let visibleSize = contentView.bounds.size
        if visibleSize.width > 1 && visibleSize.height > 1 {
            terminalView.handleViewportSizeChanged(visibleSize)
        }
    }

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

    // Use top-left origin (standard for terminal rendering)
    override var isFlipped: Bool { true }

    // Terminal display configuration
    private var fontSize: CGFloat = 13
    private var fontFamily = "SF Mono"
    private var cellWidth: CGFloat = 8
    private var cellHeight: CGFloat = 16
    private var cursorVisible = true

    // Theme (replaces hardcoded colors)
    var theme: TerminalTheme = .defaultDark {
        didSet { applyTheme(); rebuildCachedAttrs() }
    }

    // PTY handle from Rust
    private var terminalHandle: OpaquePointer?
    private var readTimer: Timer?
    private var blinkTimer: Timer?
    private var currentSessionId: UUID?
    /// Weak reference to current session for SSH password auto-input
    private weak var currentSession: TerminalSessionInfo?
    /// Accumulates recent terminal output (last ~512 chars) for SSH prompt detection
    private var sshOutputAccumulator = ""
    /// Whether SSH password has already been auto-typed for this session
    private var sshPasswordAutoTyped = false
    /// Whether SSH auth failure has been reported for this session
    private var sshAuthFailureReported = false

    // MARK: - PTY Cache (persists across tab switches)

    /// Cached PTY state for a terminal session.
    struct PTYCacheEntry {
        let handle: OpaquePointer
        var screenBuffer: [[Character]]
        var scrollbackBuffer: [[Character]]
        var cursorX: Int
        var cursorY: Int
        var ptyCols: Int
        var ptyRows: Int
        var savedCursorX: Int
        var savedCursorY: Int
    }

    /// Static cache: session ID → PTY state. Persists across view re-creation.
    private static var ptyCache: [UUID: PTYCacheEntry] = [:]

    /// Destroy a cached PTY when its tab is closed.
    static func destroyCachedPTY(sessionId: UUID) {
        if let entry = ptyCache.removeValue(forKey: sessionId) {
            pier_terminal_destroy(entry.handle)
        }
    }

    // PTY dimensions (authoritative — never recalculate from view size during processing)
    private var ptyCols: Int = 80
    private var ptyRows: Int = 24

    // Terminal → SFTP directory sync (trailing-edge: check after output stops)
    private var lastDetectedCwd: String?
    private var pendingCwdCheck = false
    private var sshExitDetected = false  // Prevent repeated SSH exit notifications

    // Screen buffer (visible area)
    private var screenBuffer: [[Character]] = []
    private var cursorX: Int = 0
    private var cursorY: Int = 0

    // Saved cursor position (ESC 7 / ESC 8, CSI s / CSI u)
    private var savedCursorX: Int = 0
    private var savedCursorY: Int = 0

    // Scrollback buffer (max 10,000 lines)
    private let maxScrollback = 10_000
    private var scrollbackBuffer: [[Character]] = []

    // Text selection
    private var selectionStart: (row: Int, col: Int)?
    private var selectionEnd: (row: Int, col: Int)?
    private var isSelecting = false

    // URL detection
    private var detectedURLs: [(range: NSRange, url: URL, row: Int, startCol: Int, endCol: Int)] = []
    private var lastURLDetectionTime: CFAbsoluteTime = 0
    private lazy var urlDetector: NSDataDetector? = {
        try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue)
    }()

    // Reusable read buffer (avoid 64KB allocation per tick)
    private var readBuffer = [UInt8](repeating: 0, count: 65536)

    // Cached fonts and attributes (rebuilt on theme/font change)
    private var cachedMonoFont: NSFont!
    private var cachedFallbackFont: NSFont!
    private var cachedNormalAttrs: [NSAttributedString.Key: Any] = [:]
    private var cachedFallbackAttrs: [NSAttributedString.Key: Any] = [:]
    private var cachedURLAttrs: [NSAttributedString.Key: Any] = [:]

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

        let attrStr = NSAttributedString(string: "M", attributes: [
            .font: font
        ])
        let size = attrStr.size()
        cellWidth = ceil(size.width)
        cellHeight = ceil(size.height * 1.2)   // slight line spacing

        rebuildCachedAttrs()

        // Blink timer for cursor
        blinkTimer = Timer.scheduledTimer(withTimeInterval: 0.6, repeats: true) { [weak self] _ in
            self?.cursorVisible.toggle()
            self?.needsDisplay = true
        }

        // Listen for SFTP directory changes → cd in terminal
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleSftpDirectoryChanged(_:)),
            name: .sftpDirectoryChanged,
            object: nil
        )

        // Listen for tab close to destroy PTY
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleTabClosed(_:)),
            name: .terminalTabClosed,
            object: nil
        )

        // Listen for programmatic text input (auto-type SSH password, etc.)
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleTerminalInput(_:)),
            name: .terminalInput,
            object: nil
        )
    }

    @objc private func handleTerminalInput(_ notification: Notification) {
        guard let handle = terminalHandle else { return }
        var text: String?
        var deliveryFlag: UnsafeMutablePointer<Bool>?
        if let info = notification.object as? [String: Any] {
            // From TerminalViewModel.sendInput: ["sessionId": UUID, "text": String]
            if let sessionId = info["sessionId"] as? UUID {
                guard sessionId == currentSessionId else { return }
            }
            text = info["text"] as? String
            deliveryFlag = info["deliveryFlag"] as? UnsafeMutablePointer<Bool>
        }
        guard let inputText = text, !inputText.isEmpty else { return }
        let bytes = Array(inputText.utf8)
        pier_terminal_write(handle, bytes, UInt(bytes.count))
        deliveryFlag?.pointee = true
    }

    @objc private func handleTabClosed(_ notification: Notification) {
        guard let sessionId = notification.object as? UUID else { return }
        // If this is the currently displayed session, stop it
        if currentSessionId == sessionId {
            stopTimers()
            if let handle = terminalHandle {
                pier_terminal_destroy(handle)
                terminalHandle = nil
            }
            currentSessionId = nil
        }
        // Also remove from static cache
        TerminalNSView.destroyCachedPTY(sessionId: sessionId)
    }

    @objc private func handleSftpDirectoryChanged(_ notification: Notification) {
        guard let info = notification.object as? [String: String],
              let path = info["path"],
              let handle = terminalHandle else { return }

        // Send "cd <path>\n" to the terminal PTY
        let cdCommand = "cd \(shellEscapeForTerminal(path))\n"
        let bytes = Array(cdCommand.utf8)
        pier_terminal_write(handle, bytes, UInt(bytes.count))
    }

    /// Shell-escape a path for terminal cd command.
    private func shellEscapeForTerminal(_ path: String) -> String {
        "'" + path.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// Apply the current theme colors to the view.
    func applyTheme() {
        layer?.backgroundColor = theme.background.cgColor
        needsDisplay = true
    }

    /// Rebuild cached font and attribute dictionaries.
    private func rebuildCachedAttrs() {
        cachedMonoFont = NSFont(name: fontFamily, size: fontSize)
            ?? NSFont.monospacedSystemFont(ofSize: fontSize, weight: .regular)
        cachedFallbackFont = NSFont.systemFont(ofSize: fontSize)
        cachedNormalAttrs = [
            .font: cachedMonoFont!,
            .foregroundColor: theme.foreground,
        ]
        cachedFallbackAttrs = [
            .font: cachedFallbackFont!,
            .foregroundColor: theme.foreground,
        ]
        cachedURLAttrs = [
            .font: cachedMonoFont!,
            .foregroundColor: NSColor.systemBlue,
            .underlineStyle: NSUnderlineStyle.single.rawValue,
        ]
    }

    /// Called by updateNSView when the session changes.
    func updateSession(_ session: TerminalSessionInfo?) {
        guard let session = session else { return }
        // Only switch if session actually changes
        if currentSessionId == session.id { return }

        // ── Save current PTY state to cache ──
        saveCurrentToCache()
        stopTimers()

        currentSessionId = session.id
        currentSession = session
        sshOutputAccumulator = ""
        sshPasswordAutoTyped = false
        sshAuthFailureReported = false

        // ── Try to restore from cache ──
        if let cached = TerminalNSView.ptyCache.removeValue(forKey: session.id) {
            terminalHandle = cached.handle
            screenBuffer = cached.screenBuffer
            scrollbackBuffer = cached.scrollbackBuffer
            cursorX = cached.cursorX
            cursorY = cached.cursorY
            ptyCols = cached.ptyCols
            ptyRows = cached.ptyRows
            savedCursorX = cached.savedCursorX
            savedCursorY = cached.savedCursorY
            startReadLoop()
            needsDisplay = true
        } else {
            // New session — need to create PTY
            terminalHandle = nil
            screenBuffer = []
            scrollbackBuffer = []
            cursorX = 0
            cursorY = 0
            pendingSession = session

            let visibleSize = enclosingScrollView?.contentView.bounds.size ?? .zero
            if window != nil && visibleSize.width > 1 && visibleSize.height > 1 {
                startTerminalForPendingSession()
            }
        }

        // Make ourselves first responder
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            self.window?.makeFirstResponder(self)
        }
    }

    /// Save the current terminal state into the static cache.
    private func saveCurrentToCache() {
        guard let sessionId = currentSessionId, let handle = terminalHandle else { return }
        let entry = PTYCacheEntry(
            handle: handle,
            screenBuffer: screenBuffer,
            scrollbackBuffer: scrollbackBuffer,
            cursorX: cursorX,
            cursorY: cursorY,
            ptyCols: ptyCols,
            ptyRows: ptyRows,
            savedCursorX: savedCursorX,
            savedCursorY: savedCursorY
        )
        TerminalNSView.ptyCache[sessionId] = entry
        // Detach handle from this view (cache now owns it)
        terminalHandle = nil
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
    }

    override func layout() {
        super.layout()
        // Start terminal once we have real dimensions from the scroll view
        if terminalHandle == nil, pendingSession != nil {
            let visibleSize = enclosingScrollView?.contentView.bounds.size ?? .zero
            if visibleSize.width > 1 && visibleSize.height > 1 {
                startTerminalForPendingSession()
            }
        }
    }

    private func startTerminalForPendingSession() {
        guard let session = pendingSession else { return }
        if let sshProgram = session.sshProgram, let sshArgs = session.sshArgs {
            startTerminalWithCommand(program: sshProgram, args: sshArgs)
        } else {
            startTerminal(shell: session.shellPath)
        }
        pendingSession = nil
    }

    /// Stop timers only (PTY handle is preserved in cache).
    private func stopTimers() {
        readTimer?.invalidate()
        readTimer = nil
    }

    /// Full cleanup — only called when the tab is physically closed.
    private func stopTerminal() {
        stopTimers()
        blinkTimer?.invalidate()
        blinkTimer = nil
        NotificationCenter.default.removeObserver(self, name: .sftpDirectoryChanged, object: nil)
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
        let cols = max(Int(80), Int(visibleSize.width / cellWidth))
        let rows = max(Int(24), Int(visibleSize.height / cellHeight))

        // Store authoritative PTY dimensions
        ptyCols = cols
        ptyRows = rows

        terminalHandle = shell.withCString { shellPtr in
            pier_terminal_create(UInt16(cols), UInt16(rows), shellPtr)
        }

        if terminalHandle != nil {
            // Initialize screen buffer to match PTY size
            screenBuffer = Array(repeating: Array(repeating: Character(" "), count: cols), count: rows)
            startReadLoop()
        }
    }

    /// Start terminal with a specific command and arguments (e.g. direct SSH).
    func startTerminalWithCommand(program: String, args: [String]) {
        let visibleSize = enclosingScrollView?.contentView.bounds.size ?? bounds.size
        let cols = max(Int(80), Int(visibleSize.width / cellWidth))
        let rows = max(Int(24), Int(visibleSize.height / cellHeight))

        ptyCols = cols
        ptyRows = rows

        // Convert args to C strings
        let cArgs = args.map { strdup($0)! }
        defer { cArgs.forEach { free($0) } }

        var argPtrs = cArgs.map { UnsafePointer($0) as UnsafePointer<CChar>? }

        terminalHandle = program.withCString { programPtr in
            argPtrs.withUnsafeMutableBufferPointer { buffer in
                pier_terminal_create_with_args(
                    UInt16(cols),
                    UInt16(rows),
                    programPtr,
                    buffer.baseAddress!,
                    UInt32(args.count)
                )
            }
        }

        if terminalHandle != nil {
            screenBuffer = Array(repeating: Array(repeating: Character(" "), count: cols), count: rows)
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

        let bytesRead = pier_terminal_read(handle, &readBuffer, UInt(readBuffer.count))

        if bytesRead > 0 {
            let data = Array(readBuffer[0..<Int(bytesRead)])
            processTerminalOutput(data)
            updateDocumentSize()
            // Throttle URL detection to at most once per 500ms
            let now = CFAbsoluteTimeGetCurrent()
            if now - lastURLDetectionTime > 0.5 {
                lastURLDetectionTime = now
                detectURLsInBuffer()
            }
            needsDisplay = true
            // Mark that we need to check CWD once output settles
            pendingCwdCheck = true

            // SSH prompt detection: accumulate output and check for password prompt / auth failure
            if let session = currentSession, session.isSSH {
                if let chunk = String(bytes: data, encoding: .utf8) {
                    sshOutputAccumulator += chunk
                    // Keep buffer manageable (last 1024 chars)
                    if sshOutputAccumulator.count > 1024 {
                        sshOutputAccumulator = String(sshOutputAccumulator.suffix(512))
                    }
                    checkSSHPrompts()
                }
            }
        } else if pendingCwdCheck {
            // Trailing-edge: output just stopped → prompt is fully rendered
            pendingCwdCheck = false
            detectPromptCwd()
            detectSSHExit()
        }
    }

    /// Check accumulated SSH output for password prompts and auth failures.
    private func checkSSHPrompts() {
        guard let handle = terminalHandle else { return }
        let lower = sshOutputAccumulator.lowercased()

        // 1. Password prompt detection — auto-type immediately
        if !sshPasswordAutoTyped {
            // SSH password prompts end with "password:" or "password: " (with optional leading text)
            if lower.hasSuffix("password: ") || lower.hasSuffix("password:") {
                if let password = currentSession?.pendingSSHPassword, !password.isEmpty {
                    // Auto-type the password
                    let input = password + "\n"
                    let bytes = Array(input.utf8)
                    pier_terminal_write(handle, bytes, UInt(bytes.count))
                    sshPasswordAutoTyped = true
                    // Consume the password from session
                    currentSession?.pendingSSHPassword = nil
                    // Clear accumulator to avoid re-triggering
                    sshOutputAccumulator = ""
                }
            }
        }

        // 2. Auth failure detection — prompt user for new password
        if !sshAuthFailureReported {
            if lower.contains("permission denied") || lower.contains("authentication failed") {
                sshAuthFailureReported = true
                if let sessionId = currentSessionId {
                    NotificationCenter.default.post(
                        name: .terminalSSHAuthFailed,
                        object: sessionId
                    )
                }
            }
        }
    }

    /// Detect when an SSH session has ended (user typed 'exit' or connection closed).
    /// Scans the last few lines of the screen buffer for disconnect patterns.
    private func detectSSHExit() {
        guard let sessionId = currentSessionId, !sshExitDetected else { return }

        // Scan the last few lines above the cursor for SSH disconnect patterns
        let linesToScan = min(5, screenBuffer.count)
        let startRow = max(0, cursorY - linesToScan)
        let endRow = cursorY

        for row in startRow..<endRow {
            guard row >= 0 && row < screenBuffer.count else { continue }
            let line = String(screenBuffer[row]).trimmingCharacters(in: .whitespaces)

            // Match patterns like:
            //   "Connection to 192.168.0.3 closed."
            //   "Connection to host.example.com closed."
            //   "logout"  (followed by "Connection to ... closed" on next line)
            if line.hasPrefix("Connection to ") && line.hasSuffix("closed.") {
                sshExitDetected = true
                NotificationCenter.default.post(
                    name: .terminalSSHExited,
                    object: sessionId
                )
                return
            }
        }
    }

    /// Detect the current working directory from the terminal prompt.
    /// Matches patterns like: `user@host:path#` or `user@host:path$`
    private func detectPromptCwd() {
        guard cursorY >= 0 && cursorY < screenBuffer.count else { return }
        let line = String(screenBuffer[cursorY]).trimmingCharacters(in: .whitespaces)
        guard !line.isEmpty else { return }

        // Match common prompt patterns:
        // root@host:/path#    root@host:/path$    root@host:~#    root@host:~/sub$
        // user@host:/path %   (zsh style)
        let pattern = #"[\w.-]+@[\w.-]+:([^\s#$%]+)[#$%]\s*$"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)),
              match.numberOfRanges > 1,
              let pathRange = Range(match.range(at: 1), in: line) else { return }

        var path = String(line[pathRange])

        // Expand ~ to home directory
        if path == "~" || path.hasPrefix("~/") {
            // For root user, ~ = /root; for others, ~ = /home/user
            // Extract username from prompt
            let userPattern = #"^([\w.-]+)@"#
            if let userRegex = try? NSRegularExpression(pattern: userPattern),
               let userMatch = userRegex.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)),
               userMatch.numberOfRanges > 1,
               let userRange = Range(userMatch.range(at: 1), in: line) {
                let user = String(line[userRange])
                let home = user == "root" ? "/root" : "/home/\(user)"
                path = path == "~" ? home : home + path.dropFirst() // drop "~"
            }
        }

        // Only post notification if the path actually changed
        if path != lastDetectedCwd && !path.isEmpty {
            lastDetectedCwd = path
            NotificationCenter.default.post(
                name: .terminalCwdChanged,
                object: ["path": path]
            )
        }
    }

    // MARK: - Terminal Output Processing

    /// The visible area size from the enclosing scroll view, NOT from self.bounds
    /// (self.bounds is the document view size, which may be larger than the visible area).
    private var visibleSize: CGSize {
        enclosingScrollView?.contentView.bounds.size ?? bounds.size
    }

    private var visibleRows: Int {
        ptyRows
    }

    private var visibleCols: Int {
        ptyCols
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

    // UTF-8 multi-byte accumulator
    private var utf8Buffer: [UInt8] = []
    private var utf8Remaining: Int = 0

    /// Check if a Unicode scalar is a wide (full-width / CJK) character that occupies 2 terminal cells.
    private func isWideCharacter(_ scalar: Unicode.Scalar) -> Bool {
        let v = scalar.value
        // CJK Unified Ideographs and extensions
        if v >= 0x2E80 && v <= 0x9FFF { return true }
        if v >= 0xF900 && v <= 0xFAFF { return true }
        // Hangul
        if v >= 0xAC00 && v <= 0xD7AF { return true }
        // Fullwidth Forms
        if v >= 0xFF01 && v <= 0xFF60 { return true }
        if v >= 0xFFE0 && v <= 0xFFE6 { return true }
        // CJK Unified Ideographs Extension B+
        if v >= 0x20000 && v <= 0x2FA1F { return true }
        return false
    }

    /// Place a decoded character into the screen buffer at the current cursor position,
    /// handling line wrap and wide (double-width) characters.
    private func placeCharacter(_ char: Character) {
        let cols = visibleCols
        let charWidth: Int
        if let scalar = char.unicodeScalars.first, isWideCharacter(scalar) {
            charWidth = 2
        } else {
            charWidth = 1
        }

        // Check if we need to wrap before placing
        if cursorX + charWidth > cols {
            cursorX = 0
            cursorY += 1
            if cursorY >= visibleRows {
                if !screenBuffer.isEmpty {
                    scrollbackBuffer.append(screenBuffer.removeFirst())
                }
                screenBuffer.append(Array(repeating: " ", count: cols))
                cursorY = visibleRows - 1
            }
            while cursorY >= screenBuffer.count {
                screenBuffer.append(Array(repeating: " ", count: cols))
            }
        }

        // Ensure buffer has the row
        while cursorY >= screenBuffer.count {
            screenBuffer.append(Array(repeating: " ", count: cols))
        }

        if cursorY < screenBuffer.count && cursorX < screenBuffer[cursorY].count {
            screenBuffer[cursorY][cursorX] = char
            cursorX += 1
            // For wide characters, place a zero-width placeholder in the next cell
            if charWidth == 2 && cursorX < screenBuffer[cursorY].count {
                screenBuffer[cursorY][cursorX] = "\u{200B}" // zero-width space as placeholder
                cursorX += 1
            }
        }
    }

    private func processTerminalOutput(_ bytes: [UInt8]) {
        let cols = visibleCols

        for byte in bytes {
            // If we are accumulating a multi-byte UTF-8 sequence, continue collecting
            if utf8Remaining > 0 {
                if byte & 0xC0 == 0x80 {
                    // Valid continuation byte
                    utf8Buffer.append(byte)
                    utf8Remaining -= 1
                    if utf8Remaining == 0 {
                        // Decode the complete UTF-8 sequence
                        if let str = String(bytes: utf8Buffer, encoding: .utf8),
                           let char = str.first {
                            placeCharacter(char)
                        }
                        utf8Buffer.removeAll()
                    }
                } else {
                    // Invalid continuation — discard buffer and reprocess this byte
                    utf8Buffer.removeAll()
                    utf8Remaining = 0
                    // Fall through to process this byte normally below
                    processTerminalByte(byte, cols: cols)
                }
                continue
            }

            // Check if this byte starts a multi-byte UTF-8 sequence (in .normal state only)
            if ansiState == .normal && byte >= 0xC0 {
                if byte & 0xE0 == 0xC0 {
                    // 2-byte sequence
                    utf8Buffer = [byte]
                    utf8Remaining = 1
                    continue
                } else if byte & 0xF0 == 0xE0 {
                    // 3-byte sequence
                    utf8Buffer = [byte]
                    utf8Remaining = 2
                    continue
                } else if byte & 0xF8 == 0xF0 {
                    // 4-byte sequence
                    utf8Buffer = [byte]
                    utf8Remaining = 3
                    continue
                }
                // Invalid lead byte (0xF8+), ignore
                continue
            }

            processTerminalByte(byte, cols: cols)
        }
    }

    /// Process a single byte that is not part of a multi-byte UTF-8 sequence.
    private func processTerminalByte(_ byte: UInt8, cols: Int) {
        let char = Character(UnicodeScalar(byte))

        switch ansiState {
        case .normal:
            switch byte {
            case 0x1B: // ESC
                ansiState = .escape
            case 0x0A: // LF (\n)
                cursorY += 1
                if cursorY >= visibleRows {
                    // Scroll: move top line to scrollback
                    if !screenBuffer.isEmpty {
                        scrollbackBuffer.append(screenBuffer.removeFirst())
                    }
                    screenBuffer.append(Array(repeating: " ", count: cols))
                    cursorY = visibleRows - 1
                    if scrollbackBuffer.count > maxScrollback {
                        scrollbackBuffer.removeFirst(scrollbackBuffer.count - maxScrollback)
                    }
                }
                // Ensure screenBuffer has enough rows
                while cursorY >= screenBuffer.count {
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
                // ASCII printable character
                placeCharacter(char)
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
                case 0x37: // '7' -> DECSC (Save Cursor Position)
                    savedCursorX = cursorX
                    savedCursorY = cursorY
                    ansiState = .normal
                case 0x38: // '8' -> DECRC (Restore Cursor Position)
                    cursorX = savedCursorX
                    cursorY = savedCursorY
                    ansiState = .normal
                case 0x4D: // 'M' -> Reverse Index (scroll down / cursor up)
                    if cursorY > 0 {
                        cursorY -= 1
                    } else {
                        // Scroll down: insert blank line at top
                        screenBuffer.insert(Array(repeating: " ", count: cols), at: 0)
                        if screenBuffer.count > visibleRows {
                            screenBuffer.removeLast()
                        }
                    }
                    ansiState = .normal
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

    private func handleCSI(finalByte: UInt8, params: String) {
        let cols = visibleCols
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

        case 0x73: // 's' — Save Cursor Position
            savedCursorX = cursorX
            savedCursorY = cursorY

        case 0x75: // 'u' — Restore Cursor Position
            cursorX = savedCursorX
            cursorY = savedCursorY

        case 0x47: // 'G' — Cursor Horizontal Absolute
            let col = max(1, p1) - 1
            cursorX = min(cols - 1, col)

        case 0x64: // 'd' — Cursor Vertical Absolute
            let row = max(1, p1) - 1
            cursorY = min(visibleRows - 1, row)

        case 0x4C: // 'L' — Insert Lines
            let n = max(1, p1)
            for _ in 0..<n {
                if cursorY < screenBuffer.count {
                    screenBuffer.insert(Array(repeating: " ", count: cols), at: cursorY)
                    if screenBuffer.count > visibleRows {
                        screenBuffer.removeLast()
                    }
                }
            }

        case 0x4D: // 'M' (CSI) — Delete Lines
            let n = max(1, p1)
            for _ in 0..<n {
                if cursorY < screenBuffer.count {
                    screenBuffer.remove(at: cursorY)
                    screenBuffer.append(Array(repeating: " ", count: cols))
                }
            }

        case 0x50: // 'P' — Delete Characters
            let n = max(1, p1)
            if cursorY < screenBuffer.count {
                for _ in 0..<n {
                    if cursorX < screenBuffer[cursorY].count {
                        screenBuffer[cursorY].remove(at: cursorX)
                        screenBuffer[cursorY].append(" ")
                    }
                }
            }

        case 0x40: // '@' — Insert Characters
            let n = max(1, p1)
            if cursorY < screenBuffer.count {
                for _ in 0..<n {
                    screenBuffer[cursorY].insert(" ", at: min(cursorX, screenBuffer[cursorY].count))
                    if screenBuffer[cursorY].count > cols {
                        screenBuffer[cursorY].removeLast()
                    }
                }
            }

        case 0x72: // 'r' — Set Scrolling Region (DECSTBM)
            break // Consume but don't implement scroll regions yet

        default:
            break // Ignore unknown CSI sequences
        }
    }


    private func updateDocumentSize() {
        let totalLines = scrollbackBuffer.count + screenBuffer.count
        let visibleHeight = enclosingScrollView?.contentView.bounds.height ?? bounds.height
        let requiredHeight = max(visibleHeight, CGFloat(totalLines) * cellHeight)
        let width = enclosingScrollView?.contentView.bounds.width ?? bounds.width
        setFrameSize(NSSize(width: width, height: requiredHeight))

        // Auto-scroll to bottom (isFlipped=true: origin at top, scroll down)
        if let scrollView = enclosingScrollView {
            let clipBounds = scrollView.contentView.bounds
            let docHeight = frame.height
            let maxScrollY = max(0, docHeight - clipBounds.height)
            let isNearBottom = clipBounds.origin.y >= maxScrollY - cellHeight * 3
            if isNearBottom || !isSelecting {
                scrollView.contentView.scroll(to: NSPoint(x: 0, y: maxScrollY))
                scrollView.reflectScrolledClipView(scrollView.contentView)
            }
        }
    }

    // MARK: - URL Detection

    private func detectURLsInBuffer() {
        detectedURLs.removeAll()
        guard let detector = urlDetector else { return }

        // Only scan visible + near-visible lines, not entire scrollback
        let clipBounds = enclosingScrollView?.contentView.bounds ?? bounds
        let scrollbackCount = scrollbackBuffer.count
        let totalLines = scrollbackCount + screenBuffer.count
        let firstRow = max(0, Int(clipBounds.origin.y / cellHeight) - 5)
        let lastRow = min(totalLines, firstRow + Int(clipBounds.height / cellHeight) + 10)

        for row in firstRow..<lastRow {
            let line: [Character]
            if row < scrollbackCount {
                line = scrollbackBuffer[row]
            } else {
                let screenRow = row - scrollbackCount
                guard screenRow < screenBuffer.count else { continue }
                line = screenBuffer[screenRow]
            }
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

    /// Access a line by absolute row index without copying the entire buffer.
    private func lineAtRow(_ row: Int) -> [Character]? {
        let scrollbackCount = scrollbackBuffer.count
        if row < scrollbackCount {
            return scrollbackBuffer[row]
        }
        let screenRow = row - scrollbackCount
        guard screenRow < screenBuffer.count else { return nil }
        return screenBuffer[screenRow]
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }

        // Ensure cached attrs are initialized
        if cachedMonoFont == nil { rebuildCachedAttrs() }

        // Background
        context.setFillColor(theme.background.cgColor)
        context.fill(bounds)

        let scrollbackCount = scrollbackBuffer.count
        let totalLines = scrollbackCount + screenBuffer.count

        // Calculate visible range from scroll position
        let clipBounds = enclosingScrollView?.contentView.bounds ?? bounds
        // isFlipped=true: origin.y is the top of the visible area
        let firstVisibleRow = max(0, Int(clipBounds.origin.y / cellHeight) - 1)
        let lastVisibleRow = min(totalLines, firstVisibleRow + Int(clipBounds.height / cellHeight) + 2)

        // Render visible lines (isFlipped: row 0 at y=0, row 1 at y=cellHeight, etc.)
        for row in firstVisibleRow..<lastVisibleRow {
            guard let line = lineAtRow(row) else { break }
            let y = CGFloat(row) * cellHeight

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

            // Render text character by character
            for (col, char) in line.enumerated() {
                // Skip spaces and zero-width space placeholders (wide char 2nd cell)
                guard char != " " && char != "\u{200B}" else { continue }

                // Choose font: use fallback for non-ASCII (CJK, emoji, etc.)
                let isASCII = char.asciiValue != nil
                let attrs: [NSAttributedString.Key: Any]
                if !rowURLs.isEmpty && rowURLs.contains(where: { col >= $0.startCol && col < $0.endCol }) {
                    attrs = cachedURLAttrs
                } else if isASCII {
                    attrs = cachedNormalAttrs
                } else {
                    attrs = cachedFallbackAttrs
                }

                let str = NSAttributedString(string: String(char), attributes: attrs)
                str.draw(at: NSPoint(x: CGFloat(col) * cellWidth + 2, y: y))
            }
        }

        // Render cursor (only in screen area, not scrollback)
        if cursorVisible {
            let cursorAbsRow = scrollbackCount + cursorY
            let cursorRect = NSRect(
                x: CGFloat(cursorX) * cellWidth + 2,
                y: CGFloat(cursorAbsRow) * cellHeight,
                width: cellWidth,
                height: cellHeight
            )
            context.setFillColor(theme.cursor.cgColor)
            context.fill(cursorRect)
        }
    }

    // MARK: - Text Selection

    private func cellPosition(for point: NSPoint) -> (row: Int, col: Int) {
        // isFlipped=true: point.y=0 is at the top
        let row = Int(point.y / cellHeight)
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
                detectSSHCommand()
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

    // MARK: - SSH Command Detection

    /// Read the current screen line when Enter is pressed and detect SSH commands.
    private func detectSSHCommand() {
        guard cursorY >= 0, cursorY < screenBuffer.count else { return }
        let line = String(screenBuffer[cursorY]).trimmingCharacters(in: .whitespaces)
        // Strip shell prompt: take everything after the last $ or # or %
        let commandPart: String
        if let promptEnd = line.lastIndex(where: { $0 == "$" || $0 == "#" || $0 == "%" }) {
            commandPart = String(line[line.index(after: promptEnd)...]).trimmingCharacters(in: .whitespaces)
        } else {
            commandPart = line
        }
        guard let parsed = parseSSHCommand(commandPart) else { return }
        sshExitDetected = false  // Reset for new SSH session
        NotificationCenter.default.post(
            name: .terminalSSHDetected,
            object: ["host": parsed.host, "username": parsed.username, "port": String(parsed.port)]
        )
    }

    /// Parse an SSH command line like `ssh [-p port] [user@]host` into components.
    private func parseSSHCommand(_ cmd: String) -> (host: String, username: String, port: UInt16)? {
        let tokens = cmd.split(separator: " ").map(String.init)
        guard tokens.first == "ssh" else { return nil }
        var username = "root"
        var port: UInt16 = 22
        var host: String?
        var i = 1
        while i < tokens.count {
            let t = tokens[i]
            if t == "-p", i + 1 < tokens.count {
                port = UInt16(tokens[i + 1]) ?? 22
                i += 2
            } else if t.hasPrefix("-") {
                // Skip other flags (e.g. -i, -o); if they take an argument, skip next too
                if ["-i", "-o", "-l", "-L", "-R", "-D", "-F", "-J", "-w", "-W"].contains(t) {
                    i += 2
                } else {
                    i += 1
                }
            } else {
                // user@host or just host
                if t.contains("@") {
                    let parts = t.split(separator: "@", maxSplits: 1)
                    username = String(parts[0])
                    host = String(parts[1])
                } else {
                    host = t
                }
                i += 1
            }
        }
        guard let h = host, !h.isEmpty else { return nil }
        return (h, username, port)
    }

    // MARK: - Scroll

    override func scrollWheel(with event: NSEvent) {
        super.scrollWheel(with: event)
    }

    // MARK: - Resize

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        if let handle = terminalHandle {
            let newCols = max(1, Int(newSize.width / cellWidth))
            let newRows = max(1, Int((enclosingScrollView?.contentView.bounds.height ?? newSize.height) / cellHeight))
            if newCols != ptyCols || newRows != ptyRows {
                ptyCols = newCols
                ptyRows = newRows
                pier_terminal_resize(handle, UInt16(newCols), UInt16(newRows))

                resizeScreenBuffer()
            }
        }
    }

    /// Called by TerminalScrollView when the viewport size changes
    /// (e.g., HSplitView divider dragged, window resized).
    func handleViewportSizeChanged(_ visibleSize: NSSize) {
        guard let handle = terminalHandle else { return }

        let newCols = max(1, Int(visibleSize.width / cellWidth))
        let newRows = max(1, Int(visibleSize.height / cellHeight))

        guard newCols != ptyCols || newRows != ptyRows else { return }

        ptyCols = newCols
        ptyRows = newRows
        pier_terminal_resize(handle, UInt16(newCols), UInt16(newRows))
        resizeScreenBuffer()

        // Update document frame to fill visible area
        let totalLines = scrollbackBuffer.count + screenBuffer.count
        let requiredHeight = max(visibleSize.height, CGFloat(totalLines) * cellHeight)
        setFrameSize(NSSize(width: visibleSize.width, height: requiredHeight))
        needsDisplay = true
    }

    /// Resize the screen buffer to match current ptyCols/ptyRows.
    private func resizeScreenBuffer() {
        // Resize screen buffer to match new dimensions
        while screenBuffer.count < ptyRows {
            screenBuffer.append(Array(repeating: Character(" "), count: ptyCols))
        }
        while screenBuffer.count > ptyRows {
            let overflow = screenBuffer.removeFirst()
            scrollbackBuffer.append(overflow)
        }
        for i in 0..<screenBuffer.count {
            if screenBuffer[i].count < ptyCols {
                screenBuffer[i].append(contentsOf: Array(repeating: Character(" "), count: ptyCols - screenBuffer[i].count))
            } else if screenBuffer[i].count > ptyCols {
                screenBuffer[i] = Array(screenBuffer[i].prefix(ptyCols))
            }
        }
        cursorX = min(cursorX, ptyCols - 1)
        cursorY = min(cursorY, ptyRows - 1)
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
