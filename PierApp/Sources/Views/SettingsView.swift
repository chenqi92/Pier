import SwiftUI

/// Application preferences/settings panel.
struct SettingsView: View {
    @ObservedObject private var themeManager = AppThemeManager.shared
    @State private var selectedSection: SettingsSection = .general

    enum SettingsSection: String, CaseIterable, Identifiable {
        case general = "settings.general"
        case terminal = "settings.terminal"
        case shortcuts = "settings.shortcuts"

        var id: String { rawValue }

        var icon: String {
            switch self {
            case .general: return "gear"
            case .terminal: return "terminal"
            case .shortcuts: return "keyboard"
            }
        }
    }

    var body: some View {
        HSplitView {
            // Section sidebar
            List(SettingsSection.allCases, selection: $selectedSection) { section in
                Label(LS(section.rawValue), systemImage: section.icon)
                    .tag(section)
            }
            .listStyle(.sidebar)
            .frame(width: 160)

            // Content
            ScrollView {
                switch selectedSection {
                case .general:
                    generalSettings
                case .terminal:
                    terminalSettings
                case .shortcuts:
                    shortcutsSettings
                }
            }
            .frame(minWidth: 400)
            .padding()
        }
        .frame(minWidth: 560, minHeight: 400)
    }

    // MARK: - General

    private var generalSettings: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text(LS("settings.general"))
                .font(.title2)
                .fontWeight(.bold)

            GroupBox(label: Text(LS("theme.appearance"))) {
                VStack(alignment: .leading, spacing: 12) {
                    Picker(LS("theme.mode"), selection: $themeManager.appearanceMode) {
                        ForEach(AppearanceMode.allCases) { mode in
                            Text(mode.displayName).tag(mode)
                        }
                    }
                    .pickerStyle(.segmented)
                    .frame(maxWidth: 300)
                }
                .padding(8)
            }

            GroupBox(LS("settings.language")) {
                VStack(alignment: .leading, spacing: 8) {
                    Picker(LS("settings.language"), selection: $themeManager.languageMode) {
                        ForEach(LanguageMode.allCases) { lang in
                            Text(lang.displayName).tag(lang)
                        }
                    }
                    .pickerStyle(.segmented)
                    .frame(maxWidth: 300)

                    Text(LS("settings.restartHint"))
                        .font(.system(size: 10))
                        .foregroundColor(.secondary)
                }
                .padding(8)
            }

            GroupBox(label: Text(LS("settings.font"))) {
                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        Text(LS("settings.fontFamily"))
                            .font(.caption)
                        Spacer()
                        Picker("", selection: $themeManager.fontFamily) {
                            ForEach(themeManager.availableFonts, id: \.name) { font in
                                Text(font.name + (font.installed ? "" : " ⚠️"))
                                    .tag(font.name)
                            }
                        }
                        .frame(width: 200)
                    }

                    HStack {
                        Text(LS("settings.fontSize"))
                            .font(.caption)
                        Spacer()
                        Slider(value: $themeManager.fontSize, in: 10...24, step: 1)
                            .frame(width: 150)
                        Text("\(Int(themeManager.fontSize))pt")
                            .font(.caption)
                            .foregroundColor(.secondary)
                            .frame(width: 32)
                    }

                    // Preview
                    Text(LS("settings.fontPreview"))
                        .font(Font.custom(themeManager.fontFamily, size: CGFloat(themeManager.fontSize)))
                        .padding(8)
                        .background(Color(nsColor: .textBackgroundColor))
                        .cornerRadius(4)
                }
                .padding(8)
            }

            Spacer()
        }
    }

    // MARK: - Terminal

    private var terminalSettings: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                Text(LS("settings.terminal"))
                    .font(.title2)
                    .fontWeight(.bold)

                // Terminal Theme
                GroupBox(label: Text(LS("theme.terminal"))) {
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(TerminalTheme.allThemes, id: \.id) { theme in
                            themeRow(theme)
                        }
                    }
                    .padding(8)
                }

                // Cursor
                GroupBox(label: Text(LS("settings.cursor"))) {
                    VStack(alignment: .leading, spacing: 12) {
                        HStack {
                            Text(LS("settings.cursorStyle"))
                                .font(.caption)
                            Spacer()
                            Picker("", selection: $themeManager.cursorStyle) {
                                ForEach(CursorStyle.allCases) { style in
                                    Text(style.displayName).tag(style)
                                }
                            }
                            .labelsHidden()
                            .pickerStyle(.segmented)
                            .frame(maxWidth: 240)
                        }

                        Toggle(LS("settings.cursorBlink"), isOn: $themeManager.cursorBlink)
                            .font(.caption)
                    }
                    .padding(8)
                }

                // Appearance
                GroupBox(label: Text(LS("settings.terminalAppearance"))) {
                    VStack(alignment: .leading, spacing: 12) {
                        HStack {
                            Text(LS("settings.backgroundOpacity"))
                                .font(.caption)
                            Spacer()
                            Slider(value: $themeManager.terminalOpacity, in: 0.3...1.0, step: 0.05)
                                .frame(maxWidth: 180)
                            Text("\(Int(themeManager.terminalOpacity * 100))%")
                                .font(.caption2)
                                .foregroundColor(.secondary)
                                .frame(width: 32)
                        }

                        Toggle(LS("settings.backgroundBlur"), isOn: $themeManager.terminalBlur)
                            .font(.caption)

                        Toggle(LS("settings.fontLigatures"), isOn: $themeManager.fontLigatures)
                            .font(.caption)
                    }
                    .padding(8)
                }

                Spacer()
            }
        }
    }

    private func themeRow(_ theme: TerminalTheme) -> some View {
        let isSelected = themeManager.terminalThemeId == theme.id

        return HStack {
            themeSwatchView(theme)

            Text(theme.name)
                .font(.caption)

            Spacer()

            if isSelected {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundColor(.green)
                    .font(.caption)
            }
        }
        .padding(.vertical, 4)
        .padding(.horizontal, 8)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(isSelected ? Color.accentColor.opacity(0.1) : Color.clear)
        )
        .contentShape(Rectangle())
        .onTapGesture {
            themeManager.setTerminalTheme(theme.id)
        }
    }

    private func themeSwatchView(_ theme: TerminalTheme) -> some View {
        HStack(spacing: 2) {
            Circle().fill(Color(nsColor: theme.background)).frame(width: 14, height: 14)
            Circle().fill(Color(nsColor: theme.foreground)).frame(width: 14, height: 14)
            Circle().fill(Color(nsColor: theme.cursor)).frame(width: 14, height: 14)
            Circle().fill(Color(nsColor: theme.ansiColors[1])).frame(width: 14, height: 14)
            Circle().fill(Color(nsColor: theme.ansiColors[2])).frame(width: 14, height: 14)
            Circle().fill(Color(nsColor: theme.ansiColors[4])).frame(width: 14, height: 14)
        }
    }

    // MARK: - Keyboard Shortcuts

    private var shortcutsSettings: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text(LS("settings.shortcuts"))
                .font(.title2)
                .fontWeight(.bold)

            GroupBox(label: Text(LS("settings.keyboardShortcuts"))) {
                VStack(spacing: 0) {
                    shortcutRow("settings.newTab", shortcut: "⌘T")
                    Divider()
                    shortcutRow("settings.closeTab", shortcut: "⌘W")
                    Divider()
                    shortcutRow("settings.runQuery", shortcut: "⌘⏎")
                    Divider()
                    shortcutRow("settings.toggleSidebar", shortcut: "⌘B")
                    Divider()
                    shortcutRow("settings.togglePanel", shortcut: "⌘J")
                    Divider()
                    shortcutRow("settings.clearTerminal", shortcut: "⌘K")
                    Divider()
                    shortcutRow("settings.copy", shortcut: "⌘C")
                    Divider()
                    shortcutRow("settings.paste", shortcut: "⌘V")
                    Divider()
                    shortcutRow("settings.find", shortcut: "⌘F")
                    Divider()
                    shortcutRow("settings.preferences", shortcut: "⌘,")
                }
                .padding(4)
            }

            Spacer()
        }
    }

    private func shortcutRow(_ label: String, shortcut: String) -> some View {
        HStack {
            Text(LS(label))
                .font(.caption)
            Spacer()
            Text(shortcut)
                .font(.system(size: 11, design: .monospaced))
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(Color(nsColor: .controlBackgroundColor))
                .cornerRadius(4)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
    }
}
