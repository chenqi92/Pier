import SwiftUI

// MARK: - Data Model

struct Segment {
    let xTop: CGFloat
    let yTop: CGFloat
    let xBottom: CGFloat
    let yBottom: CGFloat
    let colorIndex: Int
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
}

// MARK: - Lane Assignment (IDEA-style)
//
// Key principle: the HEAD first-parent chain is ALWAYS at lane 0.
// Side branches spawn to the right and merge back.
// Algorithm:
//   1. Pre-identify HEAD's first-parent chain (a Set of hashes).
//   2. Walk commits top-down (newest first).
//   3. Maintain a "column reservation" array — each slot holds the hash
//      of the commit expected to appear next in that lane.
//   4. When a commit arrives:
//      a. If it's in mainChain → force it to lane 0 (evicting anything there if needed).
//      b. Otherwise → find its reserved lane, or allocate a new one.
//   5. After placing it, reserve lanes for its parents:
//      - First parent continues on the SAME lane.
//      - Additional parents get new lanes (to the right).

struct LaneState {
    /// Column reservation list: index = lane, value = expected commit hash.
    /// nil = lane is free.
    var columns: [String?] = []
    /// Color assigned to each lane.
    var laneColors: [Int] = []
    var nextColor: Int = 1  // color 0 reserved for main chain

    /// Set of hashes on HEAD's first-parent chain.
    var mainChain: Set<String> = []

    /// Find a free lane (first nil slot), or append a new one.
    mutating func allocLane() -> Int {
        if let free = columns.firstIndex(where: { $0 == nil }) { return free }
        columns.append(nil)
        // Assign a unique color to the new lane
        laneColors.append(nextColor)
        nextColor += 1
        return columns.count - 1
    }

    /// Find which lane a hash is reserved at.
    func findLane(for hash: String) -> Int? {
        columns.firstIndex(where: { $0 == hash })
    }

    mutating func assignLanes(_ nodes: inout [CommitNode]) {
        // Ensure lane 0 exists.
        if columns.isEmpty {
            columns.append(nil)
            laneColors.append(0)  // main chain color
        }

        for i in 0..<nodes.count {
            let hash = nodes[i].id
            let isMain = mainChain.contains(hash)
            let lane: Int

            if isMain {
                // Main chain commit → ALWAYS lane 0.
                // If something else reserved lane 0, evict it.
                if let current = columns[0], current != hash {
                    // Move whatever was at lane 0 to a new lane.
                    let newLane = allocLane()
                    columns[newLane] = current
                    laneColors[newLane] = laneColors[0]
                }
                columns[0] = nil  // will be set by parent reservation below
                lane = 0
            } else if let reserved = findLane(for: hash) {
                // This commit was expected at a specific lane.
                columns[reserved] = nil
                lane = reserved
            } else {
                // New side-branch commit — allocate a lane.
                let newLane = allocLane()
                columns[newLane] = nil
                lane = newLane
            }

            // Set commit properties.
            nodes[i].lane = lane
            nodes[i].colorIndex = isMain ? 0 : laneColors[lane]

            // Reserve lanes for parents.
            let parents = nodes[i].parents
            for (pi, parentHash) in parents.enumerated() {
                if pi == 0 {
                    // First parent handling: decide whether to keep or free current lane.
                    let parentReservedAt = findLane(for: parentHash)
                    if parentReservedAt != nil {
                        // Parent already reserved at another lane (another child got there first).
                        // This branch merges into that lane → FREE current lane.
                        columns[lane] = nil
                    } else if mainChain.contains(parentHash) && lane != 0 {
                        // Parent is main chain (will be at lane 0) → FREE current side lane.
                        columns[lane] = nil
                        // Ensure lane 0 has the reservation if it's empty.
                        if columns[0] == nil {
                            columns[0] = parentHash
                        }
                    } else {
                        // Normal: continue on same lane.
                        if columns[lane] == nil {
                            columns[lane] = parentHash
                        }
                    }
                } else {
                    // Additional parents (merge sources) → check if already reserved.
                    if findLane(for: parentHash) != nil {
                        // Already reserved — the connection will be drawn to that lane.
                        continue
                    }
                    // Allocate a new lane for this parent.
                    let newLane = allocLane()
                    columns[newLane] = parentHash
                    laneColors[newLane] = nextColor
                    nextColor += 1
                }
            }

            // If no parents (root commit), free the lane.
            if parents.isEmpty {
                columns[lane] = nil
            }

            // Clean up: free any lane that's no longer needed.
            // A lane is "done" if the commit that was expected there has arrived
            // and has no more children expecting it.
            // (The freeing happens naturally: columns[reserved] = nil above.)
        }
    }

    /// Compute per-row segments for drawing.
    static func computeSegments(_ nodes: inout [CommitNode]) {
        let lw: CGFloat = BranchGraphView.laneW
        let rh: CGFloat = BranchGraphView.rowH
        func x(_ lane: Int) -> CGFloat { CGFloat(lane) * lw + lw / 2 + 4 }

        for i in 0..<nodes.count { nodes[i].segments = [] }

        // Build hash → row index map.
        var hashToRow: [String: Int] = [:]
        for (i, n) in nodes.enumerated() { hashToRow[n.id] = i }

        for (childRow, node) in nodes.enumerated() {
            for (pi, parentHash) in node.parents.enumerated() {
                let parentRow: Int
                let parentLane: Int
                if let pr = hashToRow[parentHash] {
                    parentRow = pr
                    parentLane = nodes[pr].lane
                } else {
                    // Parent not loaded yet — extend line to bottom.
                    parentRow = nodes.count
                    // Guess the lane: for first parent, same lane; for others, try to find reserved lane.
                    parentLane = (pi == 0) ? node.lane : (node.lane + pi)
                }

                let span = parentRow - childRow
                if span <= 0 { continue }

                let childLane = node.lane
                let ci = (pi == 0) ? node.colorIndex : (hashToRow[parentHash].map { nodes[$0].colorIndex } ?? node.colorIndex)
                let sx = x(childLane)
                let ex = x(parentLane)

                if childLane == parentLane {
                    // Same lane → straight vertical line.
                    for r in childRow..<min(parentRow + 1, nodes.count) {
                        let yT: CGFloat = (r == childRow) ? rh / 2 : 0
                        let yB: CGFloat = (r == parentRow) ? rh / 2 : rh
                        nodes[r].segments.append(Segment(xTop: sx, yTop: yT, xBottom: sx, yBottom: yB, colorIndex: ci))
                    }
                } else if span == 1 {
                    // Adjacent rows only: proportional straight diagonal from dot to dot.
                    let totalH = rh  // center to center for 1 row span
                    for r in childRow...min(parentRow, nodes.count - 1) {
                        let yT: CGFloat = (r == childRow) ? rh / 2 : 0
                        let yB: CGFloat = (r == parentRow) ? rh / 2 : rh
                        let progT = (CGFloat(r - childRow) * rh + yT - rh / 2) / totalH
                        let progB = (CGFloat(r - childRow) * rh + yB - rh / 2) / totalH
                        let xT = sx + (ex - sx) * progT
                        let xB = sx + (ex - sx) * progB
                        nodes[r].segments.append(Segment(xTop: xT, yTop: yT, xBottom: xB, yBottom: yB, colorIndex: ci))
                    }
                } else if childLane < parentLane {
                    // BRANCH-OFF (span > 1): proportional diagonal for first row-pair
                    // (fold at child+1 commit dot), then vertical at target lane.
                    let diagTotalH = rh
                    let diagEnd = childRow + 1
                    // Proportional diagonal: child dot → child+1 dot
                    for r in childRow...min(diagEnd, nodes.count - 1) {
                        let yT: CGFloat = (r == childRow) ? rh / 2 : 0
                        let yB: CGFloat = (r == diagEnd) ? rh / 2 : rh
                        let progT = (CGFloat(r - childRow) * rh + yT - rh / 2) / diagTotalH
                        let progB = (CGFloat(r - childRow) * rh + yB - rh / 2) / diagTotalH
                        let xT = sx + (ex - sx) * progT
                        let xB = sx + (ex - sx) * progB
                        nodes[r].segments.append(Segment(xTop: xT, yTop: yT, xBottom: xB, yBottom: yB, colorIndex: ci))
                    }
                    // Vertical at target lane from child+1 center to parent dot
                    if diagEnd < parentRow, diagEnd < nodes.count {
                        nodes[diagEnd].segments.append(Segment(xTop: ex, yTop: rh / 2, xBottom: ex, yBottom: rh, colorIndex: ci))
                    }
                    for r in (diagEnd + 1)..<min(parentRow + 1, nodes.count) {
                        let yB: CGFloat = (r == parentRow) ? rh / 2 : rh
                        nodes[r].segments.append(Segment(xTop: ex, yTop: 0, xBottom: ex, yBottom: yB, colorIndex: ci))
                    }
                } else {
                    // BRANCH-RETURN (span > 1): vertical at source lane, then
                    // proportional diagonal for last row-pair (fold at parent-1 commit dot).
                    let diagStart = parentRow - 1
                    let diagTotalH = rh
                    // Vertical at source lane from child dot to diagStart center
                    nodes[childRow].segments.append(Segment(xTop: sx, yTop: rh / 2, xBottom: sx, yBottom: rh, colorIndex: ci))
                    for r in (childRow + 1)..<min(diagStart, nodes.count) {
                        nodes[r].segments.append(Segment(xTop: sx, yTop: 0, xBottom: sx, yBottom: rh, colorIndex: ci))
                    }
                    if diagStart > childRow, diagStart < nodes.count {
                        nodes[diagStart].segments.append(Segment(xTop: sx, yTop: 0, xBottom: sx, yBottom: rh / 2, colorIndex: ci))
                    }
                    // Proportional diagonal: diagStart dot → parent dot
                    for r in max(diagStart, childRow)...min(parentRow, nodes.count - 1) {
                        let yT: CGFloat = (r == diagStart) ? rh / 2 : 0
                        let yB: CGFloat = (r == parentRow) ? rh / 2 : rh
                        let progT = (CGFloat(r - diagStart) * rh + yT - rh / 2) / diagTotalH
                        let progB = (CGFloat(r - diagStart) * rh + yB - rh / 2) / diagTotalH
                        let xT = sx + (ex - sx) * progT
                        let xB = sx + (ex - sx) * progB
                        nodes[r].segments.append(Segment(xTop: xT, yTop: yT, xBottom: xB, yBottom: yB, colorIndex: ci))
                    }
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
            if gitViewModel.graphNodes.isEmpty {
                VStack(spacing: 12) {
                    Image(systemName: "clock.arrow.circlepath").font(.system(size: 30)).foregroundColor(.secondary)
                    Text(LS("git.noGraph")).font(.caption).foregroundColor(.secondary)
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
            } else { scrollContent }
        }
        .sheet(isPresented: $showingDiff) { diffSheet }
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
