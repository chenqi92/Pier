import SwiftUI

/// AI chat panel for the right sidebar.
struct AIChatView: View {
    @StateObject private var viewModel = AIViewModel()

    var body: some View {
        VStack(spacing: 0) {
            // Header
            chatHeader

            Divider()

            // Messages
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 12) {
                        ForEach(viewModel.messages.filter { $0.role != .system }) { message in
                            chatBubble(message)
                                .id(message.id)
                        }
                    }
                    .padding(12)
                }
                .onChange(of: viewModel.messages.count) { _, _ in
                    if let last = viewModel.messages.last {
                        withAnimation {
                            proxy.scrollTo(last.id, anchor: .bottom)
                        }
                    }
                }
            }

            Divider()

            // Error
            if let error = viewModel.errorMessage {
                HStack {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundColor(.red)
                        .font(.caption2)
                    Text(error)
                        .font(.system(size: 9))
                        .foregroundColor(.red)
                        .lineLimit(2)
                    Spacer()
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 4)
                .background(Color.red.opacity(0.1))
            }

            // Quick actions
            quickActionsBar

            Divider()

            // Input
            chatInputBar
        }
    }

    // MARK: - Header

    private var chatHeader: some View {
        HStack {
            Image(systemName: "brain")
                .foregroundColor(.purple)
                .font(.caption)
            Text(LS("ai.title"))
                .font(.caption)
                .fontWeight(.medium)
            Spacer()

            if viewModel.isStreaming {
                ProgressView()
                    .scaleEffect(0.5)

                Button(action: { viewModel.cancelStreaming() }) {
                    Image(systemName: "stop.circle.fill")
                        .font(.caption)
                        .foregroundColor(.red)
                }
                .buttonStyle(.borderless)
            }

            Button(action: { viewModel.clearConversation() }) {
                Image(systemName: "trash")
                    .font(.caption)
            }
            .buttonStyle(.borderless)
            .disabled(viewModel.messages.isEmpty)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
    }

    // MARK: - Chat Bubble

    private func chatBubble(_ message: AIMessage) -> some View {
        HStack(alignment: .top, spacing: 8) {
            if message.role == .assistant {
                Image(systemName: "brain")
                    .font(.system(size: 10))
                    .foregroundColor(.purple)
                    .frame(width: 18, height: 18)
                    .background(Circle().fill(Color.purple.opacity(0.15)))
            }

            VStack(alignment: message.role == .user ? .trailing : .leading, spacing: 4) {
                if message.role == .assistant {
                    MarkdownRenderView(content: message.content)
                } else {
                    Text(message.content)
                        .font(.system(size: 11))
                }

                Text(message.timestamp, style: .time)
                    .font(.system(size: 8))
                    .foregroundColor(.secondary)
            }
            .padding(8)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(message.role == .user
                        ? Color.accentColor.opacity(0.12)
                        : Color(nsColor: .controlBackgroundColor))
            )

            if message.role == .user {
                Image(systemName: "person.circle.fill")
                    .font(.system(size: 10))
                    .foregroundColor(.accentColor)
                    .frame(width: 18, height: 18)
            }
        }
        .frame(maxWidth: .infinity, alignment: message.role == .user ? .trailing : .leading)
    }

    // MARK: - Quick Actions

    private var quickActionsBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                quickActionButton("ai.generate", icon: "wand.and.stars") {
                    viewModel.generateCommand(viewModel.inputText)
                }
                quickActionButton("ai.explain", icon: "text.magnifyingglass") {
                    viewModel.explainCommand(viewModel.inputText)
                }
                quickActionButton("ai.fixError", icon: "ladybug.fill") {
                    viewModel.analyzeError(viewModel.inputText)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 4)
        }
    }

    private func quickActionButton(_ label: String, icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(LS(label), systemImage: icon)
                .font(.system(size: 9))
        }
        .buttonStyle(.bordered)
        .controlSize(.mini)
        .disabled(viewModel.inputText.trimmingCharacters(in: .whitespaces).isEmpty || viewModel.isStreaming)
    }

    // MARK: - Input Bar

    private var chatInputBar: some View {
        HStack(spacing: 8) {
            TextField(LS("ai.inputPlaceholder"), text: $viewModel.inputText)
                .textFieldStyle(.plain)
                .font(.system(size: 11))
                .onSubmit {
                    viewModel.sendMessage()
                }

            Button(action: { viewModel.sendMessage() }) {
                Image(systemName: "arrow.up.circle.fill")
                    .font(.system(size: 16))
                    .foregroundColor(
                        viewModel.inputText.trimmingCharacters(in: .whitespaces).isEmpty
                            ? .secondary : .accentColor
                    )
            }
            .buttonStyle(.borderless)
            .disabled(viewModel.inputText.trimmingCharacters(in: .whitespaces).isEmpty || viewModel.isStreaming)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }
}
