import SwiftUI

/// Branch management popover: list, switch, create, delete, merge branches.
struct GitBranchManagerView: View {
    @ObservedObject var gitViewModel: GitViewModel
    @State private var branches: [GitBranch] = []
    @State private var newBranchName = ""
    @State private var showNewBranch = false
    @State private var showLocalOnly = true
    @State private var isLoading = false

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

            Text(branch.name)
                .font(.system(size: 10, weight: branch.isCurrent ? .semibold : .regular))
                .lineLimit(1)

            if let tracking = branch.trackingBranch, !tracking.isEmpty {
                Text(tracking)
                    .font(.system(size: 8))
                    .foregroundColor(.blue)
            }

            Spacer()
        }
        .padding(.vertical, 2)
        .contextMenu {
            if !branch.isCurrent && !branch.isRemote {
                Button(LS("git.switchBranch")) { gitViewModel.switchBranch(branch.name) }
                Button(LS("git.mergeBranch")) { gitViewModel.mergeBranch(branch.name) }
                Divider()
                Button(LS("git.deleteBranch"), role: .destructive) { gitViewModel.deleteBranch(branch.name) }
            } else if !branch.isCurrent && branch.isRemote {
                Button(LS("git.checkout")) {
                    // Create local tracking branch from remote
                    let localName = branch.name.split(separator: "/").dropFirst().joined(separator: "/")
                    gitViewModel.switchBranch(localName)
                }
            }
        }
        .onTapGesture(count: 2) {
            if !branch.isCurrent && !branch.isRemote {
                gitViewModel.switchBranch(branch.name)
            }
        }
    }

    private func createNewBranch() {
        guard !newBranchName.isEmpty else { return }
        gitViewModel.createBranch(newBranchName)
        newBranchName = ""
        showNewBranch = false
        // Refresh after a short delay to let git complete
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
