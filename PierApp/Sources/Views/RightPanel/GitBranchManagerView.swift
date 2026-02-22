import SwiftUI

/// Branch management popover: list, switch, create, delete, rename, and set tracking.
struct GitBranchManagerView: View {
    @ObservedObject var gitViewModel: GitViewModel
    @State private var branches: [GitBranch] = []
    @State private var newBranchName = ""
    @State private var showNewBranch = false
    @State private var showLocalOnly = true
    @State private var isLoading = false
    // Rename state
    @State private var renamingBranch: GitBranch?
    @State private var renameText = ""

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Image(systemName: "arrow.triangle.branch")
                    .foregroundColor(.green)
                    .font(.caption)
                Text(LS("git.branches"))
                    .font(.caption)
                    .fontWeight(.medium)
                Spacer()

                Button(action: { showNewBranch.toggle() }) {
                    Image(systemName: "plus")
                        .font(.system(size: 10))
                }
                .buttonStyle(.borderless)
                .help(LS("git.newBranch"))

                Button(action: refreshBranches) {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 10))
                }
                .buttonStyle(.borderless)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)

            Divider()

            // Filter: Local / Remote
            Picker("", selection: $showLocalOnly) {
                Text(LS("git.local")).tag(true)
                Text(LS("git.remote")).tag(false)
            }
            .pickerStyle(.segmented)
            .padding(.horizontal, 12)
            .padding(.vertical, 4)

            // New branch field
            if showNewBranch {
                HStack(spacing: 4) {
                    TextField(LS("git.branchName"), text: $newBranchName)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: 10))
                        .onSubmit { createNewBranch() }

                    Button(action: createNewBranch) {
                        Image(systemName: "checkmark")
                            .font(.system(size: 9))
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.mini)
                    .disabled(newBranchName.isEmpty)

                    Button(action: { showNewBranch = false; newBranchName = "" }) {
                        Image(systemName: "xmark")
                            .font(.system(size: 9))
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.mini)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 4)
            }

            // Branch list
            if isLoading {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(filteredBranches) { branch in
                    branchRow(branch)
                }
                .listStyle(.plain)
            }
        }
        .onAppear { refreshBranches() }
    }

    // MARK: - Helpers

    private var filteredBranches: [GitBranch] {
        branches.filter { showLocalOnly ? !$0.isRemote : $0.isRemote }
    }

    private var remoteBranches: [String] {
        branches.filter { $0.isRemote }.map { $0.name }
    }

    private func branchRow(_ branch: GitBranch) -> some View {
        HStack(spacing: 6) {
            if branch.isCurrent {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundColor(.green)
                    .font(.system(size: 10))
            } else {
                Image(systemName: "arrow.triangle.branch")
                    .foregroundColor(.secondary)
                    .font(.system(size: 10))
            }

            // Rename mode or display mode
            if renamingBranch?.name == branch.name {
                HStack(spacing: 4) {
                    TextField("", text: $renameText)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: 10))
                        .onSubmit { performRename(branch) }

                    Button(action: { performRename(branch) }) {
                        Image(systemName: "checkmark")
                            .font(.system(size: 8))
                            .foregroundColor(.green)
                    }
                    .buttonStyle(.borderless)

                    Button(action: { renamingBranch = nil }) {
                        Image(systemName: "xmark")
                            .font(.system(size: 8))
                            .foregroundColor(.secondary)
                    }
                    .buttonStyle(.borderless)
                }
            } else {
                Text(branch.name)
                    .font(.system(size: 10, weight: branch.isCurrent ? .semibold : .regular))
                    .lineLimit(1)
            }

            if let tracking = branch.trackingBranch, !tracking.isEmpty,
               renamingBranch?.name != branch.name {
                Text("→ \(tracking)")
                    .font(.system(size: 8))
                    .foregroundColor(.blue)
            }

            Spacer()
        }
        .padding(.vertical, 2)
        .contextMenu {
            if !branch.isRemote {
                // Local branch context menu
                if !branch.isCurrent {
                    Button(LS("git.switchBranch")) { gitViewModel.switchBranch(branch.name) }
                    Button(LS("git.mergeBranch")) { gitViewModel.mergeBranch(branch.name) }
                    Divider()
                }

                Button(LS("git.renameBranch")) {
                    renamingBranch = branch
                    renameText = branch.name
                }

                // Set tracking branch via submenu
                Menu(LS("git.setTracking")) {
                    // "No tracking" option
                    Button {
                        performSetTracking(branch, upstream: nil)
                    } label: {
                        HStack {
                            Text(LS("git.noTracking"))
                            if branch.trackingBranch == nil {
                                Image(systemName: "checkmark")
                            }
                        }
                    }

                    Divider()

                    // All remote branches
                    ForEach(remoteBranches, id: \.self) { remote in
                        Button {
                            performSetTracking(branch, upstream: remote)
                        } label: {
                            HStack {
                                Text(remote)
                                if branch.trackingBranch == remote {
                                    Image(systemName: "checkmark")
                                }
                            }
                        }
                    }
                }

                if !branch.isCurrent {
                    Divider()
                    Button(LS("git.deleteBranch"), role: .destructive) {
                        gitViewModel.deleteBranch(branch.name)
                        delayedRefresh()
                    }
                }
            } else {
                // Remote branch context menu
                Button(LS("git.checkout")) {
                    let localName = branch.name.split(separator: "/").dropFirst().joined(separator: "/")
                    gitViewModel.switchBranch(localName)
                    delayedRefresh()
                }

                Button(LS("git.renameBranch")) {
                    renamingBranch = branch
                    let parts = branch.name.split(separator: "/", maxSplits: 1)
                    renameText = parts.count > 1 ? String(parts[1]) : branch.name
                }
            }
        }
        .onTapGesture(count: 2) {
            if !branch.isCurrent && !branch.isRemote {
                gitViewModel.switchBranch(branch.name)
            }
        }
    }

    // MARK: - Actions

    private func performRename(_ branch: GitBranch) {
        let newName = renameText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !newName.isEmpty, newName != branch.name else {
            renamingBranch = nil
            return
        }

        Task {
            if branch.isRemote {
                let parts = branch.name.split(separator: "/", maxSplits: 1)
                let remote = parts.count > 1 ? String(parts[0]) : "origin"
                let oldBranch = parts.count > 1 ? String(parts[1]) : branch.name
                _ = await gitViewModel.runGitFull(["push", remote, "\(oldBranch):\(newName)"])
                _ = await gitViewModel.runGitFull(["push", remote, "--delete", oldBranch])
            } else {
                _ = await gitViewModel.runGitFull(["branch", "-m", branch.name, newName])
            }
            renamingBranch = nil
            refreshBranches()
        }
    }

    private func performSetTracking(_ branch: GitBranch, upstream: String?) {
        Task {
            if let upstream = upstream {
                _ = await gitViewModel.runGitFull(["branch", "--set-upstream-to=\(upstream)", branch.name])
            } else {
                _ = await gitViewModel.runGitFull(["branch", "--unset-upstream", branch.name])
            }
            refreshBranches()
        }
    }

    private func createNewBranch() {
        guard !newBranchName.isEmpty else { return }
        gitViewModel.createBranch(newBranchName)
        newBranchName = ""
        showNewBranch = false
        delayedRefresh()
    }

    private func delayedRefresh() {
        Task {
            try? await Task.sleep(nanoseconds: 500_000_000)
            refreshBranches()
        }
    }

    private func refreshBranches() {
        isLoading = true
        Task {
            branches = await gitViewModel.loadBranches()
            isLoading = false
        }
    }
}
