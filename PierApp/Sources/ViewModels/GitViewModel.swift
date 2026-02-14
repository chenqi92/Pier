import SwiftUI
import Combine

enum GitTab {
    case changes, history, stash
}

// MARK: - Data Models

enum GitFileStatus: String {
    case modified = "M"
    case added = "A"
    case deleted = "D"
    case renamed = "R"
    case untracked = "?"
    case conflicted = "U"

    var badge: String {
        switch self {
        case .modified: return "M"
        case .added: return "A"
        case .deleted: return "D"
        case .renamed: return "R"
        case .untracked: return "?"
        case .conflicted: return "U"
        }
    }

    var color: Color {
        switch self {
        case .modified: return .orange
        case .added: return .green
        case .deleted: return .red
        case .renamed: return .blue
        case .untracked: return .gray
        case .conflicted: return .purple
        }
    }
}

struct GitFileChange: Identifiable {
    var id: String { path }
    let path: String
    let status: GitFileStatus

    var fileName: String {
        (path as NSString).lastPathComponent
    }
}

struct GitCommit: Identifiable {
    let hash: String
    let shortHash: String
    let message: String
    let author: String
    let date: Date?
    let relativeDate: String

    var id: String { hash }
}

struct GitStashEntry: Identifiable {
    let index: Int
    let message: String
    let relativeDate: String

    var id: Int { index }
}

struct BlameLine: Identifiable {
    let lineNumber: Int
    let commitHash: String
    let shortHash: String
    let author: String
    let date: String
    let content: String

    var id: Int { lineNumber }
}

// MARK: - ViewModel

@MainActor
class GitViewModel: ObservableObject {
    @Published var selectedTab: GitTab = .changes
    @Published var isGitRepo = false
    @Published var currentBranch = ""
    @Published var aheadCount = 0
    @Published var behindCount = 0
    @Published var stagedFiles: [GitFileChange] = []
    @Published var unstagedFiles: [GitFileChange] = []
    @Published var commitMessage = ""
    @Published var commitHistory: [GitCommit] = []
    @Published var stashes: [GitStashEntry] = []

    private var repoPath: String = ""
    private var timer: AnyCancellable?

    // Blame
    @Published var blameLines: [BlameLine] = []
    @Published var blameFilePath: String = ""

    // Branch graph
    @Published var graphEntries: [BranchGraphView.GraphEntry] = []

    init() {
        // Default to home dir, will be updated when folder is selected
        repoPath = FileManager.default.homeDirectoryForCurrentUser.path
        checkGitRepo()
    }

    private func startPeriodicRefresh() {
        // Only poll when in a git repo
        timer?.cancel()
        timer = Timer.publish(every: 5, on: .main, in: .common)
            .autoconnect()
            .sink { [weak self] _ in
                self?.refresh()
            }
    }

    private func stopPeriodicRefresh() {
        timer?.cancel()
        timer = nil
    }

    func setRepoPath(_ path: String) {
        repoPath = path
        checkGitRepo()
    }

    deinit {
        timer?.cancel()
    }

    func checkGitRepo() {
        Task {
            let result = await runGit(["rev-parse", "--is-inside-work-tree"])
            isGitRepo = result?.trimmingCharacters(in: .whitespacesAndNewlines) == "true"
            if isGitRepo {
                startPeriodicRefresh()
                await loadBranch()
                await loadStatus()
                await loadHistory()
                await loadStashes()
            } else {
                stopPeriodicRefresh()
            }
        }
    }

    func refresh() {
        guard isGitRepo else { return }
        Task {
            await loadBranch()
            await loadStatus()
        }
    }

    // MARK: - Branch

    private func loadBranch() async {
        if let branch = await runGit(["branch", "--show-current"]) {
            currentBranch = branch.trimmingCharacters(in: .whitespacesAndNewlines)
        }

        if let revList = await runGit(["rev-list", "--left-right", "--count", "HEAD...@{u}"]) {
            let parts = revList.trimmingCharacters(in: .whitespacesAndNewlines).split(separator: "\t")
            if parts.count == 2 {
                aheadCount = Int(parts[0]) ?? 0
                behindCount = Int(parts[1]) ?? 0
            }
        }
    }

    // MARK: - Status

    private func loadStatus() async {
        guard let output = await runGit(["status", "--porcelain=v1"]) else { return }

        var staged: [GitFileChange] = []
        var unstaged: [GitFileChange] = []

        for line in output.split(separator: "\n", omittingEmptySubsequences: true) {
            guard line.count >= 4 else { continue }
            let indexStatus = line[line.index(line.startIndex, offsetBy: 0)]
            let workStatus = line[line.index(line.startIndex, offsetBy: 1)]
            let filePath = String(line[line.index(line.startIndex, offsetBy: 3)...])

            if indexStatus != " " && indexStatus != "?" {
                staged.append(GitFileChange(
                    path: filePath,
                    status: parseStatus(indexStatus)
                ))
            }
            if workStatus != " " {
                unstaged.append(GitFileChange(
                    path: filePath,
                    status: parseStatus(workStatus == "?" ? "?" : workStatus)
                ))
            }
        }

        stagedFiles = staged
        unstagedFiles = unstaged
    }

    private func parseStatus(_ char: Character) -> GitFileStatus {
        switch char {
        case "M": return .modified
        case "A": return .added
        case "D": return .deleted
        case "R": return .renamed
        case "?": return .untracked
        case "U": return .conflicted
        default: return .modified
        }
    }

    // MARK: - Actions

    func stageFile(_ path: String) {
        Task {
            _ = await runGit(["add", path])
            await loadStatus()
        }
    }

    func unstageFile(_ path: String) {
        Task {
            _ = await runGit(["reset", "HEAD", path])
            await loadStatus()
        }
    }

    func stageAll() {
        Task {
            _ = await runGit(["add", "-A"])
            await loadStatus()
        }
    }

    func discardChanges(_ path: String) {
        Task {
            _ = await runGit(["checkout", "--", path])
            await loadStatus()
        }
    }

    func commit() {
        guard !commitMessage.isEmpty else { return }
        Task {
            _ = await runGit(["commit", "-m", commitMessage])
            commitMessage = ""
            await loadStatus()
            await loadHistory()
        }
    }

    func pull() {
        Task {
            _ = await runGit(["pull"])
            await loadBranch()
            await loadStatus()
            await loadHistory()
        }
    }

    func push() {
        Task {
            _ = await runGit(["push"])
            await loadBranch()
        }
    }

    func showDiff(_ path: String) {
        Task {
            if let diff = await runGit(["diff", path]) {
                NotificationCenter.default.post(name: .gitShowDiff, object: diff)
            }
        }
    }

    func initRepo() {
        Task {
            _ = await runGit(["init"])
            checkGitRepo()
        }
    }

    func checkout(_ hash: String) {
        Task {
            _ = await runGit(["checkout", hash])
            await loadBranch()
            await loadStatus()
        }
    }

    func cherryPick(_ hash: String) {
        Task {
            _ = await runGit(["cherry-pick", hash])
            await loadStatus()
            await loadHistory()
        }
    }

    // MARK: - History

    private func loadHistory() async {
        guard let output = await runGit([
            "log", "--oneline", "-30",
            "--format=%H\\t%h\\t%s\\t%an\\t%ar"
        ]) else { return }

        commitHistory = output.split(separator: "\n").compactMap { line in
            let parts = line.split(separator: "\t", maxSplits: 4, omittingEmptySubsequences: false)
            guard parts.count >= 5 else { return nil }
            return GitCommit(
                hash: String(parts[0]),
                shortHash: String(parts[1]),
                message: String(parts[2]),
                author: String(parts[3]),
                date: nil,
                relativeDate: String(parts[4])
            )
        }
    }

    // MARK: - Stash

    private func loadStashes() async {
        guard let output = await runGit(["stash", "list", "--format=%gd\\t%gs"]) else { return }

        stashes = output.split(separator: "\n").enumerated().compactMap { index, line in
            let parts = line.split(separator: "\t", maxSplits: 1)
            guard parts.count >= 1 else { return nil }
            return GitStashEntry(
                index: index,
                message: parts.count > 1 ? String(parts[1]) : String(parts[0]),
                relativeDate: ""
            )
        }
    }

    func stashChanges() {
        Task {
            _ = await runGit(["stash", "push", "-m", "Stash from Pier"])
            await loadStatus()
            await loadStashes()
        }
    }

    func applyStash(_ index: Int) {
        Task {
            _ = await runGit(["stash", "apply", "stash@{\(index)}"])
            await loadStatus()
        }
    }

    func popStash(_ index: Int) {
        Task {
            _ = await runGit(["stash", "pop", "stash@{\(index)}"])
            await loadStatus()
            await loadStashes()
        }
    }

    func dropStash(_ index: Int) {
        Task {
            _ = await runGit(["stash", "drop", "stash@{\(index)}"])
            await loadStashes()
        }
    }

    // MARK: - Blame

    func blameFile(_ path: String) {
        Task {
            guard let output = await runGit(["blame", "--porcelain", path]) else { return }
            var lines: [BlameLine] = []
            var lineNum = 0
            var currentHash = ""
            var currentAuthor = ""
            var currentDate = ""

            let dateFormatter = DateFormatter()
            dateFormatter.dateFormat = "yyyy-MM-dd"

            for rawLine in output.split(separator: "\n", omittingEmptySubsequences: false) {
                let line = String(rawLine)

                if line.count >= 40, line.prefix(40).allSatisfy({ $0.isHexDigit }) {
                    currentHash = String(line.prefix(40))
                } else if line.hasPrefix("author ") {
                    currentAuthor = String(line.dropFirst(7))
                } else if line.hasPrefix("author-time ") {
                    if let ts = TimeInterval(line.dropFirst(12)) {
                        let date = Date(timeIntervalSince1970: ts)
                        currentDate = dateFormatter.string(from: date)
                    }
                } else if line.hasPrefix("\t") {
                    lineNum += 1
                    lines.append(BlameLine(
                        lineNumber: lineNum,
                        commitHash: currentHash,
                        shortHash: String(currentHash.prefix(7)),
                        author: currentAuthor,
                        date: currentDate,
                        content: String(line.dropFirst(1))
                    ))
                }
            }

            blameLines = lines
            blameFilePath = path
            NotificationCenter.default.post(
                name: .gitShowBlame,
                object: ["path": path]
            )
        }
    }

    // MARK: - Branch Graph

    /// Load commit graph for all branches.
    func loadBranchGraph() {
        Task {
            guard let output = await runGit([
                "log", "--all", "--oneline", "--graph", "--decorate",
                "-n", "100"
            ]) else {
                graphEntries = []
                return
            }
            graphEntries = GitViewModel.parseGraphOutput(output)
        }
    }

    // MARK: - Merge Conflict Resolution

    @Published var conflictFiles: [ConflictFile] = []
    @Published var selectedConflictFile: UUID?

    /// Detect files with merge conflicts.
    func detectConflicts() {
        Task {
            guard let output = await runGit(["diff", "--name-only", "--diff-filter=U"]) else {
                conflictFiles = []
                return
            }

            var files: [ConflictFile] = []
            for fileName in output.split(separator: "\n").map(String.init) {
                let filePath = (repoPath as NSString).appendingPathComponent(fileName)
                guard let content = try? String(contentsOfFile: filePath, encoding: .utf8) else { continue }

                let hunks = parseConflictMarkers(content)
                if !hunks.isEmpty {
                    files.append(ConflictFile(name: fileName, path: filePath, conflicts: hunks))
                }
            }

            conflictFiles = files
        }
    }

    /// Parse conflict markers from file content.
    private func parseConflictMarkers(_ content: String) -> [ConflictHunk] {
        var hunks: [ConflictHunk] = []
        let lines = content.components(separatedBy: "\n")
        var i = 0

        while i < lines.count {
            if lines[i].hasPrefix("<<<<<<<") {
                var oursLines: [String] = []
                var theirsLines: [String] = []
                i += 1

                // Collect ours
                while i < lines.count && !lines[i].hasPrefix("=======") {
                    oursLines.append(lines[i])
                    i += 1
                }
                i += 1 // skip =======

                // Collect theirs
                while i < lines.count && !lines[i].hasPrefix(">>>>>>>") {
                    theirsLines.append(lines[i])
                    i += 1
                }

                hunks.append(ConflictHunk(oursLines: oursLines, theirsLines: theirsLines))
            }
            i += 1
        }

        return hunks
    }

    /// Resolve a specific conflict hunk.
    func resolveConflict(file: ConflictFile, hunkIndex: Int, resolution: ConflictResolution) {
        guard var updatedFile = conflictFiles.first(where: { $0.id == file.id }) else { return }
        updatedFile.conflicts[hunkIndex].resolution = resolution

        if let idx = conflictFiles.firstIndex(where: { $0.id == file.id }) {
            conflictFiles[idx] = updatedFile
        }
    }

    /// Accept all ours for a file.
    func acceptAllOurs(_ file: ConflictFile) {
        for i in 0..<file.conflicts.count {
            resolveConflict(file: file, hunkIndex: i, resolution: .ours)
        }
        writeResolvedFile(file, defaultResolution: .ours)
    }

    /// Accept all theirs for a file.
    func acceptAllTheirs(_ file: ConflictFile) {
        for i in 0..<file.conflicts.count {
            resolveConflict(file: file, hunkIndex: i, resolution: .theirs)
        }
        writeResolvedFile(file, defaultResolution: .theirs)
    }

    /// Mark a file as resolved.
    func markResolved(_ file: ConflictFile) {
        writeResolvedFile(file, defaultResolution: .ours)
        Task {
            _ = await runGit(["add", file.path])
            detectConflicts()
        }
    }

    /// Write the resolved file content.
    private func writeResolvedFile(_ file: ConflictFile, defaultResolution: ConflictResolution) {
        guard let content = try? String(contentsOfFile: file.path, encoding: .utf8) else { return }
        let lines = content.components(separatedBy: "\n")
        var result: [String] = []
        var i = 0
        var hunkIndex = 0

        while i < lines.count {
            if lines[i].hasPrefix("<<<<<<<") {
                var oursLines: [String] = []
                var theirsLines: [String] = []
                i += 1

                while i < lines.count && !lines[i].hasPrefix("=======") {
                    oursLines.append(lines[i]); i += 1
                }
                i += 1
                while i < lines.count && !lines[i].hasPrefix(">>>>>>>") {
                    theirsLines.append(lines[i]); i += 1
                }

                let resolution = (hunkIndex < file.conflicts.count
                    ? file.conflicts[hunkIndex].resolution : nil) ?? defaultResolution

                switch resolution {
                case .ours:  result.append(contentsOf: oursLines)
                case .theirs: result.append(contentsOf: theirsLines)
                case .both:  result.append(contentsOf: oursLines); result.append(contentsOf: theirsLines)
                }

                hunkIndex += 1
            } else {
                result.append(lines[i])
            }
            i += 1
        }

        try? result.joined(separator: "\n").write(toFile: file.path, atomically: true, encoding: .utf8)
    }

    // MARK: - Git Command Runner

    private func runGit(_ args: [String]) async -> String? {
        let result = await CommandRunner.shared.run(
            "git",
            arguments: args,
            currentDirectory: repoPath
        )
        return result.succeeded ? result.output : nil
    }
}

// MARK: - Notifications

extension Notification.Name {
    static let gitShowDiff = Notification.Name("pier.gitShowDiff")
    static let gitShowBlame = Notification.Name("pier.gitShowBlame")
}
