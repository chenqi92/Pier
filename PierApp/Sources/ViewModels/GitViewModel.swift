import SwiftUI
import Combine
import CPierCore

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
    var id: String { path + ":" + status.badge }
    let path: String
    let status: GitFileStatus

    var fileName: String {
        (path as NSString).lastPathComponent
    }

    /// Directory portion of path for gray-text display (e.g. "PierApp/Sources/ViewModels")
    var parentPath: String {
        let dir = (path as NSString).deletingLastPathComponent
        return dir.isEmpty ? "" : dir
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

/// Date range presets for graph filtering.
enum GraphDateRange: String, CaseIterable {
    case all
    case today
    case lastWeek
    case lastMonth
    case lastYear
}

@MainActor
class GitViewModel: ObservableObject {
    // MARK: - Published State

    @Published var selectedTab: GitTab = .changes
    @Published var isGitRepo = false
    @Published var currentBranch = ""
    @Published var trackingBranch = ""  // e.g. "origin/main"
    @Published var localBranches: [String] = []
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
    @Published var graphBranches: [String] = []
    @Published var graphFilterBranch: String? = nil  // nil = all branches
    @Published var showLongEdges = true               // edge display mode
    @Published var graphSearchText = ""                // text/hash search
    @Published var graphFilterUser: String? = nil      // author filter
    @Published var graphFilterDateRange: GraphDateRange = .all
    @Published var graphFilterPath: String? = nil      // path filter
    @Published var graphSortByDate = true              // sort: date vs topo
    @Published var graphFirstParentOnly = false        // first-parent option
    @Published var graphNoMerges = false               // no-merges option
    @Published var graphAuthors: [String] = []         // available authors
    @Published var graphRepoFiles: [String] = []        // tracked file paths for tree picker
    // Display options
    @Published var graphShowHash = true                 // show hash column
    @Published var graphShowAuthor = true               // show author column
    @Published var graphShowDate = true                 // show date column
    @Published var graphShowZebraStripes = true         // alternating row background
    @Published var graphGeneration = 0                  // increments on full reload only (not loadMore)

    // MARK: - Private

    private(set) var repoPath: String = ""
    private var timer: AnyCancellable?
    private let graphPageSize = 500
    private var graphSkipCount = 0
    private var mainChainJSON: String = "[]"
    private var cachedCommitsJSON: String = "[]"  // raw commits JSON for incremental loadMore
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

        // Fetch tracking remote branch
        if let tracking = await runGit(["rev-parse", "--abbrev-ref", "--symbolic-full-name", "@{u}"]) {
            trackingBranch = tracking.trimmingCharacters(in: .whitespacesAndNewlines)
        } else {
            trackingBranch = ""
        }

        // Fetch local branch list
        if let branchOutput = await runGit(["branch", "--format=%(refname:short)"]) {
            localBranches = branchOutput.components(separatedBy: "\n")
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
                .sorted()
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
        let result = await runGitFull(["status", "--porcelain=v1"])
        // Even if output is empty (clean tree), we must clear the lists
        let output = result.stdout

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

    func unstageAll() {
        Task {
            _ = await runGit(["reset", "HEAD"])
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
                await loadBranch()
            } else {
                setOperationStatus(.failure(message: LS("git.commitFailed"), detail: result.stderr))
            }
        }
    }

    func commitAndPush() {
        guard !commitMessage.isEmpty else { return }
        Task {
            let commitResult = await runGitFull(["commit", "-m", commitMessage])
            if commitResult.succeeded {
                commitMessage = ""
                setOperationStatus(.running(description: LS("git.pushing")))
                let pushResult = await runGitFull(["push"])
                if pushResult.succeeded {
                    setOperationStatus(.success(message: LS("git.commitAndPushSuccess")))
                } else {
                    setOperationStatus(.failure(message: LS("git.pushFailed"), detail: pushResult.stderr))
                }
                await loadStatus()
                await loadHistory()
                await loadBranch()
            } else {
                setOperationStatus(.failure(message: LS("git.commitFailed"), detail: commitResult.stderr))
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

    func showDiffStaged(_ path: String) {
        Task {
            if let diff = await runGit(["diff", "--cached", path]) {
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

    // MARK: - Unified Graph + History (git2 FFI — direct .git access)

    /// Call a pier_git_* FFI function and return the C string as a Swift String.
    /// Automatically frees the C string after copying.
    private func callGitFFI(_ cString: UnsafeMutablePointer<CChar>?) -> String? {
        guard let ptr = cString else { return nil }
        let result = String(cString: ptr)
        pier_string_free(ptr)
        return result
    }

    /// Static (nonisolated) version for use in Task.detached background work.
    nonisolated static func callGitFFIStatic(_ cString: UnsafeMutablePointer<CChar>?) -> String? {
        guard let ptr = cString else { return nil }
        let result = String(cString: ptr)
        pier_string_free(ptr)
        return result
    }

    /// Compute the Unix timestamp for the date range filter.
    private func afterTimestamp() -> Int64 {
        let now = Date()
        switch graphFilterDateRange {
        case .all: return 0
        case .today:
            return Int64(Calendar.current.startOfDay(for: now).timeIntervalSince1970)
        case .lastWeek:
            return Int64((Calendar.current.date(byAdding: .weekOfYear, value: -1, to: now) ?? now).timeIntervalSince1970)
        case .lastMonth:
            return Int64((Calendar.current.date(byAdding: .month, value: -1, to: now) ?? now).timeIntervalSince1970)
        case .lastYear:
            return Int64((Calendar.current.date(byAdding: .year, value: -1, to: now) ?? now).timeIntervalSince1970)
        }
    }

    func loadGraphHistory() async {
        graphSkipCount = 0
        hasMoreHistory = true
        mainChainJSON = "[]"
        cachedCommitsJSON = "[]"
        guard !repoPath.isEmpty else { graphNodes = []; return }

        // Run branches + authors concurrently for UI pickers.
        async let branchTask: Void = fetchGraphBranches()
        async let authorTask: Void = fetchGraphAuthors()

        // Capture values for background work
        let path = repoPath
        let pageSize = graphPageSize
        let filterBranch = graphFilterBranch
        let filterUser = graphFilterUser
        let searchText = graphSearchText.trimmingCharacters(in: .whitespaces)
        let afterTs = afterTimestamp()
        let topoOrder = !graphSortByDate
        let firstParent = graphFirstParentOnly
        let noMerges = graphNoMerges
        let filterPath = graphFilterPath
        let longEdges = showLongEdges
        let lw = BranchGraphView.laneW
        let rh = BranchGraphView.rowH

        // Run heavy FFI on background thread
        let result = await Task.detached(priority: .userInitiated) { () -> (String, String, String)? in
            // Detect default branch
            let defaultBranch = Self.callGitFFIStatic(pier_git_detect_default_branch(path)) ?? "HEAD"

            // First-parent chain
            let fpJSON = Self.callGitFFIStatic(pier_git_first_parent_chain(path, defaultBranch, UInt32(pageSize * 2))) ?? "[]"

            // Load commits
            let logJSON = Self.callGitFFIStatic(pier_git_graph_log(
                path, UInt32(pageSize), 0,
                filterBranch, filterUser,
                searchText.isEmpty ? nil : searchText,
                afterTs, topoOrder, firstParent, noMerges, filterPath
            ))
            guard let json = logJSON else { return nil }

            // Compute layout
            let layoutJSON = Self.callGitFFIStatic(pier_git_compute_graph_layout(
                json, fpJSON,
                Float(lw), Float(rh),
                longEdges
            ))
            guard let layout = layoutJSON else { return nil }
            return (json, fpJSON, layout)
        }.value

        _ = await (branchTask, authorTask)

        guard let (json, fpJSON, layoutResult) = result else { graphNodes = []; return }
        mainChainJSON = fpJSON
        cachedCommitsJSON = json
        graphNodes = Self.parseLayoutNodesFromJSON(layoutResult)
        graphSkipCount = graphNodes.count
        hasMoreHistory = graphNodes.count >= graphPageSize
        graphGeneration += 1  // signal full reload to UI
    }

    func loadMoreGraphHistory() async {
        guard hasMoreHistory, !isLoadingMoreHistory, !repoPath.isEmpty else { return }
        isLoadingMoreHistory = true

        // Capture values for background work
        let path = repoPath
        let pageSize = graphPageSize
        let skipCount = graphSkipCount
        let filterBranch = graphFilterBranch
        let filterUser = graphFilterUser
        let searchText = graphSearchText.trimmingCharacters(in: .whitespaces)
        let afterTs = afterTimestamp()
        let topoOrder = !graphSortByDate
        let firstParent = graphFirstParentOnly
        let noMerges = graphNoMerges
        let filterPath = graphFilterPath
        let longEdges = showLongEdges
        let lw = BranchGraphView.laneW
        let rh = BranchGraphView.rowH
        let oldJSON = cachedCommitsJSON
        let mainJSON = mainChainJSON

        // Run heavy FFI on background thread to avoid blocking UI
        let result = await Task.detached(priority: .userInitiated) { () -> (String, String)? in
            let logJSON = Self.callGitFFIStatic(pier_git_graph_log(
                path, UInt32(pageSize), UInt32(skipCount),
                filterBranch, filterUser,
                searchText.isEmpty ? nil : searchText,
                afterTs, topoOrder, firstParent, noMerges, filterPath
            ))
            guard let json = logJSON else { return nil }

            let mergedJSON = Self.mergeJSONArrays(oldJSON, json)
            let layoutJSON = Self.callGitFFIStatic(pier_git_compute_graph_layout(
                mergedJSON, mainJSON,
                Float(lw), Float(rh),
                longEdges
            ))
            guard let layout = layoutJSON else { return nil }
            return (mergedJSON, layout)
        }.value

        guard let (mergedJSON, layoutResult) = result else {
            isLoadingMoreHistory = false
            return
        }

        cachedCommitsJSON = mergedJSON
        let previousCount = graphNodes.count
        graphNodes = Self.parseLayoutNodesFromJSON(layoutResult)
        graphSkipCount = graphNodes.count
        hasMoreHistory = (graphNodes.count - previousCount) >= graphPageSize
        isLoadingMoreHistory = false
    }

    /// Merge two JSON arrays by concatenating their elements.
    /// Much faster than decoding/re-encoding: just string manipulation.
    nonisolated private static func mergeJSONArrays(_ a: String, _ b: String) -> String {
        let aT = a.trimmingCharacters(in: .whitespaces)
        let bT = b.trimmingCharacters(in: .whitespaces)
        // Handle empty cases
        if aT == "[]" || aT.isEmpty { return bT }
        if bT == "[]" || bT.isEmpty { return aT }
        // Strip outer brackets and concatenate
        guard aT.hasPrefix("[") && aT.hasSuffix("]"),
              bT.hasPrefix("[") && bT.hasSuffix("]") else {
            return aT  // fallback
        }
        let aInner = aT.dropFirst().dropLast()
        let bInner = bT.dropFirst().dropLast()
        return "[\(aInner),\(bInner)]"
    }

    /// Fetch all local and remote branch names via FFI.
    private func fetchGraphBranches() async {
        guard !repoPath.isEmpty else { graphBranches = []; return }
        if let json = callGitFFI(pier_git_list_branches(repoPath)) {
            if let branches = try? JSONDecoder().decode([String].self, from: Data(json.utf8)) {
                graphBranches = branches
                return
            }
        }
        graphBranches = []
    }

    /// Fetch unique commit authors via FFI.
    private func fetchGraphAuthors() async {
        guard !repoPath.isEmpty else { graphAuthors = []; return }
        if let json = callGitFFI(pier_git_list_authors(repoPath, 500)) {
            if let authors = try? JSONDecoder().decode([String].self, from: Data(json.utf8)) {
                graphAuthors = authors
                return
            }
        }
        graphAuthors = []
    }

    /// Fetch tracked files via FFI.
    func fetchRepoFiles() async {
        guard !repoPath.isEmpty else { graphRepoFiles = []; return }
        if let json = callGitFFI(pier_git_list_tracked_files(repoPath)) {
            if let files = try? JSONDecoder().decode([String].self, from: Data(json.utf8)) {
                graphRepoFiles = files
                return
            }
        }
        graphRepoFiles = []
    }

    /// Parse commit nodes from JSON returned by pier_git_graph_log FFI.
    private static func parseCommitNodesFromJSON(_ json: String) -> [CommitNode] {
        struct FFICommit: Decodable {
            let hash: String
            let parents: String
            let short_hash: String
            let refs: String
            let message: String
            let author: String
            let date_timestamp: Int64
        }
        guard let data = json.data(using: .utf8),
              let commits = try? JSONDecoder().decode([FFICommit].self, from: data) else {
            return []
        }
        let cal = Calendar.current
        let now = Date()
        let todayStart = cal.startOfDay(for: now)
        let yesterdayStart = cal.date(byAdding: .day, value: -1, to: todayStart)!
        let timeFmt = DateFormatter()
        timeFmt.dateFormat = "HH:mm"
        let fullFmt = DateFormatter()
        fullFmt.dateFormat = "yyyy/M/d HH:mm"

        return commits.map { c in
            let parents = c.parents.isEmpty ? [] : c.parents.split(separator: " ").map(String.init)
            var refs: [String] = []
            let decoRaw = c.refs.trimmingCharacters(in: .whitespaces)
            if decoRaw.hasPrefix("(") && decoRaw.hasSuffix(")") {
                let inner = String(decoRaw.dropFirst().dropLast())
                refs = inner.split(separator: ",").map {
                    $0.trimmingCharacters(in: .whitespaces)
                        .replacingOccurrences(of: "HEAD -> ", with: "\u{2192} ")
                }
            }
            // Format date IDEA-style: 今天/昨天 HH:mm or yyyy/M/d HH:mm
            let commitDate = Date(timeIntervalSince1970: TimeInterval(c.date_timestamp))
            let dateStr: String
            if commitDate >= todayStart {
                dateStr = "今天 \(timeFmt.string(from: commitDate))"
            } else if commitDate >= yesterdayStart {
                dateStr = "昨天 \(timeFmt.string(from: commitDate))"
            } else {
                dateStr = fullFmt.string(from: commitDate)
            }
            return CommitNode(
                id: c.hash,
                shortHash: c.short_hash,
                message: c.message,
                author: c.author,
                relativeDate: dateStr,
                refs: refs,
                parents: parents
            )
        }
    }

    /// Raw commit data for round-tripping through JSON during loadMore pagination.
    /// This matches the LayoutInput struct expected by Rust's compute_graph_layout.
    private struct FFICommitRaw: Codable {
        let hash: String
        let parents: String
        let short_hash: String
        let refs: String
        let message: String
        let author: String
        let date_timestamp: Int64

        init(from node: CommitNode) {
            self.hash = node.id
            self.parents = node.parents.joined(separator: " ")
            self.short_hash = node.shortHash
            self.refs = node.rawRefs
            self.message = node.message
            self.author = node.author
            self.date_timestamp = node.dateTimestamp
        }
    }

    /// Parse layout JSON from Rust (GraphRow array) into CommitNode array.
    /// The Rust output includes pre-computed lane, colorIndex, segments, and arrows.
    private static func parseLayoutNodesFromJSON(_ json: String) -> [CommitNode] {
        struct FFISegment: Decodable {
            let x_top: CGFloat
            let y_top: CGFloat
            let x_bottom: CGFloat
            let y_bottom: CGFloat
            let color_index: Int
        }
        struct FFIArrow: Decodable {
            let x: CGFloat
            let y: CGFloat
            let color_index: Int
            let is_down: Bool
        }
        struct FFIGraphRow: Decodable {
            let hash: String
            let short_hash: String
            let message: String
            let author: String
            let date_timestamp: Int64
            let refs: String
            let parents: String
            let node_column: Int
            let color_index: Int
            let segments: [FFISegment]
            let arrows: [FFIArrow]
        }

        guard let data = json.data(using: .utf8),
              let rows = try? JSONDecoder().decode([FFIGraphRow].self, from: data) else {
            return []
        }

        let cal = Calendar.current
        let now = Date()
        let todayStart = cal.startOfDay(for: now)
        let yesterdayStart = cal.date(byAdding: .day, value: -1, to: todayStart)!
        let timeFmt = DateFormatter()
        timeFmt.dateFormat = "HH:mm"
        let fullFmt = DateFormatter()
        fullFmt.dateFormat = "yyyy/M/d HH:mm"

        return rows.map { r in
            let parents = r.parents.isEmpty ? [] : r.parents.split(separator: " ").map(String.init)
            var refs: [String] = []
            let decoRaw = r.refs.trimmingCharacters(in: .whitespaces)
            if decoRaw.hasPrefix("(") && decoRaw.hasSuffix(")") {
                let inner = String(decoRaw.dropFirst().dropLast())
                refs = inner.split(separator: ",").map {
                    $0.trimmingCharacters(in: .whitespaces)
                        .replacingOccurrences(of: "HEAD -> ", with: "\u{2192} ")
                }
            }
            let commitDate = Date(timeIntervalSince1970: TimeInterval(r.date_timestamp))
            let dateStr: String
            if commitDate >= todayStart {
                dateStr = "今天 \(timeFmt.string(from: commitDate))"
            } else if commitDate >= yesterdayStart {
                dateStr = "昨天 \(timeFmt.string(from: commitDate))"
            } else {
                dateStr = fullFmt.string(from: commitDate)
            }

            var node = CommitNode(
                id: r.hash,
                shortHash: r.short_hash,
                message: r.message,
                author: r.author,
                relativeDate: dateStr,
                refs: refs,
                parents: parents
            )
            node.lane = r.node_column
            node.colorIndex = r.color_index
            node.segments = r.segments.map {
                Segment(xTop: $0.x_top, yTop: $0.y_top, xBottom: $0.x_bottom, yBottom: $0.y_bottom, colorIndex: $0.color_index)
            }
            node.arrows = r.arrows.map {
                ArrowIndicator(x: $0.x, y: $0.y, colorIndex: $0.color_index, isDown: $0.is_down)
            }
            node.dateTimestamp = r.date_timestamp
            node.rawRefs = r.refs
            return node
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
