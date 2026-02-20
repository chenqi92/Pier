import Foundation

// ─────────────────────────────────────────────────────────────────────────────
// main.swift — Custom entry point for Pier Terminal
//
// By using main.swift instead of @main, we can set AppleLanguages BEFORE
// NSApplication is initialized. This guarantees that macOS creates ALL system
// menus (File, Edit, View, Window, Help, and their sub-items) in the correct
// language from the very start — no post-hoc patching needed.
//
// For SPM binaries (dev mode), we also create .lproj marker directories next
// to the executable so macOS recognizes the app's supported languages.
// ─────────────────────────────────────────────────────────────────────────────

/// Create .lproj marker directories next to the binary.
/// macOS needs these directories in Bundle.main to recognize that the app
/// supports a given language. Without them, AppleLanguages is ignored for
/// system menus (File, Edit, View, Window, Help).
/// In .app bundle mode, these exist in Contents/Resources/. In dev mode
/// (bare binary via `swift run`), they don't exist — so we create them.
func ensureLocalizationMarkers() {
    guard let execPath = Bundle.main.executablePath else { return }
    let dir = (execPath as NSString).deletingLastPathComponent
    let fm = FileManager.default
    for lang in ["en", "zh-Hans"] {
        let lproj = "\(dir)/\(lang).lproj"
        if !fm.fileExists(atPath: lproj) {
            try? fm.createDirectory(atPath: lproj, withIntermediateDirectories: true)
        }
    }
}

/// Read the stored language preference and set AppleLanguages early.
/// This must happen before PierApp.main() because NSApplication reads
/// AppleLanguages during initialization to determine system menu language.
func applyLanguageBeforeLaunch() {
    let lang = UserDefaults.standard.string(forKey: "pier.language") ?? "system"
    switch lang {
    case "zh-Hans":
        UserDefaults.standard.set(["zh-Hans"], forKey: "AppleLanguages")
    case "en":
        UserDefaults.standard.set(["en"], forKey: "AppleLanguages")
    default:
        // "system" — remove override, use macOS system language
        UserDefaults.standard.removeObject(forKey: "AppleLanguages")
    }
    UserDefaults.standard.synchronize()
}

// 1. Create .lproj directories so macOS knows we support Chinese
ensureLocalizationMarkers()

// 2. Set language preference before NSApplication initializes
applyLanguageBeforeLaunch()

// 3. Now launch the SwiftUI app (NSApplication will use the language we just set)
PierApp.main()
