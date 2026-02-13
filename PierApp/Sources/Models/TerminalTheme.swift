import AppKit

/// Defines a complete terminal color theme with ANSI colors and UI colors.
struct TerminalTheme: Identifiable, Equatable {
    let id: String
    let name: String

    // UI colors
    let background: NSColor
    let foreground: NSColor
    let cursor: NSColor
    let selection: NSColor

    // ANSI standard 16 colors (0–15)
    let ansiColors: [NSColor]

    /// Returns the ANSI color at the given index (0–15).
    func ansiColor(_ index: Int) -> NSColor {
        guard index >= 0, index < ansiColors.count else { return foreground }
        return ansiColors[index]
    }

    // MARK: - Presets

    static let defaultDark = TerminalTheme(
        id: "default_dark",
        name: "Default Dark",
        background: NSColor(red: 0.08, green: 0.08, blue: 0.10, alpha: 1.0),
        foreground: NSColor(red: 0.85, green: 0.85, blue: 0.85, alpha: 1.0),
        cursor: NSColor(red: 0.0, green: 0.8, blue: 0.4, alpha: 1.0),
        selection: NSColor(red: 0.2, green: 0.4, blue: 0.8, alpha: 0.4),
        ansiColors: [
            NSColor(red: 0.12, green: 0.12, blue: 0.14, alpha: 1.0),  // 0  Black
            NSColor(red: 0.90, green: 0.30, blue: 0.30, alpha: 1.0),  // 1  Red
            NSColor(red: 0.30, green: 0.85, blue: 0.40, alpha: 1.0),  // 2  Green
            NSColor(red: 0.90, green: 0.80, blue: 0.30, alpha: 1.0),  // 3  Yellow
            NSColor(red: 0.35, green: 0.55, blue: 0.95, alpha: 1.0),  // 4  Blue
            NSColor(red: 0.75, green: 0.40, blue: 0.90, alpha: 1.0),  // 5  Magenta
            NSColor(red: 0.30, green: 0.80, blue: 0.85, alpha: 1.0),  // 6  Cyan
            NSColor(red: 0.75, green: 0.75, blue: 0.75, alpha: 1.0),  // 7  White
            NSColor(red: 0.45, green: 0.45, blue: 0.50, alpha: 1.0),  // 8  Bright Black
            NSColor(red: 1.00, green: 0.40, blue: 0.40, alpha: 1.0),  // 9  Bright Red
            NSColor(red: 0.40, green: 1.00, blue: 0.50, alpha: 1.0),  // 10 Bright Green
            NSColor(red: 1.00, green: 0.90, blue: 0.40, alpha: 1.0),  // 11 Bright Yellow
            NSColor(red: 0.50, green: 0.70, blue: 1.00, alpha: 1.0),  // 12 Bright Blue
            NSColor(red: 0.85, green: 0.50, blue: 1.00, alpha: 1.0),  // 13 Bright Magenta
            NSColor(red: 0.40, green: 0.90, blue: 1.00, alpha: 1.0),  // 14 Bright Cyan
            NSColor(red: 0.95, green: 0.95, blue: 0.95, alpha: 1.0),  // 15 Bright White
        ]
    )

    static let solarizedDark = TerminalTheme(
        id: "solarized_dark",
        name: "Solarized Dark",
        background: NSColor(red: 0.00, green: 0.17, blue: 0.21, alpha: 1.0),
        foreground: NSColor(red: 0.51, green: 0.58, blue: 0.59, alpha: 1.0),
        cursor: NSColor(red: 0.58, green: 0.63, blue: 0.00, alpha: 1.0),
        selection: NSColor(red: 0.07, green: 0.26, blue: 0.33, alpha: 0.6),
        ansiColors: [
            NSColor(red: 0.03, green: 0.21, blue: 0.26, alpha: 1.0),  // 0
            NSColor(red: 0.86, green: 0.20, blue: 0.18, alpha: 1.0),  // 1
            NSColor(red: 0.52, green: 0.60, blue: 0.00, alpha: 1.0),  // 2
            NSColor(red: 0.71, green: 0.54, blue: 0.00, alpha: 1.0),  // 3
            NSColor(red: 0.15, green: 0.55, blue: 0.82, alpha: 1.0),  // 4
            NSColor(red: 0.83, green: 0.21, blue: 0.51, alpha: 1.0),  // 5
            NSColor(red: 0.16, green: 0.63, blue: 0.60, alpha: 1.0),  // 6
            NSColor(red: 0.93, green: 0.91, blue: 0.84, alpha: 1.0),  // 7
            NSColor(red: 0.00, green: 0.27, blue: 0.33, alpha: 1.0),  // 8
            NSColor(red: 0.80, green: 0.29, blue: 0.09, alpha: 1.0),  // 9
            NSColor(red: 0.35, green: 0.43, blue: 0.46, alpha: 1.0),  // 10
            NSColor(red: 0.40, green: 0.48, blue: 0.51, alpha: 1.0),  // 11
            NSColor(red: 0.51, green: 0.58, blue: 0.59, alpha: 1.0),  // 12
            NSColor(red: 0.42, green: 0.44, blue: 0.77, alpha: 1.0),  // 13
            NSColor(red: 0.58, green: 0.63, blue: 0.63, alpha: 1.0),  // 14
            NSColor(red: 0.99, green: 0.96, blue: 0.89, alpha: 1.0),  // 15
        ]
    )

    static let dracula = TerminalTheme(
        id: "dracula",
        name: "Dracula",
        background: NSColor(red: 0.16, green: 0.16, blue: 0.21, alpha: 1.0),
        foreground: NSColor(red: 0.97, green: 0.97, blue: 0.95, alpha: 1.0),
        cursor: NSColor(red: 0.97, green: 0.97, blue: 0.95, alpha: 1.0),
        selection: NSColor(red: 0.27, green: 0.28, blue: 0.35, alpha: 0.6),
        ansiColors: [
            NSColor(red: 0.13, green: 0.14, blue: 0.18, alpha: 1.0),  // 0
            NSColor(red: 1.00, green: 0.33, blue: 0.33, alpha: 1.0),  // 1
            NSColor(red: 0.31, green: 0.98, blue: 0.48, alpha: 1.0),  // 2
            NSColor(red: 0.95, green: 0.98, blue: 0.48, alpha: 1.0),  // 3
            NSColor(red: 0.74, green: 0.58, blue: 0.98, alpha: 1.0),  // 4
            NSColor(red: 1.00, green: 0.47, blue: 0.66, alpha: 1.0),  // 5
            NSColor(red: 0.55, green: 0.91, blue: 0.99, alpha: 1.0),  // 6
            NSColor(red: 0.97, green: 0.97, blue: 0.95, alpha: 1.0),  // 7
            NSColor(red: 0.33, green: 0.34, blue: 0.44, alpha: 1.0),  // 8
            NSColor(red: 1.00, green: 0.42, blue: 0.42, alpha: 1.0),  // 9
            NSColor(red: 0.41, green: 1.00, blue: 0.57, alpha: 1.0),  // 10
            NSColor(red: 1.00, green: 1.00, blue: 0.60, alpha: 1.0),  // 11
            NSColor(red: 0.82, green: 0.68, blue: 1.00, alpha: 1.0),  // 12
            NSColor(red: 1.00, green: 0.57, blue: 0.75, alpha: 1.0),  // 13
            NSColor(red: 0.65, green: 0.95, blue: 1.00, alpha: 1.0),  // 14
            NSColor(red: 1.00, green: 1.00, blue: 1.00, alpha: 1.0),  // 15
        ]
    )

    static let monokai = TerminalTheme(
        id: "monokai",
        name: "Monokai",
        background: NSColor(red: 0.16, green: 0.16, blue: 0.14, alpha: 1.0),
        foreground: NSColor(red: 0.97, green: 0.97, blue: 0.94, alpha: 1.0),
        cursor: NSColor(red: 0.97, green: 0.97, blue: 0.94, alpha: 1.0),
        selection: NSColor(red: 0.29, green: 0.30, blue: 0.27, alpha: 0.6),
        ansiColors: [
            NSColor(red: 0.15, green: 0.16, blue: 0.13, alpha: 1.0),  // 0
            NSColor(red: 0.98, green: 0.15, blue: 0.45, alpha: 1.0),  // 1
            NSColor(red: 0.65, green: 0.88, blue: 0.18, alpha: 1.0),  // 2
            NSColor(red: 0.90, green: 0.86, blue: 0.45, alpha: 1.0),  // 3
            NSColor(red: 0.40, green: 0.85, blue: 0.94, alpha: 1.0),  // 4
            NSColor(red: 0.68, green: 0.51, blue: 1.00, alpha: 1.0),  // 5
            NSColor(red: 0.65, green: 0.88, blue: 0.18, alpha: 1.0),  // 6
            NSColor(red: 0.97, green: 0.97, blue: 0.94, alpha: 1.0),  // 7
            NSColor(red: 0.46, green: 0.44, blue: 0.37, alpha: 1.0),  // 8
            NSColor(red: 0.95, green: 0.07, blue: 0.31, alpha: 1.0),  // 9
            NSColor(red: 0.65, green: 0.88, blue: 0.18, alpha: 1.0),  // 10
            NSColor(red: 0.90, green: 0.86, blue: 0.45, alpha: 1.0),  // 11
            NSColor(red: 0.40, green: 0.85, blue: 0.94, alpha: 1.0),  // 12
            NSColor(red: 0.68, green: 0.51, blue: 1.00, alpha: 1.0),  // 13
            NSColor(red: 0.65, green: 0.88, blue: 0.18, alpha: 1.0),  // 14
            NSColor(red: 1.00, green: 1.00, blue: 1.00, alpha: 1.0),  // 15
        ]
    )

    static let nord = TerminalTheme(
        id: "nord",
        name: "Nord",
        background: NSColor(red: 0.18, green: 0.20, blue: 0.25, alpha: 1.0),
        foreground: NSColor(red: 0.85, green: 0.87, blue: 0.91, alpha: 1.0),
        cursor: NSColor(red: 0.85, green: 0.87, blue: 0.91, alpha: 1.0),
        selection: NSColor(red: 0.26, green: 0.30, blue: 0.37, alpha: 0.6),
        ansiColors: [
            NSColor(red: 0.23, green: 0.26, blue: 0.32, alpha: 1.0),  // 0
            NSColor(red: 0.75, green: 0.38, blue: 0.42, alpha: 1.0),  // 1
            NSColor(red: 0.64, green: 0.75, blue: 0.55, alpha: 1.0),  // 2
            NSColor(red: 0.92, green: 0.80, blue: 0.55, alpha: 1.0),  // 3
            NSColor(red: 0.51, green: 0.63, blue: 0.76, alpha: 1.0),  // 4
            NSColor(red: 0.71, green: 0.56, blue: 0.68, alpha: 1.0),  // 5
            NSColor(red: 0.53, green: 0.75, blue: 0.82, alpha: 1.0),  // 6
            NSColor(red: 0.91, green: 0.93, blue: 0.94, alpha: 1.0),  // 7
            NSColor(red: 0.30, green: 0.34, blue: 0.42, alpha: 1.0),  // 8
            NSColor(red: 0.75, green: 0.38, blue: 0.42, alpha: 1.0),  // 9
            NSColor(red: 0.64, green: 0.75, blue: 0.55, alpha: 1.0),  // 10
            NSColor(red: 0.92, green: 0.80, blue: 0.55, alpha: 1.0),  // 11
            NSColor(red: 0.51, green: 0.63, blue: 0.76, alpha: 1.0),  // 12
            NSColor(red: 0.71, green: 0.56, blue: 0.68, alpha: 1.0),  // 13
            NSColor(red: 0.56, green: 0.74, blue: 0.73, alpha: 1.0),  // 14
            NSColor(red: 0.93, green: 0.94, blue: 0.96, alpha: 1.0),  // 15
        ]
    )

    /// All available themes.
    static let allThemes: [TerminalTheme] = [
        .defaultDark, .solarizedDark, .dracula, .monokai, .nord
    ]

    /// Look up a theme by ID.
    static func theme(forId id: String) -> TerminalTheme {
        allThemes.first { $0.id == id } ?? .defaultDark
    }
}
