import SwiftUI

/// Git repository status and operations panel.
///
/// Provides five tabs: Changes, History, Graph, Stash, and Conflicts.
/// Automatically follows the local file browser's current directory via
/// `.localDirectoryChanged` notification → `GitViewModel.setRepoPath()`.
struct GitPanelView: View {
    @StateObject private var viewModel = GitViewModel()
    @State private var diffText: String = ""
    @State private var showingDiff = false
    @State private var showingBlame = false
    @State private var showingBranchManager = false
    @State private var showingTagManager = false
    @State private var showingRemoteManager = false
    @State private var showingRebase = false
    @State private var showingSubmodule = false
    @State private var showingConfig = false

    var body: some View {
        VStack(spacing: 0) {
            // Header
            gitHeader

            Divider()

            // Operation status banner
            if viewModel.operationStatus != .idle {
                operationStatusBanner
            }

            if !viewModel.isGitRepo {
                notARepoView
            } else {
                // Branch & status bar
                branchBar

                Divider()

                // 5-tab selector
                tabBar

                Divider()

                // Tab content
                switch viewModel.selectedTab {
                case .changes:
                    changesView
                case .history:
                    BranchGraphView(gitViewModel: viewModel)
                case .stash:
                    stashView
                case .conflicts:
                    MergeConflictView(gitViewModel: viewModel)
                }
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .gitShowDiff)) { notification in
            if let info = notification.object as? [String: String],
               let diff = info["diff"] {
                diffText = diff
                showingDiff = true
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .gitShowBlame)) { _ in
            showingBlame = true
        }
        .sheet(isPresented: $showingDiff) {
            VStack(spacing: 0) {
                HStack {
                    Text(LS("diff.title"))
                        .font(.system(size: 12, weight: .medium))
                    Spacer()
                    Button(action: { showingDiff = false }) {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 16))
                            .foregroundColor(.secondary)
                    }
                    .buttonStyle(.plain)
                    .help(LS("diff.close"))
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(Color(nsColor: .windowBackgroundColor))
                Divider()
                DiffView(diffText: diffText)
            }
            .frame(minWidth: 700, idealWidth: 900, minHeight: 500, idealHeight: 700)
        }
        .sheet(isPresented: $showingBlame) {
            VStack(spacing: 0) {
                HStack {
                    Text(LS("git.blame"))
                        .font(.system(size: 12, weight: .medium))
                    Spacer()
                    Button(action: { showingBlame = false }) {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 16))
                            .foregroundColor(.secondary)
                    }
                    .buttonStyle(.plain)
                    .help(LS("diff.close"))
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(Color(nsColor: .windowBackgroundColor))
                Divider()
                BlameView(blameLines: viewModel.blameLines, filePath: viewModel.blameFilePath)
            }
            .frame(minWidth: 700, minHeight: 400)
        }
        .popover(isPresented: $showingBranchManager) {
            GitBranchManagerView(gitViewModel: viewModel)
                .frame(width: 320, height: 400)
        }
        .popover(isPresented: $showingTagManager) {
            GitTagManagerView(gitViewModel: viewModel)
                .frame(width: 320, height: 400)
        }
        .popover(isPresented: $showingRemoteManager) {
            GitRemoteManagerView(gitViewModel: viewModel)
                .frame(width: 360, height: 300)
        }
        .popover(isPresented: $showingRebase) {
            GitRebaseView(gitViewModel: viewModel)
                .frame(width: 420, height: 450)
        }
        .popover(isPresented: $showingSubmodule) {
            GitSubmoduleView(gitViewModel: viewModel)
                .frame(width: 380, height: 350)
        }
        .popover(isPresented: $showingConfig) {
            GitConfigView(gitViewModel: viewModel)
                .frame(width: 400, height: 450)
        }
        .onAppear {
            // Ask FileViewModel to re-broadcast its current directory so we sync on appearance
            NotificationCenter.default.post(name: .requestCurrentDirectory, object: nil)
        }
    }

    // MARK: - Header

    private var gitHeader: some View {
        HStack {
            Image(systemName: "arrow.triangle.branch")
                .foregroundColor(.orange)
                .font(.caption)
            Text(LS("git.title"))
                .font(.caption)
                .fontWeight(.medium)

            if !viewModel.repoDisplayPath.isEmpty {
                Text("·")
                    .foregroundColor(.secondary)
                    .font(.caption)
                Text(viewModel.repoDisplayPath)
                    .font(.system(size: 10))
                    .foregroundColor(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

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

    // MARK: - Operation Status Banner

    private var operationStatusBanner: some View {
        Group {
            switch viewModel.operationStatus {
            case .idle:
                EmptyView()
            case .running(let description):
                HStack(spacing: 6) {
                    ProgressView()
                        .controlSize(.mini)
                    Text(description)
                        .font(.system(size: 10))
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 12)
                .padding(.vertical, 4)
                .background(Color.blue.opacity(0.1))
            case .success(let message):
                HStack(spacing: 6) {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundColor(.green)
                        .font(.system(size: 10))
                    Text(message)
                        .font(.system(size: 10))
                        .foregroundColor(.green)
                    Spacer()
                    Button(action: { viewModel.operationStatus = .idle }) {
                        Image(systemName: "xmark")
                            .font(.system(size: 8))
                            .foregroundColor(.secondary)
                    }
                    .buttonStyle(.borderless)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 12)
                .padding(.vertical, 4)
                .background(Color.green.opacity(0.08))
            case .failure(let message, let detail):
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundColor(.red)
                            .font(.system(size: 10))
                        Text(message)
                            .font(.system(size: 10))
                            .foregroundColor(.red)
                        Spacer()
                        Button(action: { viewModel.operationStatus = .idle }) {
                            Image(systemName: "xmark")
                                .font(.system(size: 8))
                                .foregroundColor(.secondary)
                        }
                        .buttonStyle(.borderless)
                    }
                    if let detail, !detail.isEmpty {
                        Text(detail)
                            .font(.system(size: 9, design: .monospaced))
                            .foregroundColor(.secondary)
                            .lineLimit(3)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 12)
                .padding(.vertical, 4)
                .background(Color.red.opacity(0.08))
            }
        }
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

            // Manager buttons
            Button(action: { showingBranchManager.toggle() }) {
                Image(systemName: "arrow.triangle.branch")
                    .font(.system(size: 9))
            }
            .buttonStyle(.borderless)
            .help(LS("git.branches"))

            Button(action: { showingTagManager.toggle() }) {
                Image(systemName: "tag")
                    .font(.system(size: 9))
            }
            .buttonStyle(.borderless)
            .help(LS("git.tags"))

            Button(action: { showingRemoteManager.toggle() }) {
                Image(systemName: "network")
                    .font(.system(size: 9))
            }
            .buttonStyle(.borderless)
            .help(LS("git.remotes"))

            Button(action: { showingRebase.toggle() }) {
                Image(systemName: "arrow.triangle.swap")
                    .font(.system(size: 9))
            }
            .buttonStyle(.borderless)
            .help("Rebase")

            Button(action: { showingSubmodule.toggle() }) {
                Image(systemName: "square.stack.3d.up")
                    .font(.system(size: 9))
            }
            .buttonStyle(.borderless)
            .help("Submodules")

            Button(action: { showingConfig.toggle() }) {
                Image(systemName: "gearshape.2")
                    .font(.system(size: 9))
            }
            .buttonStyle(.borderless)
            .help("Git Config")

            Divider()
                .frame(height: 12)

            // Quick actions
            Button(action: { viewModel.pull() }) {
                Image(systemName: "arrow.down.circle")
                    .font(.caption)
            }
            .buttonStyle(.borderless)
            .help(LS("git.pull"))

            Button(action: { viewModel.push() }) {
                Image(systemName: "arrow.up.circle")
                    .font(.caption)
            }
            .buttonStyle(.borderless)
            .help(LS("git.push"))
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 4)
        .background(Color(nsColor: .textBackgroundColor).opacity(0.5))
    }

    // MARK: - Tab Bar

    private var tabBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 2) {
                ForEach(GitTab.allCases, id: \.self) { tab in
                    tabButton(for: tab)
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
        }
    }

    private func tabButton(for tab: GitTab) -> some View {
        let isSelected = viewModel.selectedTab == tab

        return Button(action: {
            withAnimation(.easeInOut(duration: 0.15)) {
                viewModel.selectedTab = tab
                // Load tab-specific data on demand
                if tab == .history {
                    Task { await viewModel.loadGraphHistory() }
                } else if tab == .conflicts {
                    viewModel.detectConflicts()
                }
            }
        }) {
            HStack(spacing: 4) {
                Image(systemName: tabIcon(for: tab))
                    .font(.system(size: 9))
                Text(tabTitle(for: tab))
                    .font(.system(size: 10, weight: isSelected ? .semibold : .regular))

                // Badge for conflicts
                if tab == .conflicts, !viewModel.conflictFiles.isEmpty {
                    Text("\(viewModel.conflictFiles.count)")
                        .font(.system(size: 8, weight: .bold))
                        .foregroundColor(.white)
                        .padding(.horizontal, 4)
                        .padding(.vertical, 1)
                        .background(Capsule().fill(Color.red))
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(
                RoundedRectangle(cornerRadius: 4)
                    .fill(isSelected ? Color.accentColor.opacity(0.15) : Color.clear)
            )
            .foregroundColor(isSelected ? .accentColor : .secondary)
        }
        .buttonStyle(.borderless)
    }

    private func tabTitle(for tab: GitTab) -> String {
        switch tab {
        case .changes: return LS("git.changes")
        case .history: return LS("git.history")
        case .stash: return LS("git.stash")
        case .conflicts: return LS("git.mergeConflicts")
        }
    }

    private func tabIcon(for tab: GitTab) -> String {
        switch tab {
        case .changes: return "doc.text.magnifyingglass"
        case .history: return "point.3.connected.trianglepath.dotted"
        case .stash: return "tray.full"
        case .conflicts: return "exclamationmark.triangle"
        }
    }

    // MARK: - Changes

    private var changesView: some View {
        VStack(spacing: 0) {
            // Staged section
            if !viewModel.stagedFiles.isEmpty {
                sectionHeader(String(format: LS("git.staged"), viewModel.stagedFiles.count), color: .green)
                List(viewModel.stagedFiles) { file in
                    gitFileRow(file: file, staged: true)
                }
                .listStyle(.plain)
                .frame(maxHeight: 150)
            }

            // Unstaged section
            sectionHeader(String(format: LS("git.unstaged"), viewModel.unstagedFiles.count), color: .orange)
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
                .help(LS("git.unstage"))
            } else {
                Button(action: { viewModel.stageFile(file.path) }) {
                    Image(systemName: "plus.circle")
                        .font(.system(size: 10))
                        .foregroundColor(.green)
                }
                .buttonStyle(.borderless)
                .help(LS("git.stage"))
            }
        }
        .padding(.vertical, 1)
        .contextMenu {
            Button(LS("git.showDiff")) { viewModel.showDiff(file.path) }
            Button(LS("git.blame")) { viewModel.blameFile(file.path) }
            Divider()
            if staged {
                Button(LS("git.unstage")) { viewModel.unstageFile(file.path) }
            } else {
                Button(LS("git.stage")) { viewModel.stageFile(file.path) }
                Button(LS("git.discardChanges"), role: .destructive) { viewModel.discardChanges(file.path) }
            }
        }
    }

    private var commitArea: some View {
        VStack(spacing: 6) {
            TextField(LS("git.commitPlaceholder"), text: $viewModel.commitMessage, axis: .vertical)
                .textFieldStyle(.plain)
                .font(.caption)
                .lineLimit(3...5)
                .padding(6)
                .background(Color(nsColor: .textBackgroundColor))
                .cornerRadius(4)

            HStack {
                Button(LS("git.stageAll")) { viewModel.stageAll() }
                    .buttonStyle(.borderless)
                    .font(.caption)

                Spacer()

                Button(LS("git.commit")) { viewModel.commit() }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .disabled(viewModel.commitMessage.isEmpty || viewModel.stagedFiles.isEmpty)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
    }

    // MARK: - Stash

    private var stashView: some View {
        VStack(spacing: 0) {
            HStack {
                Spacer()
                Button(LS("git.stashChanges")) { viewModel.stashChanges() }
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
                    Button(LS("git.apply")) { viewModel.applyStash(stash.index) }
                    Button(LS("git.pop")) { viewModel.popStash(stash.index) }
                    Divider()
                    Button(LS("git.drop"), role: .destructive) { viewModel.dropStash(stash.index) }
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
            Text(LS("git.notARepo"))
                .font(.title3)
                .foregroundColor(.secondary)
            if !viewModel.repoDisplayPath.isEmpty {
                Text(viewModel.repoDisplayPath)
                    .font(.system(size: 10))
                    .foregroundColor(.secondary.opacity(0.7))
            }
            Button(LS("git.initRepo")) { viewModel.initRepo() }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
