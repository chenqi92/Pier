import SwiftUI
import AppKit
import CPierCore

/// Terminal view using NSViewRepresentable with KVO-based resize detection.
/// A Coordinator observes the scroll view's frame changes via KVO — the most
/// fundamental AppKit mechanism, guaranteed to fire when SwiftUI resizes the view.
struct TerminalView: NSViewRepresentable {
    let session: TerminalSessionInfo?

    class Coordinator: NSObject {
        var frameObservation: NSKeyValueObservation?
        var lastSize: NSSize = .zero
    }

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSView(context: Context) -> TerminalScrollView {
        let scrollView = TerminalScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.borderType = .noBorder
        scrollView.drawsBackground = false

        let terminalView = TerminalNSView()
        scrollView.documentView = terminalView

        // KVO: observe scroll view frame changes — fires when SwiftUI resizes the view
        context.coordinator.frameObservation = scrollView.observe(\.frame, options: [.new, .old]) { [weak terminalView] sv, change in
            guard let tv = terminalView else { return }
            let newFrame = sv.frame
            let newSize = newFrame.size
            // Only trigger on actual size changes, not position changes
            guard abs(newSize.width - context.coordinator.lastSize.width) > 0.5 ||
                  abs(newSize.height - context.coordinator.lastSize.height) > 0.5 else { return }
            context.coordinator.lastSize = newSize
            
            if newSize.width > 1 && newSize.height > 1 {
                tv.handleViewportSizeChanged(newSize)
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
/// PTY resize is handled via KVO on scroll view frame in the Coordinator.
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


// MARK: - Per-Cell Attribute (ANSI SGR state)

/// Represents the visual attributes of a single terminal cell.
struct CellAttr: Equatable {
    var fg: UInt8 = 0      // 0=default, 1-8=standard(30-37), 9-16=bright(90-97), 17+=256-color
    var bg: UInt8 = 0      // same encoding
    var bold: Bool = false
    var italic: Bool = false
    var underline: Bool = false
    var inverse: Bool = false
    var dim: Bool = false
    static let `default` = CellAttr()
}

/// A single terminal cell: character + visual attributes.
/// By combining character and attributes into one struct, they can never go out of sync.
struct TerminalCell: Equatable {
    var character: Character = " "
    var attr: CellAttr = .default

    static let blank = TerminalCell()
}

/// AppKit NSView for high-performance terminal rendering.
class TerminalNSView: NSView {
    var session: TerminalSessionInfo?

    // Use top-left origin (standard for terminal rendering)
    override var isFlipped: Bool { true }

    // Terminal display configuration
    private var fontSize: CGFloat = AppThemeManager.shared.fontSize
    private var fontFamily = AppThemeManager.shared.fontFamily
    private var cellWidth: CGFloat = 8
    private var cellHeight: CGFloat = 16
    private var cursorVisible = true

    // Theme (replaces hardcoded colors)
    var theme: TerminalTheme = AppThemeManager.shared.currentTerminalTheme {
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
    /// Whether a password prompt was seen (user may be typing password manually)
    private var sshPasswordPromptSeen = false
    /// Whether SSH auth success has been notified for this session
    private var sshAuthSuccessNotified = false

    // MARK: - PTY Cache (persists across tab switches)

    /// Cached PTY state for a terminal session.
    struct PTYCacheEntry {
        let handle: OpaquePointer
        var screen: [[TerminalCell]]
        var scrollback: [[TerminalCell]]
        var screenLineWrapped: [Bool]
        var scrollbackLineWrapped: [Bool]
        var cursorX: Int
        var cursorY: Int
        var ptyCols: Int
        var ptyRows: Int
        var savedCursorX: Int
        var savedCursorY: Int
        var currentAttr: CellAttr
    }

    /// Static cache: session ID → PTY state. Persists across view re-creation.
    private static var ptyCache: [UUID: PTYCacheEntry] = [:]

    /// Destroy a cached PTY when its tab is closed (off main thread to avoid blocking).
    static func destroyCachedPTY(sessionId: UUID) {
        if let entry = ptyCache.removeValue(forKey: sessionId) {
            let handle = entry.handle
            DispatchQueue.global(qos: .utility).async {
                pier_terminal_destroy(handle)
            }
        }
    }

    // PTY dimensions (authoritative — never recalculate from view size during processing)
    private var ptyCols: Int = 80
    private var ptyRows: Int = 24

    // Terminal → SFTP directory sync (trailing-edge: check after output stops)
    private var lastDetectedCwd: String?
    private var pendingCwdCheck = false
    private var sshExitDetected = false  // Prevent repeated SSH exit notifications

    // Screen buffer (visible area) — unified character + attribute per cell
    private var screen: [[TerminalCell]] = []
    /// Tracks whether each screen row is a continuation (soft-wrapped from previous row).
    /// `true` = soft wrap (line overflow), `false` = hard wrap (real newline or first line).
    private var screenLineWrapped: [Bool] = []
    private var scrollbackLineWrapped: [Bool] = []
    private var cursorX: Int = 0
    private var cursorY: Int = 0

    // Current SGR state (applied to each new character)
    private var currentAttr = CellAttr.default

    // Saved cursor position (ESC 7 / ESC 8, CSI s / CSI u)
    private var savedCursorX: Int = 0
    private var savedCursorY: Int = 0

    // Scrollback buffer (max 10,000 lines) — unified character + attribute per cell
    private let maxScrollback = 10_000
    private var scrollback: [[TerminalCell]] = []

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
    private var cachedPowerlineFont: NSFont?
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
    private var blurEffectView: NSVisualEffectView?

    private func setupView() {
        wantsLayer = true
        layer?.backgroundColor = theme.background.cgColor

        // Set up background blur effect view
        updateBlurEffect()

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
            guard let self = self else { return }
            if AppThemeManager.shared.cursorBlink {
                self.cursorVisible.toggle()
            } else {
                self.cursorVisible = true
            }
            self.needsDisplay = true
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

        // Listen for font/theme setting changes
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleSettingsChanged(_:)),
            name: UserDefaults.didChangeNotification,
            object: nil
        )
    }

    @objc private func handleSettingsChanged(_ notification: Notification) {
        let mgr = AppThemeManager.shared
        let newFamily = mgr.fontFamily
        let newSize = mgr.fontSize
        let newTheme = mgr.currentTerminalTheme
        var changed = false

        if fontFamily != newFamily || fontSize != newSize {
            fontFamily = newFamily
            fontSize = newSize
            // Recalculate cell dimensions
            let font = NSFont(name: fontFamily, size: fontSize)
                ?? NSFont.monospacedSystemFont(ofSize: fontSize, weight: .regular)
            let attrStr = NSAttributedString(string: "M", attributes: [.font: font])
            let size = attrStr.size()
            cellWidth = ceil(size.width)
            cellHeight = ceil(size.height * 1.2)
            rebuildCachedAttrs()
            changed = true
        }

        if theme.id != newTheme.id {
            theme = newTheme
            layer?.backgroundColor = theme.background.cgColor
            changed = true
        }

        // Always refresh for opacity/blur/cursor changes
        updateBlurEffect()
        changed = true

        if changed {
            needsDisplay = true
        }
    }

    /// Manage the NSVisualEffectView behind the terminal for blur effects.
    private func updateBlurEffect() {
        let mgr = AppThemeManager.shared
        if mgr.terminalBlur && mgr.terminalOpacity < 1.0 {
            if blurEffectView == nil {
                let effectView = NSVisualEffectView()
                effectView.material = .hudWindow
                effectView.blendingMode = .behindWindow
                effectView.state = .active
                effectView.autoresizingMask = [.width, .height]
                effectView.frame = bounds
                addSubview(effectView, positioned: .below, relativeTo: nil)
                blurEffectView = effectView
            }
            blurEffectView?.frame = bounds
        } else {
            blurEffectView?.removeFromSuperview()
            blurEffectView = nil
        }
    }

    @objc private func handleTerminalInput(_ notification: Notification) {
        guard let handle = terminalHandle else { return }
        var text: String?
        var deliveryFlag: AnyObject?
        if let info = notification.object as? [String: Any] {
            // From TerminalViewModel.sendInput: ["sessionId": UUID, "text": String]
            if let sessionId = info["sessionId"] as? UUID {
                guard sessionId == currentSessionId else { return }
            }
            text = info["text"] as? String
            deliveryFlag = info["deliveryFlag"] as AnyObject?
        }
        guard let inputText = text, !inputText.isEmpty else { return }
        let bytes = Array(inputText.utf8)
        pier_terminal_write(handle, bytes, UInt(bytes.count))
        // Set delivery flag (supports both class wrapper and legacy pointer)
        deliveryFlag?.setValue(true, forKey: "value")
    }

    @objc private func handleTabClosed(_ notification: Notification) {
        guard let sessionId = notification.object as? UUID else { return }
        // If this is the currently displayed session, stop it
        if currentSessionId == sessionId {
            stopTimers()
            if let handle = terminalHandle {
                terminalHandle = nil
                // Destroy PTY off main thread to avoid blocking UI
                DispatchQueue.global(qos: .utility).async {
                    pier_terminal_destroy(handle)
                }
            }
            currentSessionId = nil
            // Clear buffers to prevent stale array accesses during SwiftUI re-render
            screen = []
            scrollback = []
            cursorX = 0
            cursorY = 0
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

        // Try to find a Powerline/Nerd Font for special symbols.
        // Register the bundled Nerd Font first (once) — must happen before font search.
        // Cannot rely on AppDelegate because SwiftUI creates views before applicationDidFinishLaunching.
        struct FontRegistration {
            static var done = false
        }
        if !FontRegistration.done {
            FontRegistration.done = true
            if let fontURL = Bundle.module.url(forResource: "SymbolsNerdFontMono-Regular", withExtension: "ttf")
                ?? Bundle.main.url(forResource: "SymbolsNerdFontMono-Regular", withExtension: "ttf") {
                CTFontManagerRegisterFontsForURL(fontURL as CFURL, .process, nil)
            }
        }

        let powerlineFontNames = [
            fontFamily,  // User's font may already have Powerline glyphs
            "Symbols Nerd Font Mono",  // Bundled Nerd Font
            "MesloLGS NF",
            "MesloLGS Nerd Font Mono",
            "Hack Nerd Font Mono",
            "JetBrainsMono Nerd Font Mono",
            "FiraCode Nerd Font Mono",
        ]
        cachedPowerlineFont = nil
        for name in powerlineFontNames {
            if let font = NSFont(name: name, size: fontSize) {
                // Verify it has the Powerline branch glyph (U+E0A0)
                let ctFont = font as CTFont
                var glyph: CGGlyph = 0
                var char: UniChar = 0xE0A0
                if CTFontGetGlyphsForCharacters(ctFont, &char, &glyph, 1), glyph != 0 {
                    cachedPowerlineFont = font
                    break
                }
            }
        }

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
        sshPasswordPromptSeen = false
        sshAuthSuccessNotified = false

        // ── Try to restore from cache ──
        if let cached = TerminalNSView.ptyCache.removeValue(forKey: session.id) {
            terminalHandle = cached.handle
            screen = cached.screen
            scrollback = cached.scrollback
            screenLineWrapped = cached.screenLineWrapped
            scrollbackLineWrapped = cached.scrollbackLineWrapped
            cursorX = cached.cursorX
            cursorY = cached.cursorY
            ptyCols = cached.ptyCols
            ptyRows = cached.ptyRows
            savedCursorX = cached.savedCursorX
            savedCursorY = cached.savedCursorY
            currentAttr = cached.currentAttr
            startReadLoop()
            needsDisplay = true
        } else {
            // New session — need to create PTY
            terminalHandle = nil
            screen = []
            scrollback = []
            cursorX = 0
            cursorY = 0
            currentAttr = .default
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
            screen: screen,
            scrollback: scrollback,
            screenLineWrapped: screenLineWrapped,
            scrollbackLineWrapped: scrollbackLineWrapped,
            cursorX: cursorX,
            cursorY: cursorY,
            ptyCols: ptyCols,
            ptyRows: ptyRows,
            savedCursorX: savedCursorX,
            savedCursorY: savedCursorY,
            currentAttr: currentAttr
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
        screen = []
        scrollback = []
        currentAttr = .default
        cursorX = 0
        cursorY = 0
    }

    func startTerminal(shell: String = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh") {
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
            screen = Array(repeating: Array(repeating: .blank, count: cols), count: rows)
            screenLineWrapped = Array(repeating: false, count: rows)
            scrollbackLineWrapped = []
            currentAttr = .default
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
            screen = Array(repeating: Array(repeating: .blank, count: cols), count: rows)
            screenLineWrapped = Array(repeating: false, count: rows)
            scrollbackLineWrapped = []
            currentAttr = .default
            startReadLoop()
        }
    }


    private func startReadLoop() {
        readTimer = Timer.scheduledTimer(withTimeInterval: 0.016, repeats: true) { [weak self] _ in
            self?.readTerminalOutput()
        }
    }

    private func readTerminalOutput() {
        // Bail if session was closed (timer callback may fire after handleTabClosed)
        guard let handle = terminalHandle, currentSessionId != nil else { return }

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
                sshPasswordPromptSeen = true
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

        // 3. SSH auth success detection — after password prompt, if we see
        //    shell prompt or welcome banner, auth succeeded
        if sshPasswordPromptSeen && !sshAuthSuccessNotified && !sshAuthFailureReported {
            // Look for typical SSH login success indicators
            if lower.contains("last login:") ||
               lower.contains("welcome to") ||
               lower.hasSuffix("$ ") ||
               lower.hasSuffix("# ") ||
               lower.hasSuffix("% ") {
                sshAuthSuccessNotified = true
                if let sessionId = currentSessionId {
                    NotificationCenter.default.post(
                        name: .terminalSSHAuthSuccess,
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
        let linesToScan = min(5, screen.count)
        let startRow = max(0, cursorY - linesToScan)
        let endRow = cursorY

        for row in startRow..<endRow {
            guard row >= 0 && row < screen.count else { continue }
            let line = String(screen[row].map { $0.character }).trimmingCharacters(in: .whitespaces)

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
        guard cursorY >= 0 && cursorY < screen.count else { return }
        let line = String(screen[cursorY].map { $0.character }).trimmingCharacters(in: .whitespaces)
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
                if !screen.isEmpty {
                    scrollback.append(screen.removeFirst())
                    scrollbackLineWrapped.append(screenLineWrapped.isEmpty ? false : screenLineWrapped.removeFirst())
                }
                screen.append(Array(repeating: .blank, count: cols))
                screenLineWrapped.append(true)  // soft wrap: continuation of previous line
                cursorY = visibleRows - 1
            }
            while cursorY >= screen.count {
                screen.append(Array(repeating: .blank, count: cols))
                screenLineWrapped.append(true)  // soft wrap
            }
            // Mark this new row as soft-wrapped continuation
            if cursorY < screenLineWrapped.count {
                screenLineWrapped[cursorY] = true
            }
        }

        // Ensure buffer has the row
        while cursorY >= screen.count {
            screen.append(Array(repeating: .blank, count: cols))
        }

        if cursorY < screen.count && cursorX < screen[cursorY].count {
            screen[cursorY][cursorX] = TerminalCell(character: char, attr: currentAttr)
            cursorX += 1
            // For wide characters, place a zero-width placeholder in the next cell
            if charWidth == 2 && cursorX < screen[cursorY].count {
                screen[cursorY][cursorX] = TerminalCell(character: "\u{200B}", attr: currentAttr)
                cursorX += 1
            }
        }
    }

    private func processTerminalOutput(_ bytes: [UInt8]) {
        // Guard: bail if screen was cleared (session closed)
        guard !screen.isEmpty else { return }
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
                    if !screen.isEmpty {
                        scrollback.append(screen.removeFirst())
                        scrollbackLineWrapped.append(screenLineWrapped.isEmpty ? false : screenLineWrapped.removeFirst())
                    }
                    screen.append(Array(repeating: .blank, count: cols))
                    screenLineWrapped.append(false)  // hard wrap (LF)
                    cursorY = visibleRows - 1
                    if scrollback.count > maxScrollback {
                        scrollback.removeFirst(scrollback.count - maxScrollback)
                        if !scrollbackLineWrapped.isEmpty { scrollbackLineWrapped.removeFirst() }
                    }
                }
                // Ensure screen has enough rows
                while cursorY >= screen.count {
                    screen.append(Array(repeating: .blank, count: cols))
                    screenLineWrapped.append(false)  // hard wrap (LF)
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
                        screen.insert(Array(repeating: .blank, count: cols), at: 0)
                        if screen.count > visibleRows {
                            screen.removeLast()
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

    /// Ensure screen buffer has at least `row + 1` rows,
    /// and that the row at `row` has at least `visibleCols` columns.
    private func ensureBufferCovers(row: Int) {
        guard row >= 0 else { return }
        let cols = max(1, visibleCols)
        while screen.count <= row {
            screen.append(Array(repeating: .blank, count: cols))
            screenLineWrapped.append(false)
        }
        if screen[row].count < cols {
            screen[row].append(contentsOf: Array(repeating: TerminalCell.blank, count: cols - screen[row].count))
        }
    }

    private func handleCSI(finalByte: UInt8, params: String) {
        // Guard: bail if screen was cleared (session closed)
        guard !screen.isEmpty else { return }
        let cols = visibleCols
        guard cols > 0 else { return }

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
                ensureBufferCovers(row: cursorY)
                for x in cursorX..<min(cols, screen[cursorY].count) {
                    screen[cursorY][x] = .blank
                }
                for y in (cursorY + 1)..<screen.count {
                    screen[y] = Array(repeating: .blank, count: cols)
                }
            case 1: // Clear from start to cursor
                for y in 0..<min(cursorY, screen.count) {
                    screen[y] = Array(repeating: .blank, count: cols)
                }
                ensureBufferCovers(row: cursorY)
                let endX = min(cursorX, screen[cursorY].count - 1)
                if endX >= 0 {
                    for x in 0...endX {
                        screen[cursorY][x] = .blank
                    }
                }
            case 2, 3: // Clear entire screen
                for y in 0..<screen.count {
                    screen[y] = Array(repeating: .blank, count: cols)
                }
            default:
                break
            }

        case 0x4B: // 'K' — Erase in Line
            ensureBufferCovers(row: cursorY)
            switch p1 {
            case 0: // Clear from cursor to end of line
                for x in cursorX..<min(cols, screen[cursorY].count) {
                    screen[cursorY][x] = .blank
                }
            case 1: // Clear from start to cursor
                let endX = min(cursorX, screen[cursorY].count - 1)
                if endX >= 0 {
                    for x in 0...endX {
                        screen[cursorY][x] = .blank
                    }
                }
            case 2: // Clear entire line
                screen[cursorY] = Array(repeating: .blank, count: cols)
            default:
                break
            }

        case 0x6D: // 'm' — SGR (Select Graphic Rendition)
            handleSGR(params: params)

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
                ensureBufferCovers(row: cursorY)
                screen.insert(Array(repeating: .blank, count: cols), at: cursorY)
                if screen.count > visibleRows {
                    screen.removeLast()
                }
            }

        case 0x4D: // 'M' (CSI) — Delete Lines
            let n = max(1, p1)
            for _ in 0..<n {
                if cursorY < screen.count {
                    screen.remove(at: cursorY)
                    screen.append(Array(repeating: .blank, count: cols))
                }
            }

        case 0x50: // 'P' — Delete Characters
            let n = max(1, p1)
            ensureBufferCovers(row: cursorY)
            for _ in 0..<n {
                if cursorX < screen[cursorY].count {
                    screen[cursorY].remove(at: cursorX)
                    screen[cursorY].append(.blank)
                }
            }

        case 0x40: // '@' — Insert Characters
            let n = max(1, p1)
            ensureBufferCovers(row: cursorY)
            for _ in 0..<n {
                screen[cursorY].insert(.blank, at: min(cursorX, screen[cursorY].count))
                if screen[cursorY].count > cols {
                    screen[cursorY].removeLast()
                }
            }

        case 0x72: // 'r' — Set Scrolling Region (DECSTBM)
            break // Consume but don't implement scroll regions yet

        default:
            break // Ignore unknown CSI sequences
        }
    }

    // MARK: - SGR (Select Graphic Rendition) Parser

    /// Parse and apply SGR parameters to the current cell attribute state.
    private func handleSGR(params: String) {
        // Empty params means SGR 0 (reset)
        let codes: [Int]
        if params.isEmpty {
            codes = [0]
        } else {
            codes = params.split(separator: ";").compactMap { Int($0) }
        }

        var i = 0
        while i < codes.count {
            let code = codes[i]
            switch code {
            case 0:    // Reset
                currentAttr = .default
            case 1:    // Bold
                currentAttr.bold = true
            case 2:    // Dim
                currentAttr.dim = true
            case 3:    // Italic
                currentAttr.italic = true
            case 4:    // Underline
                currentAttr.underline = true
            case 7:    // Inverse
                currentAttr.inverse = true
            case 22:   // Normal intensity (not bold, not dim)
                currentAttr.bold = false
                currentAttr.dim = false
            case 23:   // Not italic
                currentAttr.italic = false
            case 24:   // Not underlined
                currentAttr.underline = false
            case 27:   // Not inverse
                currentAttr.inverse = false
            case 30...37:  // Standard foreground colors
                currentAttr.fg = UInt8(code - 30 + 1) // 1-8
            case 38:   // Extended foreground color
                if i + 1 < codes.count && codes[i + 1] == 5 && i + 2 < codes.count {
                    // 256-color: ESC[38;5;{n}m
                    currentAttr.fg = UInt8(min(255, codes[i + 2]) + 1) // offset by 1 (0=default)
                    i += 2
                } else if i + 1 < codes.count && codes[i + 1] == 2 && i + 4 < codes.count {
                    // True color: ESC[38;2;r;g;b — map to nearest 256-color
                    let r = codes[i + 2], g = codes[i + 3], b = codes[i + 4]
                    currentAttr.fg = UInt8(nearest256Color(r: r, g: g, b: b) + 1)
                    i += 4
                }
            case 39:   // Default foreground
                currentAttr.fg = 0
            case 40...47:  // Standard background colors
                currentAttr.bg = UInt8(code - 40 + 1) // 1-8
            case 48:   // Extended background color
                if i + 1 < codes.count && codes[i + 1] == 5 && i + 2 < codes.count {
                    currentAttr.bg = UInt8(min(255, codes[i + 2]) + 1)
                    i += 2
                } else if i + 1 < codes.count && codes[i + 1] == 2 && i + 4 < codes.count {
                    let r = codes[i + 2], g = codes[i + 3], b = codes[i + 4]
                    currentAttr.bg = UInt8(nearest256Color(r: r, g: g, b: b) + 1)
                    i += 4
                }
            case 49:   // Default background
                currentAttr.bg = 0
            case 90...97:  // Bright foreground colors
                currentAttr.fg = UInt8(code - 90 + 9) // 9-16
            case 100...107: // Bright background colors
                currentAttr.bg = UInt8(code - 100 + 9)
            default:
                break
            }
            i += 1
        }
    }

    /// Map true-color (r, g, b) to nearest 256-color index.
    private func nearest256Color(r: Int, g: Int, b: Int) -> Int {
        // Use grayscale ramp if close to gray
        if r == g && g == b {
            if r < 8 { return 16 }  // black
            if r > 248 { return 231 }  // white
            return 232 + Int(round(Double(r - 8) / 247.0 * 23.0))
        }
        // Map to 6x6x6 color cube (indices 16-231)
        let ri = Int(round(Double(r) / 255.0 * 5.0))
        let gi = Int(round(Double(g) / 255.0 * 5.0))
        let bi = Int(round(Double(b) / 255.0 * 5.0))
        return 16 + 36 * ri + 6 * gi + bi
    }

    // MARK: - ANSI Color Resolution

    /// Standard 8 ANSI colors (indices 0-7).
    private static let ansi8Colors: [NSColor] = [
        NSColor(srgbRed: 0.0,  green: 0.0,  blue: 0.0,  alpha: 1), // 0 Black
        NSColor(srgbRed: 0.8,  green: 0.0,  blue: 0.0,  alpha: 1), // 1 Red
        NSColor(srgbRed: 0.0,  green: 0.8,  blue: 0.0,  alpha: 1), // 2 Green
        NSColor(srgbRed: 0.8,  green: 0.8,  blue: 0.0,  alpha: 1), // 3 Yellow
        NSColor(srgbRed: 0.2,  green: 0.4,  blue: 0.9,  alpha: 1), // 4 Blue
        NSColor(srgbRed: 0.8,  green: 0.0,  blue: 0.8,  alpha: 1), // 5 Magenta
        NSColor(srgbRed: 0.0,  green: 0.8,  blue: 0.8,  alpha: 1), // 6 Cyan
        NSColor(srgbRed: 0.75, green: 0.75, blue: 0.75, alpha: 1), // 7 White
    ]

    /// Bright 8 ANSI colors (indices 8-15).
    private static let ansiBrightColors: [NSColor] = [
        NSColor(srgbRed: 0.5,  green: 0.5,  blue: 0.5,  alpha: 1), // 8  Bright Black (Gray)
        NSColor(srgbRed: 1.0,  green: 0.33, blue: 0.33, alpha: 1), // 9  Bright Red
        NSColor(srgbRed: 0.33, green: 1.0,  blue: 0.33, alpha: 1), // 10 Bright Green
        NSColor(srgbRed: 1.0,  green: 1.0,  blue: 0.33, alpha: 1), // 11 Bright Yellow
        NSColor(srgbRed: 0.4,  green: 0.6,  blue: 1.0,  alpha: 1), // 12 Bright Blue
        NSColor(srgbRed: 1.0,  green: 0.33, blue: 1.0,  alpha: 1), // 13 Bright Magenta
        NSColor(srgbRed: 0.33, green: 1.0,  blue: 1.0,  alpha: 1), // 14 Bright Cyan
        NSColor(srgbRed: 1.0,  green: 1.0,  blue: 1.0,  alpha: 1), // 15 Bright White
    ]

    /// Resolve a CellAttr color code to NSColor.
    /// colorCode: 0=default, 1-8=standard, 9-16=bright, 17-256=256-color palette (offset by 1)
    private func resolveAnsiColor(_ colorCode: UInt8, isForeground: Bool) -> NSColor? {
        switch colorCode {
        case 0:
            return nil // Use theme default
        case 1...8:
            return Self.ansi8Colors[Int(colorCode) - 1]
        case 9...16:
            return Self.ansiBrightColors[Int(colorCode) - 9]
        default:
            // 256-color palette (colorCode - 1 = actual 256-color index)
            let idx = Int(colorCode) - 1
            if idx < 16 {
                // Standard + bright (already handled but just in case)
                return idx < 8 ? Self.ansi8Colors[idx] : Self.ansiBrightColors[idx - 8]
            } else if idx < 232 {
                // 6x6x6 color cube (indices 16-231)
                let cubeIdx = idx - 16
                let r = cubeIdx / 36
                let g = (cubeIdx % 36) / 6
                let b = cubeIdx % 6
                let rr = r == 0 ? 0.0 : (Double(r) * 40.0 + 55.0) / 255.0
                let gg = g == 0 ? 0.0 : (Double(g) * 40.0 + 55.0) / 255.0
                let bb = b == 0 ? 0.0 : (Double(b) * 40.0 + 55.0) / 255.0
                return NSColor(srgbRed: rr, green: gg, blue: bb, alpha: 1)
            } else if idx < 256 {
                // Grayscale ramp (indices 232-255) → 8 to 238
                let level = Double((idx - 232) * 10 + 8) / 255.0
                return NSColor(srgbRed: level, green: level, blue: level, alpha: 1)
            }
            return nil
        }
    }

    private func updateDocumentSize() {
        let totalLines = scrollback.count + screen.count
        let visibleHeight = enclosingScrollView?.contentView.bounds.height ?? bounds.height
        let requiredHeight = max(visibleHeight, CGFloat(totalLines) * cellHeight)

        // Use ptyCols * cellWidth as authoritative width — do NOT read from
        // contentView.bounds.width which may be stale when SwiftUI resizes
        // the hosting view via HSplitView.
        let width = CGFloat(ptyCols) * cellWidth

        // Use super.setFrameSize to avoid triggering the override which would
        // re-calculate ptyCols from the frame width (undoing notification-based resize).
        super.setFrameSize(NSSize(width: width, height: requiredHeight))

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
        let scrollbackCount = scrollback.count
        let totalLines = scrollbackCount + screen.count
        let firstRow = max(0, Int(clipBounds.origin.y / cellHeight) - 5)
        let lastRow = min(totalLines, firstRow + Int(clipBounds.height / cellHeight) + 10)

        for row in firstRow..<lastRow {
            let cellLine: [TerminalCell]
            if row < scrollbackCount {
                guard row >= 0 && row < scrollback.count else { continue }
                cellLine = scrollback[row]
            } else {
                let screenRow = row - scrollbackCount
                guard screenRow >= 0 && screenRow < screen.count else { continue }
                cellLine = screen[screenRow]
            }
            let text = String(cellLine.map { $0.character })
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

    /// Access a line by absolute row index (scrollback + screen).
    private func cellLineAtRow(_ row: Int) -> [TerminalCell]? {
        let scrollbackCount = scrollback.count
        if row < scrollbackCount {
            guard row >= 0 else { return nil }
            return scrollback[row]
        }
        let screenRow = row - scrollbackCount
        guard screenRow >= 0 && screenRow < screen.count else { return nil }
        return screen[screenRow]
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }

        // Ensure cached attrs are initialized
        if cachedMonoFont == nil { rebuildCachedAttrs() }

        // Background with opacity
        let opacity = CGFloat(AppThemeManager.shared.terminalOpacity)
        context.setFillColor(theme.background.withAlphaComponent(opacity).cgColor)
        context.fill(bounds)

        let scrollbackCount = scrollback.count
        let totalLines = scrollbackCount + screen.count

        // Calculate visible range from scroll position
        let clipBounds = enclosingScrollView?.contentView.bounds ?? bounds
        // isFlipped=true: origin.y is the top of the visible area
        let firstVisibleRow = max(0, Int(clipBounds.origin.y / cellHeight) - 1)
        let lastVisibleRow = min(totalLines, firstVisibleRow + Int(clipBounds.height / cellHeight) + 2)

        // Render visible lines (isFlipped: row 0 at y=0, row 1 at y=cellHeight, etc.)
        for row in firstVisibleRow..<lastVisibleRow {
            guard let line = cellLineAtRow(row) else { break }
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

            // Render text character by character with per-cell ANSI attributes
            for (col, cell) in line.enumerated() {
                let cellAttr = cell.attr
                let char = cell.character

                // Resolve foreground and background colors
                var fgColor: NSColor
                var bgColor: NSColor?

                if cellAttr.inverse {
                    // Inverse: swap fg/bg
                    fgColor = resolveAnsiColor(cellAttr.bg, isForeground: false) ?? theme.background
                    let resolvedBg = resolveAnsiColor(cellAttr.fg, isForeground: true) ?? theme.foreground
                    bgColor = resolvedBg
                } else {
                    fgColor = resolveAnsiColor(cellAttr.fg, isForeground: true) ?? theme.foreground
                    bgColor = resolveAnsiColor(cellAttr.bg, isForeground: false)
                }

                // Dim: reduce alpha
                if cellAttr.dim {
                    fgColor = fgColor.withAlphaComponent(0.5)
                }

                // Draw cell background if non-default
                if let bg = bgColor {
                    let cellRect = NSRect(
                        x: CGFloat(col) * cellWidth + 2,
                        y: y,
                        width: cellWidth,
                        height: cellHeight
                    )
                    context.setFillColor(bg.cgColor)
                    context.fill(cellRect)
                }

                // Skip spaces and zero-width space placeholders (wide char 2nd cell)
                guard char != " " && char != "\u{200B}" else { continue }

                // URL styling overrides
                let isURL = !rowURLs.isEmpty && rowURLs.contains(where: { col >= $0.startCol && col < $0.endCol })

                // Build font with bold/italic traits + Powerline fallback
                let isASCII = char.asciiValue != nil
                let isPowerlineOrNerdFont = char.unicodeScalars.first.map {
                    let v = Int($0.value)
                    // Powerline symbols
                    return (0xE0A0...0xE0D4).contains(v) ||
                    // Seti-UI + Custom
                    (0xE5FA...0xE6B5).contains(v) ||
                    // Devicons
                    (0xE700...0xE7C5).contains(v) ||
                    // Font Awesome
                    (0xF000...0xF2E0).contains(v) ||
                    // Font Awesome Extension
                    (0xE200...0xE2A9).contains(v) ||
                    // Material Design Icons
                    (0xF0001...0xF1AF0).contains(v) ||
                    // Weather Icons
                    (0xE300...0xE3E3).contains(v) ||
                    // Octicons
                    (0xF400...0xF532).contains(v) ||
                    (0x2665...0x2665).contains(v) || // ♥
                    (0x26A1...0x26A1).contains(v) || // ⚡
                    // IEC Power Symbols
                    (0x23FB...0x23FE).contains(v) ||
                    (0x2B58...0x2B58).contains(v) ||
                    // Font Logos
                    (0xF300...0xF375).contains(v) ||
                    // Pomicons
                    (0xE000...0xE00A).contains(v) ||
                    // Codicons
                    (0xEA60...0xEBEB).contains(v)
                } ?? false
                let baseFont: NSFont
                if isPowerlineOrNerdFont, let plFont = cachedPowerlineFont {
                    baseFont = plFont
                } else if isASCII {
                    baseFont = cachedMonoFont
                } else {
                    baseFont = cachedFallbackFont
                }
                var font = baseFont

                if cellAttr.bold || cellAttr.italic {
                    var traits: NSFontTraitMask = []
                    if cellAttr.bold { traits.insert(.boldFontMask) }
                    if cellAttr.italic { traits.insert(.italicFontMask) }
                    if let converted = NSFontManager.shared.convert(baseFont, toHaveTrait: traits) as NSFont? {
                        font = converted
                    }
                }

                // Build attributes
                var attrs: [NSAttributedString.Key: Any] = [
                    .font: font,
                    .foregroundColor: isURL ? NSColor.linkColor : fgColor,
                ]
                if cellAttr.underline || isURL {
                    attrs[.underlineStyle] = NSUnderlineStyle.single.rawValue
                }

                let str = NSAttributedString(string: String(char), attributes: attrs)
                // Adjust vertical position for Nerd Font symbols to align with text baseline
                var drawY = y
                if isPowerlineOrNerdFont, let plFont = cachedPowerlineFont {
                    let mainAscent = cachedMonoFont.ascender
                    let symbolAscent = plFont.ascender
                    drawY += (mainAscent - symbolAscent)
                }
                str.draw(at: NSPoint(x: CGFloat(col) * cellWidth + 2, y: drawY))
            }
        }

        // Render cursor (only in screen area, not scrollback)
        if cursorVisible {
            let cursorAbsRow = scrollbackCount + cursorY
            let x = CGFloat(cursorX) * cellWidth + 2
            let y = CGFloat(cursorAbsRow) * cellHeight
            let style = AppThemeManager.shared.cursorStyle

            context.setFillColor(theme.cursor.cgColor)
            switch style {
            case .block:
                let cursorRect = NSRect(x: x, y: y, width: cellWidth, height: cellHeight)
                context.setFillColor(theme.cursor.withAlphaComponent(0.7).cgColor)
                context.fill(cursorRect)
            case .underline:
                let cursorRect = NSRect(x: x, y: y + cellHeight - 2, width: cellWidth, height: 2)
                context.fill(cursorRect)
            case .bar:
                let cursorRect = NSRect(x: x, y: y, width: 2, height: cellHeight)
                context.fill(cursorRect)
            }
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

        let pos = cellPosition(for: point)

        if event.clickCount == 2 {
            // Double-click: select word at cursor position
            selectWord(at: pos)
            return
        } else if event.clickCount == 3 {
            // Triple-click: select entire line
            selectLine(at: pos.row)
            return
        }

        // Single click: start drag selection
        selectionStart = pos
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

    // MARK: - Word & Line Selection

    /// Select the word at the given cell position (for double-click).
    private func selectWord(at pos: (row: Int, col: Int)) {
        guard let line = cellLineAtRow(pos.row) else { return }
        let col = min(pos.col, line.count - 1)
        guard col >= 0 else { return }

        // Define word characters (alphanumeric + underscore + common path chars)
        func isWordChar(_ c: Character) -> Bool {
            c.isLetter || c.isNumber || c == "_" || c == "-" || c == "." || c == "/" || c == "~"
        }

        // Find word start
        var startCol = col
        while startCol > 0 && isWordChar(line[startCol - 1].character) {
            startCol -= 1
        }
        // Find word end
        var endCol = col
        while endCol < line.count - 1 && isWordChar(line[endCol + 1].character) {
            endCol += 1
        }

        selectionStart = (row: pos.row, col: startCol)
        selectionEnd = (row: pos.row, col: endCol + 1)
        isSelecting = false
        needsDisplay = true
    }

    /// Select an entire line (for triple-click).
    private func selectLine(at row: Int) {
        guard let line = cellLineAtRow(row) else { return }
        selectionStart = (row: row, col: 0)
        selectionEnd = (row: row, col: line.count)
        isSelecting = false
        needsDisplay = true
    }

    // MARK: - Context Menu (Right-Click)

    override func menu(for event: NSEvent) -> NSMenu? {
        let menu = NSMenu()

        let copyItem = NSMenuItem(title: LS("terminal.copy"), action: #selector(copySelection), keyEquivalent: "c")
        copyItem.keyEquivalentModifierMask = .command
        copyItem.isEnabled = selectedText() != nil
        menu.addItem(copyItem)

        let pasteItem = NSMenuItem(title: LS("terminal.paste"), action: #selector(pasteClipboard), keyEquivalent: "v")
        pasteItem.keyEquivalentModifierMask = .command
        menu.addItem(pasteItem)

        menu.addItem(NSMenuItem.separator())

        let selectAllItem = NSMenuItem(title: LS("terminal.selectAll"), action: #selector(selectAllText), keyEquivalent: "a")
        selectAllItem.keyEquivalentModifierMask = .command
        menu.addItem(selectAllItem)

        let clearItem = NSMenuItem(title: LS("terminal.clear"), action: #selector(clearTerminal), keyEquivalent: "k")
        clearItem.keyEquivalentModifierMask = .command
        menu.addItem(clearItem)

        menu.addItem(NSMenuItem.separator())

        let splitHItem = NSMenuItem(title: LS("terminal.splitHorizontal"), action: #selector(splitHorizontally), keyEquivalent: "")
        menu.addItem(splitHItem)

        let splitVItem = NSMenuItem(title: LS("terminal.splitVertical"), action: #selector(splitVertically), keyEquivalent: "")
        menu.addItem(splitVItem)

        menu.addItem(NSMenuItem.separator())

        let closeItem = NSMenuItem(title: LS("terminal.closePane"), action: #selector(closePane), keyEquivalent: "")
        menu.addItem(closeItem)

        return menu
    }

    @objc private func copySelection() {
        if let text = selectedText() {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
        }
    }

    @objc private func pasteClipboard() {
        if let text = NSPasteboard.general.string(forType: .string) {
            let bytes = Array(text.utf8)
            if let handle = terminalHandle, !bytes.isEmpty {
                pier_terminal_write(handle, bytes, UInt(bytes.count))
            }
        }
    }

    @objc private func selectAllText() {
        let totalLines = scrollback.count + screen.count
        guard totalLines > 0 else { return }
        selectionStart = (row: 0, col: 0)
        if let lastLine = cellLineAtRow(totalLines - 1) {
            selectionEnd = (row: totalLines - 1, col: lastLine.count)
        }
        needsDisplay = true
    }

    @objc private func clearTerminal() {
        scrollback.removeAll()
        for row in 0..<screen.count {
            screen[row] = Array(repeating: TerminalCell(), count: ptyCols)
        }
        cursorX = 0
        cursorY = 0
        updateDocumentSize()
        needsDisplay = true
    }

    @objc private func splitHorizontally() {
        guard let sessionId = currentSessionId else { return }
        NotificationCenter.default.post(name: .terminalSplitH, object: sessionId)
    }

    @objc private func splitVertically() {
        guard let sessionId = currentSessionId else { return }
        NotificationCenter.default.post(name: .terminalSplitV, object: sessionId)
    }

    @objc private func closePane() {
        guard let sessionId = currentSessionId else { return }
        NotificationCenter.default.post(name: .terminalClosePane, object: sessionId)
    }

    /// Get the selected text as a string.
    private func selectedText() -> String? {
        guard let start = selectionStart, let end = selectionEnd else { return nil }
        let normalized = normalizeSelection(start: start, end: end)
        let sRow = normalized.start.row
        let sCol = normalized.start.col
        let eRow = normalized.end.row
        let eCol = normalized.end.col

        var result = ""

        for row in sRow..<min(eRow + 1, scrollback.count + screen.count) {
            guard let line = cellLineAtRow(row) else { continue }
            let startCol = (row == sRow) ? min(sCol, line.count) : 0
            let endCol = (row == eRow) ? min(eCol, line.count) : line.count

            if startCol < endCol {
                let slice = line[startCol..<endCol].map { $0.character }
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
        guard cursorY >= 0, cursorY < screen.count else { return }
        let line = String(screen[cursorY].map { $0.character }).trimmingCharacters(in: .whitespaces)
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
    // NOTE: setFrameSize override REMOVED — it was reading stale contentView.bounds
    // and overriding the correct ptyCols set by the notification handler.
    // PTY resize is now handled exclusively via handleViewportSizeChanged.

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

        // Update document frame to fill visible area (use super to avoid re-triggering our setFrameSize override)
        let totalLines = scrollback.count + screen.count
        let requiredHeight = max(visibleSize.height, CGFloat(totalLines) * cellHeight)
        super.setFrameSize(NSSize(width: visibleSize.width, height: requiredHeight))

        // Scroll to bottom to keep cursor/latest content visible after resize
        if let scrollView = enclosingScrollView {
            let maxScrollY = max(0, requiredHeight - visibleSize.height)
            scrollView.contentView.scroll(to: NSPoint(x: 0, y: maxScrollY))
            scrollView.reflectScrolledClipView(scrollView.contentView)
        }

        needsDisplay = true
    }

    /// Resize the screen buffer to match current ptyCols/ptyRows.
    /// Only adjusts row count — does NOT reflow or truncate line content.
    /// The shell receives SIGWINCH and re-renders future output at the new width.
    private func resizeScreenBuffer() {
        let oldCols = screen.first?.count ?? ptyCols

        // ── Step 1: Combine all rows (scrollback + screen) into logical lines ──
        // A "logical line" is a sequence of physical rows connected by soft wraps.
        let allRows: [[TerminalCell]] = scrollback + screen
        var allWrapped: [Bool] = scrollbackLineWrapped + screenLineWrapped

        // Ensure arrays match
        while allWrapped.count < allRows.count { allWrapped.append(false) }
        while allWrapped.count > allRows.count { allWrapped.removeLast() }

        // Build logical lines: each is a flat array of TerminalCell
        // A logical line starts where wrapped[i] == false (hard break or first line)
        var logicalLines: [[TerminalCell]] = []
        var currentLogical: [TerminalCell] = []

        for i in 0..<allRows.count {
            if i == 0 || !allWrapped[i] {
                // Start of a new logical line
                if i > 0 {
                    logicalLines.append(currentLogical)
                }
                currentLogical = allRows[i]
            } else {
                // Continuation (soft wrap) — append to current logical line
                currentLogical.append(contentsOf: allRows[i])
            }
        }
        if !currentLogical.isEmpty || !allRows.isEmpty {
            logicalLines.append(currentLogical)
        }

        // ── Step 2: Strip trailing blanks from each logical line ──
        for i in 0..<logicalLines.count {
            while logicalLines[i].count > 0 && logicalLines[i].last?.character == " " && logicalLines[i].last?.attr == .default {
                logicalLines[i].removeLast()
            }
        }

        // ── Step 3: Re-wrap each logical line at new ptyCols ──
        var newRows: [[TerminalCell]] = []
        var newWrapped: [Bool] = []

        for logicalLine in logicalLines {
            if logicalLine.isEmpty {
                // Empty line (just a newline) → single blank row
                newRows.append(Array(repeating: .blank, count: ptyCols))
                newWrapped.append(false)
            } else {
                // Split into chunks of ptyCols
                var offset = 0
                var isFirst = true
                while offset < logicalLine.count {
                    let end = min(offset + ptyCols, logicalLine.count)
                    var row = Array(logicalLine[offset..<end])
                    // Pad to ptyCols
                    if row.count < ptyCols {
                        row.append(contentsOf: Array(repeating: TerminalCell.blank, count: ptyCols - row.count))
                    }
                    newRows.append(row)
                    newWrapped.append(isFirst ? false : true)  // first chunk = hard, rest = soft
                    isFirst = false
                    offset = end
                }
            }
        }

        // ── Step 4: Split into scrollback and screen ──
        if newRows.count <= ptyRows {
            // Everything fits on screen
            scrollback = []
            scrollbackLineWrapped = []
            screen = newRows
            screenLineWrapped = newWrapped
            // Pad to ptyRows
            while screen.count < ptyRows {
                screen.append(Array(repeating: .blank, count: ptyCols))
                screenLineWrapped.append(false)
            }
        } else {
            // Split: last ptyRows rows are screen, rest is scrollback
            let splitPoint = newRows.count - ptyRows
            scrollback = Array(newRows[0..<splitPoint])
            scrollbackLineWrapped = Array(newWrapped[0..<splitPoint])
            screen = Array(newRows[splitPoint...])
            screenLineWrapped = Array(newWrapped[splitPoint...])
        }

        // Trim scrollback to max limit
        if scrollback.count > maxScrollback {
            let excess = scrollback.count - maxScrollback
            scrollback.removeFirst(excess)
            scrollbackLineWrapped.removeFirst(min(excess, scrollbackLineWrapped.count))
        }

        cursorX = min(cursorX, ptyCols - 1)
        cursorY = min(cursorY, ptyRows - 1)
    }

    // MARK: - Cleanup

    deinit {
        readTimer?.invalidate()
        blinkTimer?.invalidate()
        // Save PTY to cache instead of destroying — the session survives
        // NSView deallocation (e.g. tab switch). Only handleTabClosed destroys PTYs.
        if let sessionId = currentSessionId, let handle = terminalHandle {
            let entry = PTYCacheEntry(
                handle: handle,
                screen: screen,
                scrollback: scrollback,
                screenLineWrapped: screenLineWrapped,
                scrollbackLineWrapped: scrollbackLineWrapped,
                cursorX: cursorX,
                cursorY: cursorY,
                ptyCols: ptyCols,
                ptyRows: ptyRows,
                savedCursorX: savedCursorX,
                savedCursorY: savedCursorY,
                currentAttr: currentAttr
            )
            TerminalNSView.ptyCache[sessionId] = entry
        }
    }
}
