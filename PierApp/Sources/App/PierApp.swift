import SwiftUI
import CPierCore

/// Pier Terminal — macOS XShell-like terminal application.
@main
struct PierApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @StateObject private var serviceManager = RemoteServiceManager()

    var body: some Scene {
        WindowGroup {
            MainView()
                .environmentObject(serviceManager)
                .frame(minWidth: 1200, minHeight: 700)
        }
        .windowStyle(.titleBar)
        .windowToolbarStyle(.unified(showsTitle: true))
        .defaultSize(width: 1400, height: 900)
        .commands {
            // Custom menu items
            CommandGroup(after: .newItem) {
                Button("settings.newTerminalTab") {
                    NotificationCenter.default.post(name: .newTerminalTab, object: nil)
                }
                .keyboardShortcut("t", modifiers: .command)

                Button("settings.newSSHConnection") {
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

// Settings view is now in Views/SettingsView.swift

struct AISettingsView: View {
    @AppStorage("llmProvider") var llmProvider = "openai"
    @AppStorage("llmModel") var llmModel = "gpt-4"
    @State private var apiKeyField = ""
    @State private var saveStatus: String?

    var body: some View {
        Form {
            Picker("Provider:", selection: $llmProvider) {
                Text("OpenAI").tag("openai")
                Text("Claude").tag("claude")
                Text("Ollama (Local)").tag("ollama")
            }
            SecureField("API Key:", text: $apiKeyField)
                .onChange(of: apiKeyField) { _, newValue in
                    guard !newValue.isEmpty else { return }
                    do {
                        try KeychainService.shared.save(key: "llm_api_key", value: newValue)
                        saveStatus = String(localized: "settings.keySaved")
                    } catch {
                        saveStatus = "❌ \(error.localizedDescription)"
                    }
                }
            TextField("Model:", text: $llmModel)
            if let status = saveStatus {
                Text(status)
                    .font(.caption)
                    .foregroundColor(status.hasPrefix("✅") ? .green : .red)
            }
        }
        .padding()
        .onAppear {
            // Load existing key (show placeholder dots, not actual value)
            if let key = try? KeychainService.shared.load(key: "llm_api_key"), key != nil {
                apiKeyField = "••••••••"
            }
        }
    }
}

// MARK: - Notification Names

extension Notification.Name {
    static let newTerminalTab = Notification.Name("pier.newTerminalTab")
    static let newSSHConnection = Notification.Name("pier.newSSHConnection")
}
