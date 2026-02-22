import SwiftUI

// MARK: - Data Model

struct Segment {
    let xTop: CGFloat
    let yTop: CGFloat
    let xBottom: CGFloat
    let yBottom: CGFloat
    let colorIndex: Int
}

/// Arrow indicator for long-span branch lines (IDEA-style break).
struct ArrowIndicator {
    let x: CGFloat
    let y: CGFloat
    let colorIndex: Int
    let isDown: Bool  // true = ↓ (start break), false = ↑ (resume)
}

struct CommitNode: Identifiable {
    let id: String          // full hash
    let shortHash: String
    let message: String
    let author: String
    let relativeDate: String
    let refs: [String]
    let parents: [String]   // full hashes of parents
    var isMerge: Bool { parents.count >= 2 }
    var lane: Int = 0
    var colorIndex: Int = 0
    var segments: [Segment] = []
    var arrows: [ArrowIndicator] = []
    var dateTimestamp: Int64 = 0   // original Unix timestamp for round-tripping
    var rawRefs: String = ""       // original refs decoration string for round-tripping
}

// MARK: - Highlight Mode

enum GraphHighlightMode: String, CaseIterable {
    case none
    case myCommits
    case mergeCommits
    case currentBranch
}

// MARK: - Graph Layout (IDEA-style)
//
// The graph layout computation (DFS layoutIndex, active edges, column positioning,
// segment/arrow generation) is now performed in Rust (pier-core/src/git_graph.rs)
// via the pier_git_compute_graph_layout FFI function.
//
// Swift only handles rendering: the CommitNode's lane, colorIndex, segments,
// and arrows fields are populated directly from the Rust-computed JSON.

// MARK: - View

struct BranchGraphView: View {
    @ObservedObject var gitViewModel: GitViewModel

    static let palette: [Color] = [
        Color(red: 0.27, green: 0.69, blue: 0.35),   // 0 = main (green, like IDEA)
        Color(red: 0.25, green: 0.58, blue: 0.96),   // blue
        Color(red: 0.87, green: 0.42, blue: 0.12),   // orange
        Color(red: 0.68, green: 0.35, blue: 0.82),   // purple
        Color(red: 0.94, green: 0.33, blue: 0.31),   // red
        Color(red: 0.16, green: 0.71, blue: 0.76),   // teal
        Color(red: 0.89, green: 0.68, blue: 0.12),   // yellow
        Color(red: 0.85, green: 0.35, blue: 0.60),   // pink
    ]
    static let laneW: CGFloat = 14
    static let rowH: CGFloat = 22
    static let dotR: CGFloat = 3.5

    @State private var selectedHash: String?
    @State private var selectedDetail: GitCommitDetail?
    @State private var showingPathPicker = false
    @State private var pathPickerSelection: Set<String> = []
    @State private var highlightMode: GraphHighlightMode = .none

    // Context menu dialog state
    @State private var ctxTargetNode: CommitNode?
    @State private var showNewBranchDialog = false
    @State private var showNewTagDialog = false
    @State private var showResetDialog = false
    @State private var newBranchName = ""
    @State private var newTagName = ""
    @State private var resetMode = "mixed" // soft, mixed, hard
    @State private var showDiffSheet = false
    @State private var diffOutput = ""
    @State private var diffFiles: [String] = []           // changed file paths for compare
    @State private var selectedDiffFile: String?          // currently selected file
    @State private var diffFileContent: String = ""        // diff content of selected file
    @State private var diffCommitHash: String = ""         // commit hash being compared
    @State private var showEditMessageDialog = false
    @State private var editMessageText = ""

    // Column widths — resizable by dragging handle on each column's right edge
    @State private var hashColumnWidth: CGFloat = 62
    @State private var messageColumnWidth: CGFloat = 300
    @State private var authorColumnWidth: CGFloat = 100
    @State private var dateColumnWidth: CGFloat = 100
    @State private var cachedGraphWidth: CGFloat = 60  // graph lane column width, updated on data change

    var body: some View {
        VStack(spacing: 0) {
            // Branch filter bar
            branchFilterBar
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(Color(nsColor: .controlBackgroundColor))

            Divider()

            if gitViewModel.graphNodes.isEmpty {
                VStack(spacing: 12) {
                    Image(systemName: "clock.arrow.circlepath").font(.system(size: 30)).foregroundColor(.secondary)
                    Text(LS("git.noGraph")).font(.caption).foregroundColor(.secondary)
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
            } else { scrollContent }
        }

        .sheet(isPresented: $showingPathPicker) { pathPickerSheet }
        .alert(LS("git.ctx.newBranch"), isPresented: $showNewBranchDialog) {
            TextField(LS("git.ctx.branchNamePlaceholder"), text: $newBranchName)
            Button(LS("git.ctx.create")) {
                guard let node = ctxTargetNode, !newBranchName.isEmpty else { return }
                Task { await performNewBranch(name: newBranchName, from: node.id) }
            }
            Button(LS("git.ctx.cancel"), role: .cancel) { newBranchName = "" }
        } message: {
            if let node = ctxTargetNode {
                Text(LS("git.ctx.newBranchMsg") + " \(node.shortHash)")
            }
        }
        .alert(LS("git.ctx.newTag"), isPresented: $showNewTagDialog) {
            TextField(LS("git.ctx.tagNamePlaceholder"), text: $newTagName)
            Button(LS("git.ctx.create")) {
                guard let node = ctxTargetNode, !newTagName.isEmpty else { return }
                Task { await performNewTag(name: newTagName, at: node.id) }
            }
            Button(LS("git.ctx.cancel"), role: .cancel) { newTagName = "" }
        } message: {
            if let node = ctxTargetNode {
                Text(LS("git.ctx.newTagMsg") + " \(node.shortHash)")
            }
        }
        .confirmationDialog(LS("git.ctx.resetToHere"), isPresented: $showResetDialog) {
            Button("Soft") {
                guard let node = ctxTargetNode else { return }
                Task { await performReset(to: node.id, mode: "soft") }
            }
            Button("Mixed") {
                guard let node = ctxTargetNode else { return }
                Task { await performReset(to: node.id, mode: "mixed") }
            }
            Button("Hard", role: .destructive) {
                guard let node = ctxTargetNode else { return }
                Task { await performReset(to: node.id, mode: "hard") }
            }
            Button(LS("git.ctx.cancel"), role: .cancel) {}
        } message: {
            if let node = ctxTargetNode {
                Text(LS("git.ctx.resetMsg") + " \(node.shortHash)")
            }
        }
        .sheet(isPresented: $showDiffSheet) {
            HSplitView {
                // Left: changed file list
                VStack(spacing: 0) {
                    HStack {
                        Text(LS("git.ctx.changedFiles")).font(.headline)
                        Spacer()
                        Text("\(diffFiles.count)").font(.caption).foregroundColor(.secondary)
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    Divider()
                    List(diffFiles, id: \.self, selection: $selectedDiffFile) { file in
                        HStack(spacing: 6) {
                            Image(systemName: "doc.text")
                                .font(.caption)
                                .foregroundColor(.secondary)
                            Text((file as NSString).lastPathComponent)
                                .font(.system(size: 11))
                                .lineLimit(1)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .listStyle(.sidebar)
                }
                .frame(minWidth: 180, idealWidth: 220, maxWidth: 280)

                // Right: diff view for selected file
                VStack(spacing: 0) {
                    HStack {
                        if let file = selectedDiffFile {
                            Text(file).font(.system(size: 11, design: .monospaced)).lineLimit(1)
                        } else {
                            Text(LS("git.ctx.selectFile")).foregroundColor(.secondary)
                        }
                        Spacer()
                        Button(LS("git.ctx.close")) { showDiffSheet = false }
                            .buttonStyle(.plain)
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    Divider()
                    if !diffFileContent.isEmpty {
                        DiffView(diffText: diffFileContent)
                    } else {
                        VStack(spacing: 12) {
                            Image(systemName: "arrow.left.circle")
                                .font(.system(size: 30))
                                .foregroundColor(.secondary)
                            Text(LS("git.ctx.selectFileHint"))
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                }
            }
            .frame(minWidth: 900, minHeight: 600)
            .onChange(of: selectedDiffFile) {
                guard let file = selectedDiffFile else { diffFileContent = ""; return }
                Task {
                    let result = await gitViewModel.runGitFull(["diff", diffCommitHash, "--", file])
                    diffFileContent = result.combinedOutput
                }
            }
        }
        .sheet(isPresented: $showEditMessageDialog) {
            VStack(spacing: 0) {
                HStack {
                    Text(LS("git.ctx.editMessage")).font(.headline)
                    Spacer()
                }
                .padding(.horizontal, 16)
                .padding(.top, 16)
                .padding(.bottom, 8)

                TextEditor(text: $editMessageText)
                    .font(.system(size: 12, design: .monospaced))
                    .scrollContentBackground(.hidden)
                    .padding(8)
                    .background(Color(nsColor: .textBackgroundColor))
                    .cornerRadius(6)
                    .padding(.horizontal, 16)

                HStack {
                    Spacer()
                    Button(LS("git.ctx.cancel")) {
                        editMessageText = ""
                        showEditMessageDialog = false
                    }
                    .keyboardShortcut(.cancelAction)
                    Button(LS("git.ctx.save")) {
                        guard let node = ctxTargetNode, !editMessageText.isEmpty else { return }
                        showEditMessageDialog = false
                        Task { await performEditMessage(hash: node.id, newMessage: editMessageText) }
                    }
                    .keyboardShortcut(.defaultAction)
                    .disabled(editMessageText.isEmpty)
                }
                .padding(16)
            }
            .frame(minWidth: 500, minHeight: 300)
        }
        .onChange(of: gitViewModel.graphGeneration) {
            // Full reload: recalculate graph width from scratch
            cachedGraphWidth = computeGraphColumnWidth()
        }
        .onChange(of: gitViewModel.graphNodes.count) {
            // loadMore: only grow, never shrink (prevents horizontal scroll jump)
            let newWidth = computeGraphColumnWidth()
            if newWidth > cachedGraphWidth {
                cachedGraphWidth = newWidth
            }
        }
        .onAppear {
            cachedGraphWidth = computeGraphColumnWidth()
        }
    }

    // MARK: - IDEA-Style Toolbar

    private var branchFilterBar: some View {
        HStack(spacing: 4) {
            // ── Search field ──
            HStack(spacing: 3) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 9))
                    .foregroundColor(.secondary)
                TextField(LS("git.searchPlaceholder"), text: $gitViewModel.graphSearchText)
                    .font(.system(size: 10))
                    .textFieldStyle(.plain)
                    .frame(minWidth: 80, maxWidth: 140)
                    .onSubmit { Task { await gitViewModel.loadGraphHistory() } }
                if !gitViewModel.graphSearchText.isEmpty {
                    Button { gitViewModel.graphSearchText = ""; Task { await gitViewModel.loadGraphHistory() } } label: {
                        Image(systemName: "xmark.circle.fill").font(.system(size: 8)).foregroundColor(.secondary)
                    }.buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .background(RoundedRectangle(cornerRadius: 4).fill(Color(nsColor: .textBackgroundColor)))
            .overlay(RoundedRectangle(cornerRadius: 4).stroke(Color(nsColor: .separatorColor), lineWidth: 0.5))

            // ── Branch dropdown ──
            filterDropdown(
                label: gitViewModel.graphFilterBranch ?? LS("git.allBranches"),
                icon: "arrow.triangle.branch"
            ) {
                Button {
                    if gitViewModel.graphFilterBranch != nil {
                        gitViewModel.graphFilterBranch = nil
                        Task { await gitViewModel.loadGraphHistory() }
                    }
                } label: {
                    HStack {
                        Text(LS("git.allBranches"))
                        if gitViewModel.graphFilterBranch == nil { Image(systemName: "checkmark") }
                    }
                }
                Divider()
                ForEach(gitViewModel.graphBranches, id: \.self) { branch in
                    Button {
                        if gitViewModel.graphFilterBranch != branch {
                            gitViewModel.graphFilterBranch = branch
                            Task { await gitViewModel.loadGraphHistory() }
                        }
                    } label: {
                        HStack {
                            Text(branch)
                            if gitViewModel.graphFilterBranch == branch { Image(systemName: "checkmark") }
                        }
                    }
                }
            }

            // ── User dropdown ──
            filterDropdown(
                label: gitViewModel.graphFilterUser ?? LS("git.user"),
                icon: "person"
            ) {
                Button {
                    if gitViewModel.graphFilterUser != nil {
                        gitViewModel.graphFilterUser = nil
                        Task { await gitViewModel.loadGraphHistory() }
                    }
                } label: {
                    HStack {
                        Text(LS("git.allUsers"))
                        if gitViewModel.graphFilterUser == nil { Image(systemName: "checkmark") }
                    }
                }
                Divider()
                ForEach(gitViewModel.graphAuthors, id: \.self) { author in
                    Button {
                        if gitViewModel.graphFilterUser != author {
                            gitViewModel.graphFilterUser = author
                            Task { await gitViewModel.loadGraphHistory() }
                        }
                    } label: {
                        HStack {
                            Text(author)
                            if gitViewModel.graphFilterUser == author { Image(systemName: "checkmark") }
                        }
                    }
                }
            }

            // ── Date dropdown ──
            filterDropdown(
                label: dateRangeLabel(gitViewModel.graphFilterDateRange),
                icon: "calendar"
            ) {
                ForEach(GraphDateRange.allCases, id: \.self) { range in
                    Button {
                        if gitViewModel.graphFilterDateRange != range {
                            gitViewModel.graphFilterDateRange = range
                            Task { await gitViewModel.loadGraphHistory() }
                        }
                    } label: {
                        HStack {
                            Text(dateRangeLabel(range))
                            if gitViewModel.graphFilterDateRange == range { Image(systemName: "checkmark") }
                        }
                    }
                }
            }

            // ── Path button (opens tree picker sheet) ──
            Button {
                Task {
                    await gitViewModel.fetchRepoFiles()
                    // Initialize selection from current filter
                    if let current = gitViewModel.graphFilterPath {
                        pathPickerSelection = Set(current.components(separatedBy: "\n").filter { !$0.isEmpty })
                    } else {
                        pathPickerSelection = []
                    }
                    showingPathPicker = true
                }
            } label: {
                HStack(spacing: 3) {
                    Image(systemName: "folder")
                        .font(.system(size: 8))
                        .foregroundColor(.secondary)
                    Text(gitViewModel.graphFilterPath != nil ? String(gitViewModel.graphFilterPath!.prefix(20)) : LS("git.path"))
                        .font(.system(size: 10, weight: .medium))
                        .lineLimit(1)
                    Image(systemName: "chevron.down")
                        .font(.system(size: 7, weight: .semibold))
                        .foregroundColor(.secondary)
                }
                .padding(.horizontal, 6)
                .padding(.vertical, 3)
                .background(RoundedRectangle(cornerRadius: 4).fill(
                    gitViewModel.graphFilterPath != nil
                        ? Color.accentColor.opacity(0.15)
                        : Color(nsColor: .controlColor)
                ))
            }
            .buttonStyle(.plain)
            .fixedSize()
            // Clear path filter button
            if gitViewModel.graphFilterPath != nil {
                Button {
                    gitViewModel.graphFilterPath = nil
                    Task { await gitViewModel.loadGraphHistory() }
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 9))
                        .foregroundColor(.secondary)
                }
                .buttonStyle(.plain)
            }

            Spacer()

            // ── Settings gear menu ──
            Menu {
                // Sort section
                Section(LS("git.sort")) {
                    Button {
                        if !gitViewModel.graphSortByDate {
                            gitViewModel.graphSortByDate = true
                            Task { await gitViewModel.loadGraphHistory() }
                        }
                    } label: {
                        HStack {
                            Text(LS("git.sortByDate"))
                            if gitViewModel.graphSortByDate { Image(systemName: "checkmark") }
                        }
                    }
                    Button {
                        if gitViewModel.graphSortByDate {
                            gitViewModel.graphSortByDate = false
                            Task { await gitViewModel.loadGraphHistory() }
                        }
                    } label: {
                        HStack {
                            Text(LS("git.sortByTopo"))
                            if !gitViewModel.graphSortByDate { Image(systemName: "checkmark") }
                        }
                    }
                }

                Divider()

                // Options section
                Section(LS("git.options")) {
                    Button {
                        gitViewModel.graphFirstParentOnly.toggle()
                        Task { await gitViewModel.loadGraphHistory() }
                    } label: {
                        HStack {
                            Text(LS("git.firstParent"))
                            if gitViewModel.graphFirstParentOnly { Image(systemName: "checkmark") }
                        }
                    }
                    Button {
                        gitViewModel.graphNoMerges.toggle()
                        Task { await gitViewModel.loadGraphHistory() }
                    } label: {
                        HStack {
                            Text(LS("git.noMerges"))
                            if gitViewModel.graphNoMerges { Image(systemName: "checkmark") }
                        }
                    }
                }

                Divider()

                // Branch operations section
                Section(LS("git.branchOps")) {
                    Button {
                        if gitViewModel.showLongEdges {
                            gitViewModel.showLongEdges = false
                            Task { await gitViewModel.loadGraphHistory() }
                        }
                    } label: {
                        HStack {
                            Text(LS("git.collapseLin"))
                            if !gitViewModel.showLongEdges { Image(systemName: "checkmark") }
                        }
                    }
                    Button {
                        if !gitViewModel.showLongEdges {
                            gitViewModel.showLongEdges = true
                            Task { await gitViewModel.loadGraphHistory() }
                        }
                    } label: {
                        HStack {
                            Text(LS("git.expandLin"))
                            if gitViewModel.showLongEdges { Image(systemName: "checkmark") }
                        }
                    }
                }

                Divider()

                // Highlight section
                Section(LS("git.highlight")) {
                    ForEach(GraphHighlightMode.allCases, id: \.self) { mode in
                        Button {
                            highlightMode = mode
                        } label: {
                            HStack {
                                Text(highlightLabel(mode))
                                if highlightMode == mode { Image(systemName: "checkmark") }
                            }
                        }
                    }
                }

                Divider()

                // Display section — zebra stripes
                Section(LS("git.display")) {
                    Button {
                        gitViewModel.graphShowZebraStripes.toggle()
                    } label: {
                        HStack {
                            Text(LS("git.zebraStripes"))
                            if gitViewModel.graphShowZebraStripes { Image(systemName: "checkmark") }
                        }
                    }
                }

                Divider()

                // Column visibility
                Section(LS("git.columns")) {
                    Button {
                        gitViewModel.graphShowHash.toggle()
                    } label: {
                        HStack {
                            Text(LS("git.columnHash"))
                            if gitViewModel.graphShowHash { Image(systemName: "checkmark") }
                        }
                    }
                    Button {
                        gitViewModel.graphShowAuthor.toggle()
                    } label: {
                        HStack {
                            Text(LS("git.columnAuthor"))
                            if gitViewModel.graphShowAuthor { Image(systemName: "checkmark") }
                        }
                    }
                    Button {
                        gitViewModel.graphShowDate.toggle()
                    } label: {
                        HStack {
                            Text(LS("git.columnDate"))
                            if gitViewModel.graphShowDate { Image(systemName: "checkmark") }
                        }
                    }
                }
            } label: {
                Image(systemName: "line.3.horizontal.decrease.circle")
                    .font(.system(size: 13))
                    .foregroundColor(.secondary)
                    .padding(3)
                    .contentShape(Rectangle())
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
        }
    }

    // MARK: - Toolbar Helpers

    /// Reusable dropdown button builder for filter menus.
    private func filterDropdown<Content: View>(
        label: String, icon: String, @ViewBuilder content: @escaping () -> Content
    ) -> some View {
        Menu {
            content()
        } label: {
            HStack(spacing: 3) {
                Image(systemName: icon)
                    .font(.system(size: 8))
                    .foregroundColor(.secondary)
                Text(label)
                    .font(.system(size: 10, weight: .medium))
                    .lineLimit(1)
                Image(systemName: "chevron.down")
                    .font(.system(size: 7, weight: .semibold))
                    .foregroundColor(.secondary)
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .background(RoundedRectangle(cornerRadius: 4).fill(Color(nsColor: .controlColor)))
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
    }

    /// Display label for a date range.
    private func dateRangeLabel(_ range: GraphDateRange) -> String {
        switch range {
        case .all: return LS("git.date")
        case .today: return LS("git.today")
        case .lastWeek: return LS("git.lastWeek")
        case .lastMonth: return LS("git.lastMonth")
        case .lastYear: return LS("git.lastYear")
        }
    }

    /// Invisible drag handle on the right edge of a column.
    private func columnResizeHandle(_ width: Binding<CGFloat>) -> some View {
        ColumnResizeHandle(width: width)
    }
}

// MARK: - Column Resize Handle (separate View for @GestureState)

/// Separate struct so each handle gets its own @GestureState for drag tracking.
private struct ColumnResizeHandle: View {
    @Binding var width: CGFloat
    @GestureState private var startWidth: CGFloat? = nil

    init(width: Binding<CGFloat>) {
        self._width = width
    }

    var body: some View {
        Color.clear
            .frame(width: 6)
            .contentShape(Rectangle())
            .onHover { hovering in
                if hovering {
                    NSCursor.resizeLeftRight.push()
                } else {
                    NSCursor.pop()
                }
            }
            .gesture(
                DragGesture(minimumDistance: 1)
                    .updating($startWidth) { _, state, _ in
                        if state == nil { state = width }
                    }
                    .onChanged { value in
                        if let sw = startWidth {
                            width = max(30, sw + value.translation.width)
                        }
                    }
            )
    }
}

extension BranchGraphView {

    /// Calculate graph column width from current nodes.
    private func computeGraphColumnWidth() -> CGFloat {
        let nodes = gitViewModel.graphNodes
        var maxX: CGFloat = 0
        for n in nodes {
            let nodeDx = CGFloat(n.lane) * Self.laneW + Self.laneW / 2 + 4
            maxX = max(maxX, nodeDx)
            for s in n.segments {
                maxX = max(maxX, s.xTop, s.xBottom)
            }
        }
        return max(maxX + Self.laneW, 60)
    }

    // MARK: - Scroll Content

    private var scrollContent: some View {
        ScrollView([.vertical, .horizontal]) {
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(Array(gitViewModel.graphNodes.enumerated()), id: \.element.id) { index, node in
                    VStack(spacing: 0) {
                        HStack(alignment: .center, spacing: 0) {
                            Canvas { ctx, size in drawRow(ctx, node: node, size: size) }
                                .frame(width: cachedGraphWidth, height: Self.rowH)
                            commitLabel(node)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .frame(height: Self.rowH)
                        .background(rowBackground(index: index, nodeId: node.id))
                        .opacity(shouldDimRow(node) ? 0.3 : 1.0)
                        .contentShape(Rectangle())
                        .onTapGesture { toggleDetail(node.id) }
                        .contextMenu { commitContextMenu(node) }
                        .onAppear {
                            // Preload: trigger loadMore at 50% scroll position
                            let threshold = max(1, Int(Double(gitViewModel.graphNodes.count) * 0.5))
                            if index == threshold && gitViewModel.hasMoreHistory && !gitViewModel.isLoadingMoreHistory {
                                Task { await gitViewModel.loadMoreGraphHistory() }
                            }
                        }
                        if let d = selectedDetail, d.hash == node.id { detailSection(d) }
                    }
                }
                loadingFooter
            }
        }
    }

    /// Row background: selection highlight OR zebra stripe OR clear.
    private func rowBackground(index: Int, nodeId: String) -> Color {
        if selectedHash == nodeId {
            return Color.accentColor.opacity(0.08)
        }
        if gitViewModel.graphShowZebraStripes && index % 2 == 1 {
            return Color(nsColor: .textColor).opacity(0.03)
        }
        return .clear
    }

    /// Whether this row should be dimmed based on current highlight mode.
    private func shouldDimRow(_ node: CommitNode) -> Bool {
        switch highlightMode {
        case .none:
            return false
        case .myCommits:
            let gitUser = gitViewModel.graphGitUserName
            if gitUser.isEmpty { return false }
            return node.author != gitUser
        case .mergeCommits:
            return !node.isMerge
        case .currentBranch:
            return node.colorIndex != 0
        }
    }

    /// Localized label for highlight mode.
    private func highlightLabel(_ mode: GraphHighlightMode) -> String {
        switch mode {
        case .none: return LS("git.highlightNone")
        case .myCommits: return LS("git.highlightMyCommits")
        case .mergeCommits: return LS("git.highlightMerge")
        case .currentBranch: return LS("git.highlightBranch")
        }
    }

    // MARK: - Context Menu (IDEA-style)

    /// Build the right-click context menu for a commit row.
    @ViewBuilder
    private func commitContextMenu(_ node: CommitNode) -> some View {
        // ── Parse refs into categories ──
        let localBranches = node.refs.filter {
            !$0.hasPrefix("origin/") && !$0.hasPrefix("→ ") && !$0.hasPrefix("tag:") && $0 != "HEAD"
        }
        let remoteBranches = node.refs.filter { $0.hasPrefix("origin/") }
        // HEAD branch: "→ main" → "main"
        let headBranch = node.refs.first(where: { $0.hasPrefix("→ ") })?.replacingOccurrences(of: "→ ", with: "")

        // Total checkout options beyond revision
        let extraOptions = (headBranch != nil ? 1 : 0) + localBranches.count + remoteBranches.count

        // ── 1. Checkout ──
        if extraOptions == 0 {
            // Only revision — direct button, no submenu
            Button(LS("git.ctx.checkoutRevision") + " \(node.shortHash)...") {
                Task { await performCheckout(target: node.id) }
            }
        } else {
            // Multiple options — submenu
            Menu(LS("git.ctx.checkout")) {
                Button(LS("git.ctx.checkoutRevision") + " \(node.shortHash)...") {
                    Task { await performCheckout(target: node.id) }
                }
                if let hb = headBranch {
                    Button(LS("git.ctx.checkoutBranch") + " '\(hb)'") {
                        Task { await performCheckout(target: hb) }
                    }
                }
                ForEach(localBranches, id: \.self) { branch in
                    Button(LS("git.ctx.checkoutBranch") + " '\(branch)'") {
                        Task { await performCheckout(target: branch) }
                    }
                }
                ForEach(remoteBranches, id: \.self) { branch in
                    Button(LS("git.ctx.checkoutBranch") + " '\(branch)'") {
                        let localName = branch.replacingOccurrences(of: "origin/", with: "")
                        Task { await performCheckout(target: localName, tracking: branch) }
                    }
                }
            }
        }

        // ── 2. Compare with local ──
        Button(LS("git.ctx.compareWithLocal")) {
            Task { await performCompareWithLocal(hash: node.id) }
        }

        Divider()

        // ── 3. Reset current branch to here ──
        Button(LS("git.ctx.resetToHere")) {
            ctxTargetNode = node
            showResetDialog = true
        }

        Divider()

        // ── Unpushed-only actions (grayed out for pushed commits) ──
        let isUnpushed = gitViewModel.graphUnpushedHashes.contains(node.id)

        // ── 4. Undo commit ──
        Button(LS("git.ctx.undoCommit")) {
            Task { await performUndoCommit(hash: node.id) }
        }
        .disabled(!isUnpushed)

        // ── 5. Edit commit message ──
        Button(LS("git.ctx.editMessage")) {
            ctxTargetNode = node
            Task {
                // Fetch full commit message (subject + body) via git log
                let result = await gitViewModel.runGitFull(["log", "-1", "--format=%B", node.id])
                editMessageText = result.combinedOutput.trimmingCharacters(in: .whitespacesAndNewlines)
                showEditMessageDialog = true
            }
        }
        .disabled(!isUnpushed)

        // ── 6. Drop commit ──
        Button(LS("git.ctx.dropCommit"), role: .destructive) {
            Task { await performDropCommit(node: node) }
        }
        .disabled(!isUnpushed)

        Divider()

        // ── 7. New branch ──
        Button(LS("git.ctx.newBranch")) {
            ctxTargetNode = node
            newBranchName = ""
            showNewBranchDialog = true
        }

        // ── 8. New tag ──
        Button(LS("git.ctx.newTag")) {
            ctxTargetNode = node
            newTagName = ""
            showNewTagDialog = true
        }

        // ── 9. Open in browser (only for GitHub/GitLab repos) ──
        if let commitURL = gitViewModel.commitBrowserURL(hash: node.id) {
            Divider()
            Button(LS("git.ctx.openInBrowser")) {
                NSWorkspace.shared.open(commitURL)
            }
        }
    }

    // MARK: - Context Menu Actions

    private func performCheckout(target: String, tracking: String? = nil) async {
        var args = ["checkout"]
        if let tracking {
            args += ["-b", target, tracking]
        } else {
            args.append(target)
        }
        let result = await gitViewModel.runGitFull(args)
        if result.succeeded {
            gitViewModel.setOperationStatus(.success(message: LS("git.ctx.checkoutSuccess") + " '\(target)'"))
            await gitViewModel.loadGraphHistory()
        } else {
            gitViewModel.setOperationStatus(.failure(message: LS("git.ctx.checkoutFailed"), detail: result.combinedOutput))
        }
    }

    private func performCompareWithLocal(hash: String) async {
        // Get list of changed files
        let nameResult = await gitViewModel.runGitFull(["diff", "--name-only", hash])
        let files = nameResult.combinedOutput.split(separator: "\n").map(String.init).filter { !$0.isEmpty }
        diffFiles = files
        diffCommitHash = hash
        selectedDiffFile = nil
        diffFileContent = ""
        if files.isEmpty {
            gitViewModel.setOperationStatus(.success(message: LS("git.ctx.noDifferences")))
        } else {
            showDiffSheet = true
            // Auto-select first file
            selectedDiffFile = files.first
        }
    }

    private func performReset(to hash: String, mode: String) async {
        let result = await gitViewModel.runGitFull(["reset", "--\(mode)", hash])
        if result.succeeded {
            gitViewModel.setOperationStatus(.success(message: LS("git.ctx.resetSuccess") + " (\(mode))"))
            await gitViewModel.loadGraphHistory()
        } else {
            gitViewModel.setOperationStatus(.failure(message: LS("git.ctx.resetFailed"), detail: result.combinedOutput))
        }
    }

    private func performNewBranch(name: String, from hash: String) async {
        let result = await gitViewModel.runGitFull(["branch", name, hash])
        if result.succeeded {
            gitViewModel.setOperationStatus(.success(message: LS("git.ctx.branchCreated") + " '\(name)'"))
            await gitViewModel.loadGraphHistory()
        } else {
            gitViewModel.setOperationStatus(.failure(message: LS("git.ctx.branchFailed"), detail: result.combinedOutput))
        }
        newBranchName = ""
    }

    private func performNewTag(name: String, at hash: String) async {
        let result = await gitViewModel.runGitFull(["tag", name, hash])
        if result.succeeded {
            gitViewModel.setOperationStatus(.success(message: LS("git.ctx.tagCreated") + " '\(name)'"))
            await gitViewModel.loadGraphHistory()
        } else {
            gitViewModel.setOperationStatus(.failure(message: LS("git.ctx.tagFailed"), detail: result.combinedOutput))
        }
        newTagName = ""
    }

    private func performUndoCommit(hash: String) async {
        // git reset --soft <hash>~1 — keeps changes staged
        let result = await gitViewModel.runGitFull(["reset", "--soft", "\(hash)~1"])
        if result.succeeded {
            gitViewModel.setOperationStatus(.success(message: LS("git.ctx.undoSuccess")))
            await gitViewModel.loadGraphHistory()
        } else {
            gitViewModel.setOperationStatus(.failure(message: LS("git.ctx.undoFailed"), detail: result.combinedOutput))
        }
    }

    private func performEditMessage(hash: String, newMessage: String) async {
        // Only works for HEAD commit: git commit --amend -m "new message"
        let isHead = gitViewModel.graphNodes.first?.id == hash
        if isHead {
            let result = await gitViewModel.runGitFull(["commit", "--amend", "-m", newMessage])
            if result.succeeded {
                gitViewModel.setOperationStatus(.success(message: LS("git.ctx.editSuccess")))
                await gitViewModel.loadGraphHistory()
            } else {
                gitViewModel.setOperationStatus(.failure(message: LS("git.ctx.editFailed"), detail: result.combinedOutput))
            }
        } else {
            // Non-HEAD: inform user this only works for HEAD
            gitViewModel.setOperationStatus(.failure(message: LS("git.ctx.editOnlyHead"), detail: nil))
        }
        editMessageText = ""
    }

    private func performDropCommit(node: CommitNode) async {
        let isHead = gitViewModel.graphNodes.first?.id == node.id
        if isHead {
            // HEAD commit: git reset --hard HEAD~1
            let result = await gitViewModel.runGitFull(["reset", "--hard", "HEAD~1"])
            if result.succeeded {
                gitViewModel.setOperationStatus(.success(message: LS("git.ctx.dropSuccess")))
                await gitViewModel.loadGraphHistory()
            } else {
                gitViewModel.setOperationStatus(.failure(message: LS("git.ctx.dropFailed"), detail: result.combinedOutput))
            }
        } else {
            // Non-HEAD: git rebase --onto <parent> <commit> HEAD
            guard let parent = node.parents.first else {
                gitViewModel.setOperationStatus(.failure(message: LS("git.ctx.dropFailed"), detail: "No parent commit"))
                return
            }
            let result = await gitViewModel.runGitFull(["rebase", "--onto", parent, node.id])
            if result.succeeded {
                gitViewModel.setOperationStatus(.success(message: LS("git.ctx.dropSuccess")))
                await gitViewModel.loadGraphHistory()
            } else {
                gitViewModel.setOperationStatus(.failure(message: LS("git.ctx.dropFailed"), detail: result.combinedOutput))
            }
        }
    }

    // MARK: - Commit Label (columns)

    private func commitLabel(_ n: CommitNode) -> some View {
        HStack(spacing: 0) {
            // Hash column + handle on right
            if gitViewModel.graphShowHash {
                Text(n.shortHash).font(.system(size: 10, design: .monospaced))
                    .foregroundColor(n.isMerge ? .secondary : .blue)
                    .frame(width: hashColumnWidth, alignment: .leading)
                    .padding(.leading, 4)
                columnResizeHandle($hashColumnWidth)
            }

            // Message column + handle on right
            HStack(spacing: 4) {
                ForEach(Array(n.refs.enumerated()), id: \.offset) { i, ref in
                    Text(ref).font(.system(size: 8, weight: .semibold))
                        .padding(.horizontal, 4).padding(.vertical, 1)
                        .background(RoundedRectangle(cornerRadius: 3).fill(Self.palette[i % Self.palette.count].opacity(0.15)))
                        .foregroundColor(Self.palette[i % Self.palette.count])
                        .fixedSize()
                }
                Text(n.message).font(.system(size: 10)).lineLimit(1)
                    .foregroundColor(n.isMerge ? .secondary : .primary)
            }
            .frame(width: messageColumnWidth, alignment: .leading)
            .clipped()
            columnResizeHandle($messageColumnWidth)

            // Author column + handle on right
            if gitViewModel.graphShowAuthor {
                Text(n.author).font(.system(size: 9)).foregroundColor(.secondary)
                    .lineLimit(1)
                    .frame(width: authorColumnWidth, alignment: .trailing)
                columnResizeHandle($authorColumnWidth)
            }

            // Date column (last column, no handle needed)
            if gitViewModel.graphShowDate {
                Text(n.relativeDate).font(.system(size: 9)).foregroundColor(.secondary.opacity(0.6))
                    .lineLimit(1)
                    .frame(width: dateColumnWidth, alignment: .trailing)
                    .padding(.trailing, 8)
            }
        }
    }

    // MARK: - Canvas

    private func drawRow(_ ctx: GraphicsContext, node: CommitNode, size: CGSize) {
        func col(_ ci: Int) -> Color { Self.palette[ci % Self.palette.count] }
        let rh = Self.rowH
        let cy = rh / 2

        // Draw segments
        for seg in node.segments {
            var p = Path()
            p.move(to: .init(x: seg.xTop, y: seg.yTop))
            p.addLine(to: .init(x: seg.xBottom, y: seg.yBottom))
            ctx.stroke(p, with: .color(col(seg.colorIndex)), lineWidth: 1.5)
        }

        // Draw IDEA-style chevron arrows (clean V shape — vertical approach is in the segment)
        for arrow in node.arrows {
            let color = col(arrow.colorIndex)
            let armLen: CGFloat = 5.0     // arm length of chevron
            let halfW: CGFloat = 4.0      // horizontal half-width
            var chev = Path()
            if arrow.isDown {
                // Down chevron ˅
                chev.move(to: .init(x: arrow.x - halfW, y: arrow.y - armLen))
                chev.addLine(to: .init(x: arrow.x, y: arrow.y))
                chev.addLine(to: .init(x: arrow.x + halfW, y: arrow.y - armLen))
            } else {
                // Up chevron ˄
                chev.move(to: .init(x: arrow.x - halfW, y: arrow.y + armLen))
                chev.addLine(to: .init(x: arrow.x, y: arrow.y))
                chev.addLine(to: .init(x: arrow.x + halfW, y: arrow.y + armLen))
            }
            ctx.stroke(chev, with: .color(color), lineWidth: 2.0)
        }

        // Commit dot — concentric circle for HEAD (current checkout), IDEA-style
        let dx = CGFloat(node.lane) * Self.laneW + Self.laneW / 2 + 4
        let r = Self.dotR
        let dotColor = col(node.colorIndex)

        // HEAD = commit with "→ branchName" (attached) or "HEAD" (detached) in refs
        let isHead = node.refs.contains(where: { $0.hasPrefix("→ ") || $0 == "HEAD" })

        if isHead {
            // Concentric circle: outer ring + inner filled dot
            let outerR = r + 2.0
            ctx.stroke(Path(ellipseIn: CGRect(x: dx - outerR, y: cy - outerR,
                                              width: outerR * 2, height: outerR * 2)),
                       with: .color(dotColor), lineWidth: 1.5)
            ctx.fill(Path(ellipseIn: CGRect(x: dx - r, y: cy - r,
                                            width: r * 2, height: r * 2)),
                     with: .color(dotColor))
        } else {
            // Normal filled dot
            ctx.fill(Path(ellipseIn: CGRect(x: dx - r, y: cy - r,
                                            width: r * 2, height: r * 2)),
                     with: .color(dotColor))
        }
    }

    // MARK: - Footer

    private var loadingFooter: some View {
        Group {
            if gitViewModel.isLoadingMoreHistory {
                HStack { Spacer(); ProgressView().controlSize(.small)
                    Text(LS("git.loadingMore")).font(.system(size: 9)).foregroundColor(.secondary); Spacer()
                }.padding(.vertical, 8)
            } else if gitViewModel.hasMoreHistory {
                Color.clear.frame(height: 1).onAppear { Task { await gitViewModel.loadMoreGraphHistory() } }
            } else if !gitViewModel.graphNodes.isEmpty {
                HStack { Spacer()
                    Text(LS("git.allLoaded")).font(.system(size: 9)).foregroundColor(.secondary.opacity(0.5)); Spacer()
                }.padding(.vertical, 6)
            }
        }
    }

    // MARK: - Detail & Diff

    private func detailSection(_ d: GitCommitDetail) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            // Hash + Author + Date on same line, all selectable
            HStack(spacing: 8) {
                Text(String(d.hash.prefix(8)))
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundColor(.blue)
                    .textSelection(.enabled)
                Image(systemName: "person.fill").font(.system(size: 9)).foregroundColor(.secondary)
                Text("\(d.author) <\(d.authorEmail)>")
                    .font(.system(size: 10))
                    .foregroundColor(.secondary)
                    .textSelection(.enabled)
                Spacer()
                Text(d.date).font(.system(size: 9)).foregroundColor(.secondary)
                    .textSelection(.enabled)
            }.padding(.horizontal, 12).padding(.top, 6)
            Text(d.message).font(.system(size: 10)).textSelection(.enabled).padding(.horizontal, 12)
            if !d.changedFiles.isEmpty {
                VStack(alignment: .leading, spacing: 2) {
                    Text(LS("git.changedFiles") + " (\(d.changedFiles.count))")
                        .font(.system(size: 9, weight: .medium)).foregroundColor(.secondary).padding(.horizontal, 12)
                    ForEach(d.changedFiles, id: \.path) { f in
                        HStack(spacing: 4) {
                            Text("+\(f.additions)").font(.system(size: 8, design: .monospaced)).foregroundColor(.green)
                            Text("-\(f.deletions)").font(.system(size: 8, design: .monospaced)).foregroundColor(.red)
                            Text(f.path).font(.system(size: 9)).foregroundColor(.accentColor).underline().lineLimit(1)
                            Spacer()
                        }
                        .padding(.horizontal, 16).padding(.vertical, 2)
                        .contentShape(Rectangle())
                        .onTapGesture { showFileDiff(d.hash, f.path, f.additions, f.deletions) }
                    }
                }
            }
            Divider().padding(.top, 4)
        }.padding(.vertical, 2).background(Color(nsColor: .controlBackgroundColor).opacity(0.3))
    }

    private func showFileDiff(_ hash: String, _ path: String, _ add: Int, _ del: Int) {
        Task {
            if let d = await gitViewModel.runGit(["diff", "\(hash)~1", hash, "--", path]) {
                DiffWindowController.show(diffText: d)
            } else if let d = await gitViewModel.runGit(["show", hash, "--", path]) {
                DiffWindowController.show(diffText: d)
            }
        }
    }

    private func toggleDetail(_ hash: String) {
        if selectedHash == hash { selectedHash = nil; selectedDetail = nil; return }
        selectedHash = hash
        Task { selectedDetail = await gitViewModel.loadCommitDetail(hash: hash) }
    }

    // MARK: - Path Picker Sheet (IDEA-Style File Tree)

    private var pathPickerSheet: some View {
        VStack(spacing: 0) {
            // Title bar
            HStack {
                Text(LS("git.selectPaths"))
                    .font(.system(size: 13, weight: .semibold))
                Spacer()
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)

            Divider()

            // Tree content
            let tree = FileTreeNode.buildTree(from: gitViewModel.graphRepoFiles)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(tree) { node in
                        fileTreeRow(node: node, depth: 0)
                    }
                }
                .padding(.vertical, 4)
                .padding(.horizontal, 8)
            }
            .frame(minHeight: 300, maxHeight: 500)
            .background(Color(nsColor: .textBackgroundColor))

            Divider()

            // Bottom buttons
            HStack {
                Spacer()
                Button(LS("sftp.cancel")) {
                    showingPathPicker = false
                }
                .keyboardShortcut(.cancelAction)

                Button(LS("git.confirm")) {
                    if pathPickerSelection.isEmpty {
                        gitViewModel.graphFilterPath = nil
                    } else {
                        gitViewModel.graphFilterPath = pathPickerSelection.sorted().joined(separator: "\n")
                    }
                    showingPathPicker = false
                    Task { await gitViewModel.loadGraphHistory() }
                }
                .keyboardShortcut(.defaultAction)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
        }
        .frame(width: 500, height: 500)
    }

    private func fileTreeRow(node: FileTreeNode, depth: Int) -> AnyView {
        if node.children.isEmpty {
            // Leaf file
            let isSelected = pathPickerSelection.contains(node.fullPath)
            return AnyView(
                Button {
                    if isSelected {
                        pathPickerSelection.remove(node.fullPath)
                    } else {
                        pathPickerSelection.insert(node.fullPath)
                    }
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: isSelected ? "checkmark.square.fill" : "square")
                            .font(.system(size: 11))
                            .foregroundColor(isSelected ? .accentColor : .secondary)
                        Image(systemName: "doc")
                            .font(.system(size: 10))
                            .foregroundColor(.secondary)
                        Text(node.name)
                            .font(.system(size: 11))
                            .lineLimit(1)
                        Spacer()
                    }
                    .padding(.leading, CGFloat(depth) * 16 + 4)
                    .padding(.vertical, 2)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            )
        } else {
            // Directory with children
            let dirSelected = isDirectorySelected(node)
            let partiallySelected = isDirectoryPartiallySelected(node)
            return AnyView(
                DisclosureGroup {
                    ForEach(node.children) { child in
                        fileTreeRow(node: child, depth: depth + 1)
                    }
                } label: {
                    Button {
                        toggleDirectorySelection(node)
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: dirSelected ? "checkmark.square.fill" : (partiallySelected ? "minus.square" : "square"))
                                .font(.system(size: 11))
                                .foregroundColor(dirSelected || partiallySelected ? .accentColor : .secondary)
                            Image(systemName: "folder.fill")
                                .font(.system(size: 10))
                                .foregroundColor(.blue)
                            Text(node.name)
                                .font(.system(size: 11, weight: .medium))
                                .lineLimit(1)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
                .padding(.leading, CGFloat(depth) * 16)
            )
        }
    }

    private func allLeafPaths(_ node: FileTreeNode) -> [String] {
        if node.children.isEmpty { return [node.fullPath] }
        return node.children.flatMap { allLeafPaths($0) }
    }

    private func isDirectorySelected(_ node: FileTreeNode) -> Bool {
        let paths = allLeafPaths(node)
        return !paths.isEmpty && paths.allSatisfy { pathPickerSelection.contains($0) }
    }

    private func isDirectoryPartiallySelected(_ node: FileTreeNode) -> Bool {
        let paths = allLeafPaths(node)
        return paths.contains { pathPickerSelection.contains($0) } && !isDirectorySelected(node)
    }

    private func toggleDirectorySelection(_ node: FileTreeNode) {
        let paths = allLeafPaths(node)
        if isDirectorySelected(node) {
            for p in paths { pathPickerSelection.remove(p) }
        } else {
            for p in paths { pathPickerSelection.insert(p) }
        }
    }
}

// MARK: - File Tree Node

/// Hierarchical tree node built from flat git file paths.
final class FileTreeNode: Identifiable, ObservableObject {
    let id = UUID()
    let name: String
    let fullPath: String
    var children: [FileTreeNode] = []

    init(name: String, fullPath: String) {
        self.name = name
        self.fullPath = fullPath
    }

    /// Build a hierarchical tree from a sorted list of relative file paths.
    static func buildTree(from paths: [String]) -> [FileTreeNode] {
        let root = FileTreeNode(name: "", fullPath: "")
        for path in paths {
            let components = path.split(separator: "/").map(String.init)
            var current = root
            var accumulated = ""
            for (i, comp) in components.enumerated() {
                accumulated = accumulated.isEmpty ? comp : accumulated + "/" + comp
                if let existing = current.children.first(where: { $0.name == comp }) {
                    current = existing
                } else {
                    let node = FileTreeNode(name: comp, fullPath: accumulated)
                    current.children.append(node)
                    current = node
                    // Only leaf nodes are files; intermediate are dirs
                    if i < components.count - 1 {
                        // This is a directory node — it might get children later
                    }
                }
            }
        }
        // Sort: directories first, then files, alphabetically within each group
        func sortChildren(_ node: FileTreeNode) {
            node.children.sort { a, b in
                let aDir = !a.children.isEmpty
                let bDir = !b.children.isEmpty
                if aDir != bDir { return aDir }
                return a.name.localizedStandardCompare(b.name) == .orderedAscending
            }
            node.children.forEach { sortChildren($0) }
        }
        sortChildren(root)
        return root.children
    }
}
