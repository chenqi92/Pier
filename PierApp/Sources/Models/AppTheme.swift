import SwiftUI
import AppKit

/// Manages app-wide appearance (dark/light/system).
enum AppearanceMode: String, CaseIterable, Identifiable {
    case system = "system"
    case light  = "light"
    case dark   = "dark"

    var id: String { rawValue }

    var displayName: LocalizedStringKey {
        switch self {
        case .system: return "theme.system"
        case .light:  return "theme.light"
        case .dark:   return "theme.dark"
        }
    }
}

/// Singleton manager for app appearance.
class AppThemeManager: ObservableObject {
    static let shared = AppThemeManager()

    @AppStorage("pier.appearance") var appearanceMode: AppearanceMode = .system {
        didSet { applyAppearance() }
    }

    @AppStorage("pier.terminalTheme") var terminalThemeId: String = "default_dark"

    /// Current terminal theme derived from stored ID.
    var currentTerminalTheme: TerminalTheme {
        TerminalTheme.theme(forId: terminalThemeId)
    }

    private init() {
        applyAppearance()
    }

    /// Apply the stored appearance mode to NSApp.
    func applyAppearance() {
        switch appearanceMode {
        case .system:
            NSApp.appearance = nil
        case .light:
            NSApp.appearance = NSAppearance(named: .aqua)
        case .dark:
            NSApp.appearance = NSAppearance(named: .darkAqua)
        }
    }

    /// Switch terminal theme by ID.
    func setTerminalTheme(_ id: String) {
        terminalThemeId = id
        objectWillChange.send()
    }
}
