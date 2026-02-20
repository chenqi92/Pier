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
