import SwiftUI

/// Git merge conflict resolver with side-by-side ours/theirs comparison.
struct MergeConflictView: View {
    @ObservedObject var gitViewModel: GitViewModel

    var body: some View {
        VStack(spacing: 0) {
            headerView
            Divider()

            if gitViewModel.conflictFiles.isEmpty {
                noConflictsPlaceholder
            } else {
                conflictContent
            }
        }
    }

    // MARK: - Header

    private var headerView: some View {
        HStack {
            Image(systemName: "arrow.triangle.merge")
                .foregroundColor(.red)
                .font(.caption)
            Text(LS("git.mergeConflicts"))
                .font(.caption)
                .fontWeight(.medium)
            Spacer()

            if !gitViewModel.conflictFiles.isEmpty {
                Text("\(gitViewModel.conflictFiles.count)")
                    .font(.system(size: 9))
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1)
                    .background(Capsule().fill(Color.red.opacity(0.2)))
                    .foregroundColor(.red)
            }

            Button(action: { gitViewModel.detectConflicts() }) {
                Image(systemName: "arrow.clockwise")
                    .font(.caption)
            }
            .buttonStyle(.borderless)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
    }

    // MARK: - Content

    private var conflictContent: some View {
        HSplitView {
            // File list
            List(gitViewModel.conflictFiles, selection: Binding(
                get: { gitViewModel.selectedConflictFile },
                set: { gitViewModel.selectedConflictFile = $0 }
            )) { file in
                HStack {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 9))
                        .foregroundColor(.red)
                    Text(file.name)
                        .font(.system(size: 10))
                    Spacer()
                    Text("\(file.conflicts.count)")
                        .font(.system(size: 8))
                        .padding(.horizontal, 4)
                        .background(Capsule().fill(Color.red.opacity(0.15)))
                }
            }
            .listStyle(.sidebar)
            .frame(minWidth: 160, maxWidth: 200)

            // Conflict hunks
            if let fileId = gitViewModel.selectedConflictFile,
               let file = gitViewModel.conflictFiles.first(where: { $0.id == fileId }) {
                conflictHunkList(file)
            } else {
                VStack {
                    Text(LS("git.selectConflictFile"))
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }

    private func conflictHunkList(_ file: ConflictFile) -> some View {
        VStack(spacing: 0) {
            // Bulk actions
            HStack {
                Button(action: { gitViewModel.acceptAllOurs(file) }) {
                    Label(LS("git.acceptAllOurs"), systemImage: "arrow.left.circle")
                        .font(.system(size: 9))
                }
                .buttonStyle(.bordered)
                .controlSize(.mini)

                Button(action: { gitViewModel.acceptAllTheirs(file) }) {
                    Label(LS("git.acceptAllTheirs"), systemImage: "arrow.right.circle")
                        .font(.system(size: 9))
                }
                .buttonStyle(.bordered)
                .controlSize(.mini)

                Spacer()

                Button(action: { gitViewModel.markResolved(file) }) {
                    Label(LS("git.markResolved"), systemImage: "checkmark.circle.fill")
                        .font(.system(size: 9))
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.mini)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)

            Divider()

            // Conflict hunks
            ScrollView {
                VStack(spacing: 12) {
                    ForEach(Array(file.conflicts.enumerated()), id: \.offset) { idx, conflict in
                        conflictHunkView(conflict, index: idx, file: file)
                    }
                }
                .padding(8)
            }
        }
    }

    private func conflictHunkView(_ conflict: ConflictHunk, index: Int, file: ConflictFile) -> some View {
        VStack(spacing: 0) {
            // Hunk header
            HStack {
                Text("Conflict \(index + 1)")
                    .font(.system(size: 9, weight: .semibold))

                Spacer()

                Button("git.acceptOurs") {
                    gitViewModel.resolveConflict(file: file, hunkIndex: index, resolution: .ours)
                }
                .font(.system(size: 8))
                .buttonStyle(.bordered)
                .controlSize(.mini)

                Button("git.acceptTheirs") {
                    gitViewModel.resolveConflict(file: file, hunkIndex: index, resolution: .theirs)
                }
                .font(.system(size: 8))
                .buttonStyle(.bordered)
                .controlSize(.mini)

                Button("git.acceptBoth") {
                    gitViewModel.resolveConflict(file: file, hunkIndex: index, resolution: .both)
                }
                .font(.system(size: 8))
                .buttonStyle(.bordered)
                .controlSize(.mini)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)

            // Side by side
            HStack(spacing: 1) {
                // Ours
                VStack(alignment: .leading, spacing: 0) {
                    Text("OURS")
                        .font(.system(size: 8, weight: .bold))
                        .foregroundColor(.green)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)

                    ForEach(Array(conflict.oursLines.enumerated()), id: \.offset) { _, line in
                        Text(line)
                            .font(.system(size: 9, design: .monospaced))
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 1)
                    }
                }
                .background(Color.green.opacity(0.06))
                .cornerRadius(4)

                // Theirs
                VStack(alignment: .leading, spacing: 0) {
                    Text("THEIRS")
                        .font(.system(size: 8, weight: .bold))
                        .foregroundColor(.blue)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)

                    ForEach(Array(conflict.theirsLines.enumerated()), id: \.offset) { _, line in
                        Text(line)
                            .font(.system(size: 9, design: .monospaced))
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 1)
                    }
                }
                .background(Color.blue.opacity(0.06))
                .cornerRadius(4)
            }
        }
        .background(Color(nsColor: .controlBackgroundColor))
        .cornerRadius(6)
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .stroke(Color.secondary.opacity(0.2), lineWidth: 0.5)
        )
    }

    // MARK: - Empty State

    private var noConflictsPlaceholder: some View {
        VStack(spacing: 12) {
            Image(systemName: "checkmark.circle")
                .font(.system(size: 30))
                .foregroundColor(.green)
            Text(LS("git.noConflicts"))
                .font(.caption)
                .foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Data Models

struct ConflictFile: Identifiable {
    let id = UUID()
    let name: String
    let path: String
    var conflicts: [ConflictHunk]
}

struct ConflictHunk {
    let oursLines: [String]
    let theirsLines: [String]
    var resolution: ConflictResolution?
}

enum ConflictResolution {
    case ours
    case theirs
    case both
}
