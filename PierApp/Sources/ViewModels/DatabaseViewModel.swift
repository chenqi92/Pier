import SwiftUI
import Combine

// MARK: - Data Models

struct MySQLConnection: Identifiable, Codable {
    let id: String
    let name: String
    let host: String
    let port: Int
    let username: String
    let database: String

    init(name: String, host: String, port: Int, username: String, database: String) {
        self.id = UUID().uuidString
        self.name = name
        self.host = host
        self.port = port
        self.username = username
        self.database = database
    }
}

struct QueryHistoryEntry: Identifiable, Codable {
    let id: UUID
    let query: String
    let database: String
    let timestamp: Date
    let rowCount: Int
    let executionTime: TimeInterval
    let succeeded: Bool

    init(query: String, database: String, rowCount: Int, executionTime: TimeInterval, succeeded: Bool) {
        self.id = UUID()
        self.query = query
        self.database = database
        self.timestamp = Date()
        self.rowCount = rowCount
        self.executionTime = executionTime
        self.succeeded = succeeded
    }
}

/// Parsed MySQL config file section
struct MySQLConfigSection: Identifiable {
    let id = UUID()
    var name: String   // e.g. "mysqld", "client"
    var entries: [(key: String, value: String)]
}

// MARK: - ViewModel

@MainActor
class DatabaseViewModel: ObservableObject {
    // Connection state
    @Published var isConnected = false
    @Published var connectionName = ""
    @Published var connectionError: String?
    @Published var savedConnections: [MySQLConnection] = []

    // Connection form
    @Published var formHost = "127.0.0.1"
    @Published var formPort = "3306"
    @Published var formUsername = "root"
    @Published var formPassword = ""
    @Published var formDatabase = ""
    @Published var showPassword = false

    // Database browser
    @Published var databases: [String] = []
    @Published var selectedDatabase = ""
    @Published var tables: [String] = []
    @Published var selectedTable: String? = nil

    // Query
    @Published var queryText = ""
    @Published var isExecuting = false
    @Published var resultColumns: [String] = []
    @Published var resultRows: [[String]] = []
    @Published var queryError: String? = nil
    @Published var lastQueryTime: TimeInterval? = nil
    @Published var resultRowCount: Int? = nil

    // Data manipulation
    @Published var selectedRows: Set<Int> = []       // Selected row indices
    @Published var editingCell: (row: Int, col: Int)? = nil
    @Published var editingValue: String = ""
    @Published var primaryKeyColumn: String? = nil    // Auto-detected PK column
    private var lastSelectQuery: String = ""          // For refresh after edit

    // Query History
    @Published var queryHistory: [QueryHistoryEntry] = []

    // Config viewer
    @Published var configSections: [MySQLConfigSection] = []
    @Published var configRawContent: String = ""
    @Published var isLoadingConfig = false
    @Published var configError: String?

    // Import/Export
    @Published var isExporting = false
    @Published var isImporting = false
    @Published var exportProgress: String?
    @Published var importProgress: String?

    // Internal
    private var currentHost = ""
    private var currentPort = 3306
    private var currentUser = ""
    private var currentPassword = ""
    private var currentDB = ""

    /// Remote service manager for SSH command execution
    weak var serviceManager: RemoteServiceManager?

    /// Debounced history save
    private var historySaveWork: DispatchWorkItem?

    init() {
        loadSavedConnections()
        loadHistory()
    }

    /// Auto-fill connection form from detected services.
    /// Since commands execute on the REMOTE server, we use the remote MySQL port
    /// (typically 3306), NOT the local SSH tunnel port (e.g. 13306).
    func autoFillFromDetectedServices() {
        guard let sm = serviceManager else { return }

        // Check for mysql in detected services
        if let mysqlService = sm.detectedServices.first(where: { $0.name == "mysql" }) {
            formHost = "127.0.0.1"
            formPort = String(mysqlService.port)  // Remote port, NOT tunnel localPort
        }
    }

    // MARK: - Connection

    func connect() {
        guard let port = Int(formPort) else {
            connectionError = "Invalid port number"
            return
        }

        currentHost = formHost
        currentPort = port
        currentUser = formUsername
        currentPassword = formPassword
        currentDB = formDatabase

        Task {
            connectionError = nil
            // Test connection by querying databases
            let result = await executeMysql("SHOW DATABASES;")
            if let error = result.error {
                connectionError = error
                return
            }

            isConnected = true
            connectionName = "\(currentUser)@\(currentHost):\(currentPort)"

            // Parse databases
            databases = result.rows.flatMap { $0 }.filter {
                !["Database", "information_schema", "performance_schema", "sys"].contains($0)
            }

            if !formDatabase.isEmpty {
                selectedDatabase = formDatabase
                loadTables(database: formDatabase)
            } else if let first = databases.first {
                selectedDatabase = first
                loadTables(database: first)
            }

            // Save connection
            saveConnection()
        }
    }

    func connectWith(_ conn: MySQLConnection) {
        formHost = conn.host
        formPort = String(conn.port)
        formUsername = conn.username
        formDatabase = conn.database
        // Password needs to be entered again (security)
    }

    func testConnection() {
        Task {
            connectionError = nil
            let result = await executeMysql("SELECT 1;", host: formHost,
                port: Int(formPort) ?? 3306, user: formUsername, password: formPassword, db: formDatabase)
            if let error = result.error {
                connectionError = "❌ \(error)"
            } else {
                connectionError = "✅ Connection successful!"
            }
        }
    }

    func disconnect() {
        isConnected = false
        databases = []
        tables = []
        resultColumns = []
        resultRows = []
        queryError = nil
        connectionName = ""
        selectedRows.removeAll()
        editingCell = nil
        editingValue = ""
        primaryKeyColumn = nil
        lastSelectQuery = ""
        selectedTable = nil
    }

    // MARK: - Database Operations

    func loadTables(database: String) {
        guard isConnected else { return }
        currentDB = database
        Task {
            let result = await executeMysql("SHOW TABLES;", db: database)
            if result.error == nil {
                tables = result.rows.flatMap { $0 }
                    .filter { !$0.hasPrefix("Tables_in_") }
            }
        }
    }

    func executeQuery() {
        guard !queryText.isEmpty else { return }
        isExecuting = true
        queryError = nil
        selectedRows.removeAll()
        editingCell = nil

        Task {
            let start = Date()
            let result = await executeMysql(queryText, db: currentDB)
            let elapsed = Date().timeIntervalSince(start)

            isExecuting = false
            lastQueryTime = elapsed

            let entry = QueryHistoryEntry(
                query: queryText,
                database: currentDB,
                rowCount: result.rows.count,
                executionTime: elapsed,
                succeeded: result.error == nil
            )
            queryHistory.insert(entry, at: 0)
            if queryHistory.count > 200 { queryHistory = Array(queryHistory.prefix(200)) }
            saveHistory()

            if let error = result.error {
                queryError = error
                resultColumns = []
                resultRows = []
                resultRowCount = nil
            } else {
                resultColumns = result.columns
                resultRows = result.rows
                resultRowCount = result.rows.count
                queryError = nil

                // Remember for refresh and detect PK
                if queryText.trimmingCharacters(in: .whitespacesAndNewlines)
                    .uppercased().hasPrefix("SELECT") {
                    lastSelectQuery = queryText
                    if let table = selectedTable {
                        await detectPrimaryKey(for: table)
                    }
                }
            }
        }
    }

    // MARK: - Data Manipulation

    /// Detect primary key column for a table
    private func detectPrimaryKey(for table: String) async {
        let result = await executeMysql(
            "SHOW KEYS FROM `\(table)` WHERE Key_name = 'PRIMARY';",
            db: currentDB
        )
        if result.error == nil, !result.rows.isEmpty {
            // Column_name is typically at index 4 in SHOW KEYS output
            if let colIdx = result.columns.firstIndex(of: "Column_name"),
               colIdx < result.rows[0].count {
                primaryKeyColumn = result.rows[0][colIdx]
            }
        }
    }

    /// Build WHERE clause to identify a specific row
    private func buildWhereClause(forRow rowIndex: Int) -> String? {
        guard rowIndex < resultRows.count else { return nil }
        let row = resultRows[rowIndex]

        // Prefer primary key
        if let pk = primaryKeyColumn,
           let pkIdx = resultColumns.firstIndex(of: pk),
           pkIdx < row.count {
            let val = row[pkIdx]
            return "`\(pk)` = '\(escapeSql(val))'"
        }

        // Fallback: match all columns
        var parts: [String] = []
        for (i, col) in resultColumns.enumerated() where i < row.count {
            let val = row[i]
            if val == "NULL" {
                parts.append("`\(col)` IS NULL")
            } else {
                parts.append("`\(col)` = '\(escapeSql(val))'")
            }
        }
        return parts.isEmpty ? nil : parts.joined(separator: " AND ")
    }

    /// Start editing a cell
    func startEditing(row: Int, col: Int) {
        guard row < resultRows.count, col < resultColumns.count else { return }
        editingCell = (row: row, col: col)
        editingValue = resultRows[row][col]
    }

    /// Cancel editing
    func cancelEditing() {
        editingCell = nil
        editingValue = ""
    }

    /// Commit cell edit — generates and executes UPDATE SQL
    func commitEdit() {
        guard let cell = editingCell,
              let table = selectedTable,
              cell.row < resultRows.count,
              cell.col < resultColumns.count else {
            cancelEditing()
            return
        }

        let oldValue = resultRows[cell.row][cell.col]
        let newValue = editingValue

        // Nothing changed
        if oldValue == newValue {
            cancelEditing()
            return
        }

        guard let whereClause = buildWhereClause(forRow: cell.row) else {
            queryError = "Cannot determine row identity for UPDATE"
            cancelEditing()
            return
        }

        let colName = resultColumns[cell.col]
        let setClause = newValue == "NULL"
            ? "`\(colName)` = NULL"
            : "`\(colName)` = '\(escapeSql(newValue))'"

        let sql = "UPDATE `\(table)` SET \(setClause) WHERE \(whereClause) LIMIT 1;"

        cancelEditing()

        Task {
            let result = await executeMysql(sql, db: currentDB)
            if let error = result.error {
                queryError = "UPDATE failed: \(error)"
            } else {
                queryError = nil
                // Refresh results
                refreshCurrentQuery()
            }
        }
    }

    /// Delete selected rows — generates and executes DELETE SQL
    func deleteSelectedRows() {
        guard let table = selectedTable, !selectedRows.isEmpty else { return }

        let sortedRows = selectedRows.sorted(by: >)  // Process in reverse to keep indices valid
        var whereClauses: [String] = []

        for rowIndex in sortedRows {
            if let clause = buildWhereClause(forRow: rowIndex) {
                whereClauses.append("(\(clause))")
            }
        }

        guard !whereClauses.isEmpty else {
            queryError = "Cannot determine row identity for DELETE"
            return
        }

        let sql = "DELETE FROM `\(table)` WHERE \(whereClauses.joined(separator: " OR "));"

        Task {
            let result = await executeMysql(sql, db: currentDB)
            if let error = result.error {
                queryError = "DELETE failed: \(error)"
            } else {
                queryError = nil
                selectedRows.removeAll()
                refreshCurrentQuery()
            }
        }
    }

    /// Refresh the current query results without altering the editor text
    func refreshCurrentQuery() {
        guard !lastSelectQuery.isEmpty else { return }

        isExecuting = true
        queryError = nil
        selectedRows.removeAll()
        editingCell = nil

        Task {
            let start = Date()
            let result = await executeMysql(lastSelectQuery, db: currentDB)
            let elapsed = Date().timeIntervalSince(start)

            isExecuting = false
            lastQueryTime = elapsed

            if let error = result.error {
                queryError = error
            } else {
                resultColumns = result.columns
                resultRows = result.rows
                resultRowCount = result.rows.count
                queryError = nil
            }
        }
    }

    /// Toggle row selection
    func toggleRowSelection(_ index: Int) {
        if selectedRows.contains(index) {
            selectedRows.remove(index)
        } else {
            selectedRows.insert(index)
        }
    }

    /// Select/deselect all rows
    func toggleSelectAll() {
        if selectedRows.count == resultRows.count {
            selectedRows.removeAll()
        } else {
            selectedRows = Set(0..<resultRows.count)
        }
    }

    private func escapeSql(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\0", with: "\\0")
            .replacingOccurrences(of: "\n", with: "\\n")
            .replacingOccurrences(of: "\r", with: "\\r")
            .replacingOccurrences(of: "\u{1a}", with: "\\Z")
            .replacingOccurrences(of: "'", with: "\\'")
            .replacingOccurrences(of: "\"", with: "\\\"")
    }

    // MARK: - MySQL Execution (via SSH)

    struct QueryResult {
        let columns: [String]
        let rows: [[String]]
        let error: String?
    }

    private func executeMysql(
        _ query: String,
        host: String? = nil,
        port: Int? = nil,
        user: String? = nil,
        password: String? = nil,
        db: String? = nil
    ) async -> QueryResult {
        guard let sm = serviceManager else {
            return QueryResult(columns: [], rows: [], error: LS("db.notConnectedSSH"))
        }

        guard sm.isConnected else {
            return QueryResult(columns: [], rows: [], error: LS("db.sshDisconnected"))
        }

        let h = host ?? currentHost
        let p = port ?? currentPort
        let u = user ?? currentUser
        let pw = password ?? currentPassword
        let d = db ?? currentDB

        // Build the mysql command line for remote execution
        // Escape single quotes in the query for safe shell embedding
        let escapedQuery = query.replacingOccurrences(of: "'", with: "'\\''")

        var cmd = "mysql -h \(h) -P \(p) -u \(u)"

        if !pw.isEmpty {
            // Use MYSQL_PWD env var to avoid password in process listing
            cmd = "MYSQL_PWD='\(pw.replacingOccurrences(of: "'", with: "'\\''"))' " + cmd
        }

        cmd += " --batch --raw"

        if !d.isEmpty {
            cmd += " -D '\(d.replacingOccurrences(of: "'", with: "'\\''"))'"
        }

        cmd += " -e '\(escapedQuery)'"

        // Redirect stderr to stdout so we capture MySQL error messages
        cmd += " 2>&1"

        let (exitCode, output) = await sm.exec(cmd, timeout: 60)

        if exitCode != 0 {
            let errorMsg = output.isEmpty
                ? "MySQL error (exit code: \(exitCode)). Check credentials and ensure MySQL is running."
                : output
            return QueryResult(columns: [], rows: [], error: errorMsg)
        }

        return parseTSV(output)
    }

    private func parseTSV(_ output: String) -> QueryResult {
        let lines = output.split(separator: "\n", omittingEmptySubsequences: false)
        guard !lines.isEmpty else {
            return QueryResult(columns: [], rows: [], error: nil)
        }

        let columns = lines[0].split(separator: "\t", omittingEmptySubsequences: false).map(String.init)

        let rows = lines.dropFirst().compactMap { line -> [String]? in
            let row = line.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
            return row.isEmpty ? nil : row
        }

        return QueryResult(columns: columns, rows: rows, error: nil)
    }

    // MARK: - MySQL Config

    /// Load MySQL config from remote server
    func loadMySQLConfig() {
        guard let sm = serviceManager, sm.isConnected else {
            configError = LS("db.sshDisconnected")
            return
        }

        isLoadingConfig = true
        configError = nil

        Task {
            // Try common config paths
            let configPaths = [
                "/etc/mysql/my.cnf",
                "/etc/my.cnf",
                "/etc/mysql/mysql.conf.d/mysqld.cnf",
                "/etc/mysql/conf.d/",
            ]

            var configContent = ""
            var foundPath = ""

            for path in configPaths {
                let (code, output) = await sm.exec("cat \(path) 2>/dev/null", timeout: 10)
                if code == 0, !output.isEmpty {
                    configContent += "# Source: \(path)\n\(output)\n\n"
                    if foundPath.isEmpty { foundPath = path }
                }
            }

            isLoadingConfig = false

            if configContent.isEmpty {
                configError = LS("db.configNotFound")
                return
            }

            configRawContent = configContent
            configSections = parseMySQLConfig(configContent)
        }
    }

    /// Save MySQL config to remote server
    func saveMySQLConfig(_ content: String, toPath path: String) {
        guard let sm = serviceManager, sm.isConnected else { return }

        Task {
            // Write via tee to handle sudo
            let escapedContent = content.replacingOccurrences(of: "'", with: "'\\''")
            let (code, output) = await sm.exec("echo '\(escapedContent)' | sudo tee \(path) > /dev/null", timeout: 15)

            if code != 0 {
                configError = "Save failed: \(output)"
            } else {
                configError = nil
            }
        }
    }

    private func parseMySQLConfig(_ content: String) -> [MySQLConfigSection] {
        var sections: [MySQLConfigSection] = []
        var currentSection = MySQLConfigSection(name: "global", entries: [])

        for line in content.components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            // Skip comments and empty lines
            if trimmed.isEmpty || trimmed.hasPrefix("#") || trimmed.hasPrefix(";") {
                continue
            }

            // Source comment (our own marker)
            if trimmed.hasPrefix("# Source:") {
                continue
            }

            // Section header
            if trimmed.hasPrefix("[") && trimmed.hasSuffix("]") {
                if !currentSection.entries.isEmpty || currentSection.name != "global" {
                    sections.append(currentSection)
                }
                let name = String(trimmed.dropFirst().dropLast())
                currentSection = MySQLConfigSection(name: name, entries: [])
                continue
            }

            // Key = value or key (no value)
            if let eqRange = trimmed.range(of: "=") {
                let key = String(trimmed[trimmed.startIndex..<eqRange.lowerBound]).trimmingCharacters(in: .whitespaces)
                let value = String(trimmed[eqRange.upperBound...]).trimmingCharacters(in: .whitespaces)
                currentSection.entries.append((key: key, value: value))
            } else {
                currentSection.entries.append((key: trimmed, value: ""))
            }
        }

        if !currentSection.entries.isEmpty {
            sections.append(currentSection)
        }

        return sections
    }

    // MARK: - Import / Export

    /// Export database via mysqldump (remote execution, save result locally)
    func exportDatabase(_ database: String, tables: [String]? = nil) {
        guard let sm = serviceManager, sm.isConnected else { return }
        isExporting = true
        exportProgress = LS("db.exportStarting")

        Task {
            var cmd = "mysqldump -h \(currentHost) -P \(currentPort) -u \(currentUser)"
            if !currentPassword.isEmpty {
                cmd = "MYSQL_PWD='\(currentPassword.replacingOccurrences(of: "'", with: "'\\''"))' " + cmd
            }
            cmd += " \(database)"

            if let selectedTables = tables, !selectedTables.isEmpty {
                cmd += " " + selectedTables.joined(separator: " ")
            }

            exportProgress = LS("db.exportRunning")
            let (code, output) = await sm.exec(cmd, timeout: 300)

            isExporting = false

            if code != 0 {
                exportProgress = "❌ " + output
                return
            }

            // Save to local downloads
            let timestamp = ISO8601DateFormatter().string(from: Date())
                .replacingOccurrences(of: ":", with: "-")
            let filename = "pier_dump_\(database)_\(timestamp).sql"
            guard let downloadsDir = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first else {
                exportProgress = "❌ Cannot find Downloads directory"
                return
            }
            let url = downloadsDir.appendingPathComponent(filename)

            do {
                try output.write(to: url, atomically: true, encoding: .utf8)
                exportProgress = "✅ \(LS("db.exportSaved")): \(filename)"
            } catch {
                exportProgress = "❌ \(LS("db.exportFailed")): \(error.localizedDescription)"
            }
        }
    }

    /// Import SQL file to remote server via SCP + remote mysql
    func importSQL(from localURL: URL, toDatabase database: String) {
        guard let sm = serviceManager, sm.isConnected else { return }
        isImporting = true
        importProgress = LS("db.importStarting")

        Task {
            // Step 1: Upload SQL file to remote /tmp via SCP
            let remoteFileName = "pier_import_\(UUID().uuidString.prefix(8)).sql"
            let remoteTmpPath = "/tmp/\(remoteFileName)"

            importProgress = LS("db.importUploading")
            let uploadResult = await sm.uploadFile(localPath: localURL.path, remotePath: remoteTmpPath)

            guard uploadResult.success else {
                isImporting = false
                importProgress = "❌ Upload failed: \(uploadResult.error ?? "Unknown")"
                return
            }

            // Step 2: Execute the uploaded SQL file on the remote server
            var cmd = "mysql -h \(currentHost) -P \(currentPort) -u \(currentUser)"
            if !currentPassword.isEmpty {
                cmd = "MYSQL_PWD='\(currentPassword.replacingOccurrences(of: "'", with: "'\\''"))' " + cmd
            }
            cmd += " -D \(database) < \(remoteTmpPath)"

            importProgress = LS("db.importRunning")
            let (code, output) = await sm.exec(cmd, timeout: 300)

            // Step 3: Clean up the temp file
            _ = await sm.exec("rm -f \(remoteTmpPath)", timeout: 10)

            isImporting = false

            if code != 0 {
                importProgress = "❌ \(output)"
            } else {
                importProgress = "✅ \(LS("db.importSuccess"))"
                // Refresh tables
                loadTables(database: database)
            }
        }
    }

    // MARK: - Saved Connections

    private func saveConnection() {
        let conn = MySQLConnection(
            name: "\(currentUser)@\(currentHost)",
            host: currentHost,
            port: currentPort,
            username: currentUser,
            database: currentDB
        )

        // Avoid duplicates
        if !savedConnections.contains(where: { $0.host == conn.host && $0.port == conn.port && $0.username == conn.username }) {
            savedConnections.append(conn)
            persistConnections()
        }
    }

    private func loadSavedConnections() {
        let path = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".pier/mysql_connections.json")
        guard let data = try? Data(contentsOf: path) else { return }
        savedConnections = (try? JSONDecoder().decode([MySQLConnection].self, from: data)) ?? []
    }

    private func persistConnections() {
        let dir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".pier")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let path = dir.appendingPathComponent("mysql_connections.json")
        if let data = try? JSONEncoder().encode(savedConnections) {
            try? data.write(to: path)
        }
    }

    // MARK: - Query History Persistence

    private static var historyURL: URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let dir = appSupport.appendingPathComponent("Pier", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("query_history.json")
    }

    private func loadHistory() {
        guard let data = try? Data(contentsOf: Self.historyURL),
              let entries = try? JSONDecoder().decode([QueryHistoryEntry].self, from: data) else { return }
        queryHistory = entries
    }

    private func saveHistory() {
        historySaveWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self = self else { return }
            guard let data = try? JSONEncoder().encode(self.queryHistory) else { return }
            try? data.write(to: Self.historyURL, options: .atomic)
        }
        historySaveWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 2, execute: work)
    }

    func clearHistory() {
        queryHistory.removeAll()
        saveHistory()
    }

    // MARK: - Data Export (local result set to CSV/JSON)

    /// Export current query results as CSV. Returns the file URL on success.
    func exportToCSV() -> URL? {
        guard !resultColumns.isEmpty else { return nil }

        let timestamp = ISO8601DateFormatter().string(from: Date())
            .replacingOccurrences(of: ":", with: "-")
        let filename = "pier_export_\(timestamp).csv"
        guard let downloadsDir = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first else { return nil }
        let url = downloadsDir.appendingPathComponent(filename)

        var csv = resultColumns.joined(separator: ",") + "\n"
        for row in resultRows {
            let escaped = row.map { field in
                let needsQuoting = field.contains(",") || field.contains("\"") || field.contains("\n")
                if needsQuoting {
                    return "\"" + field.replacingOccurrences(of: "\"", with: "\"\"") + "\""
                }
                return field
            }
            csv += escaped.joined(separator: ",") + "\n"
        }

        guard let data = csv.data(using: .utf8) else { return nil }
        try? data.write(to: url, options: .atomic)
        return url
    }

    /// Export current query results as JSON. Returns the file URL on success.
    func exportToJSON() -> URL? {
        guard !resultColumns.isEmpty else { return nil }

        let timestamp = ISO8601DateFormatter().string(from: Date())
            .replacingOccurrences(of: ":", with: "-")
        let filename = "pier_export_\(timestamp).json"
        guard let downloadsDir = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first else { return nil }
        let url = downloadsDir.appendingPathComponent(filename)

        let records: [[String: String]] = resultRows.map { row in
            var dict: [String: String] = [:]
            for (i, col) in resultColumns.enumerated() {
                dict[col] = i < row.count ? row[i] : ""
            }
            return dict
        }

        guard let data = try? JSONSerialization.data(
            withJSONObject: records,
            options: [.prettyPrinted, .sortedKeys]
        ) else { return nil }

        try? data.write(to: url, options: .atomic)
        return url
    }
}
