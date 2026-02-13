import SwiftUI

/// Main three-panel layout view — the heart of Pier Terminal.
///
/// Layout:
/// ┌──────────┬────────────────────────┬──────────────┐
/// │  Local   │       Terminal         │  Right Panel │
/// │  Files   │    (Shell / SSH)       │  (MD/SFTP)   │
/// │          │                        │              │
/// └──────────┴────────────────────────┴──────────────┘
struct MainView: View {
    @StateObject private var fileViewModel = FileViewModel()
    @StateObject private var terminalViewModel = TerminalViewModel()

    @State private var showLeftPanel = true
    @State private var showRightPanel = true
    @State private var leftPanelWidth: CGFloat = 250
    @State private var rightPanelWidth: CGFloat = 300

    var body: some View {
        HSplitView {
            // ── Left Panel: Local File Browser ──
            if showLeftPanel {
                LocalFileView(viewModel: fileViewModel)
                    .frame(minWidth: 180, idealWidth: leftPanelWidth, maxWidth: 400)
            }

            // ── Center Panel: Terminal ──
            TerminalContainerView(viewModel: terminalViewModel)
                .frame(minWidth: 400)
                .onDrop(of: [.fileURL, .utf8PlainText], isTargeted: nil) { providers in
                    handleFileDrop(providers: providers)
                }

            // ── Right Panel: Multi-function Area ──
            if showRightPanel {
                RightPanelView()
                    .frame(minWidth: 200, idealWidth: rightPanelWidth, maxWidth: 500)
            }
        }
        .toolbar {
            ToolbarItemGroup(placement: .navigation) {
                Button(action: { withAnimation { showLeftPanel.toggle() } }) {
                    Image(systemName: "sidebar.left")
                }
                .help("Toggle file browser")
            }

            ToolbarItemGroup(placement: .primaryAction) {
                Button(action: { terminalViewModel.addNewTab() }) {
                    Image(systemName: "plus")
                }
                .help("New terminal tab")

                Button(action: {}) {
                    Image(systemName: "network")
                }
                .help("SSH connection manager")

                Button(action: { withAnimation { showRightPanel.toggle() } }) {
                    Image(systemName: "sidebar.right")
                }
                .help("Toggle right panel")
            }
        }
        .frame(minWidth: 900, minHeight: 500)
    }

    /// Handle files dropped onto the terminal area.
    private func handleFileDrop(providers: [NSItemProvider]) -> Bool {
        for provider in providers {
            if provider.hasItemConformingToTypeIdentifier("public.file-url") {
                provider.loadItem(forTypeIdentifier: "public.file-url", options: nil) { item, _ in
                    if let data = item as? Data,
                       let url = URL(dataRepresentation: data, relativeTo: nil) {
                        // Insert the file path into the active terminal
                        let escapedPath = url.path.replacingOccurrences(of: " ", with: "\\ ")
                        DispatchQueue.main.async {
                            terminalViewModel.sendInput(escapedPath)
                        }
                    }
                }
            }
        }
        return true
    }
}

// MARK: - Terminal Container

/// Container for terminal tabs.
struct TerminalContainerView: View {
    @ObservedObject var viewModel: TerminalViewModel

    var body: some View {
        VStack(spacing: 0) {
            // Tab bar
            TerminalTabBar(viewModel: viewModel)
                .frame(height: 36)

            Divider()

            // Terminal content
            if viewModel.tabs.isEmpty {
                emptyState
            } else {
                TerminalView(session: viewModel.currentSession)
            }

            Divider()

            // Status bar
            StatusBarView(viewModel: viewModel)
                .frame(height: 24)
        }
    }

    private var emptyState: some View {
        VStack(spacing: 16) {
            Image(systemName: "terminal")
                .font(.system(size: 48))
                .foregroundColor(.secondary)
            Text("No Terminal Sessions")
                .font(.title3)
                .foregroundColor(.secondary)
            Button("New Terminal") {
                viewModel.addNewTab()
            }
            .buttonStyle(.borderedProminent)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .textBackgroundColor))
    }
}

// MARK: - Terminal Tab Bar

struct TerminalTabBar: View {
    @ObservedObject var viewModel: TerminalViewModel

    var body: some View {
        HStack(spacing: 0) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 1) {
                    ForEach(viewModel.tabs) { tab in
                        TerminalTabItem(
                            tab: tab,
                            isSelected: viewModel.selectedTabId == tab.id,
                            onSelect: { viewModel.selectTab(tab.id) },
                            onClose: { viewModel.closeTab(tab.id) }
                        )
                    }
                }
            }

            Spacer()

            Button(action: { viewModel.addNewTab() }) {
                Image(systemName: "plus")
                    .font(.caption)
            }
            .buttonStyle(.borderless)
            .padding(.horizontal, 8)
        }
        .background(Color(nsColor: .controlBackgroundColor))
    }
}

struct TerminalTabItem: View {
    let tab: TerminalTab
    let isSelected: Bool
    let onSelect: () -> Void
    let onClose: () -> Void

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: tab.isSSH ? "network" : "terminal")
                .font(.caption2)
                .foregroundColor(tab.isSSH ? .green : .secondary)

            Text(tab.title)
                .font(.caption)
                .lineLimit(1)

            Button(action: onClose) {
                Image(systemName: "xmark")
                    .font(.system(size: 8))
            }
            .buttonStyle(.borderless)
            .opacity(isSelected ? 1 : 0)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(isSelected ? Color(nsColor: .selectedContentBackgroundColor) : Color.clear)
        .cornerRadius(4)
        .onTapGesture(perform: onSelect)
    }
}

// MARK: - Status Bar

struct StatusBarView: View {
    @ObservedObject var viewModel: TerminalViewModel

    var body: some View {
        HStack {
            if let session = viewModel.currentSession {
                Image(systemName: "circle.fill")
                    .font(.system(size: 6))
                    .foregroundColor(.green)
                Text(session.shellPath)
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }

            Spacer()

            Text("\(viewModel.tabs.count) session(s)")
                .font(.caption2)
                .foregroundColor(.secondary)
        }
        .padding(.horizontal, 12)
        .background(Color(nsColor: .controlBackgroundColor))
    }
}
