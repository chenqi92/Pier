import SwiftUI

/// MySQL database client with visual query, table browsing, config viewer, and import/export.
struct DatabaseClientView: View {
    @ObservedObject var viewModel: DatabaseViewModel
    @ObservedObject var serviceManager: RemoteServiceManager
    @State private var showExportAlert = false
    @State private var exportedFileName = ""
    @State private var selectedTab: DBTab = .query
    @State private var showImportPicker = false
    @State private var showDumpOptions = false
    @State private var showHistoryPopover = false
    @State private var dumpDatabase = ""
    @State private var dumpSelectedTables: Set<String> = []
    @State private var showDeleteConfirm = false

    enum DBTab: String, CaseIterable {
        case query = "db.tabQuery"
        case config = "db.tabConfig"
        case importExport = "db.tabImportExport"
    }

    var body: some View {
        VStack(spacing: 0) {
            // Header
            dbHeader

            Divider()

            if !viewModel.isConnected {
                connectionFormView
            } else {
                // Tab bar
                tabBar

                Divider()

                // Connected content
                switch selectedTab {
                case .query:
                    queryTabContent
                case .config:
                    configTabContent
                case .importExport:
                    importExportTabContent
                }
            }
        }
        .onAppear {
            viewModel.serviceManager = serviceManager
            viewModel.autoFillFromDetectedServices()
        }
        .onChange(of: serviceManager.isConnected) { _, connected in
            if connected {
                viewModel.serviceManager = serviceManager
                viewModel.autoFillFromDetectedServices()
            } else {
                viewModel.disconnect()
            }
        }
    }

    // MARK: - Tab Bar

    private var tabBar: some View {
        HStack(spacing: 0) {
            ForEach(DBTab.allCases, id: \.self) { tab in
                Button(action: { selectedTab = tab }) {
                    Text(LS(tab.rawValue))
                        .font(.system(size: 10, weight: selectedTab == tab ? .semibold : .regular))
                        .foregroundColor(selectedTab == tab ? .accentColor : .secondary)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 5)
                        .background(
                            selectedTab == tab
                                ? Color.accentColor.opacity(0.1)
                                : Color.clear
                        )
                        .cornerRadius(4)
                }
                .buttonStyle(.plain)
            }
            Spacer()
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 2)
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.3))
    }

    // MARK: - Header

    private var dbHeader: some View {
        HStack {
            Image(systemName: "cylinder.fill")
                .foregroundColor(.cyan)
                .font(.caption)
            Text(LS("db.title"))
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
                .help(LS("db.disconnect"))
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
    }

    // MARK: - Connection Form

    private var connectionFormView: some View {
        VStack(spacing: 12) {
            // SSH status notice
            if serviceManager.isConnected {
                HStack(spacing: 4) {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.caption)
                        .foregroundColor(.green)
                    Text(LS("db.sshConnected"))
                        .font(.system(size: 10))
                        .foregroundColor(.green)
                    Spacer()
                }
                .padding(.horizontal, 12)
                .padding(.top, 4)

                // Show detected MySQL instances
                if !serviceManager.detectedServices.filter({ $0.name == "mysql" }).isEmpty {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(LS("db.detectedInstances"))
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundColor(.secondary)

                        ForEach(serviceManager.detectedServices.filter({ $0.name == "mysql" })) { svc in
                            HStack(spacing: 6) {
                                Circle()
                                    .fill(svc.isRunning ? Color.green : Color.orange)
                                    .frame(width: 6, height: 6)
                                Text("MySQL \(svc.version)")
                                    .font(.system(size: 10, weight: .medium))
                                Spacer()
                                Text(":\(svc.port)")
                                    .font(.system(size: 9, design: .monospaced))
                                    .foregroundColor(.secondary)
                                Button(action: {
                                    viewModel.formHost = "127.0.0.1"
                                    viewModel.formPort = String(svc.port)
                                }) {
                                    Text(LS("db.useThis"))
                                        .font(.system(size: 9))
                                }
                                .buttonStyle(.bordered)
                                .controlSize(.mini)
                            }
                            .padding(.horizontal, 8)
                            .padding(.vertical, 3)
                            .background(Color(nsColor: .controlBackgroundColor))
                            .cornerRadius(4)
                        }
                    }
                    .padding(.horizontal, 12)
                    .padding(.top, 2)
                }
            } else {
                HStack(spacing: 4) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundColor(.orange)
                    Text(LS("db.sshRequired"))
                        .font(.system(size: 10))
                        .foregroundColor(.orange)
                    Spacer()
                }
                .padding(.horizontal, 12)
                .padding(.top, 4)
            }

            // Saved connections
            if !viewModel.savedConnections.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Text(LS("db.savedConnections"))
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
                Text(LS("db.newConnection"))
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundColor(.secondary)

                HStack(spacing: 8) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(LS("db.host")).font(.system(size: 9)).foregroundColor(.secondary)
                        TextField("127.0.0.1", text: $viewModel.formHost)
                            .textFieldStyle(.roundedBorder)
                            .font(.caption)
                    }
                    VStack(alignment: .leading, spacing: 4) {
                        Text(LS("db.port")).font(.system(size: 9)).foregroundColor(.secondary)
                        TextField("3306", text: $viewModel.formPort)
                            .textFieldStyle(.roundedBorder)
                            .font(.caption)
                            .frame(width: 60)
                    }
                }

                HStack(spacing: 8) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(LS("db.user")).font(.system(size: 9)).foregroundColor(.secondary)
                        TextField("root", text: $viewModel.formUsername)
                            .textFieldStyle(.roundedBorder)
                            .font(.caption)
                    }
                    VStack(alignment: .leading, spacing: 4) {
                        Text(LS("db.password")).font(.system(size: 9)).foregroundColor(.secondary)
                        HStack(spacing: 4) {
                            if viewModel.showPassword {
                                TextField("", text: $viewModel.formPassword)
                                    .textFieldStyle(.roundedBorder)
                                    .font(.caption)
                            } else {
                                SecureField("", text: $viewModel.formPassword)
                                    .textFieldStyle(.roundedBorder)
                                    .font(.caption)
                            }
                            Button(action: { viewModel.showPassword.toggle() }) {
                                Image(systemName: viewModel.showPassword ? "eye.slash" : "eye")
                                    .font(.system(size: 10))
                                    .foregroundColor(.secondary)
                            }
                            .buttonStyle(.borderless)
                            .help(viewModel.showPassword ? LS("db.hidePassword") : LS("db.showPassword"))
                        }
                    }
                }

                VStack(alignment: .leading, spacing: 4) {
                    Text(LS("db.database")).font(.system(size: 9)).foregroundColor(.secondary)
                    TextField("", text: $viewModel.formDatabase)
                        .textFieldStyle(.roundedBorder)
                        .font(.caption)
                }

                if let error = viewModel.connectionError {
                    Text(error)
                        .font(.system(size: 9))
                        .foregroundColor(error.hasPrefix("✅") ? .green : .red)
                        .textSelection(.enabled)
                }

                HStack {
                    Spacer()
                    Button(LS("db.test")) { viewModel.testConnection() }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .disabled(!serviceManager.isConnected)
                    Button(LS("db.connect")) { viewModel.connect() }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                        .disabled(viewModel.formHost.isEmpty || viewModel.formUsername.isEmpty || !serviceManager.isConnected)
                }
            }
            .padding(.horizontal, 12)

            Spacer()
        }
    }

    // MARK: - Query Tab

    private var queryTabContent: some View {
        VStack(spacing: 0) {
            // Compact database & table bar
            dbTableBar

            Divider()

            // Query editor
            queryEditor

            Divider()

            // Results
            resultView
        }
    }

    // MARK: - Database & Table Bar (compact horizontal)

    private var dbTableBar: some View {
        HStack(spacing: 6) {
            // Database picker
            Picker("", selection: $viewModel.selectedDatabase) {
                ForEach(viewModel.databases, id: \.self) { db in
                    Text(db).tag(db)
                }
            }
            .frame(maxWidth: 120)
            .controlSize(.small)
            .onChange(of: viewModel.selectedDatabase) { _, newDB in
                viewModel.loadTables(database: newDB)
            }

            // Table picker
            Picker("", selection: Binding(
                get: { viewModel.selectedTable ?? "" },
                set: { viewModel.selectedTable = $0.isEmpty ? nil : $0 }
            )) {
                Text("--").tag("")
                ForEach(viewModel.tables, id: \.self) { table in
                    Text(table).tag(table)
                }
            }
            .frame(maxWidth: 140)
            .controlSize(.small)
            .onChange(of: viewModel.selectedTable) { _, newTable in
                if let table = newTable, !table.isEmpty {
                    viewModel.queryText = "SELECT * FROM `\(table)` LIMIT 100;"
                    viewModel.executeQuery()
                }
            }

            Spacer()

            // History popover button
            Button(action: { showHistoryPopover.toggle() }) {
                Image(systemName: "clock.arrow.circlepath")
                    .font(.system(size: 10))
            }
            .buttonStyle(.borderless)
            .help(LS("db.queryHistory"))
            .popover(isPresented: $showHistoryPopover, arrowEdge: .bottom) {
                queryHistoryPopover
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.3))
    }

    // MARK: - Query Editor

    private var queryEditor: some View {
        VStack(spacing: 0) {
            // SQL editor
            TextEditor(text: $viewModel.queryText)
                .font(.system(.caption, design: .monospaced))
                .frame(minHeight: 50, maxHeight: 100)
                .scrollContentBackground(.hidden)
                .background(Color(nsColor: .textBackgroundColor))

            HStack {
                if let time = viewModel.lastQueryTime {
                    Text("⏱ \(String(format: "%.2f", time))s")
                        .font(.system(size: 9))
                        .foregroundColor(.secondary)
                }
                if let count = viewModel.resultRowCount {
                    Text("• \(count) " + LS("db.rows"))
                        .font(.system(size: 9))
                        .foregroundColor(.secondary)
                }

                Spacer()

                Button(action: { viewModel.executeQuery() }) {
                    HStack(spacing: 4) {
                        Image(systemName: "play.fill")
                            .font(.system(size: 8))
                        Text(LS("db.run"))
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
            // Toolbar: selection actions + export
            if !viewModel.resultColumns.isEmpty {
                HStack(spacing: 6) {
                    if viewModel.selectedTable != nil {
                        Button(action: { viewModel.toggleSelectAll() }) {
                            Image(systemName: viewModel.selectedRows.count == viewModel.resultRows.count
                                  && !viewModel.resultRows.isEmpty
                                ? "checkmark.square.fill" : "square")
                                .font(.system(size: 10))
                                .foregroundColor(viewModel.selectedRows.isEmpty ? .secondary : .accentColor)
                        }
                        .buttonStyle(.borderless)
                        .help(LS("db.selectAll"))

                        if !viewModel.selectedRows.isEmpty {
                            Text("\(viewModel.selectedRows.count) " + LS("db.rowsSelected"))
                                .font(.system(size: 9))
                                .foregroundColor(.secondary)

                            Button(action: { showDeleteConfirm = true }) {
                                HStack(spacing: 3) {
                                    Image(systemName: "trash")
                                        .font(.system(size: 8))
                                    Text(LS("db.deleteRows"))
                                        .font(.system(size: 9, weight: .medium))
                                }
                                .foregroundColor(.red)
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.mini)
                        }
                    }

                    Spacer()

                    Button(action: {
                        if let url = viewModel.exportToCSV() {
                            exportedFileName = url.lastPathComponent
                            showExportAlert = true
                        }
                    }) {
                        HStack(spacing: 3) {
                            Image(systemName: "tablecells")
                                .font(.system(size: 8))
                            Text("CSV")
                                .font(.system(size: 9, weight: .medium))
                        }
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.mini)

                    Button(action: {
                        if let url = viewModel.exportToJSON() {
                            exportedFileName = url.lastPathComponent
                            showExportAlert = true
                        }
                    }) {
                        HStack(spacing: 3) {
                            Image(systemName: "curlybraces")
                                .font(.system(size: 8))
                            Text("JSON")
                                .font(.system(size: 9, weight: .medium))
                        }
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.mini)
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(Color(nsColor: .controlBackgroundColor).opacity(0.5))
            }

            if viewModel.isExecuting {
                ProgressView(LS("db.executing"))
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
                if viewModel.resultRows.isEmpty {
                    // Empty result set — friendly prompt
                    VStack(spacing: 8) {
                        Image(systemName: "tray")
                            .font(.system(size: 24))
                            .foregroundColor(.secondary.opacity(0.4))
                        Text(LS("db.noData"))
                            .font(.caption)
                            .foregroundColor(.secondary)
                        Text(LS("db.noDataHint"))
                            .font(.system(size: 9))
                            .foregroundColor(.secondary.opacity(0.6))
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    // Interactive table — use GeometryReader to fill width
                    GeometryReader { geo in
                        let isEditable = viewModel.selectedTable != nil
                        let gutterWidth: CGFloat = isEditable ? 50 : 34
                        let colWidths = calculateColumnWidths(availableWidth: geo.size.width, gutterWidth: gutterWidth)

                        ScrollView([.horizontal, .vertical]) {
                            LazyVStack(spacing: 0, pinnedViews: [.sectionHeaders]) {
                                Section(header: tableHeader(colWidths: colWidths, gutterWidth: gutterWidth)) {
                                    ForEach(Array(viewModel.resultRows.enumerated()), id: \.offset) { index, row in
                                        dataRow(index: index, row: row, colWidths: colWidths, gutterWidth: gutterWidth, isEditable: isEditable)
                                    }
                                }
                            }
                        }
                    }
                }
            } else {
                Text(LS("db.runQueryHint"))
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .alert(LS("db.exportSuccess"), isPresented: $showExportAlert) {
            Button(LS("common.ok"), role: .cancel) { }
        } message: {
            Text(exportedFileName)
        }
        .alert(LS("db.confirmDelete"), isPresented: $showDeleteConfirm) {
            Button(LS("db.delete"), role: .destructive) {
                viewModel.deleteSelectedRows()
            }
            Button(LS("common.cancel"), role: .cancel) { }
        } message: {
            Text(String(format: LS("db.deleteConfirmMsg"), viewModel.selectedRows.count))
        }
    }

    // MARK: - Data Row

    private func dataRow(index: Int, row: [String], colWidths: [CGFloat], gutterWidth: CGFloat, isEditable: Bool) -> some View {
        HStack(spacing: 0) {
            // Gutter: checkbox + row number
            HStack(spacing: 3) {
                if isEditable {
                    Image(systemName: viewModel.selectedRows.contains(index)
                        ? "checkmark.circle.fill" : "circle")
                        .font(.system(size: 10))
                        .foregroundColor(viewModel.selectedRows.contains(index) ? .accentColor : .secondary.opacity(0.4))
                        .onTapGesture { viewModel.toggleRowSelection(index) }
                }
                Text("\(index + 1)")
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundColor(.secondary.opacity(0.6))
            }
            .frame(width: gutterWidth, alignment: .trailing)
            .padding(.trailing, 4)
            .padding(.vertical, 2)

            // Data cells
            ForEach(Array(row.enumerated()), id: \.offset) { colIdx, value in
                cellView(
                    row: index,
                    col: colIdx,
                    value: value,
                    width: colIdx < colWidths.count ? colWidths[colIdx] : 100,
                    isEditable: isEditable
                )
            }
        }
        .background(
            viewModel.selectedRows.contains(index)
                ? Color.accentColor.opacity(0.10)
                : (index % 2 == 0 ? Color.clear : Color(nsColor: .controlBackgroundColor).opacity(0.08))
        )
        .contextMenu {
            if isEditable {
                Button(action: {
                    let rowText = row.joined(separator: "\t")
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(rowText, forType: .string)
                }) {
                    Label(LS("db.copyRow"), systemImage: "doc.on.doc")
                }

                Divider()

                Button(action: {
                    viewModel.selectedRows = [index]
                    showDeleteConfirm = true
                }) {
                    Label(LS("db.deleteRow"), systemImage: "trash")
                }
            } else {
                Button(action: {
                    let rowText = row.joined(separator: "\t")
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(rowText, forType: .string)
                }) {
                    Label(LS("db.copyRow"), systemImage: "doc.on.doc")
                }
            }
        }
    }

    /// Interactive cell view — double-click to edit
    @ViewBuilder
    private func cellView(row: Int, col: Int, value: String, width: CGFloat, isEditable: Bool) -> some View {
        if let editing = viewModel.editingCell, editing.row == row, editing.col == col {
            TextField("", text: $viewModel.editingValue, onCommit: {
                viewModel.commitEdit()
            })
            .font(.system(size: 10, design: .monospaced))
            .textFieldStyle(.roundedBorder)
            .frame(width: max(width - 4, 50))
            .padding(.horizontal, 2)
            .padding(.vertical, 1)
            .onExitCommand { viewModel.cancelEditing() }
        } else {
            Text(value == "NULL" ? "NULL" : value)
                .font(.system(size: 10, design: .monospaced))
                .foregroundColor(value == "NULL" ? .secondary.opacity(0.5) : .primary)
                .italic(value == "NULL")
                .lineLimit(1)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .frame(width: width, alignment: .leading)
                .contentShape(Rectangle())
                .onTapGesture(count: 2) {
                    if isEditable {
                        viewModel.startEditing(row: row, col: col)
                    }
                }
                .contextMenu {
                    Button(action: {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(value, forType: .string)
                    }) {
                        Label(LS("db.copyCellValue"), systemImage: "doc.on.clipboard")
                    }

                    if isEditable {
                        Divider()
                        Button(action: {
                            viewModel.startEditing(row: row, col: col)
                        }) {
                            Label(LS("db.editCell"), systemImage: "pencil")
                        }
                        if value != "NULL" {
                            Button(action: {
                                viewModel.editingCell = (row: row, col: col)
                                viewModel.editingValue = "NULL"
                                viewModel.commitEdit()
                            }) {
                                Label(LS("db.setNull"), systemImage: "xmark.circle")
                            }
                        }
                    }
                }
        }
    }

    // MARK: - Table Header

    private func tableHeader(colWidths: [CGFloat], gutterWidth: CGFloat) -> some View {
        HStack(spacing: 0) {
            Text("#")
                .font(.system(size: 9, weight: .semibold, design: .monospaced))
                .foregroundColor(.secondary)
                .frame(width: gutterWidth, alignment: .trailing)
                .padding(.trailing, 4)
                .padding(.vertical, 3)

            ForEach(Array(viewModel.resultColumns.enumerated()), id: \.offset) { idx, col in
                Text(col)
                    .font(.system(size: 10, weight: .semibold, design: .monospaced))
                    .lineLimit(1)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 3)
                    .frame(width: idx < colWidths.count ? colWidths[idx] : 100, alignment: .leading)
            }
        }
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.8))
    }

    /// Calculate column widths — fills available width when columns are few
    private func calculateColumnWidths(availableWidth: CGFloat, gutterWidth: CGFloat) -> [CGFloat] {
        guard !viewModel.resultColumns.isEmpty else { return [] }

        // First pass: compute natural widths based on content
        let naturalWidths = viewModel.resultColumns.enumerated().map { idx, col -> CGFloat in
            var maxLen = col.count
            for row in viewModel.resultRows.prefix(50) {
                if idx < row.count {
                    // Count wider characters (CJK) as ~2
                    let charLen = row[idx].reduce(0) { sum, ch in
                        sum + (ch.unicodeScalars.first.map { $0.value > 0x2E80 ? 2 : 1 } ?? 1)
                    }
                    maxLen = max(maxLen, charLen)
                }
            }
            return CGFloat(min(max(maxLen * 7 + 16, 60), 300))
        }

        let totalNatural = naturalWidths.reduce(0, +)
        let usable = availableWidth - gutterWidth - 8 // 8px margin

        if totalNatural < usable && viewModel.resultColumns.count <= 8 {
            // Stretch columns proportionally to fill width
            let scale = usable / totalNatural
            return naturalWidths.map { $0 * scale }
        }

        return naturalWidths
    }

    // MARK: - Query History Popover

    private var queryHistoryPopover: some View {
        VStack(spacing: 0) {
            HStack {
                Text(LS("db.queryHistory"))
                    .font(.system(size: 11, weight: .semibold))
                Spacer()
                if !viewModel.queryHistory.isEmpty {
                    Button(action: { viewModel.clearHistory() }) {
                        Image(systemName: "trash")
                            .font(.system(size: 10))
                    }
                    .buttonStyle(.borderless)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)

            Divider()

            if viewModel.queryHistory.isEmpty {
                Text(LS("db.noHistory"))
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .padding(20)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 2) {
                        ForEach(viewModel.queryHistory.prefix(30)) { entry in
                            Button(action: {
                                viewModel.queryText = entry.query
                                showHistoryPopover = false
                            }) {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(entry.query)
                                        .font(.system(size: 10, design: .monospaced))
                                        .lineLimit(2)
                                        .foregroundColor(.primary)
                                    HStack(spacing: 4) {
                                        Image(systemName: entry.succeeded ? "checkmark.circle" : "xmark.circle")
                                            .font(.system(size: 8))
                                            .foregroundColor(entry.succeeded ? .green : .red)
                                        if !entry.database.isEmpty {
                                            Text(entry.database)
                                                .font(.system(size: 9))
                                                .foregroundColor(.secondary)
                                        }
                                        Spacer()
                                        Text(entry.timestamp, style: .relative)
                                            .font(.system(size: 9))
                                            .foregroundColor(.secondary)
                                    }
                                }
                                .padding(.horizontal, 8)
                                .padding(.vertical, 4)
                                .background(Color(nsColor: .controlBackgroundColor).opacity(0.3))
                                .cornerRadius(4)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                }
                .frame(maxHeight: 300)
            }
        }
        .frame(width: 350)
    }

    // MARK: - Config Tab

    private var configTabContent: some View {
        VStack(spacing: 0) {
            // Config toolbar
            HStack {
                Image(systemName: "gearshape.fill")
                    .font(.caption)
                    .foregroundColor(.orange)
                Text(LS("db.mysqlConfig"))
                    .font(.system(size: 10, weight: .semibold))
                Spacer()
                Button(action: { viewModel.loadMySQLConfig() }) {
                    HStack(spacing: 3) {
                        Image(systemName: "arrow.clockwise")
                            .font(.system(size: 9))
                        Text(LS("db.loadConfig"))
                            .font(.system(size: 10))
                    }
                }
                .buttonStyle(.bordered)
                .controlSize(.mini)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)

            Divider()

            if viewModel.isLoadingConfig {
                VStack {
                    ProgressView()
                    Text(LS("db.loadingConfig"))
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let error = viewModel.configError {
                VStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle")
                        .font(.title2)
                        .foregroundColor(.orange)
                    Text(error)
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if viewModel.configSections.isEmpty {
                VStack(spacing: 12) {
                    Image(systemName: "doc.text.magnifyingglass")
                        .font(.system(size: 28))
                        .foregroundColor(.secondary)
                    Text(LS("db.configHint"))
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .multilineTextAlignment(.center)
                    Button(action: { viewModel.loadMySQLConfig() }) {
                        Text(LS("db.loadConfig"))
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                // Config sections display
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 12) {
                        ForEach(viewModel.configSections) { section in
                            VStack(alignment: .leading, spacing: 4) {
                                Text("[\(section.name)]")
                                    .font(.system(size: 11, weight: .bold, design: .monospaced))
                                    .foregroundColor(.cyan)

                                ForEach(Array(section.entries.enumerated()), id: \.offset) { _, entry in
                                    HStack(spacing: 8) {
                                        Text(entry.key)
                                            .font(.system(size: 10, design: .monospaced))
                                            .foregroundColor(.primary)
                                            .frame(minWidth: 120, alignment: .trailing)
                                        if !entry.value.isEmpty {
                                            Text("=")
                                                .font(.system(size: 10, design: .monospaced))
                                                .foregroundColor(.secondary)
                                            Text(entry.value)
                                                .font(.system(size: 10, design: .monospaced))
                                                .foregroundColor(.green)
                                                .textSelection(.enabled)
                                        }
                                    }
                                }
                            }
                            .padding(.horizontal, 12)
                            .padding(.vertical, 8)
                            .background(Color(nsColor: .controlBackgroundColor).opacity(0.3))
                            .cornerRadius(6)
                        }
                    }
                    .padding(12)
                }
            }
        }
    }

    // MARK: - Import/Export Tab

    private var importExportTabContent: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    // Export section
                    VStack(alignment: .leading, spacing: 8) {
                        HStack(spacing: 6) {
                            Image(systemName: "arrow.up.doc.fill")
                                .font(.caption)
                                .foregroundColor(.blue)
                            Text(LS("db.exportSection"))
                                .font(.system(size: 11, weight: .semibold))
                        }

                        Text(LS("db.exportDesc"))
                            .font(.system(size: 10))
                            .foregroundColor(.secondary)

                        // Database picker for export
                        if !viewModel.databases.isEmpty {
                            HStack(spacing: 8) {
                                Text(LS("db.database"))
                                    .font(.system(size: 10))
                                    .foregroundColor(.secondary)
                                Picker("", selection: $dumpDatabase) {
                                    Text("--").tag("")
                                    ForEach(viewModel.databases, id: \.self) { db in
                                        Text(db).tag(db)
                                    }
                                }
                                .frame(maxWidth: 150)
                                .controlSize(.small)
                            }

                            HStack {
                                Button(action: {
                                    guard !dumpDatabase.isEmpty else { return }
                                    viewModel.exportDatabase(dumpDatabase)
                                }) {
                                    HStack(spacing: 4) {
                                        Image(systemName: "square.and.arrow.down")
                                            .font(.system(size: 9))
                                        Text("mysqldump")
                                            .font(.system(size: 10, weight: .medium))
                                    }
                                }
                                .buttonStyle(.borderedProminent)
                                .controlSize(.small)
                                .disabled(dumpDatabase.isEmpty || viewModel.isExporting)

                                if viewModel.isExporting {
                                    ProgressView()
                                        .scaleEffect(0.6)
                                }
                            }

                            if let progress = viewModel.exportProgress {
                                Text(progress)
                                    .font(.system(size: 9))
                                    .foregroundColor(progress.hasPrefix("✅") ? .green : (progress.hasPrefix("❌") ? .red : .secondary))
                            }
                        }
                    }
                    .padding(12)
                    .background(Color(nsColor: .controlBackgroundColor).opacity(0.3))
                    .cornerRadius(8)

                    Divider()

                    // Import section
                    VStack(alignment: .leading, spacing: 8) {
                        HStack(spacing: 6) {
                            Image(systemName: "arrow.down.doc.fill")
                                .font(.caption)
                                .foregroundColor(.green)
                            Text(LS("db.importSection"))
                                .font(.system(size: 11, weight: .semibold))
                        }

                        Text(LS("db.importDesc"))
                            .font(.system(size: 10))
                            .foregroundColor(.secondary)

                        if !viewModel.databases.isEmpty {
                            HStack(spacing: 8) {
                                Text(LS("db.targetDatabase"))
                                    .font(.system(size: 10))
                                    .foregroundColor(.secondary)
                                Picker("", selection: $dumpDatabase) {
                                    Text("--").tag("")
                                    ForEach(viewModel.databases, id: \.self) { db in
                                        Text(db).tag(db)
                                    }
                                }
                                .frame(maxWidth: 150)
                                .controlSize(.small)
                            }

                            Button(action: { showImportPicker = true }) {
                                HStack(spacing: 4) {
                                    Image(systemName: "doc.badge.plus")
                                        .font(.system(size: 9))
                                    Text(LS("db.selectSQLFile"))
                                        .font(.system(size: 10, weight: .medium))
                                }
                            }
                            .buttonStyle(.borderedProminent)
                            .controlSize(.small)
                            .disabled(dumpDatabase.isEmpty || viewModel.isImporting)

                            if viewModel.isImporting {
                                HStack(spacing: 4) {
                                    ProgressView()
                                        .scaleEffect(0.6)
                                    Text(viewModel.importProgress ?? "")
                                        .font(.system(size: 9))
                                        .foregroundColor(.secondary)
                                }
                            }

                            if let progress = viewModel.importProgress, !viewModel.isImporting {
                                Text(progress)
                                    .font(.system(size: 9))
                                    .foregroundColor(progress.hasPrefix("✅") ? .green : (progress.hasPrefix("❌") ? .red : .secondary))
                            }
                        }
                    }
                    .padding(12)
                    .background(Color(nsColor: .controlBackgroundColor).opacity(0.3))
                    .cornerRadius(8)
                }
                .padding(12)
            }
        }
        .fileImporter(isPresented: $showImportPicker, allowedContentTypes: [.init(filenameExtension: "sql")!], allowsMultipleSelection: false) { result in
            if case .success(let urls) = result, let url = urls.first {
                _ = url.startAccessingSecurityScopedResource()
                viewModel.importSQL(from: url, toDatabase: dumpDatabase)
                url.stopAccessingSecurityScopedResource()
            }
        }
    }
}
