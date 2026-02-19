import SwiftUI

// MARK: - Split Node Model

/// Recursive tree model for terminal split panes.
/// Each tab holds a root SplitNode. A leaf is a single terminal session;
/// a branch splits into children either horizontally or vertically.
enum SplitDirection {
    case horizontal  // children laid out side-by-side
    case vertical    // children laid out top-to-bottom
}

class SplitNode: ObservableObject, Identifiable {
    let id = UUID()

    enum Content {
        case leaf(TerminalSessionInfo)
        case branch(SplitDirection, [SplitNode])
    }

    @Published var content: Content

    init(session: TerminalSessionInfo) {
        self.content = .leaf(session)
    }

    init(direction: SplitDirection, children: [SplitNode]) {
        self.content = .branch(direction, children)
    }

    /// The session if this is a leaf node.
    var session: TerminalSessionInfo? {
        if case .leaf(let s) = content { return s }
        return nil
    }

    /// All leaf sessions in this tree (depth-first).
    var allSessions: [TerminalSessionInfo] {
        switch content {
        case .leaf(let s):
            return [s]
        case .branch(_, let children):
            return children.flatMap { $0.allSessions }
        }
    }

    /// Split this leaf into two panes.
    func split(direction: SplitDirection, newSession: TerminalSessionInfo) {
        guard case .leaf(let existingSession) = content else { return }
        let existingNode = SplitNode(session: existingSession)
        let newNode = SplitNode(session: newSession)
        content = .branch(direction, [existingNode, newNode])
    }

    /// Remove a child node by ID, collapsing a branch with a single remaining child.
    @discardableResult
    func removeChild(_ childId: UUID) -> Bool {
        guard case .branch(let dir, var children) = content else { return false }

        // Try to remove directly among children
        if let idx = children.firstIndex(where: { $0.id == childId }) {
            children.remove(at: idx)
            if children.count == 1 {
                // Collapse: replace self with the single remaining child
                content = children[0].content
            } else {
                content = .branch(dir, children)
            }
            return true
        }

        // Recurse into children
        for child in children {
            if child.removeChild(childId) { return true }
        }
        return false
    }
}

// MARK: - Split View

/// Renders a SplitNode tree as nested HSplitView/VSplitView panes.
struct TerminalSplitView: View {
    @ObservedObject var node: SplitNode
    var onSplitH: ((UUID) -> Void)?
    var onSplitV: ((UUID) -> Void)?
    var onClosePane: ((UUID) -> Void)?

    var body: some View {
        switch node.content {
        case .leaf(let session):
            TerminalView(session: session)

        case .branch(let direction, let children):
            if direction == .horizontal {
                HSplitView {
                    ForEach(children) { child in
                        TerminalSplitView(
                            node: child,
                            onSplitH: onSplitH,
                            onSplitV: onSplitV,
                            onClosePane: onClosePane
                        )
                    }
                }
            } else {
                VSplitView {
                    ForEach(children) { child in
                        TerminalSplitView(
                            node: child,
                            onSplitH: onSplitH,
                            onSplitV: onSplitV,
                            onClosePane: onClosePane
                        )
                    }
                }
            }
        }
    }
}
