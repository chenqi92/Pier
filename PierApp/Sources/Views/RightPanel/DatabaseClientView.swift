import SwiftUI

/// MySQL database client with visual query and table browsing.
struct DatabaseClientView: View {
    @StateObject private var viewModel = DatabaseViewModel()

    var body: some View {
        VStack(spacing: 0) {
            // Header
            dbHeader

            Divider()

            if !viewModel.isConnected {
                connectionFormView
            } else {
                // Connected content
                HSplitView {
                    // Database/Table sidebar
                    dbSidebar
                        .frame(minWidth: 120, maxWidth: 180)

                    // Query & Results area
                    VStack(spacing: 0) {
                        queryEditor
                        Divider()
                        resultView
                    }
                }
            }
        }
    }

    // MARK: - Header

    private var dbHeader: some View {
        HStack {
            Image(systemName: "cylinder.fill")
                .foregroundColor(.cyan)
                .font(.caption)
            Text("db.title")
                .font(.caption)
                .fontWeight(.medium)

            if viewModel.isConnected {
                Text("•")
                    .foregroundColor(.green)
                Text(viewModel.connectionName)
                    .font(.system(size: 9))
                    .foregroundColor(.secondary)
            }

            Spacer()

            if viewModel.isConnected {
                Button(action: { viewModel.disconnect() }) {
                    Image(systemName: "bolt.horizontal.circle")
                        .font(.caption)
                        .foregroundColor(.red)
                }
                .buttonStyle(.borderless)
                .help(String(localized: "db.disconnect"))
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
    }

    // MARK: - Connection Form

    private var connectionFormView: some View {
        VStack(spacing: 12) {
            // Saved connections
            if !viewModel.savedConnections.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Text("db.savedConnections")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundColor(.secondary)

                    ForEach(viewModel.savedConnections) { conn in
                        Button(action: { viewModel.connectWith(conn) }) {
                            HStack {
                                Image(systemName: "cylinder")
                                    .font(.caption)
                                Text(conn.name)
                                    .font(.caption)
                                Spacer()
                                Text("\(conn.host):\(conn.port)")
                                    .font(.system(size: 9))
                                    .foregroundColor(.secondary)
                            }
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(Color(nsColor: .controlBackgroundColor))
                            .cornerRadius(4)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 12)
                .padding(.top, 8)

                Divider()
                    .padding(.horizontal, 12)
            }

            // New connection form
            VStack(alignment: .leading, spacing: 8) {
                Text("db.newConnection")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundColor(.secondary)

                HStack(spacing: 8) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("db.host").font(.system(size: 9)).foregroundColor(.secondary)
                        TextField("localhost", text: $viewModel.formHost)
                            .textFieldStyle(.roundedBorder)
                            .font(.caption)
                    }
                    VStack(alignment: .leading, spacing: 4) {
                        Text("db.port").font(.system(size: 9)).foregroundColor(.secondary)
                        TextField("3306", text: $viewModel.formPort)
                            .textFieldStyle(.roundedBorder)
                            .font(.caption)
                            .frame(width: 60)
                    }
                }

                HStack(spacing: 8) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("db.user").font(.system(size: 9)).foregroundColor(.secondary)
                        TextField("root", text: $viewModel.formUsername)
                            .textFieldStyle(.roundedBorder)
                            .font(.caption)
                    }
                    VStack(alignment: .leading, spacing: 4) {
                        Text("db.password").font(.system(size: 9)).foregroundColor(.secondary)
                        SecureField("", text: $viewModel.formPassword)
                            .textFieldStyle(.roundedBorder)
                            .font(.caption)
                    }
                }

                VStack(alignment: .leading, spacing: 4) {
                    Text("db.database").font(.system(size: 9)).foregroundColor(.secondary)
                    TextField("", text: $viewModel.formDatabase)
                        .textFieldStyle(.roundedBorder)
                        .font(.caption)
                }

                if let error = viewModel.connectionError {
                    Text(error)
                        .font(.system(size: 9))
                        .foregroundColor(.red)
                }

                HStack {
                    Spacer()
                    Button("db.test") { viewModel.testConnection() }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                    Button("db.connect") { viewModel.connect() }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                        .disabled(viewModel.formHost.isEmpty || viewModel.formUsername.isEmpty)
                }
            }
            .padding(.horizontal, 12)

            Spacer()
        }
    }

    // MARK: - Database Sidebar

    private var dbSidebar: some View {
        VStack(spacing: 0) {
            // Database selector
            Picker("", selection: $viewModel.selectedDatabase) {
                ForEach(viewModel.databases, id: \.self) { db in
                    Text(db).tag(db)
                }
            }
            .font(.caption)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .onChange(of: viewModel.selectedDatabase) { _, newDB in
                viewModel.loadTables(database: newDB)
            }

            Divider()

            // Table list
            List(viewModel.tables, id: \.self, selection: $viewModel.selectedTable) { table in
                HStack(spacing: 4) {
                    Image(systemName: "tablecells")
                        .font(.system(size: 9))
                        .foregroundColor(.cyan)
                    Text(table)
                        .font(.caption)
                        .lineLimit(1)
                }
                .contextMenu {
                    Button("SELECT * FROM \(table)") {
                        viewModel.queryText = "SELECT * FROM `\(table)` LIMIT 100;"
                        viewModel.executeQuery()
                    }
                    Button("DESCRIBE \(table)") {
                        viewModel.queryText = "DESCRIBE `\(table)`;"
                        viewModel.executeQuery()
                    }
                    Button("db.showCreateTable") {
                        viewModel.queryText = "SHOW CREATE TABLE `\(table)`;"
                        viewModel.executeQuery()
                    }
                    Divider()
                    Button("db.dropTable", role: .destructive) {
                        viewModel.queryText = "DROP TABLE `\(table)`;"
                    }
                }
            }
            .listStyle(.sidebar)
            .onChange(of: viewModel.selectedTable) { _, newTable in
                if let table = newTable {
                    viewModel.queryText = "SELECT * FROM `\(table)` LIMIT 100;"
                    viewModel.executeQuery()
                }
            }
        }
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.3))
    }

    // MARK: - Query Editor

    private var queryEditor: some View {
        VStack(spacing: 0) {
            // SQL editor
            TextEditor(text: $viewModel.queryText)
                .font(.system(.caption, design: .monospaced))
                .frame(minHeight: 60, maxHeight: 120)
                .scrollContentBackground(.hidden)
                .background(Color(nsColor: .textBackgroundColor))

            HStack {
                if let time = viewModel.lastQueryTime {
                    Text("⏱ \(String(format: "%.2f", time))s")
                        .font(.system(size: 9))
                        .foregroundColor(.secondary)
                }
                if let count = viewModel.resultRowCount {
                    Text("• \(count) rows")
                        .font(.system(size: 9))
                        .foregroundColor(.secondary)
                }

                Spacer()

                Button(action: { viewModel.executeQuery() }) {
                    HStack(spacing: 4) {
                        Image(systemName: "play.fill")
                            .font(.system(size: 8))
                        Text("db.run")
                            .font(.caption)
                    }
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .keyboardShortcut(.return, modifiers: [.command])
                .disabled(viewModel.queryText.isEmpty || viewModel.isExecuting)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
        }
    }

    // MARK: - Result View

    private var resultView: some View {
        VStack(spacing: 0) {
            if viewModel.isExecuting {
                ProgressView("Executing...")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let error = viewModel.queryError {
                ScrollView {
                    Text(error)
                        .font(.system(.caption, design: .monospaced))
                        .foregroundColor(.red)
                        .padding()
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)
                }
            } else if !viewModel.resultColumns.isEmpty {
                // Table view
                ScrollView([.horizontal, .vertical]) {
                    VStack(spacing: 0) {
                        // Column headers
                        HStack(spacing: 0) {
                            ForEach(viewModel.resultColumns, id: \.self) { col in
                                Text(col)
                                    .font(.system(size: 10, weight: .semibold, design: .monospaced))
                                    .padding(.horizontal, 8)
                                    .padding(.vertical, 4)
                                    .frame(minWidth: 80, alignment: .leading)
                                    .background(Color(nsColor: .controlBackgroundColor))
                                    .border(Color(nsColor: .separatorColor), width: 0.5)
                            }
                        }

                        // Data rows
                        ForEach(Array(viewModel.resultRows.enumerated()), id: \.offset) { index, row in
                            HStack(spacing: 0) {
                                ForEach(Array(row.enumerated()), id: \.offset) { colIdx, value in
                                    Text(value)
                                        .font(.system(size: 10, design: .monospaced))
                                        .padding(.horizontal, 8)
                                        .padding(.vertical, 3)
                                        .frame(minWidth: 80, alignment: .leading)
                                        .background(index % 2 == 0
                                            ? Color.clear
                                            : Color(nsColor: .controlBackgroundColor).opacity(0.3))
                                        .border(Color(nsColor: .separatorColor), width: 0.5)
                                }
                            }
                        }
                    }
                }
                .textSelection(.enabled)
            } else {
                Text("db.runQueryHint")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }
}
