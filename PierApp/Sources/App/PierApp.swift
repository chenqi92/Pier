import SwiftUI
import CPierCore

/// Pier Terminal — macOS XShell-like terminal application.
/// Entry point is main.swift, which sets AppleLanguages before calling PierApp.main().
struct PierApp: App {
    init() {
    }

    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @StateObject private var serviceManager = RemoteServiceManager()

    @State private var showAbout = false

    var body: some Scene {
        WindowGroup {
            MainView()
                .environmentObject(serviceManager)
                .frame(minWidth: 1200, minHeight: 700)
                .sheet(isPresented: $showAbout) {
                    AboutView()
                }
        }
        .windowStyle(.titleBar)
        .windowToolbarStyle(.unified(showsTitle: true))
        .defaultSize(width: 1400, height: 900)
        .commands {
            // Replace About menu
            CommandGroup(replacing: .appInfo) {
                Button(LS("about.menuItem")) {
                    showAbout = true
                }
            }

            // Custom menu items
            CommandGroup(after: .newItem) {
                Button(LS("settings.newTerminalTab")) {
                    NotificationCenter.default.post(name: .newTerminalTab, object: nil)
                }
                .keyboardShortcut("t", modifiers: .command)

                Button(LS("settings.newSSHConnection")) {
                    NotificationCenter.default.post(name: .newSSHConnection, object: nil)
                }
                .keyboardShortcut("k", modifiers: [.command, .shift])
            }

            // Help menu
            CommandGroup(replacing: .help) {
                Button(LS("help.quickStart")) {
                    if let url = URL(string: "https://github.com/chenqi92/Pier/wiki") {
                        NSWorkspace.shared.open(url)
                    }
                }

                Button(LS("help.shortcuts")) {
                    NotificationCenter.default.post(name: .showKeyboardShortcuts, object: nil)
                }
                .keyboardShortcut("/", modifiers: .command)

                Divider()

                Button(LS("help.feedback")) {
                    if let url = URL(string: "https://github.com/chenqi92/Pier/issues") {
                        NSWorkspace.shared.open(url)
                    }
                }

                Button(LS("help.github")) {
                    if let url = URL(string: "https://github.com/chenqi92/Pier") {
                        NSWorkspace.shared.open(url)
                    }
                }

                Divider()

                Button(LS("help.website")) {
                    if let url = URL(string: "https://kkape.com") {
                        NSWorkspace.shared.open(url)
                    }
                }
            }
        }

        Settings {
            SettingsView()
        }
    }
}

// Settings view is now in Views/SettingsView.swift

struct AISettingsView: View {
    @AppStorage("llmProvider") var llmProvider = "openai"
    @AppStorage("llmModel") var llmModel = "gpt-4"
    @State private var apiKeyField = ""
    @State private var saveStatus: String?

    var body: some View {
        Form {
            Picker(LS("ai.provider"), selection: $llmProvider) {
                Text(LS("ai.providerOpenAI")).tag("openai")
                Text(LS("ai.providerClaude")).tag("claude")
                Text(LS("ai.providerOllama")).tag("ollama")
            }
            SecureField(LS("ai.apiKey"), text: $apiKeyField)
                .onChange(of: apiKeyField) { _, newValue in
                    guard !newValue.isEmpty else { return }
                    do {
                        try KeychainService.shared.save(key: "llm_api_key", value: newValue)
                        saveStatus = LS("settings.keySaved")
                    } catch {
                        saveStatus = "❌ \(error.localizedDescription)"
                    }
                }
            TextField(LS("ai.model"), text: $llmModel)
            if let status = saveStatus {
                Text(status)
                    .font(.caption)
                    .foregroundColor(status.hasPrefix("✅") ? .green : .red)
            }
        }
        .padding()
        .onAppear {
            // Load existing key (show placeholder dots, not actual value)
            if let _ = try? KeychainService.shared.load(key: "llm_api_key") {
                apiKeyField = "••••••••"
            }
        }
    }
}

// MARK: - Notification Names

extension Notification.Name {
    static let newTerminalTab = Notification.Name("pier.newTerminalTab")
    static let newSSHConnection = Notification.Name("pier.newSSHConnection")
    static let showNewTabChooser = Notification.Name("pier.showNewTabChooser")
    static let showKeyboardShortcuts = Notification.Name("pier.showKeyboardShortcuts")
    // Terminal pane split/close (from NSView right-click menu)
    static let terminalSplitH = Notification.Name("pier.terminalSplitH")
    static let terminalSplitV = Notification.Name("pier.terminalSplitV")
    static let terminalClosePane = Notification.Name("pier.terminalClosePane")
}
