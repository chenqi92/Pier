import Foundation

/// Service for interacting with LLM providers (OpenAI, Claude, Ollama).
@MainActor
class LLMService: ObservableObject {
    enum Provider: String {
        case openai
        case claude
        case ollama
    }

    @Published var isLoading = false
    @Published var lastResponse: String?

    private var provider: Provider = .openai
    private var apiKey: String = ""
    private var model: String = "gpt-4"
    private var baseURL: URL?

    init() {
        loadConfiguration()
    }

    // MARK: - Configuration

    func loadConfiguration() {
        let defaults = UserDefaults.standard
        provider = Provider(rawValue: defaults.string(forKey: "llmProvider") ?? "openai") ?? .openai
        // Read API key from Keychain (secure), not UserDefaults (plaintext)
        apiKey = (try? KeychainService.shared.load(key: "llm_api_key")) ?? ""
        model = defaults.string(forKey: "llmModel") ?? "gpt-4"

        switch provider {
        case .openai:
            baseURL = URL(string: "https://api.openai.com/v1")
        case .claude:
            baseURL = URL(string: "https://api.anthropic.com/v1")
        case .ollama:
            baseURL = URL(string: "http://localhost:11434/api")
        }
    }

    // MARK: - Chat

    /// Send a prompt to the LLM with terminal context.
    func sendPrompt(
        _ prompt: String,
        context: TerminalContext? = nil,
        onChunk: @escaping (String) -> Void,
        onComplete: @escaping (Result<String, Error>) -> Void
    ) {
        isLoading = true

        var systemMessage = """
        You are an expert shell assistant for macOS. Help the user with terminal commands.
        Be concise and provide executable commands when possible.
        """

        if let ctx = context {
            systemMessage += "\nCurrent directory: \(ctx.currentDirectory)"
            systemMessage += "\nOS: macOS"
            if let lastCmd = ctx.lastCommand {
                systemMessage += "\nLast command: \(lastCmd)"
            }
            if let lastErr = ctx.lastError {
                systemMessage += "\nLast error: \(lastErr)"
            }
        }

        Task {
            do {
                let response = try await callAPI(system: systemMessage, prompt: prompt)
                await MainActor.run {
                    self.lastResponse = response
                    self.isLoading = false
                    onComplete(.success(response))
                }
            } catch {
                await MainActor.run {
                    self.isLoading = false
                    onComplete(.failure(error))
                }
            }
        }
    }

    // MARK: - API Calls

    private func callAPI(system: String, prompt: String) async throws -> String {
        guard let baseURL = baseURL else {
            throw LLMError.notConfigured
        }

        switch provider {
        case .openai:
            return try await callOpenAI(baseURL: baseURL, system: system, prompt: prompt)
        case .claude:
            return try await callClaude(baseURL: baseURL, system: system, prompt: prompt)
        case .ollama:
            return try await callOllama(baseURL: baseURL, system: system, prompt: prompt)
        }
    }

    private func callOpenAI(baseURL: URL, system: String, prompt: String) async throws -> String {
        let url = baseURL.appendingPathComponent("chat/completions")
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let body: [String: Any] = [
            "model": model,
            "messages": [
                ["role": "system", "content": system],
                ["role": "user", "content": prompt],
            ],
            "temperature": 0.3,
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, _) = try await URLSession.shared.data(for: request)
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        let choices = json?["choices"] as? [[String: Any]]
        let message = choices?.first?["message"] as? [String: Any]
        return message?["content"] as? String ?? "No response"
    }

    private func callClaude(baseURL: URL, system: String, prompt: String) async throws -> String {
        let url = baseURL.appendingPathComponent("messages")
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")

        let body: [String: Any] = [
            "model": model,
            "max_tokens": 1024,
            "system": system,
            "messages": [
                ["role": "user", "content": prompt],
            ],
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, _) = try await URLSession.shared.data(for: request)
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        let content = json?["content"] as? [[String: Any]]
        return content?.first?["text"] as? String ?? "No response"
    }

    private func callOllama(baseURL: URL, system: String, prompt: String) async throws -> String {
        let url = baseURL.appendingPathComponent("generate")
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let body: [String: Any] = [
            "model": model,
            "system": system,
            "prompt": prompt,
            "stream": false,
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, _) = try await URLSession.shared.data(for: request)
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        return json?["response"] as? String ?? "No response"
    }
}

// MARK: - Supporting Types

struct TerminalContext {
    let currentDirectory: String
    let lastCommand: String?
    let lastError: String?
    let shellType: String
}

enum LLMError: LocalizedError {
    case notConfigured
    case apiError(String)

    var errorDescription: String? {
        switch self {
        case .notConfigured: return "LLM provider not configured"
        case .apiError(let msg): return "API error: \(msg)"
        }
    }
}
