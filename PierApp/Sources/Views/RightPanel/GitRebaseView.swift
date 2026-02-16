import SwiftUI

/// Interactive rebase planning UI.
struct GitRebaseView: View {
    @ObservedObject var gitViewModel: GitViewModel
    @State private var todoItems: [RebaseTodoItem] = []
    @State private var isLoading = false
    @State private var rebaseInProgress = false
    @State private var commitCount = 10

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Image(systemName: "arrow.triangle.swap")
                    .foregroundColor(.purple)
                    .font(.caption)
                Text("Interactive Rebase")
                    .font(.caption)
                    .fontWeight(.medium)
                Spacer()

                if rebaseInProgress {
                    Button("Abort") { gitViewModel.abortRebase() }
                        .buttonStyle(.bordered)
                        .controlSize(.mini)
                        .foregroundColor(.red)

                    Button("Continue") { gitViewModel.continueRebase() }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.mini)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)

            Divider()

            if rebaseInProgress {
                rebaseInProgressView
            } else if isLoading {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if todoItems.isEmpty {
                emptyStateView
            } else {
                // Commit list with rebase actions
                VStack(spacing: 0) {
                    // Controls
                    HStack {
                        Picker("Commits:", selection: $commitCount) {
                            Text("10").tag(10)
                            Text("20").tag(20)
                            Text("50").tag(50)
                        }
                        .pickerStyle(.segmented)
                        .frame(width: 180)
                        .onChange(of: commitCount) { _ in loadItems() }

                        Spacer()

                        Button("Execute Rebase") {
                            executeRebase()
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                        .disabled(todoItems.isEmpty)
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)

                    Divider()

                    // Todo items
                    List {
                        ForEach(Array(todoItems.enumerated()), id: \.element.id) { index, item in
                            rebaseItemRow(item, index: index)
                        }
                        .onMove(perform: moveItems)
                    }
                    .listStyle(.plain)
                }
            }
        }
        .onAppear { loadItems() }
    }

    // MARK: - Item Row

    private func rebaseItemRow(_ item: RebaseTodoItem, index: Int) -> some View {
        HStack(spacing: 8) {
            // Action picker
            Picker("", selection: binding(for: index)) {
                ForEach(RebaseAction.allCases, id: \.self) { action in
                    Label(action.rawValue.capitalized, systemImage: action.icon)
                        .font(.system(size: 9))
                        .tag(action)
                }
            }
            .pickerStyle(.menu)
            .frame(width: 80)

            Image(systemName: item.action.icon)
                .foregroundColor(item.action.color)
                .font(.system(size: 10))

            // Hash
            Text(String(item.hash.prefix(7)))
                .font(.system(size: 9, design: .monospaced))
                .foregroundColor(.secondary)

            // Message
            Text(item.message)
                .font(.system(size: 10))
                .lineLimit(1)

            Spacer()
        }
        .padding(.vertical, 1)
    }

    // MARK: - Helpers

    private func binding(for index: Int) -> Binding<RebaseAction> {
        Binding(
            get: { todoItems[index].action },
            set: { todoItems[index].action = $0 }
        )
    }

    private func moveItems(from source: IndexSet, to destination: Int) {
        todoItems.move(fromOffsets: source, toOffset: destination)
    }

    private func loadItems() {
        isLoading = true
        Task {
            rebaseInProgress = await gitViewModel.isRebaseInProgress()
            todoItems = await gitViewModel.loadRebaseTodoItems(count: commitCount)
            isLoading = false
        }
    }

    private func executeRebase() {
        guard let lastItem = todoItems.last else { return }
        gitViewModel.executeRebase(items: todoItems, onto: "\(lastItem.hash)~1")
    }

    // MARK: - States

    private var emptyStateView: some View {
        VStack(spacing: 12) {
            Image(systemName: "arrow.triangle.swap")
                .font(.system(size: 30))
                .foregroundColor(.secondary)
            Text("No commits to rebase")
                .font(.caption)
                .foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var rebaseInProgressView: some View {
        VStack(spacing: 12) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 30))
                .foregroundColor(.orange)
            Text("Rebase in progress")
                .font(.caption)
                .fontWeight(.medium)
            Text("Resolve conflicts and continue, or abort the rebase.")
                .font(.system(size: 10))
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
