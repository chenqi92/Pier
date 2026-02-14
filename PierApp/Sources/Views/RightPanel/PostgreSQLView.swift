import SwiftUI

/// PostgreSQL client view for the right panel.
struct PostgreSQLView: View {
    @StateObject private var viewModel = PostgreSQLViewModel()

    var body: some View {
        VStack(spacing: 0) {
            // Connection header
            connectionHeader

            Divider()

            if viewModel.isConnected {
                HSplitView {
                    // Left: databases + tables sidebar
                    tableSidebar
                        .frame(minWidth: 160, maxWidth: 220)

                    // Right: query editor + results
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

    // MARK: - Connection Header

    private var connectionHeader: some View {
        HStack {
            Image(systemName: "externaldrive.connected.to.line.below")
                .foregroundColor(.blue)
                .font(.caption)
            Text("PostgreSQL")
                .font(.caption)
                .fontWeight(.medium)

            Spacer()

            if viewModel.isConnected {
                Text(LS("pg.connected"))
                    .font(.system(size: 9))
                    .foregroundColor(.green)

                Button(action: { viewModel.disconnect() }) {
                    Image(systemName: "xmark.circle")
                        .font(.caption)
                }
                .buttonStyle(.borderless)
            } else {
                Button(action: { viewModel.connect() }) {
                    Label(LS("pg.connect"), systemImage: "link")
                        .font(.caption)
                }
                .buttonStyle(.bordered)
                .controlSize(.mini)
                .disabled(viewModel.isLoading)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
    }

    // MARK: - Table Sidebar

    private var tableSidebar: some View {
        VStack(spacing: 0) {
            // Database picker
            Picker("", selection: $viewModel.selectedDatabase) {
                ForEach(viewModel.databases) { db in
                    Text(db.name).tag(db.name)
                }
            }
            .labelsHidden()
            .font(.caption)
            .padding(6)
            .onChange(of: viewModel.selectedDatabase) { _, newVal in
                viewModel.selectDatabase(newVal)
            }

            Divider()

            // Tables list
            List(viewModel.tables, selection: Binding(
                get: { viewModel.selectedTable?.id },
                set: { id in
                    if let t = viewModel.tables.first(where: { $0.id == id }) {
                        viewModel.selectTable(t)
                    }
                }
            )) { table in
                HStack {
                    Image(systemName: "tablecells")
                        .font(.system(size: 9))
                        .foregroundColor(.secondary)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(table.name)
                            .font(.system(size: 10))
                        Text("\(table.rowCount) rows · \(table.size)")
                            .font(.system(size: 8))
                            .foregroundColor(.secondary)
                    }
                }
            }
            .listStyle(.sidebar)

            // Column info
            if !viewModel.columns.isEmpty {
                Divider()
                columnInfoPanel
            }
        }
    }

    private var columnInfoPanel: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 4) {
                Text(LS("pg.columns"))
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundColor(.secondary)
                    .padding(.horizontal, 8)
                    .padding(.top, 4)

                ForEach(viewModel.columns) { col in
                    HStack(spacing: 4) {
                        if col.isPrimaryKey {
                            Image(systemName: "key.fill")
                                .font(.system(size: 7))
                                .foregroundColor(.yellow)
                        }
                        if col.foreignKey != nil {
                            Image(systemName: "link")
                                .font(.system(size: 7))
                                .foregroundColor(.blue)
                        }
                        Text(col.name)
                            .font(.system(size: 9))
                        Spacer()
                        Text(col.dataType)
                            .font(.system(size: 8))
                            .foregroundColor(.secondary)
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 1)
                }
            }
            .padding(.bottom, 4)
        }
        .frame(maxHeight: 140)
    }

    // MARK: - Query Editor

    private var queryEditor: some View {
        VStack(spacing: 0) {
            HStack {
                Text(LS("pg.query"))
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
                    Label(LS("pg.execute"), systemImage: "play.fill")
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
                .frame(minHeight: 60, maxHeight: 120)
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

                    // Data grid
                    ScrollView([.horizontal, .vertical]) {
                        resultTable(result)
                    }
                }
            } else {
                VStack(spacing: 8) {
                    Image(systemName: "tablecells")
                        .font(.system(size: 24))
                        .foregroundColor(.secondary)
                    Text(LS("pg.noResults"))
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }

    private func resultTable(_ result: PGQueryResult) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header
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

            // Rows
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
            Image(systemName: "externaldrive.connected.to.line.below")
                .font(.system(size: 30))
                .foregroundColor(.secondary)
            Text(LS("pg.notConnected"))
                .font(.caption)
                .foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
