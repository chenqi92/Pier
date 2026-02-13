import SwiftUI
import CPierCore

/// Pier Terminal — macOS XShell-like terminal application.
@main
struct PierApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        WindowGroup {
            MainView()
                .frame(minWidth: 1200, minHeight: 700)
                .onAppear {
                    // Initialize Rust core
                    pier_init()
                }
        }
        .windowStyle(.titleBar)
        .windowToolbarStyle(.unified(showsTitle: true))
        .defaultSize(width: 1400, height: 900)
        .commands {
            // Custom menu items
            CommandGroup(after: .newItem) {
                Button("New Terminal Tab") {
                    NotificationCenter.default.post(name: .newTerminalTab, object: nil)
                }
                .keyboardShortcut("t", modifiers: .command)

                Button("New SSH Connection") {
                    NotificationCenter.default.post(name: .newSSHConnection, object: nil)
                }
                .keyboardShortcut("k", modifiers: [.command, .shift])
            }
        }

        Settings {
            SettingsView()
        }
    }
}

/// Settings view placeholder.
struct SettingsView: View {
    var body: some View {
        TabView {
            GeneralSettingsView()
                .tabItem { Label("General", systemImage: "gear") }
            AppearanceSettingsView()
                .tabItem { Label("Appearance", systemImage: "paintpalette") }
            ConnectionSettingsView()
                .tabItem { Label("Connections", systemImage: "network") }
            AISettingsView()
                .tabItem { Label("AI", systemImage: "brain") }
        }
        .frame(width: 500, height: 400)
    }
}

struct GeneralSettingsView: View {
    @AppStorage("defaultShell") var defaultShell = "/bin/zsh"

    var body: some View {
        Form {
            TextField("Default Shell:", text: $defaultShell)
        }
        .padding()
    }
}

struct AppearanceSettingsView: View {
    @AppStorage("fontSize") var fontSize: Double = 13
    @AppStorage("fontFamily") var fontFamily = "SF Mono"

    var body: some View {
        Form {
            Slider(value: $fontSize, in: 8...24, step: 1) {
                Text("Font Size: \(Int(fontSize))")
            }
            TextField("Font Family:", text: $fontFamily)
        }
        .padding()
    }
}

struct ConnectionSettingsView: View {
    var body: some View {
        Text("SSH Connection Profiles")
            .padding()
    }
}

struct AISettingsView: View {
    @AppStorage("llmProvider") var llmProvider = "openai"
    @AppStorage("llmApiKey") var llmApiKey = ""
    @AppStorage("llmModel") var llmModel = "gpt-4"

    var body: some View {
        Form {
            Picker("Provider:", selection: $llmProvider) {
                Text("OpenAI").tag("openai")
                Text("Claude").tag("claude")
                Text("Ollama (Local)").tag("ollama")
            }
            SecureField("API Key:", text: $llmApiKey)
            TextField("Model:", text: $llmModel)
        }
        .padding()
    }
}

// MARK: - Notification Names

extension Notification.Name {
    static let newTerminalTab = Notification.Name("pier.newTerminalTab")
    static let newSSHConnection = Notification.Name("pier.newSSHConnection")
}
