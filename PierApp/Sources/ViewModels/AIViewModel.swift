import Foundation
import Combine

/// LLM provider protocol for streaming chat completions.
protocol LLMProvider {
    func sendMessage(messages: [AIMessage], model: String) -> AsyncThrowingStream<String, Error>
}

/// A single message in the AI conversation.
struct AIMessage: Identifiable, Equatable {
    let id: UUID
    let role: AIRole
    var content: String
    let timestamp: Date

    init(role: AIRole, content: String) {
        self.id = UUID()
        self.role = role
        self.content = content
        self.timestamp = Date()
    }
}

enum AIRole: String, Codable {
    case system
    case user
    case assistant
}

/// View model for AI chat panel.
@MainActor
class AIViewModel: ObservableObject {
    @Published var messages: [AIMessage] = []
    @Published var inputText: String = ""
    @Published var isStreaming: Bool = false
    @Published var errorMessage: String?

    private var currentTask: Task<Void, Never>?
    private let provider: LLMProvider

    init(provider: LLMProvider? = nil) {
        self.provider = provider ?? OpenAIProvider()
    }

    deinit {
        currentTask?.cancel()
    }

    // MARK: - Send Message

    /// Send a user message and stream the AI response.
    func sendMessage() {
        let text = inputText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }

        let userMsg = AIMessage(role: .user, content: text)
        messages.append(userMsg)
        inputText = ""
        isStreaming = true
        errorMessage = nil

        // Create assistant placeholder
        let assistantMsg = AIMessage(role: .assistant, content: "")
        messages.append(assistantMsg)
        let assistantIndex = messages.count - 1

        let allMessages = messages.dropLast() // exclude empty assistant placeholder
        let sendMessages = Array(allMessages)

        currentTask = Task {
            do {
                let model = UserDefaults.standard.string(forKey: "llmModel") ?? "gpt-4"
                let stream = provider.sendMessage(messages: sendMessages, model: model)

                for try await chunk in stream {
                    guard !Task.isCancelled else { break }
                    messages[assistantIndex].content += chunk
                }
            } catch {
                if !Task.isCancelled {
                    errorMessage = error.localizedDescription
                }
            }

            isStreaming = false
        }
    }

    /// Cancel the current streaming response.
    func cancelStreaming() {
        currentTask?.cancel()
        currentTask = nil
        isStreaming = false
    }

    /// Clear conversation.
    func clearConversation() {
        messages.removeAll()
        errorMessage = nil
    }

    // MARK: - Quick Actions

    /// Generate a shell command from a natural language description.
    func generateCommand(_ description: String) {
        let systemPrompt = """
        You are a shell command expert. Generate the exact shell command for the user's request.
        Only output the command itself with no explanation. If multiple commands are needed, separate with && or ;.
        """
        let systemMsg = AIMessage(role: .system, content: systemPrompt)
        let userMsg = AIMessage(role: .user, content: description)
        messages = [systemMsg, userMsg]

        let assistantMsg = AIMessage(role: .assistant, content: "")
        messages.append(assistantMsg)
        let idx = messages.count - 1
        isStreaming = true

        currentTask = Task {
            do {
                let model = UserDefaults.standard.string(forKey: "llmModel") ?? "gpt-4"
                let stream = provider.sendMessage(messages: [systemMsg, userMsg], model: model)
                for try await chunk in stream {
                    guard !Task.isCancelled else { break }
                    messages[idx].content += chunk
                }
            } catch {
                errorMessage = error.localizedDescription
            }
            isStreaming = false
        }
    }

    /// Explain what a shell command does.
    func explainCommand(_ command: String) {
        let systemPrompt = """
        You are a shell command expert. Explain what the following command does, step by step.
        Be concise but thorough. Format in markdown.
        """
        let systemMsg = AIMessage(role: .system, content: systemPrompt)
        let userMsg = AIMessage(role: .user, content: command)
        messages = [systemMsg, userMsg]

        let assistantMsg = AIMessage(role: .assistant, content: "")
        messages.append(assistantMsg)
        let idx = messages.count - 1
        isStreaming = true

        currentTask = Task {
            do {
                let model = UserDefaults.standard.string(forKey: "llmModel") ?? "gpt-4"
                let stream = provider.sendMessage(messages: [systemMsg, userMsg], model: model)
                for try await chunk in stream {
                    guard !Task.isCancelled else { break }
                    messages[idx].content += chunk
                }
            } catch {
                errorMessage = error.localizedDescription
            }
            isStreaming = false
        }
    }

    /// Analyze a shell error and suggest fixes.
    func analyzeError(_ error: String, context: String = "") {
        let systemPrompt = """
        You are a devops expert. Analyze the following shell error and provide:
        1. What went wrong
        2. The likely cause
        3. How to fix it
        Be concise. Format in markdown.
        """
        let contextStr = context.isEmpty ? error : "Error:\n\(error)\n\nContext:\n\(context)"
        let systemMsg = AIMessage(role: .system, content: systemPrompt)
        let userMsg = AIMessage(role: .user, content: contextStr)
        messages = [systemMsg, userMsg]

        let assistantMsg = AIMessage(role: .assistant, content: "")
        messages.append(assistantMsg)
        let idx = messages.count - 1
        isStreaming = true

        currentTask = Task {
            do {
                let model = UserDefaults.standard.string(forKey: "llmModel") ?? "gpt-4"
                let stream = provider.sendMessage(messages: [systemMsg, userMsg], model: model)
                for try await chunk in stream {
                    guard !Task.isCancelled else { break }
                    messages[idx].content += chunk
                }
            } catch {
                errorMessage = error.localizedDescription
            }
            isStreaming = false
        }
    }
}

// MARK: - OpenAI Provider

/// OpenAI-compatible streaming provider (works with OpenAI, Azure, local proxies).
struct OpenAIProvider: LLMProvider {
    func sendMessage(messages: [AIMessage], model: String) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            Task {
                do {
                    guard let apiKey = try? KeychainService.shared.load(key: "llm_api_key"),
                          !apiKey.isEmpty else {
                        continuation.finish(throwing: AIError.noApiKey)
                        return
                    }

                    let provider = UserDefaults.standard.string(forKey: "llmProvider") ?? "openai"
                    let baseURL: String
                    switch provider {
                    case "ollama":
                        baseURL = "http://localhost:11434/v1/chat/completions"
                    default:
                        baseURL = "https://api.openai.com/v1/chat/completions"
                    }

                    guard let url = URL(string: baseURL) else {
                        continuation.finish(throwing: AIError.invalidURL)
                        return
                    }

                    var request = URLRequest(url: url)
                    request.httpMethod = "POST"
                    request.setValue("application/json", forHTTPHeaderField: "Content-Type")

                    if provider != "ollama" {
                        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
                    }

                    let body: [String: Any] = [
                        "model": model,
                        "messages": messages.map { ["role": $0.role.rawValue, "content": $0.content] },
                        "stream": true,
                    ]
                    request.httpBody = try JSONSerialization.data(withJSONObject: body)

                    let (bytes, response) = try await URLSession.shared.bytes(for: request)

                    guard let httpResponse = response as? HTTPURLResponse,
                          httpResponse.statusCode == 200 else {
                        let statusCode = (response as? HTTPURLResponse)?.statusCode ?? 0
                        continuation.finish(throwing: AIError.httpError(statusCode))
                        return
                    }

                    // Parse SSE stream
                    for try await line in bytes.lines {
                        if Task.isCancelled {
                            continuation.finish()
                            return
                        }

                        guard line.hasPrefix("data: ") else { continue }
                        let data = String(line.dropFirst(6))

                        if data == "[DONE]" { break }

                        guard let jsonData = data.data(using: .utf8),
                              let json = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any],
                              let choices = json["choices"] as? [[String: Any]],
                              let delta = choices.first?["delta"] as? [String: Any],
                              let content = delta["content"] as? String else {
                            continue
                        }

                        continuation.yield(content)
                    }

                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
        }
    }
}

/// AI-related errors.
enum AIError: LocalizedError {
    case noApiKey
    case invalidURL
    case httpError(Int)

    var errorDescription: String? {
        switch self {
        case .noApiKey: return "No API key configured. Set it in Settings → AI."
        case .invalidURL: return "Invalid API URL."
        case .httpError(let code): return "HTTP error: \(code)"
        }
    }
}
