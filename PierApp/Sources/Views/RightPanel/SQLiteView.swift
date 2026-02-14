import SwiftUI

/// SQLite client view for browsing local database files.
struct SQLiteView: View {
    @StateObject private var viewModel = SQLiteViewModel()

    var body: some View {
        VStack(spacing: 0) {
            connectionHeader
            Divider()

            if viewModel.isConnected {
                HSplitView {
                    tableSidebar
                        .frame(minWidth: 150, maxWidth: 200)
                    VStack(spacing: 0) {
                        queryEditor
                        Divider()
                        resultsArea
                    }
                }
            } else {
                disconnectedPlaceholder
            }
        }
    }

    // MARK: - Header

    private var connectionHeader: some View {
        HStack {
            Image(systemName: "cylinder")
                .foregroundColor(.green)
                .font(.caption)
            Text("SQLite")
                .font(.caption)
                .fontWeight(.medium)

            if viewModel.isConnected {
                Text(viewModel.filePath.components(separatedBy: "/").last ?? "")
                    .font(.system(size: 9))
                    .foregroundColor(.secondary)
                    .lineLimit(1)
            }

            Spacer()

            if viewModel.isConnected {
                Button(action: { viewModel.closeDatabase() }) {
                    Image(systemName: "xmark.circle")
                        .font(.caption)
                }
                .buttonStyle(.borderless)
            } else {
                Button(action: { viewModel.browseFile() }) {
                    Label("sqlite.open", systemImage: "folder")
                        .font(.caption)
                }
                .buttonStyle(.bordered)
                .controlSize(.mini)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
    }

    // MARK: - Table Sidebar

    private var tableSidebar: some View {
        VStack(spacing: 0) {
            List(viewModel.tables, selection: Binding(
                get: { viewModel.selectedTable?.id },
                set: { id in
                    if let t = viewModel.tables.first(where: { $0.id == id }) {
                        viewModel.selectTable(t)
                    }
                }
            )) { table in
                HStack {
                    Image(systemName: table.type == "view" ? "eye" : "tablecells")
                        .font(.system(size: 9))
                        .foregroundColor(.secondary)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(table.name)
                            .font(.system(size: 10))
                        Text("\(table.rowCount) rows")
                            .font(.system(size: 8))
                            .foregroundColor(.secondary)
                    }
                }
            }
            .listStyle(.sidebar)

            if !viewModel.columns.isEmpty {
                Divider()
                columnInfoPanel
            }
        }
    }

    private var columnInfoPanel: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 4) {
                Text("sqlite.columns")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundColor(.secondary)
                    .padding(.horizontal, 8)
                    .padding(.top, 4)

                ForEach(viewModel.columns) { col in
                    HStack(spacing: 4) {
                        if col.primaryKey {
                            Image(systemName: "key.fill")
                                .font(.system(size: 7))
                                .foregroundColor(.yellow)
                        }
                        Text(col.name)
                            .font(.system(size: 9))
                        Spacer()
                        Text(col.type)
                            .font(.system(size: 8))
                            .foregroundColor(.secondary)
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 1)
                }
            }
            .padding(.bottom, 4)
        }
        .frame(maxHeight: 130)
    }

    // MARK: - Query Editor

    private var queryEditor: some View {
        VStack(spacing: 0) {
            HStack {
                Text("sqlite.query")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundColor(.secondary)
                Spacer()

                Menu {
                    ForEach(viewModel.queryHistory, id: \.self) { q in
                        Button(q.prefix(60) + (q.count > 60 ? "…" : "")) {
                            viewModel.queryText = q
                        }
                    }
                } label: {
                    Image(systemName: "clock")
                        .font(.caption2)
                }
                .menuStyle(.borderlessButton)
                .frame(width: 20)
                .disabled(viewModel.queryHistory.isEmpty)

                Button(action: { viewModel.executeQuery() }) {
                    Label("sqlite.execute", systemImage: "play.fill")
                        .font(.system(size: 9))
                }
                .buttonStyle(.bordered)
                .controlSize(.mini)
                .disabled(viewModel.queryText.isEmpty || viewModel.isLoading)
                .keyboardShortcut(.return, modifiers: .command)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)

            TextEditor(text: $viewModel.queryText)
                .font(.system(size: 11, design: .monospaced))
                .frame(minHeight: 50, maxHeight: 100)
                .padding(.horizontal, 4)
        }
    }

    // MARK: - Results

    private var resultsArea: some View {
        Group {
            if let error = viewModel.errorMessage {
                VStack {
                    Image(systemName: "exclamationmark.triangle")
                        .foregroundColor(.red)
                    Text(error)
                        .font(.caption)
                        .foregroundColor(.red)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let result = viewModel.queryResult {
                VStack(spacing: 0) {
                    HStack {
                        Text("\(result.affectedRows) rows")
                            .font(.system(size: 9))
                            .foregroundColor(.secondary)
                        Spacer()
                        Text(String(format: "%.2fms", result.executionTime * 1000))
                            .font(.system(size: 9))
                            .foregroundColor(.secondary)
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)

                    Divider()

                    ScrollView([.horizontal, .vertical]) {
                        resultTable(result)
                    }
                }
            } else {
                VStack(spacing: 8) {
                    Image(systemName: "tablecells")
                        .font(.system(size: 24))
                        .foregroundColor(.secondary)
                    Text("sqlite.noResults")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }

    private func resultTable(_ result: SQLiteQueryResult) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            if !result.columns.isEmpty {
                HStack(spacing: 0) {
                    ForEach(result.columns, id: \.self) { col in
                        Text(col)
                            .font(.system(size: 9, weight: .semibold, design: .monospaced))
                            .frame(minWidth: 80, alignment: .leading)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 3)
                    }
                }
                .background(Color.secondary.opacity(0.1))
                Divider()
            }

            ForEach(Array(result.rows.enumerated()), id: \.offset) { idx, row in
                HStack(spacing: 0) {
                    ForEach(Array(row.enumerated()), id: \.offset) { _, cell in
                        Text(cell)
                            .font(.system(size: 9, design: .monospaced))
                            .frame(minWidth: 80, alignment: .leading)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                    }
                }
                .background(idx % 2 == 0 ? Color.clear : Color.secondary.opacity(0.04))
            }
        }
        .padding(4)
    }

    // MARK: - Disconnected

    private var disconnectedPlaceholder: some View {
        VStack(spacing: 12) {
            Image(systemName: "cylinder")
                .font(.system(size: 30))
                .foregroundColor(.secondary)
            Text("sqlite.notConnected")
                .font(.caption)
                .foregroundColor(.secondary)

            Button(action: { viewModel.browseFile() }) {
                Label("sqlite.open", systemImage: "folder")
            }
            .buttonStyle(.bordered)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
