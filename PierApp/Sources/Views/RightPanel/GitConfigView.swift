import SwiftUI

/// Git config viewer and editor.
struct GitConfigView: View {
    @ObservedObject var gitViewModel: GitViewModel
    @State private var entries: [GitConfigEntry] = []
    @State private var selectedScope: GitConfigScope = .local
    @State private var isLoading = false
    @State private var showAddEntry = false
    @State private var newKey = ""
    @State private var newValue = ""
    @State private var filterText = ""
    @State private var editingEntry: GitConfigEntry?
    @State private var editingValue = ""

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Image(systemName: "gearshape.2")
                    .foregroundColor(.gray)
                    .font(.caption)
                Text(LS("git.config"))
                    .font(.caption)
                    .fontWeight(.medium)
                Spacer()

                Button(action: { showAddEntry.toggle() }) {
                    Image(systemName: "plus")
                        .font(.system(size: 10))
                }
                .buttonStyle(.borderless)

                Button(action: refresh) {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 10))
                }
                .buttonStyle(.borderless)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)

            Divider()

            // Scope picker
            Picker("", selection: $selectedScope) {
                ForEach(GitConfigScope.allCases, id: \.self) { scope in
                    Text(scope.displayName).tag(scope)
                }
            }
            .pickerStyle(.segmented)
            .padding(.horizontal, 12)
            .padding(.vertical, 4)
            .onChange(of: selectedScope) { refresh() }

            // Filter
            HStack(spacing: 4) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 9))
                    .foregroundColor(.secondary)
                TextField(LS("gitConfig.filter"), text: $filterText)
                    .textFieldStyle(.plain)
                    .font(.system(size: 10))
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .background(Color(nsColor: .controlBackgroundColor))

            Divider()

            // Add entry form
            if showAddEntry {
                VStack(spacing: 4) {
                    TextField(LS("gitConfig.keyPlaceholder"), text: $newKey)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: 10))

                    TextField(LS("gitConfig.value"), text: $newValue)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: 10))

                    HStack {
                        Spacer()
                        Button(action: { showAddEntry = false; newKey = ""; newValue = "" }) {
                            Text(LS("sftp.cancel"))
                                .font(.system(size: 9))
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.mini)

                        Button(action: addEntry) {
                            Text(LS("gitConfig.set"))
                                .font(.system(size: 9))
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.mini)
                        .disabled(newKey.isEmpty)
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 4)

                Divider()
            }

            // Config entries
            if isLoading {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if filteredEntries.isEmpty {
                VStack(spacing: 12) {
                    Image(systemName: "gearshape.2")
                        .font(.system(size: 24))
                        .foregroundColor(.secondary)
                    Text(LS("gitConfig.noEntries"))
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(filteredEntries) { entry in
                    configRow(entry)
                }
                .listStyle(.plain)
            }
        }
        .onAppear { refresh() }
    }

    // MARK: - Helpers

    private var filteredEntries: [GitConfigEntry] {
        if filterText.isEmpty { return entries }
        let query = filterText.lowercased()
        return entries.filter {
            $0.key.lowercased().contains(query) || $0.value.lowercased().contains(query)
        }
    }

    private func configRow(_ entry: GitConfigEntry) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(entry.key)
                .font(.system(size: 10, weight: .medium, design: .monospaced))
                .foregroundColor(.blue)
                .lineLimit(1)

            if editingEntry?.key == entry.key {
                // Inline editing mode
                HStack(spacing: 4) {
                    TextField("", text: $editingValue)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: 9))
                        .onSubmit { saveEditingValue(for: entry.key) }

                    Button(action: { saveEditingValue(for: entry.key) }) {
                        Image(systemName: "checkmark")
                            .font(.system(size: 8))
                            .foregroundColor(.green)
                    }
                    .buttonStyle(.borderless)

                    Button(action: { editingEntry = nil }) {
                        Image(systemName: "xmark")
                            .font(.system(size: 8))
                            .foregroundColor(.secondary)
                    }
                    .buttonStyle(.borderless)
                }
            } else {
                // Display mode — click to edit
                Text(entry.value)
                    .font(.system(size: 9))
                    .foregroundColor(.secondary)
                    .lineLimit(2)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                    .onTapGesture {
                        editingEntry = entry
                        editingValue = entry.value
                    }
            }
        }
        .padding(.vertical, 1)
        .contextMenu {
            Button(LS("gitConfig.edit")) {
                editingEntry = entry
                editingValue = entry.value
            }
            Divider()
            Button(LS("gitConfig.copyKey")) {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(entry.key, forType: .string)
            }
            Button(LS("gitConfig.copyValue")) {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(entry.value, forType: .string)
            }
            Divider()
            Button(LS("gitConfig.remove"), role: .destructive) {
                gitViewModel.unsetGitConfig(key: entry.key, scope: selectedScope)
                Task {
                    try? await Task.sleep(nanoseconds: 500_000_000)
                    refresh()
                }
            }
        }
    }

    private func saveEditingValue(for key: String) {
        gitViewModel.setGitConfig(key: key, value: editingValue, scope: selectedScope)
        editingEntry = nil
        Task {
            try? await Task.sleep(nanoseconds: 500_000_000)
            refresh()
        }
    }

    private func addEntry() {
        guard !newKey.isEmpty else { return }
        gitViewModel.setGitConfig(key: newKey, value: newValue, scope: selectedScope)
        newKey = ""
        newValue = ""
        showAddEntry = false
        Task {
            try? await Task.sleep(nanoseconds: 500_000_000)
            refresh()
        }
    }

    private func refresh() {
        isLoading = true
        editingEntry = nil
        Task {
            entries = await gitViewModel.loadGitConfig(scope: selectedScope)
            isLoading = false
        }
    }
}
