import SwiftUI
import AppKit

/// Manages app-wide appearance (dark/light/system).
enum AppearanceMode: String, CaseIterable, Identifiable {
    case system = "system"
    case light  = "light"
    case dark   = "dark"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .system: return LS("theme.system")
        case .light:  return LS("theme.light")
        case .dark:   return LS("theme.dark")
        }
    }
}

/// Language preference: follow system or force a locale.
enum LanguageMode: String, CaseIterable, Identifiable {
    case system = "system"
    case chinese = "zh-Hans"
    case english = "en"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .system:  return LS("settings.languageSystem")
        case .chinese: return LS("settings.languageChinese")
        case .english: return LS("settings.languageEnglish")
        }
    }
}

/// Singleton manager for app appearance.
class AppThemeManager: ObservableObject {
    static let shared = AppThemeManager()

    @AppStorage("pier.appearance") var appearanceMode: AppearanceMode = .system {
        didSet { applyAppearance() }
    }

    @AppStorage("pier.language") var languageMode: LanguageMode = .system {
        didSet { applyLanguage() }
    }

    @AppStorage("pier.terminalTheme") var terminalThemeId: String = "default_dark"

    // Font settings
    @AppStorage("pier.fontSize") var fontSize: Double = 13
    @AppStorage("pier.fontFamily") var fontFamily: String = "SF Mono"

    // Pane width memory
    @AppStorage("pier.sidebarWidth") var sidebarWidth: Double = 200
    @AppStorage("pier.rightPanelWidth") var rightPanelWidth: Double = 280

    /// Current terminal theme derived from stored ID.
    var currentTerminalTheme: TerminalTheme {
        TerminalTheme.theme(forId: terminalThemeId)
    }

    private init() {
        applyAppearance()
        applyLanguage()
    }

    /// Apply the stored appearance mode to NSApp.
    /// Also auto-switches terminal theme between default_dark and default_light.
    func applyAppearance() {
        switch appearanceMode {
        case .system:
            NSApp.appearance = nil
            // Auto-detect current effective appearance
            let isDark = NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            autoSwitchTerminalTheme(isDark: isDark)
        case .light:
            NSApp.appearance = NSAppearance(named: .aqua)
            autoSwitchTerminalTheme(isDark: false)
        case .dark:
            NSApp.appearance = NSAppearance(named: .darkAqua)
            autoSwitchTerminalTheme(isDark: true)
        }
    }

    /// Auto-switch terminal theme only when user is using one of the default themes.
    private func autoSwitchTerminalTheme(isDark: Bool) {
        if isDark && terminalThemeId == "default_light" {
            terminalThemeId = "default_dark"
        } else if !isDark && terminalThemeId == "default_dark" {
            terminalThemeId = "default_light"
        }
    }

    /// Apply the stored language preference.
    /// Invalidates the cached localization bundle so LS() picks up the new locale.
    func applyLanguage() {
        switch languageMode {
        case .system:
            UserDefaults.standard.removeObject(forKey: "AppleLanguages")
        case .chinese:
            UserDefaults.standard.set(["zh-Hans"], forKey: "AppleLanguages")
        case .english:
            UserDefaults.standard.set(["en"], forKey: "AppleLanguages")
        }
        UserDefaults.standard.synchronize()
        invalidateLocalizedBundle()
    }

    /// Switch terminal theme by ID.
    func setTerminalTheme(_ id: String) {
        terminalThemeId = id
        objectWillChange.send()
    }

    /// Enable window frame auto-save.
    func setupWindowPersistence() {
        DispatchQueue.main.async {
            NSApp.windows.first?.setFrameAutosaveName("PierMainWindow")
        }
    }
}
