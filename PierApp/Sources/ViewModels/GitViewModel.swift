import SwiftUI
import Combine

enum GitTab: CaseIterable {
    case changes, history, stash, conflicts
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
    // MARK: - Published State

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
    @Published var operationStatus: GitOperationStatus = .idle
    @Published var repoDisplayPath: String = ""

    // Blame
    @Published var blameLines: [BlameLine] = []
    @Published var blameFilePath: String = ""

    // Unified graph + history
    @Published var graphNodes: [CommitNode] = []
    @Published var isLoadingMoreHistory = false
    @Published var hasMoreHistory = true

    // MARK: - Private

    private(set) var repoPath: String = ""
    private var timer: AnyCancellable?
    private let graphPageSize = 50
    private var graphSkipCount = 0
    private var laneState = LaneState()
    private var directoryObserver: AnyCancellable?
    private var statusDismissTask: Task<Void, Never>?

    // MARK: - Init / Deinit

    init() {
        // Listen for directory changes from the local file browser
        directoryObserver = NotificationCenter.default
            .publisher(for: .localDirectoryChanged)
            .compactMap { $0.object as? String }
            .receive(on: DispatchQueue.main)
            .sink { [weak self] path in
                self?.setRepoPath(path)
            }
    }

    deinit {
        timer?.cancel()
        directoryObserver?.cancel()
        statusDismissTask?.cancel()
    }

    // MARK: - Periodic Refresh

    private func startPeriodicRefresh() {
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

    // MARK: - Repo Path Management

    /// Set the working directory and resolve the git repository root.
    /// If the directory is inside a git repo, finds the top-level root.
    func setRepoPath(_ path: String) {
        Task {
            // Resolve the git root from the given directory
            let result = await CommandRunner.shared.run(
                "git",
                arguments: ["rev-parse", "--show-toplevel"],
                currentDirectory: path
            )

            if result.succeeded, let root = result.output {
                let resolvedRoot = root.trimmingCharacters(in: .whitespacesAndNewlines)
                guard resolvedRoot != repoPath else { return }
                // Clear old state immediately to prevent stale data from previous repo
                clearState()
                repoPath = resolvedRoot
                repoDisplayPath = abbreviatePath(resolvedRoot)
                isGitRepo = true
                startPeriodicRefresh()
                await loadAll()
            } else {
                repoPath = path
                repoDisplayPath = abbreviatePath(path)
                isGitRepo = false
                stopPeriodicRefresh()
                clearState()
            }
        }
    }

    /// Refresh current status (branch + file changes + conflicts).
    func refresh() {
        guard isGitRepo else { return }
        Task {
            await loadBranch()
            await loadStatus()
        }
    }

    /// Full reload of all data (branch, status, history, stashes, graph, conflicts).
    private func loadAll() async {
        await loadBranch()
        await loadStatus()
        await loadHistory()
        await loadGraphHistory()
        await loadStashes()
        detectConflicts()
    }

    /// Clear all published state when directory is not a git repo.
    private func clearState() {
        currentBranch = ""
        aheadCount = 0
        behindCount = 0
        stagedFiles = []
        unstagedFiles = []
        commitHistory = []
        stashes = []
        graphNodes = []
        conflictFiles = []
    }

    /// Abbreviate a path for display, e.g. "/Users/foo/Projects/Bar" → "~/Projects/Bar".
    private func abbreviatePath(_ path: String) -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        if path.hasPrefix(home) {
            return "~" + path.dropFirst(home.count)
        }
        return path
    }

    // MARK: - Branch

    func loadBranch() async {
        if let branch = await runGit(["branch", "--show-current"]) {
            currentBranch = branch.trimmingCharacters(in: .whitespacesAndNewlines)
        }

        if let revList = await runGit(["rev-list", "--left-right", "--count", "HEAD...@{u}"]) {
            let parts = revList.trimmingCharacters(in: .whitespacesAndNewlines).split(separator: "\t")
            if parts.count == 2 {
                aheadCount = Int(parts[0]) ?? 0
                behindCount = Int(parts[1]) ?? 0
            }
        } else {
            // No upstream tracking branch — reset counts
            aheadCount = 0
            behindCount = 0
        }
    }

    // MARK: - Status

    func loadStatus() async {
        guard let output = await runGit(["status", "--porcelain=v1"]) else { return }

        var staged: [GitFileChange] = []
        var unstaged: [GitFileChange] = []

        for line in output.split(separator: "\n", omittingEmptySubsequences: true) {
            let lineStr = String(line)
            guard lineStr.count >= 4 else { continue }
            let indexStatus = lineStr[lineStr.startIndex]
            let workStatus = lineStr[lineStr.index(lineStr.startIndex, offsetBy: 1)]
            let filePath = String(lineStr[lineStr.index(lineStr.startIndex, offsetBy: 3)...])

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
            let result = await runGitFull(["commit", "-m", commitMessage])
            if result.succeeded {
                setOperationStatus(.success(message: LS("git.commitSuccess")))
                commitMessage = ""
                await loadStatus()
                await loadHistory()
            } else {
                setOperationStatus(.failure(message: LS("git.commitFailed"), detail: result.stderr))
            }
        }
    }

    func pull() {
        Task {
            setOperationStatus(.running(description: LS("git.pulling")))
            let result = await runGitFull(["pull"])
            if result.succeeded {
                setOperationStatus(.success(message: LS("git.pullSuccess")))
                await loadBranch()
                await loadStatus()
                await loadHistory()
            } else {
                setOperationStatus(.failure(message: LS("git.pullFailed"), detail: result.stderr))
            }
        }
    }

    func push() {
        Task {
            setOperationStatus(.running(description: LS("git.pushing")))
            let result = await runGitFull(["push"])
            if result.succeeded {
                setOperationStatus(.success(message: LS("git.pushSuccess")))
                await loadBranch()
            } else {
                setOperationStatus(.failure(message: LS("git.pushFailed"), detail: result.stderr))
            }
        }
    }

    func showDiff(_ path: String) {
        Task {
            if let diff = await runGit(["diff", path]) {
                NotificationCenter.default.post(
                    name: .gitShowDiff,
                    object: ["diff": diff]
                )
            }
        }
    }

    func initRepo() {
        Task {
            let result = await runGitFull(["init"])
            if result.succeeded {
                setOperationStatus(.success(message: LS("git.initSuccess")))
                setRepoPath(repoPath)
            } else {
                setOperationStatus(.failure(message: LS("git.initFailed"), detail: result.stderr))
            }
        }
    }

    func checkout(_ hash: String) {
        Task {
            let result = await runGitFull(["checkout", hash])
            if result.succeeded {
                setOperationStatus(.success(message: String(format: LS("git.checkoutSuccess"), String(hash.prefix(7)))))
                await loadBranch()
                await loadStatus()
            } else {
                setOperationStatus(.failure(message: LS("git.checkoutFailed"), detail: result.stderr))
            }
        }
    }

    func cherryPick(_ hash: String) {
        Task {
            let result = await runGitFull(["cherry-pick", hash])
            if result.succeeded {
                setOperationStatus(.success(message: String(format: LS("git.cherryPickSuccess"), String(hash.prefix(7)))))
                await loadStatus()
                await loadHistory()
            } else {
                setOperationStatus(.failure(message: LS("git.cherryPickFailed"), detail: result.stderr))
            }
        }
    }

    // MARK: - History

    func loadHistory() async {
        let sep = "<SEP>"
        guard let output = await runGit([
            "log", "-50",
            "--format=%H" + sep + "%h" + sep + "%s" + sep + "%an" + sep + "%ar"
        ]) else { return }

        commitHistory = output.split(separator: "\n").compactMap { line in
            let parts = String(line).components(separatedBy: sep)
            guard parts.count >= 5 else { return nil }
            return GitCommit(
                hash: parts[0],
                shortHash: parts[1],
                message: parts[2],
                author: parts[3],
                date: nil,
                relativeDate: parts[4]
            )
        }
    }

    // MARK: - Unified Graph + History (progressive loading)

    func loadGraphHistory() async {
        graphSkipCount = 0
        hasMoreHistory = true
        laneState = LaneState()

        // Phase 1: Fetch HEAD's first-parent chain (determines which commits stay at lane 0).
        if let fpOutput = await runGit(["log", "--first-parent", "HEAD", "--format=%H"]) {
            laneState.mainChain = Set(fpOutput.split(separator: "\n").map(String.init))
        }

        // Phase 2: Load all commits (all branches, date order).
        let sep = "<SEP>"
        guard let output = await runGit([
            "log", "--all", "--date-order",
            "-\(graphPageSize)",
            "--format=%H" + sep + "%P" + sep + "%h" + sep + "%d" + sep + "%s" + sep + "%an" + sep + "%ar"
        ]) else {
            graphNodes = []
            return
        }
        var nodes = Self.parseCommitNodes(output)
        laneState.assignLanes(&nodes)
        LaneState.computeSegments(&nodes)
        graphNodes = nodes
        graphSkipCount = nodes.count
        hasMoreHistory = nodes.count >= graphPageSize
    }

    func loadMoreGraphHistory() async {
        guard hasMoreHistory, !isLoadingMoreHistory else { return }
        isLoadingMoreHistory = true
        let sep = "<SEP>"
        guard let output = await runGit([
            "log", "--all", "--date-order",
            "-\(graphPageSize)",
            "--skip=\(graphSkipCount)",
            "--format=%H" + sep + "%P" + sep + "%h" + sep + "%d" + sep + "%s" + sep + "%an" + sep + "%ar"
        ]) else {
            isLoadingMoreHistory = false
            return
        }
        var nodes = Self.parseCommitNodes(output)
        laneState.assignLanes(&nodes)
        var allNodes = graphNodes
        allNodes.append(contentsOf: nodes)
        LaneState.computeSegments(&allNodes)
        graphNodes = allNodes
        graphSkipCount += nodes.count
        hasMoreHistory = nodes.count >= graphPageSize
        isLoadingMoreHistory = false
    }

    /// Parse git log output into CommitNode array (before lane assignment).
    private static func parseCommitNodes(_ output: String) -> [CommitNode] {
        let sep = "<SEP>"
        return output.components(separatedBy: "\n").compactMap { line -> CommitNode? in
            guard !line.isEmpty else { return nil }
            let parts = line.components(separatedBy: sep)
            guard parts.count >= 7 else { return nil }
            let hash = parts[0]
            let parentStr = parts[1]
            let parents = parentStr.isEmpty ? [] : parentStr.split(separator: " ").map(String.init)
            let shortHash = parts[2]
            // Parse decorations
            var refs: [String] = []
            let decoRaw = parts[3].trimmingCharacters(in: .whitespaces)
            if decoRaw.hasPrefix("(") && decoRaw.hasSuffix(")") {
                let inner = String(decoRaw.dropFirst().dropLast())
                refs = inner.split(separator: ",").map {
                    $0.trimmingCharacters(in: .whitespaces)
                        .replacingOccurrences(of: "HEAD -> ", with: "\u{2192} ")
                }
            }
            return CommitNode(
                id: hash,
                shortHash: shortHash,
                message: parts[4],
                author: parts[5],
                relativeDate: parts[6],
                refs: refs,
                parents: parents
            )
        }
    }

    // MARK: - Stash

    private func loadStashes() async {
        let sep = "<SEP>"
        guard let output = await runGit(["stash", "list", "--format=%gd" + sep + "%gs"]) else { return }

        stashes = output.split(separator: "\n").enumerated().compactMap { index, line in
            let parts = String(line).components(separatedBy: sep)
            guard parts.count >= 1 else { return nil }
            return GitStashEntry(
                index: index,
                message: parts.count > 1 ? parts[1] : parts[0],
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

    /// Run a git command and return stdout on success, nil on failure.
    func runGit(_ args: [String]) async -> String? {
        guard !repoPath.isEmpty else { return nil }
        let result = await CommandRunner.shared.run(
            "git",
            arguments: args,
            currentDirectory: repoPath
        )
        return result.succeeded ? result.output : nil
    }



    /// Run a git command and return the full CommandResult (stdout + stderr + exitCode).
    func runGitFull(_ args: [String]) async -> CommandResult {
        guard !repoPath.isEmpty else {
            return CommandResult(stdout: "", stderr: "No repository path set", exitCode: -1)
        }
        return await CommandRunner.shared.run(
            "git",
            arguments: args,
            currentDirectory: repoPath
        )
    }

    // MARK: - Operation Status

    /// Update operation status and auto-dismiss success/failure after a delay.
    func setOperationStatus(_ status: GitOperationStatus) {
        operationStatus = status
        statusDismissTask?.cancel()

        switch status {
        case .success, .failure:
            statusDismissTask = Task { [weak self] in
                try? await Task.sleep(nanoseconds: 4_000_000_000) // 4 seconds
                guard !Task.isCancelled else { return }
                self?.operationStatus = .idle
            }
        case .idle, .running:
            break
        }
    }
}

// MARK: - Operation Status Model

enum GitOperationStatus: Equatable {
    case idle
    case running(description: String)
    case success(message: String)
    case failure(message: String, detail: String?)
}

// MARK: - Notifications

extension Notification.Name {
    static let gitShowDiff = Notification.Name("pier.gitShowDiff")
    static let gitShowBlame = Notification.Name("pier.gitShowBlame")
}
