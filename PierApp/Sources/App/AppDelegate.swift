import Cocoa
import SwiftUI
import CPierCore

/// App delegate for macOS-specific lifecycle management.
class AppDelegate: NSObject, NSApplicationDelegate {

    private var eventMonitor: Any?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Use thin overlay-style scrollbars (auto-hiding, like trackpad)
        UserDefaults.standard.set("WhenScrolling", forKey: "AppleShowScrollBars")

        // Ensure the app appears as a regular GUI app (needed when running
        // as a bare binary outside of .app bundle, e.g. via `swift run`)
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)

        // Set custom app icon (swift build doesn't create .app bundle,
        // so CFBundleIconFile in Info.plist doesn't take effect in the Dock)
        if let iconURL = Bundle.main.url(forResource: "AppIcon", withExtension: "icns")
            ?? Bundle.module.url(forResource: "AppIcon", withExtension: "icns"),
           let icon = NSImage(contentsOf: iconURL) {
            NSApp.applicationIconImage = icon
        }

        // Initialize Rust core exactly once (fixes B1: was in onAppear, could fire multiple times)
        pier_init()

        // Ensure SSH ControlMaster config is set up for manually-typed SSH commands
        setupSSHControlMasterConfig()

        // Register bundled Nerd Font for terminal icon support (eza --icons, etc.)
        registerBundledFonts()

        // Configure app appearance (use stored preference, not hardcoded dark)
        AppThemeManager.shared.applyAppearance()

        // Set up global keyboard shortcuts (save monitor ref for cleanup, use [weak self])
        eventMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            return self?.handleKeyEvent(event) ?? event
        }
    }


    func applicationWillTerminate(_ notification: Notification) {
        // Remove event monitor to prevent leak
        if let monitor = eventMonitor {
            NSEvent.removeMonitor(monitor)
            eventMonitor = nil
        }
        // Clean up terminal sessions
        NotificationCenter.default.post(name: .appWillTerminate, object: nil)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        return true
    }

    private func handleKeyEvent(_ event: NSEvent) -> NSEvent? {
        // Global key handling (if needed beyond SwiftUI)
        return event
    }
}

/// Register bundled fonts (Nerd Font Symbols) so the terminal can render icon characters.
private func registerBundledFonts() {
    let fontFileName = "SymbolsNerdFontMono-Regular"
    // Try Bundle.module first (SPM resources), then Bundle.main
    let fontURL = Bundle.module.url(forResource: fontFileName, withExtension: "ttf")
        ?? Bundle.main.url(forResource: fontFileName, withExtension: "ttf")
    guard let url = fontURL else {
        return
    }
    var errorRef: Unmanaged<CFError>?
    if !CTFontManagerRegisterFontsForURL(url as CFURL, .process, &errorRef) {
        if let error = errorRef?.takeRetainedValue() {
            // Font already registered is fine — ignore that error
            let nsError = error as Error as NSError
            if nsError.code != 105 { // kCTFontManagerErrorAlreadyRegistered
                NSLog("Failed to register Nerd Font: \(error)")
            }
        }
    }
}

extension Notification.Name {
    static let appWillTerminate = Notification.Name("pier.appWillTerminate")
}

/// Set up SSH ControlMaster configuration so that ANY ssh command typed in
/// the Pier terminal will automatically create a ControlMaster socket at
/// the path that `SSHControlMaster` expects (`/tmp/pier-ssh-%r@%h:%p`).
///
/// This enables the right panel to detect and reuse manually-typed SSH sessions.
///
/// Steps:
/// 1. Write `/tmp/pier-ssh-config` with ControlMaster settings.
/// 2. Ensure `~/.ssh/config` has `Include /tmp/pier-ssh-config` as the FIRST line.
private func setupSSHControlMasterConfig() {
    let pierConfigPath = "/tmp/pier-ssh-config"
    let pierConfig = """
    # Pier Terminal — auto-generated SSH config for ControlMaster multiplexing.
    # This file is managed by Pier and will be recreated on each launch.
    # Do NOT edit manually.
    Host *
        ControlMaster auto
        ControlPath /tmp/pier-ssh-%r@%h:%p
        ControlPersist 600
    """

    // Step 1: Write Pier SSH config
    do {
        try pierConfig.write(toFile: pierConfigPath, atomically: true, encoding: .utf8)
    } catch {
        NSLog("[Pier] Failed to write SSH config: \(error)")
        return
    }

    // Step 2: Ensure ~/.ssh/config includes our file
    let sshDir = NSHomeDirectory() + "/.ssh"
    let sshConfigPath = sshDir + "/config"
    let includeLine = "Include /tmp/pier-ssh-config"

    // Create ~/.ssh directory if it doesn't exist
    let fm = FileManager.default
    if !fm.fileExists(atPath: sshDir) {
        try? fm.createDirectory(atPath: sshDir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    }

    // Read existing config or start fresh
    var configContent = (try? String(contentsOfFile: sshConfigPath, encoding: .utf8)) ?? ""

    // Check if Include is already present
    if !configContent.contains(includeLine) {
        // Insert Include as the FIRST line (SSH processes config top-down, first match wins)
        configContent = includeLine + "\n\n" + configContent
        do {
            try configContent.write(toFile: sshConfigPath, atomically: true, encoding: .utf8)
            // Ensure correct permissions (SSH requires 600)
            try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: sshConfigPath)
        } catch {
            NSLog("[Pier] Failed to update ~/.ssh/config: \(error)")
        }
    }
}
