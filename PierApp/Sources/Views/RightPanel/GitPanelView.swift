import SwiftUI

/// Git repository status and operations panel.
struct GitPanelView: View {
    @StateObject private var viewModel = GitViewModel()

    var body: some View {
        VStack(spacing: 0) {
            // Header
            gitHeader

            Divider()

            if !viewModel.isGitRepo {
                notARepoView
            } else {
                // Branch & status bar
                branchBar

                Divider()

                // Tab: Changes / History / Stash
                Picker("", selection: $viewModel.selectedTab) {
                    Text("Changes").tag(GitTab.changes)
                    Text("History").tag(GitTab.history)
                    Text("Stash").tag(GitTab.stash)
                }
                .pickerStyle(.segmented)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)

                Divider()

                switch viewModel.selectedTab {
                case .changes:
                    changesView
                case .history:
                    historyView
                case .stash:
                    stashView
                }
            }
        }
    }

    // MARK: - Header

    private var gitHeader: some View {
        HStack {
            Image(systemName: "arrow.triangle.branch")
                .foregroundColor(.orange)
                .font(.caption)
            Text("Git")
                .font(.caption)
                .fontWeight(.medium)
            Spacer()

            Button(action: { viewModel.refresh() }) {
                Image(systemName: "arrow.clockwise")
                    .font(.caption)
            }
            .buttonStyle(.borderless)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
    }

    // MARK: - Branch Bar

    private var branchBar: some View {
        HStack(spacing: 6) {
            Image(systemName: "arrow.triangle.branch")
                .font(.system(size: 10))
                .foregroundColor(.green)

            Text(viewModel.currentBranch)
                .font(.caption)
                .fontWeight(.medium)

            if viewModel.aheadCount > 0 {
                HStack(spacing: 2) {
                    Image(systemName: "arrow.up")
                        .font(.system(size: 8))
                    Text("\(viewModel.aheadCount)")
                        .font(.system(size: 9))
                }
                .foregroundColor(.blue)
            }

            if viewModel.behindCount > 0 {
                HStack(spacing: 2) {
                    Image(systemName: "arrow.down")
                        .font(.system(size: 8))
                    Text("\(viewModel.behindCount)")
                        .font(.system(size: 9))
                }
                .foregroundColor(.orange)
            }

            Spacer()

            // Quick actions
            Button(action: { viewModel.pull() }) {
                Image(systemName: "arrow.down.circle")
                    .font(.caption)
            }
            .buttonStyle(.borderless)
            .help("Git Pull")

            Button(action: { viewModel.push() }) {
                Image(systemName: "arrow.up.circle")
                    .font(.caption)
            }
            .buttonStyle(.borderless)
            .help("Git Push")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 4)
        .background(Color(nsColor: .textBackgroundColor).opacity(0.5))
    }

    // MARK: - Changes

    private var changesView: some View {
        VStack(spacing: 0) {
            // Staged section
            if !viewModel.stagedFiles.isEmpty {
                sectionHeader("Staged (\(viewModel.stagedFiles.count))", color: .green)
                List(viewModel.stagedFiles) { file in
                    gitFileRow(file: file, staged: true)
                }
                .listStyle(.plain)
                .frame(maxHeight: 150)
            }

            // Unstaged section
            sectionHeader("Changes (\(viewModel.unstagedFiles.count))", color: .orange)
            List(viewModel.unstagedFiles) { file in
                gitFileRow(file: file, staged: false)
            }
            .listStyle(.plain)

            Divider()

            // Commit area
            commitArea
        }
    }

    private func sectionHeader(_ title: String, color: Color) -> some View {
        HStack {
            Circle()
                .fill(color)
                .frame(width: 6, height: 6)
            Text(title)
                .font(.system(size: 10, weight: .semibold))
                .foregroundColor(.secondary)
            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 3)
        .background(Color(nsColor: .controlBackgroundColor))
    }

    private func gitFileRow(file: GitFileChange, staged: Bool) -> some View {
        HStack(spacing: 6) {
            // Status badge
            Text(file.status.badge)
                .font(.system(size: 9, weight: .bold, design: .monospaced))
                .foregroundColor(file.status.color)
                .frame(width: 14)

            Text(file.fileName)
                .font(.caption)
                .lineLimit(1)

            Spacer()

            if staged {
                Button(action: { viewModel.unstageFile(file.path) }) {
                    Image(systemName: "minus.circle")
                        .font(.system(size: 10))
                        .foregroundColor(.orange)
                }
                .buttonStyle(.borderless)
                .help("Unstage")
            } else {
                Button(action: { viewModel.stageFile(file.path) }) {
                    Image(systemName: "plus.circle")
                        .font(.system(size: 10))
                        .foregroundColor(.green)
                }
                .buttonStyle(.borderless)
                .help("Stage")
            }
        }
        .padding(.vertical, 1)
        .contextMenu {
            Button("Show Diff") { viewModel.showDiff(file.path) }
            Divider()
            if staged {
                Button("Unstage") { viewModel.unstageFile(file.path) }
            } else {
                Button("Stage") { viewModel.stageFile(file.path) }
                Button("Discard Changes", role: .destructive) { viewModel.discardChanges(file.path) }
            }
        }
    }

    private var commitArea: some View {
        VStack(spacing: 6) {
            TextField("Commit message...", text: $viewModel.commitMessage, axis: .vertical)
                .textFieldStyle(.plain)
                .font(.caption)
                .lineLimit(3...5)
                .padding(6)
                .background(Color(nsColor: .textBackgroundColor))
                .cornerRadius(4)

            HStack {
                Button("Stage All") { viewModel.stageAll() }
                    .buttonStyle(.borderless)
                    .font(.caption)

                Spacer()

                Button("Commit") { viewModel.commit() }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .disabled(viewModel.commitMessage.isEmpty || viewModel.stagedFiles.isEmpty)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
    }

    // MARK: - History

    private var historyView: some View {
        List(viewModel.commitHistory) { commit in
            VStack(alignment: .leading, spacing: 3) {
                Text(commit.message)
                    .font(.caption)
                    .lineLimit(2)

                HStack(spacing: 6) {
                    Text(commit.shortHash)
                        .font(.system(size: 9, design: .monospaced))
                        .foregroundColor(.blue)
                    Text(commit.author)
                        .font(.system(size: 9))
                        .foregroundColor(.secondary)
                    Spacer()
                    Text(commit.relativeDate)
                        .font(.system(size: 9))
                        .foregroundColor(.secondary)
                }
            }
            .padding(.vertical, 2)
            .contextMenu {
                Button("Copy Hash") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(commit.hash, forType: .string)
                }
                Button("Checkout") { viewModel.checkout(commit.hash) }
                Button("Cherry-pick") { viewModel.cherryPick(commit.hash) }
            }
        }
        .listStyle(.plain)
    }

    // MARK: - Stash

    private var stashView: some View {
        VStack(spacing: 0) {
            HStack {
                Spacer()
                Button("Stash Changes") { viewModel.stashChanges() }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)

            List(viewModel.stashes) { stash in
                HStack(spacing: 8) {
                    Image(systemName: "tray.full")
                        .font(.caption)
                        .foregroundColor(.purple)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(stash.message)
                            .font(.caption)
                            .lineLimit(1)
                        Text(stash.relativeDate)
                            .font(.system(size: 9))
                            .foregroundColor(.secondary)
                    }
                    Spacer()
                }
                .contextMenu {
                    Button("Apply") { viewModel.applyStash(stash.index) }
                    Button("Pop") { viewModel.popStash(stash.index) }
                    Divider()
                    Button("Drop", role: .destructive) { viewModel.dropStash(stash.index) }
                }
            }
            .listStyle(.plain)
        }
    }

    // MARK: - Not a Repo

    private var notARepoView: some View {
        VStack(spacing: 16) {
            Image(systemName: "arrow.triangle.branch")
                .font(.system(size: 36))
                .foregroundColor(.secondary)
            Text("Not a Git Repository")
                .font(.caption)
                .foregroundColor(.secondary)
            Button("Initialize Repository") { viewModel.initRepo() }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
