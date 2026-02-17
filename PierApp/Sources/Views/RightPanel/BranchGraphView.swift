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
}

// MARK: - Graph Layout (IDEA-style)
//
// Based on JetBrains IntelliJ IDEA open-source graph rendering:
//   https://github.com/JetBrains/intellij-community/tree/master/platform/vcs-log/graph
//
// Three-phase algorithm:
//  1. Layout Index: DFS from HEAD, each first-parent chain shares the same layoutIndex.
//  2. Active Edges: For each row, collect all edges passing through it.
//  3. Dynamic Position: Sort node + active edges by layoutIndex → position = column.
//
// This produces column positions that SHIFT LEFT/RIGHT as branches appear/disappear,
// matching IDEA's compact visual style.

struct LaneState {
    /// Set of hashes on default branch's first-parent chain.
    var mainChain: Set<String> = []

    // ── Phase 1: Layout Index (IDEA's stack-based DFS) ─────────────────

    /// Assign layoutIndex to every commit using IDEA's exact DFS algorithm
    /// from GraphLayoutBuilder.kt:
    ///   - Stack-based walk from each head
    ///   - At each node, find first unvisited parent (down-node) and push
    ///   - When no unvisited parent exists, pop and backtrack
    ///   - Same first-parent chain shares same layoutIndex
    ///   - layoutIndex increments when a chain ends
    /// This depth-first ordering ensures side branches from deeper merges
    /// get lower layoutIndex values than those from shallower merges.
    static func assignLayoutIndices(_ nodes: inout [CommitNode], mainChain: Set<String>) {
        guard !nodes.isEmpty else { return }

        var hashToRow: [String: Int] = [:]
        for (i, n) in nodes.enumerated() { hashToRow[n.id] = i }

        // Identify heads: nodes not referenced as parent by any other node
        var isParentOf = Set<String>()
        for n in nodes {
            for p in n.parents { isParentOf.insert(p) }
        }
        var heads: [Int] = []
        for (i, n) in nodes.enumerated() {
            if !isParentOf.contains(n.id) {
                heads.append(i)
            }
        }
        // IDEA: heads sorted by comparator (effectively row order = date order)
        heads.sort { a, b in a < b }

        var layoutIndex = Array(repeating: 0, count: nodes.count)
        var currentLI = 1

        // Pure DFS — matching IDEA's GraphLayoutBuilder.build() exactly.
        // No pre-assignment. The DFS naturally assigns layout indices by
        // following first-parent chains and backtracking to merge sources.
        // This produces IDEA's exact column ordering.
        func dfsWalk(from head: Int) {
            if layoutIndex[head] != 0 { return }
            var stack = [head]
            while !stack.isEmpty {
                let cur = stack.last!
                let firstVisit = layoutIndex[cur] == 0
                if firstVisit {
                    layoutIndex[cur] = currentLI
                }
                // Find first unvisited down-node (parent in git order)
                // IDEA: getDownNodes().firstOrNull { layoutIndex[it] == 0 }
                var nextNode: Int? = nil
                for p in nodes[cur].parents {
                    if let pr = hashToRow[p], layoutIndex[pr] == 0 {
                        nextNode = pr
                        break
                    }
                }
                if let next = nextNode {
                    stack.append(next)
                } else {
                    if firstVisit { currentLI += 1 }
                    stack.removeLast()
                }
            }
        }

        for head in heads {
            dfsWalk(from: head)
        }

        // Assign any remaining (disconnected) nodes
        for i in 0..<nodes.count {
            if layoutIndex[i] == 0 {
                dfsWalk(from: i)
            }
        }

        for i in 0..<nodes.count {
            nodes[i].lane = layoutIndex[i]
        }
        // Debug: write layoutIndex for first 100 rows to file
        var debugLines: [String] = []
        debugLines.append("heads: \(heads.map { "r\($0)=\(String(nodes[$0].id.prefix(8)))" })")
        let debugLimit = min(500, nodes.count)
        for i in 0..<debugLimit {
            let onMain = mainChain.contains(nodes[i].id)
            debugLines.append("r\(i) \(String(nodes[i].id.prefix(8))) LI=\(layoutIndex[i]) mc=\(onMain) p=\(nodes[i].parents.map { String($0.prefix(8)) }) \(String(nodes[i].message.prefix(45)))")
        }
        try? debugLines.joined(separator: "\n").write(toFile: "/tmp/pier_graph_debug.txt", atomically: true, encoding: .utf8)
    }

    // ── Phase 2 & 3: Active edges + dynamic per-row column positions ──

    /// Represents an edge from child row to parent row, carrying a layoutIndex for sorting
    struct ActiveEdge: Hashable {
        let childRow: Int
        let parentRow: Int
        let layoutIndex: Int
        let colorIndex: Int

        func hash(into hasher: inout Hasher) {
            hasher.combine(childRow)
            hasher.combine(parentRow)
        }
        static func == (lhs: ActiveEdge, rhs: ActiveEdge) -> Bool {
            return lhs.childRow == rhs.childRow && lhs.parentRow == rhs.parentRow
        }
    }

    /// Compute dynamic column positions for all nodes and generate segments.
    /// This replaces both `assignLanes` and `computeSegments`.
    // IDEA's long-edge constants (from PrintElementGeneratorImpl.kt)
    static let longEdgeSize = 30       // edges >= this span get hidden in the middle
    static let visiblePartSize = 1     // show this many rows near each endpoint

    /// Whether an edge is visible (occupies a column) at the given row.
    /// Long edges (span >= longEdgeSize) are hidden in the middle — only visible
    /// within `visiblePartSize` rows of each endpoint.
    static func isEdgeVisibleInRow(childRow: Int, parentRow: Int, row: Int) -> Bool {
        let span = parentRow - childRow
        if span < longEdgeSize { return true }
        let upOffset = row - childRow       // distance from child end
        let downOffset = parentRow - row    // distance from parent end
        return upOffset <= visiblePartSize || downOffset <= visiblePartSize
    }

    /// Returns the arrow type at the given row, if any.
    /// A down-arrow appears at the row where the edge becomes hidden from the child side.
    /// An up-arrow appears at the row where the edge becomes visible from the parent side.
    static func arrowType(childRow: Int, parentRow: Int, row: Int) -> Bool? {
        let span = parentRow - childRow
        if span < longEdgeSize { return nil }
        let upOffset = row - childRow
        let downOffset = parentRow - row
        if upOffset == visiblePartSize { return true }    // down arrow ↓
        if downOffset == visiblePartSize { return false } // up arrow ↑
        return nil
    }

    static func computeIDEALayout(_ nodes: inout [CommitNode], mainChain: Set<String>) {
        guard !nodes.isEmpty else { return }

        // Phase 1: Assign layoutIndex
        assignLayoutIndices(&nodes, mainChain: mainChain)

        let lw: CGFloat = BranchGraphView.laneW
        let rh: CGFloat = BranchGraphView.rowH
        func xPos(_ col: Int) -> CGFloat { CGFloat(col) * lw + lw / 2 + 4 }

        // Build hash → row map
        var hashToRow: [String: Int] = [:]
        for (i, n) in nodes.enumerated() { hashToRow[n.id] = i }

        // Collect ALL edges (child → parent)
        struct EdgeInfo {
            let childRow: Int     // "up" in IDEA terminology
            let parentRow: Int    // "down" in IDEA terminology
            let parentIndex: Int  // 0 = first parent, 1+ = merge source
            let upLI: Int         // layoutIndex of child node
            let downLI: Int       // layoutIndex of parent node
            let colorIndex: Int
        }
        var allEdges: [EdgeInfo] = []

        // Color assignment: same layoutIndex = same color
        // layoutIndex 1 = main chain → color 0
        // Others get unique colors based on layoutIndex
        var liToColor: [Int: Int] = [:]
        var nextColor = 1
        func colorFor(_ li: Int, isMain: Bool) -> Int {
            if isMain { return 0 }
            if let c = liToColor[li] { return c }
            let c = nextColor
            nextColor += 1
            liToColor[li] = c
            return c
        }

        // Assign colors to all nodes first
        for i in 0..<nodes.count {
            let isMain = mainChain.contains(nodes[i].id)
            nodes[i].colorIndex = colorFor(nodes[i].lane, isMain: isMain)
        }

        // Build edge list
        for (childRow, node) in nodes.enumerated() {
            for (pi, parentHash) in node.parents.enumerated() {
                let parentRow: Int
                if let pr = hashToRow[parentHash] {
                    parentRow = pr
                } else {
                    continue  // parent not loaded — skip edge (IDEA only processes loaded edges)
                }
                if parentRow <= childRow { continue }

                // IDEA stores layoutIndex of both endpoints for comparator
                let childLI = nodes[childRow].lane
                let parentLI = parentRow < nodes.count ? nodes[parentRow].lane : childLI
                // Color: first-parent edges inherit child's color;
                // merge edges (2nd+ parent) use parent's color (side branch color)
                let ci: Int
                if pi == 0 {
                    ci = nodes[childRow].colorIndex
                } else if parentRow < nodes.count {
                    ci = nodes[parentRow].colorIndex
                } else {
                    ci = nodes[childRow].colorIndex
                }

                allEdges.append(EdgeInfo(childRow: childRow, parentRow: parentRow,
                                        parentIndex: pi, upLI: childLI, downLI: parentLI, colorIndex: ci))
            }
        }

        // ── Phase 2: Determine column positions per row ──
        //
        // IDEA's key insight (from EdgesInRowGenerator.java):
        // An edge from childRow to parentRow is only "active" (occupies a column)
        // at STRICTLY INTERMEDIATE rows: childRow < r < parentRow.
        // At the child and parent rows, the NODE itself handles the connection.
        //
        // For each row: sort(node + active_edges) by layoutIndex → position = column.

        // Group edges by their first intermediate row for efficient sweep
        var edgesByStartRow: [Int: [Int]] = [:]
        for (ei, edge) in allEdges.enumerated() {
            let firstIntermediate = edge.childRow + 1
            let lastIntermediate = min(edge.parentRow - 1, nodes.count - 1)
            if firstIntermediate <= lastIntermediate {
                edgesByStartRow[firstIntermediate, default: []].append(ei)
            }
        }

        var activeEdgeIndices = Set<Int>()
        var nodeColumns: [Int] = Array(repeating: 0, count: nodes.count)
        var edgeColumnAtRow: [[Int: Int]] = Array(repeating: [:], count: nodes.count)

        // Clear segments
        for i in 0..<nodes.count {
            nodes[i].segments = []
            nodes[i].arrows = []
        }

        for row in 0..<nodes.count {
            // Add edges whose first intermediate row is this row
            if let newEdges = edgesByStartRow[row] {
                for ei in newEdges { activeEdgeIndices.insert(ei) }
            }

            // Build sorted elements for this row.
            // IDEA's GraphElementComparatorByLayoutIndex (faithful port from Java source).
            struct RowElement {
                let isNode: Bool
                let edgeIndex: Int
                let upLI: Int      // for edges: child LI; for nodes: node LI
                let downLI: Int    // for edges: parent LI; for nodes: node LI
                let upRow: Int     // for edges: childRow; for nodes: row
                let downRow: Int   // for edges: parentRow; for nodes: row
            }

            // IDEA's compare2(edge, node): positive means edge goes RIGHT of node
            func compare2(_ e: RowElement, _ n: RowElement) -> Int {
                let maxEdgeLI = max(e.upLI, e.downLI)
                let nodeLI = n.upLI
                if maxEdgeLI != nodeLI { return maxEdgeLI - nodeLI }
                return e.upRow - n.upRow
            }

            func compareElements(_ lhs: RowElement, _ rhs: RowElement) -> Int {
                if !lhs.isNode && !rhs.isNode {
                    // Edge vs Edge: reduce to edge-vs-node
                    if lhs.upRow == rhs.upRow {
                        if lhs.downRow < rhs.downRow {
                            let vn = RowElement(isNode: true, edgeIndex: -1, upLI: lhs.downLI,
                                                downLI: lhs.downLI, upRow: lhs.downRow, downRow: lhs.downRow)
                            return -compare2(rhs, vn)
                        } else {
                            let vn = RowElement(isNode: true, edgeIndex: -1, upLI: rhs.downLI,
                                                downLI: rhs.downLI, upRow: rhs.downRow, downRow: rhs.downRow)
                            return compare2(lhs, vn)
                        }
                    }
                    if lhs.upRow < rhs.upRow {
                        let vn = RowElement(isNode: true, edgeIndex: -1, upLI: rhs.upLI,
                                            downLI: rhs.upLI, upRow: rhs.upRow, downRow: rhs.upRow)
                        return compare2(lhs, vn)
                    } else {
                        let vn = RowElement(isNode: true, edgeIndex: -1, upLI: lhs.upLI,
                                            downLI: lhs.upLI, upRow: lhs.upRow, downRow: lhs.upRow)
                        return -compare2(rhs, vn)
                    }
                }
                if !lhs.isNode && rhs.isNode { return compare2(lhs, rhs) }
                if lhs.isNode && !rhs.isNode { return -compare2(rhs, lhs) }
                return 0
            }

            var elements: [RowElement] = []
            let nodeLI = nodes[row].lane
            elements.append(RowElement(isNode: true, edgeIndex: -1, upLI: nodeLI,
                                       downLI: nodeLI, upRow: row, downRow: row))
            for ei in activeEdgeIndices {
                let e = allEdges[ei]
                let clampedPR = min(e.parentRow, nodes.count - 1)
                guard Self.isEdgeVisibleInRow(childRow: e.childRow, parentRow: clampedPR, row: row) else { continue }
                elements.append(RowElement(isNode: false, edgeIndex: ei, upLI: e.upLI,
                                           downLI: e.downLI, upRow: e.childRow, downRow: e.parentRow))
            }
            elements.sort { compareElements($0, $1) < 0 }

            for (col, elem) in elements.enumerated() {
                if elem.isNode {
                    nodeColumns[row] = col
                } else {
                    edgeColumnAtRow[row][elem.edgeIndex] = col
                }
            }

            // Remove edges whose last intermediate row is this row
            activeEdgeIndices = activeEdgeIndices.filter { ei in
                let lastInterm = min(allEdges[ei].parentRow - 1, nodes.count - 1)
                return row < lastInterm
            }
        }

        // Update node lanes to actual column positions
        for i in 0..<nodes.count {
            nodes[i].lane = nodeColumns[i]
        }

        // ── Phase 3: Generate segments via anchor-based polyline ──
        //
        // For each edge, build anchor points at each row's center (rh/2),
        // then split into per-row half-segments that connect at row boundaries
        // using midpoint x to ensure continuous lines.

        for (ei, edge) in allEdges.enumerated() {
            let ci = edge.colorIndex
            let clampedParent = min(edge.parentRow, nodes.count - 1)
            let span = clampedParent - edge.childRow
            if span <= 0 { continue }

            // Build anchor list: (row, xPosition) — only for VISIBLE rows
            var anchors: [(row: Int, x: CGFloat)] = []
            // First: child node dot
            anchors.append((edge.childRow, xPos(nodeColumns[edge.childRow])))
            // Intermediate: only visible edge column positions
            for r in (edge.childRow + 1)..<clampedParent {
                guard r < nodes.count else { break }
                if !Self.isEdgeVisibleInRow(childRow: edge.childRow, parentRow: clampedParent, row: r) {
                    continue  // skip hidden middle portion
                }
                let col = edgeColumnAtRow[r][ei] ?? nodeColumns[edge.childRow]
                anchors.append((r, xPos(col)))
            }
            // Last: parent node dot (or last loaded row)
            anchors.append((clampedParent, xPos(nodeColumns[clampedParent])))

            // Generate half-row segments between consecutive anchors
            for ai in 0..<(anchors.count - 1) {
                let (rowA, xA) = anchors[ai]
                let (rowB, xB) = anchors[ai + 1]
                guard rowA < nodes.count else { continue }

                if rowB == rowA + 1 {
                    // Adjacent rows — draw connected half-segments
                    let xMid = (xA + xB) / 2
                    nodes[rowA].segments.append(Segment(
                        xTop: xA, yTop: rh / 2, xBottom: xMid, yBottom: rh, colorIndex: ci))
                    if rowB < nodes.count {
                        nodes[rowB].segments.append(Segment(
                            xTop: xMid, yTop: 0, xBottom: xB, yBottom: rh / 2, colorIndex: ci))
                    }
                }
                // else: gap in visibility (long edge break) — no segments drawn
            }

            // Add arrow indicators at long-edge break points
            if span >= Self.longEdgeSize {
                // Down arrow at child side (where edge disappears going down)
                let downArrowRow = edge.childRow + Self.visiblePartSize
                if downArrowRow < nodes.count {
                    let col = edgeColumnAtRow[downArrowRow][ei] ?? nodeColumns[edge.childRow]
                    nodes[downArrowRow].arrows.append(ArrowIndicator(
                        x: xPos(col), y: rh, colorIndex: ci, isDown: true))
                }
                // Up arrow at parent side (where edge reappears going up)
                let upArrowRow = clampedParent - Self.visiblePartSize
                if upArrowRow >= 0 && upArrowRow < nodes.count {
                    let col = edgeColumnAtRow[upArrowRow][ei] ?? nodeColumns[clampedParent]
                    nodes[upArrowRow].arrows.append(ArrowIndicator(
                        x: xPos(col), y: 0, colorIndex: ci, isDown: false))
                }
            }
        }
    }
}

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
    static let rowH: CGFloat = 28
    static let dotR: CGFloat = 4

    @State private var selectedHash: String?
    @State private var selectedDetail: GitCommitDetail?
    @State private var showingDiff = false
    @State private var diffText = ""
    @State private var diffPath = ""
    @State private var diffAdd = 0
    @State private var diffDel = 0

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
        .sheet(isPresented: $showingDiff) { diffSheet }
    }

    private var branchFilterBar: some View {
        HStack(spacing: 6) {
            Image(systemName: "arrow.triangle.branch")
                .font(.system(size: 10))
                .foregroundColor(.secondary)

            Menu {
                Button {
                    if gitViewModel.graphFilterBranch != nil {
                        gitViewModel.graphFilterBranch = nil
                        Task { await gitViewModel.loadGraphHistory() }
                    }
                } label: {
                    HStack {
                        Text(LS("git.allBranches"))
                        if gitViewModel.graphFilterBranch == nil {
                            Image(systemName: "checkmark")
                        }
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
                            if gitViewModel.graphFilterBranch == branch {
                                Image(systemName: "checkmark")
                            }
                        }
                    }
                }
            } label: {
                HStack(spacing: 4) {
                    Text(gitViewModel.graphFilterBranch ?? LS("git.allBranches"))
                        .font(.system(size: 11, weight: .medium))
                        .lineLimit(1)
                    Image(systemName: "chevron.down")
                        .font(.system(size: 8, weight: .semibold))
                        .foregroundColor(.secondary)
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(RoundedRectangle(cornerRadius: 4).fill(Color(nsColor: .controlColor)))
            }
            .menuStyle(.borderlessButton)
            .fixedSize()

            Spacer()
        }
    }

    private var scrollContent: some View {
        let nodes = gitViewModel.graphNodes
        let maxLane = nodes.map(\.lane).max() ?? 0
        let gw = CGFloat(maxLane + 2) * Self.laneW + 8

        return ScrollView(.vertical) {
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(nodes) { node in
                    VStack(spacing: 0) {
                        HStack(alignment: .center, spacing: 0) {
                            Canvas { ctx, size in drawRow(ctx, node: node, size: size) }
                                .frame(width: gw, height: Self.rowH)
                            commitLabel(node)
                            Spacer(minLength: 0)
                        }
                        .frame(height: Self.rowH)
                        .background(selectedHash == node.id ? Color.accentColor.opacity(0.08) : .clear)
                        .contentShape(Rectangle())
                        .onTapGesture { toggleDetail(node.id) }
                        if let d = selectedDetail, d.hash == node.id { detailSection(d) }
                    }
                }
                loadingFooter
            }
        }
    }

    private func commitLabel(_ n: CommitNode) -> some View {
        HStack(spacing: 5) {
            Text(n.shortHash).font(.system(size: 10, design: .monospaced))
                .foregroundColor(n.isMerge ? .secondary : .blue)
                .frame(width: 54, alignment: .leading)
            ForEach(Array(n.refs.enumerated()), id: \.offset) { i, ref in
                Text(ref).font(.system(size: 8, weight: .semibold))
                    .padding(.horizontal, 4).padding(.vertical, 1)
                    .background(RoundedRectangle(cornerRadius: 3).fill(Self.palette[i % Self.palette.count].opacity(0.15)))
                    .foregroundColor(Self.palette[i % Self.palette.count])
            }
            Text(n.message).font(.system(size: 10)).lineLimit(1)
                .foregroundColor(n.isMerge ? .secondary : .primary)
            Spacer(minLength: 8)
            if !n.author.isEmpty {
                Text(n.author).font(.system(size: 9)).foregroundColor(.secondary)
                    .lineLimit(1).frame(maxWidth: 80, alignment: .trailing)
            }
            if !n.relativeDate.isEmpty {
                Text(n.relativeDate).font(.system(size: 9)).foregroundColor(.secondary.opacity(0.6))
                    .lineLimit(1).frame(width: 80, alignment: .trailing)
            }
        }.padding(.leading, 4).padding(.trailing, 8)
    }

    // MARK: - Canvas

    private func drawRow(_ ctx: GraphicsContext, node: CommitNode, size: CGSize) {
        func col(_ ci: Int) -> Color { Self.palette[ci % Self.palette.count] }
        for seg in node.segments {
            var p = Path()
            p.move(to: .init(x: seg.xTop, y: seg.yTop))
            p.addLine(to: .init(x: seg.xBottom, y: seg.yBottom))
            ctx.stroke(p, with: .color(col(seg.colorIndex)), lineWidth: 2)
        }
        // Draw arrow indicators for long-span breaks
        for arrow in node.arrows {
            let color = col(arrow.colorIndex)
            if arrow.isDown {
                // Down arrow: ▼
                var tri = Path()
                tri.move(to: .init(x: arrow.x, y: arrow.y - 4))
                tri.addLine(to: .init(x: arrow.x - 3.5, y: arrow.y - 8))
                tri.addLine(to: .init(x: arrow.x + 3.5, y: arrow.y - 8))
                tri.closeSubpath()
                ctx.fill(tri, with: .color(color))
            } else {
                // Up arrow (continuation): ▲
                var tri = Path()
                tri.move(to: .init(x: arrow.x, y: arrow.y + 4))
                tri.addLine(to: .init(x: arrow.x - 3.5, y: arrow.y + 8))
                tri.addLine(to: .init(x: arrow.x + 3.5, y: arrow.y + 8))
                tri.closeSubpath()
                ctx.fill(tri, with: .color(color))
            }
        }
        // Commit dot — all dots same size and color
        let dx = CGFloat(node.lane) * Self.laneW + Self.laneW / 2 + 4
        let cy = size.height / 2
        let r = Self.dotR
        ctx.fill(Path(ellipseIn: CGRect(x: dx - r, y: cy - r, width: r * 2, height: r * 2)),
                 with: .color(col(node.colorIndex)))
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
            HStack(spacing: 8) {
                Image(systemName: "person.fill").font(.system(size: 9)).foregroundColor(.secondary)
                Text("\(d.author) <\(d.authorEmail)>").font(.system(size: 10)).foregroundColor(.secondary)
                Spacer()
                Text(d.date).font(.system(size: 9)).foregroundColor(.secondary)
            }.padding(.horizontal, 12).padding(.top, 4)
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

    private var diffSheet: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "doc.text.fill").font(.system(size: 11)).foregroundColor(.secondary)
                Text(diffPath).font(.system(size: 11, weight: .medium, design: .monospaced)).lineLimit(1)
                HStack(spacing: 4) {
                    Text("+\(diffAdd)").font(.system(size: 10, weight: .semibold, design: .monospaced)).foregroundColor(.green)
                    Text("-\(diffDel)").font(.system(size: 10, weight: .semibold, design: .monospaced)).foregroundColor(.red)
                }.padding(.horizontal, 6).padding(.vertical, 2)
                    .background(RoundedRectangle(cornerRadius: 4).fill(Color(nsColor: .controlBackgroundColor)))
                Spacer()
                Button(action: { showingDiff = false }) {
                    Image(systemName: "xmark.circle.fill").font(.system(size: 16)).foregroundColor(.secondary)
                }.buttonStyle(.plain)
            }.padding(.horizontal, 12).padding(.vertical, 8).background(Color(nsColor: .windowBackgroundColor))
            Divider()
            GeometryReader { geo in
                ScrollView([.horizontal, .vertical]) {
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(Array(diffText.components(separatedBy: "\n").enumerated()), id: \.offset) { i, line in
                            diffLine(line, i + 1)
                        }
                    }
                    .padding(.vertical, 4)
                    .frame(minWidth: geo.size.width, minHeight: geo.size.height, alignment: .topLeading)
                }
            }
            .background(Color(nsColor: .textBackgroundColor))
        }.frame(minWidth: 700, idealWidth: 900, minHeight: 500, idealHeight: 700)
    }

    private func diffLine(_ line: String, _ num: Int) -> some View {
        let (bg, fg): (Color, Color) = {
            if line.hasPrefix("+++") || line.hasPrefix("---") { return (.blue.opacity(0.05), .secondary) }
            if line.hasPrefix("@@") { return (.purple.opacity(0.08), .purple) }
            if line.hasPrefix("+") { return (.green.opacity(0.1), Color(nsColor: .systemGreen)) }
            if line.hasPrefix("-") { return (.red.opacity(0.1), Color(nsColor: .systemRed)) }
            return (.clear, .primary)
        }()
        return HStack(spacing: 0) {
            Text("\(num)").font(.system(size: 10, design: .monospaced)).foregroundColor(.secondary.opacity(0.5))
                .frame(width: 40, alignment: .trailing).padding(.trailing, 6).background(bg.opacity(0.3))
            Text(line.isEmpty ? " " : line).font(.system(size: 11, design: .monospaced)).foregroundColor(fg).textSelection(.enabled)
            Spacer(minLength: 0)
        }.background(bg)
    }

    private func showFileDiff(_ hash: String, _ path: String, _ add: Int, _ del: Int) {
        diffAdd = add; diffDel = del
        Task {
            if let d = await gitViewModel.runGit(["diff", "\(hash)~1", hash, "--", path]) {
                diffText = d; diffPath = path; showingDiff = true
            } else if let d = await gitViewModel.runGit(["show", hash, "--", path]) {
                diffText = d; diffPath = path; showingDiff = true
            }
        }
    }

    private func toggleDetail(_ hash: String) {
        if selectedHash == hash { selectedHash = nil; selectedDetail = nil; return }
        selectedHash = hash
        Task { selectedDetail = await gitViewModel.loadCommitDetail(hash: hash) }
    }
}
