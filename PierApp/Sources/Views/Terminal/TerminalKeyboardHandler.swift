import AppKit

// MARK: - Delegate Protocol

/// Protocol for `TerminalKeyboardHandler` to communicate with `TerminalNSView`.
///
/// This cleanly separates keyboard handling logic from the view layer.
/// The handler owns all key mapping, IME integration, and fullwidth normalization;
/// the view provides terminal state and PTY write access.
@MainActor
protocol TerminalKeyboardDelegate: AnyObject {
    var terminalHandle: OpaquePointer? { get }
    var bracketedPasteMode: Bool { get }
    var applicationCursorKeys: Bool { get }
    var useAlternateScreen: Bool { get }

    // Cursor position — used for IME candidate window placement
    var cursorX: Int { get }
    var cursorY: Int { get }
    var cellWidth: CGFloat { get }
    var cellHeight: CGFloat { get }

    /// Get the currently selected text (for ⌘C copy).
    func selectedText() -> String?
    /// Clear selection after writing to PTY.
    func clearSelection()
    /// Write raw bytes to the terminal PTY.
    func writeToPTY(_ bytes: [UInt8])
    /// Check current screen line for SSH command (called on Enter).
    func detectSSHCommand()
}

// MARK: - Keyboard Handler

/// Centralized keyboard input handler for the terminal emulator.
///
/// ## Architecture (modeled after iTerm2's `iTermKeyboardHandler`)
///
/// ```
/// performKeyEquivalent ─┐
///                       ├─► interpretKeyEvents ─► insertText / doCommandBySelector
/// keyDown ──────────────┘                                │
///                                                        ▼
///                                                  delegate.writeToPTY
/// ```
///
/// ## Responsibilities
/// 1. **Event routing** — `performKeyEquivalent` vs `keyDown`, dedup, IME bypass
/// 2. **IME integration** — `NSTextInputClient` callbacks (`insertText`, `setMarkedText`, etc.)
/// 3. **Key mapping** — keyCode → VT100/xterm escape sequences
/// 4. **Fullwidth normalization** — CJK fullwidth → ASCII halfwidth
/// 5. **Clipboard** — ⌘C/⌘V with bracketed paste support
///
/// ## State Management
/// - `eventBeingHandled` — the NSEvent currently in the pipeline
/// - `keyPressHandled` — set by `insertText`/`doCommandBySelector` to prevent double-handling
/// - `hadMarkedTextBefore` — tracks IME composition state before processing
@MainActor
final class TerminalKeyboardHandler {

    weak var delegate: TerminalKeyboardDelegate?

    // MARK: - State

    /// The event currently being processed by `interpretKeyEvents`.
    private(set) var eventBeingHandled: NSEvent?
    /// Set when `insertText` or `doCommandBySelector` handles the event.
    private var keyPressHandled = false
    /// Whether marked text existed before the current event was processed.
    private var hadMarkedTextBefore = false
    /// Tracked marked text string (for IME composition).
    private(set) var markedText: NSAttributedString?
    /// Range of the marked text.
    private(set) var markedTextRange: NSRange = NSRange(location: NSNotFound, length: 0)

    // MARK: - Debug

    private static let enableDebugLog = false

    private static func debugLog(_ msg: String) {
        guard enableDebugLog else { return }
        print("[KeyHandler] \(msg)")
    }

    // MARK: - Entry Points

    /// Called from `TerminalNSView.performKeyEquivalent(with:)`.
    ///
    /// Returns `true` to claim the event (preventing SwiftUI/menu interception).
    /// - ⌘ shortcuts: ⌘C copy, ⌘V paste handled here; other ⌘ keys pass to menu system.
    /// - All other keys: routed through `interpretKeyEvents` for proper IME support.
    func handlePerformKeyEquivalent(_ event: NSEvent, view: NSView) -> Bool {
        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)

        // ⌘-based shortcuts
        if modifiers.contains(.command) {
            return handleCommandShortcut(event)
        }

        // Ctrl+key: bypass IME, write directly (Ctrl+C, Ctrl+D, etc.)
        if modifiers.contains(.control) {
            handleControlKey(event)
            return true
        }

        // Functional keys that must bypass IME — they have special terminal semantics
        // (escape sequences, detectSSHCommand on Enter, etc.) that would be lost if
        // routed through insertText.
        if Self.mapSpecialKey(event.keyCode, applicationCursorKeys: delegate?.applicationCursorKeys ?? false) != nil {
            handleRawKeyEvent(event)
            return true
        }

        // Regular character keys: route through interpretKeyEvents for IME support.
        // MUST return true to prevent SwiftUI/menu from stealing the event.
        routeThroughIME(event, view: view)
        return true
    }

    /// Called from `TerminalNSView.keyDown(with:)`.
    /// Only reached if `performKeyEquivalent` returned `false` (i.e., ⌘ shortcuts
    /// that we didn't claim). In practice, most keys are handled in performKeyEquivalent.
    func handleKeyDown(_ event: NSEvent, view: NSView) {
        routeThroughIME(event, view: view)
    }

    // MARK: - NSTextInputClient Callbacks

    /// Called by `interpretKeyEvents` when the IME (or system) commits text.
    /// This is the primary path for all character input — both direct ASCII
    /// and composed CJK text.
    func handleInsertText(_ string: Any) {
        let text: String
        if let str = string as? String {
            text = str
        } else if let attrStr = string as? NSAttributedString {
            text = attrStr.string
        } else {
            return
        }

        guard !text.isEmpty else { return }

        // Clear any marked text
        markedText = nil
        markedTextRange = NSRange(location: NSNotFound, length: 0)

        // Normalize CJK fullwidth punctuation to ASCII halfwidth
        let normalized = Self.normalizeFullwidth(text)
        let bytes = Array(normalized.utf8)

        Self.debugLog("insertText '\(text)' → '\(normalized)' (\(bytes.count) bytes)")

        delegate?.clearSelection()
        delegate?.writeToPTY(bytes)
        keyPressHandled = true
    }

    /// Called by `interpretKeyEvents` for non-text key actions (Enter, Backspace,
    /// arrow keys, etc.). Falls through to our keyCode → escape sequence mapper.
    func handleDoCommandBySelector(_ selector: Selector) {
        guard !keyPressHandled, let event = eventBeingHandled else { return }

        // If there was marked text before and the IME consumed it, don't process
        if hadMarkedTextBefore { return }

        Self.debugLog("doCommandBySelector: \(NSStringFromSelector(selector)) keyCode=\(event.keyCode)")

        handleRawKeyEvent(event)
        keyPressHandled = true
    }

    /// Called when IME shows inline composition (e.g., pinyin underlined text).
    func handleSetMarkedText(_ string: Any, selectedRange: NSRange) {
        if let str = string as? String {
            markedText = NSAttributedString(string: str)
        } else if let attrStr = string as? NSAttributedString {
            markedText = attrStr
        }

        if let mt = markedText, mt.length > 0 {
            markedTextRange = NSRange(location: 0, length: mt.length)
        } else {
            markedTextRange = NSRange(location: NSNotFound, length: 0)
        }
    }

    /// Called when IME composition is cancelled or committed.
    func handleUnmarkText() {
        markedText = nil
        markedTextRange = NSRange(location: NSNotFound, length: 0)
    }

    /// Returns the rect for positioning the IME candidate window.
    func firstRect(in view: NSView) -> NSRect {
        guard let window = view.window,
              let del = delegate else { return .zero }
        let x = CGFloat(del.cursorX) * del.cellWidth
        let y = view.bounds.height - CGFloat(del.cursorY + 1) * del.cellHeight
        let pointInWindow = view.convert(NSPoint(x: x, y: y), to: nil)
        let pointOnScreen = window.convertPoint(toScreen: pointInWindow)
        return NSRect(origin: pointOnScreen,
                      size: NSSize(width: del.cellWidth, height: del.cellHeight))
    }

    // MARK: - Private: Event Routing

    /// Route the event through macOS's text input system for proper IME processing.
    ///
    /// Uses `inputContext.handleEvent` (like iTerm2) instead of `interpretKeyEvents`
    /// to avoid NSBeep from unhandled selectors in NSResponder's default doCommand(by:).
    private func routeThroughIME(_ event: NSEvent, view: NSView) {
        hadMarkedTextBefore = markedText != nil && (markedText?.length ?? 0) > 0
        eventBeingHandled = event
        keyPressHandled = false

        // Use NSTextInputContext.handleEvent for proper IME routing.
        // This is the recommended API and avoids the NSBeep issue that
        // interpretKeyEvents can trigger when doCommandBySelector falls through.
        let handled = view.inputContext?.handleEvent(event) ?? false

        // If the input context didn't handle it (or doesn't exist),
        // and our callbacks weren't invoked, process as raw key event.
        if !keyPressHandled && !handled {
            Self.debugLog("inputContext did not handle event, falling back to raw handler")
            handleRawKeyEvent(event)
        }

        // If inputContext handled the event but our callbacks weren't invoked
        // (e.g., IME consumed the key internally), treat it as handled.
        if handled && !keyPressHandled {
            Self.debugLog("inputContext handled event internally (IME consumed)")
        }

        eventBeingHandled = nil
    }

    // MARK: - Private: Command Shortcuts (⌘)

    /// Handle ⌘-based shortcuts. Returns `true` if consumed.
    private func handleCommandShortcut(_ event: NSEvent) -> Bool {
        guard delegate?.terminalHandle != nil else { return false }

        switch event.charactersIgnoringModifiers {
        case "c":
            // ⌘C: copy selection
            if let text = delegate?.selectedText() {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(text, forType: .string)
                return true
            }
            return false  // No selection — let menu system handle

        case "v":
            // ⌘V: paste with bracketed paste support
            guard let text = NSPasteboard.general.string(forType: .string),
                  !text.isEmpty else { return false }
            pasteToPTY(text)
            return true

        default:
            return false  // Let menu system handle other ⌘ shortcuts
        }
    }

    /// Paste text to PTY, wrapping with bracketed paste escape sequences if enabled.
    private func pasteToPTY(_ text: String) {
        let bytes = Array(text.utf8)
        if delegate?.bracketedPasteMode == true {
            let prefix: [UInt8] = [0x1B, 0x5B, 0x32, 0x30, 0x30, 0x7E]  // \e[200~
            let suffix: [UInt8] = [0x1B, 0x5B, 0x32, 0x30, 0x31, 0x7E]  // \e[201~
            delegate?.writeToPTY(prefix)
            delegate?.writeToPTY(bytes)
            delegate?.writeToPTY(suffix)
        } else {
            delegate?.writeToPTY(bytes)
        }
    }

    // MARK: - Private: Control Keys

    /// Handle Ctrl+key combinations directly (bypass IME).
    private func handleControlKey(_ event: NSEvent) {
        if let raw = event.charactersIgnoringModifiers?.lowercased(),
           let ch = raw.first, ch >= "a" && ch <= "z" {
            let byte = UInt8(ch.asciiValue! - 96)  // Ctrl+A = 0x01, ..., Ctrl+Z = 0x1A
            delegate?.clearSelection()
            delegate?.writeToPTY([byte])
        } else if let chars = event.characters, !chars.isEmpty {
            delegate?.clearSelection()
            delegate?.writeToPTY(Array(chars.utf8))
        }
    }

    // MARK: - Private: Raw Key Event Processing

    /// Map a raw NSEvent to terminal escape sequences and write to PTY.
    /// This handles special keys (arrows, function keys, etc.) by keyCode,
    /// and falls through to UTF-8 encoding for regular characters.
    private func handleRawKeyEvent(_ event: NSEvent) {
        guard delegate?.terminalHandle != nil else { return }

        let keyCode = event.keyCode
        let chars = event.characters ?? ""
        let appCursor = delegate?.applicationCursorKeys ?? false

        var bytes: [UInt8] = []

        // Special keys by keyCode
        if let mapped = Self.mapSpecialKey(keyCode, applicationCursorKeys: appCursor) {
            // Enter: also detect SSH command
            if keyCode == 36 {
                delegate?.detectSSHCommand()
            }
            bytes = mapped
        } else if !chars.isEmpty {
            // Regular character fallback (shouldn't normally reach here for text input,
            // since interpretKeyEvents → insertText handles it)
            let normalized = Self.normalizeFullwidth(chars)
            bytes = Array(normalized.utf8)
        }

        if !bytes.isEmpty {
            Self.debugLog("rawKey keyCode=\(keyCode) chars='\(chars)' → \(bytes.map { String(format: "%02X", $0) }.joined(separator: " "))")
            delegate?.clearSelection()
            delegate?.writeToPTY(bytes)
        }
    }

    // MARK: - Key Mapping

    /// Map a keyCode to VT100/xterm escape sequence bytes.
    /// Returns `nil` if the keyCode is not a special key.
    private static func mapSpecialKey(_ keyCode: UInt16, applicationCursorKeys appCursor: Bool) -> [UInt8]? {
        switch keyCode {
        case 36: return [0x0D]                                                    // Return
        case 51: return [0x7F]                                                    // Backspace
        case 53: return [0x1B]                                                    // Escape
        case 48: return [0x09]                                                    // Tab
        case 123: return appCursor ? [0x1B, 0x4F, 0x44] : [0x1B, 0x5B, 0x44]    // Left
        case 124: return appCursor ? [0x1B, 0x4F, 0x43] : [0x1B, 0x5B, 0x43]    // Right
        case 125: return appCursor ? [0x1B, 0x4F, 0x42] : [0x1B, 0x5B, 0x42]    // Down
        case 126: return appCursor ? [0x1B, 0x4F, 0x41] : [0x1B, 0x5B, 0x41]    // Up
        case 115: return [0x1B, 0x5B, 0x48]                                      // Home
        case 119: return [0x1B, 0x5B, 0x46]                                      // End
        case 117: return [0x1B, 0x5B, 0x33, 0x7E]                                // Forward Delete
        case 116: return [0x1B, 0x5B, 0x35, 0x7E]                                // Page Up
        case 121: return [0x1B, 0x5B, 0x36, 0x7E]                                // Page Down
        // Function keys F1-F12
        case 122: return [0x1B, 0x4F, 0x50]                                      // F1
        case 120: return [0x1B, 0x4F, 0x51]                                      // F2
        case 99:  return [0x1B, 0x4F, 0x52]                                      // F3
        case 118: return [0x1B, 0x4F, 0x53]                                      // F4
        case 96:  return [0x1B, 0x5B, 0x31, 0x35, 0x7E]                          // F5
        case 97:  return [0x1B, 0x5B, 0x31, 0x37, 0x7E]                          // F6
        case 98:  return [0x1B, 0x5B, 0x31, 0x38, 0x7E]                          // F7
        case 100: return [0x1B, 0x5B, 0x31, 0x39, 0x7E]                          // F8
        case 101: return [0x1B, 0x5B, 0x32, 0x30, 0x7E]                          // F9
        case 109: return [0x1B, 0x5B, 0x32, 0x31, 0x7E]                          // F10
        case 103: return [0x1B, 0x5B, 0x32, 0x33, 0x7E]                          // F11
        case 111: return [0x1B, 0x5B, 0x32, 0x34, 0x7E]                          // F12
        default: return nil
        }
    }

    // MARK: - Fullwidth → Halfwidth Normalization

    /// Map of CJK fullwidth/special punctuation to ASCII equivalents.
    /// Includes both fullwidth forms (U+FFxx) and Chinese-specific punctuation.
    private static let fullwidthToHalfwidth: [Character: Character] = [
        // Fullwidth ASCII variants (U+FF01–U+FF5E)
        "｜": "|",   // pipe
        "＞": ">",   // redirect
        "＜": "<",   // redirect
        "；": ";",   // command separator
        "＆": "&",   // background / logical AND
        "（": "(",   // subshell
        "）": ")",
        "｛": "{",   // brace expansion
        "｝": "}",
        "［": "[",   // test
        "］": "]",
        "＇": "'",   // single quote
        "＂": "\"",  // double quote
        "～": "~",   // home directory
        "＄": "$",   // variable
        "＃": "#",   // comment
        "＊": "*",   // glob
        "？": "?",   // glob
        "！": "!",   // history
        "＝": "=",   // assignment
        "＋": "+",   // arithmetic
        "＠": "@",   // user@host
        "＼": "\\",  // escape
        "／": "/",   // path separator
        "：": ":",   // PATH separator
        "．": ".",   // current dir (fullwidth)
        "，": ",",   // argument separator
        // Chinese-specific punctuation
        "。": ".",   // ideographic period → ASCII dot
        "、": ",",   // enumeration comma → ASCII comma
        "「": "[",   // left corner bracket
        "」": "]",   // right corner bracket
        "『": "{",   // left double corner bracket
        "』": "}",   // right double corner bracket
        "【": "[",   // left black lenticular bracket
        "】": "]",   // right black lenticular bracket
    ]

    /// Replace fullwidth/CJK characters with their halfwidth ASCII equivalents.
    static func normalizeFullwidth(_ input: String) -> String {
        guard input.contains(where: { fullwidthToHalfwidth[$0] != nil }) else {
            return input
        }
        return String(input.map { fullwidthToHalfwidth[$0] ?? $0 })
    }
}
