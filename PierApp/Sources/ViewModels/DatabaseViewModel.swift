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

    // Internal
    private var currentHost = ""
    private var currentPort = 3306
    private var currentUser = ""
    private var currentPassword = ""
    private var currentDB = ""

    init() {
        loadSavedConnections()
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

        Task {
            let start = Date()
            let result = await executeMysql(queryText, db: currentDB)
            let elapsed = Date().timeIntervalSince(start)

            isExecuting = false
            lastQueryTime = elapsed

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
            }
        }
    }

    // MARK: - MySQL CLI Execution

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
        let h = host ?? currentHost
        let p = port ?? currentPort
        let u = user ?? currentUser
        let pw = password ?? currentPassword
        let d = db ?? currentDB

        var args = [
            "-h", h,
            "-P", String(p),
            "-u", u,
            "--batch",       // Tab-separated output
            "--raw",         // Raw output (no escaping)
            "-e", query
        ]

        if !d.isEmpty {
            args.append(contentsOf: ["-D", d])
        }

        // Pass password via environment variable (not CLI arg) to prevent
        // exposure via `ps aux`. MYSQL_PWD is the standard env var for this.
        var env: [String: String]? = nil
        if !pw.isEmpty {
            env = ["MYSQL_PWD": pw]
        }

        let result = await CommandRunner.shared.run(
            "mysql",
            arguments: args,
            environment: env
        )

        if !result.succeeded {
            let errorMsg = result.stderr.isEmpty ? "Unknown error" : result.stderr
            return QueryResult(columns: [], rows: [], error: errorMsg)
        }

        return parseTSV(result.stdout)
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
}
