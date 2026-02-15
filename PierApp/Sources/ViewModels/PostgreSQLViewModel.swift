import SwiftUI
import Combine

// MARK: - Data Models

struct PGDatabase: Identifiable {
    let name: String
    let owner: String
    let encoding: String
    var id: String { name }
}

struct PGTable: Identifiable {
    let schema: String
    let name: String
    let rowCount: Int
    let size: String

    var id: String { "\(schema).\(name)" }
    var fullName: String { "\(schema).\(name)" }
}

struct PGColumn: Identifiable {
    let name: String
    let dataType: String
    let isNullable: Bool
    let isPrimaryKey: Bool
    let defaultValue: String?
    let foreignKey: String?   // "referenced_table(column)" or nil

    var id: String { name }
}

struct PGQueryResult {
    let columns: [String]
    let rows: [[String]]
    let affectedRows: Int
    let executionTime: TimeInterval
}

// MARK: - ViewModel

@MainActor
class PostgreSQLViewModel: ObservableObject {
    @Published var isConnected = false
    @Published var isLoading = false
    @Published var databases: [PGDatabase] = []
    @Published var selectedDatabase: String = "postgres"
    @Published var tables: [PGTable] = []
    @Published var selectedTable: PGTable?
    @Published var columns: [PGColumn] = []
    @Published var queryText: String = ""
    @Published var queryResult: PGQueryResult?
    @Published var errorMessage: String?
    @Published var queryHistory: [String] = []

    var pgPort: UInt16 = 15432

    // MARK: - Connection

    func connect() {
        isLoading = true
        errorMessage = nil

        Task {
            let result = await runPSQL(["--command", "SELECT 1"])
            if result != nil {
                isConnected = true
                await loadDatabases()
                await loadTables()
            } else {
                errorMessage = String(localized: "pg.connectFailed")
            }
            isLoading = false
        }
    }

    func disconnect() {
        isConnected = false
        databases = []
        tables = []
        selectedTable = nil
        columns = []
        queryResult = nil
    }

    // MARK: - Database Operations

    func loadDatabases() async {
        guard let output = await runPSQL([
            "--command", "SELECT datname, pg_catalog.pg_get_userbyid(datdba), pg_encoding_to_char(encoding) FROM pg_database WHERE datistemplate = false ORDER BY datname",
            "--tuples-only", "--no-align", "--field-separator", "|"
        ]) else { return }

        databases = output.split(separator: "\n").compactMap { line in
            let parts = line.split(separator: "|", omittingEmptySubsequences: false).map(String.init)
            guard parts.count >= 3 else { return nil }
            return PGDatabase(name: parts[0].trimmingCharacters(in: .whitespaces),
                              owner: parts[1].trimmingCharacters(in: .whitespaces),
                              encoding: parts[2].trimmingCharacters(in: .whitespaces))
        }
    }

    func selectDatabase(_ name: String) {
        selectedDatabase = name
        Task {
            await loadTables()
        }
    }

    // MARK: - Table Operations

    func loadTables() async {
        guard let output = await runPSQL([
            "--dbname", selectedDatabase,
            "--command", """
            SELECT schemaname, tablename,
                   COALESCE(n_live_tup, 0)::text,
                   pg_size_pretty(pg_total_relation_size(schemaname||'.'||tablename))
            FROM pg_stat_user_tables ORDER BY schemaname, tablename
            """,
            "--tuples-only", "--no-align", "--field-separator", "|"
        ]) else { return }

        tables = output.split(separator: "\n").compactMap { line in
            let parts = line.split(separator: "|", omittingEmptySubsequences: false).map(String.init)
            guard parts.count >= 4 else { return nil }
            return PGTable(
                schema: parts[0].trimmingCharacters(in: .whitespaces),
                name: parts[1].trimmingCharacters(in: .whitespaces),
                rowCount: Int(parts[2].trimmingCharacters(in: .whitespaces)) ?? 0,
                size: parts[3].trimmingCharacters(in: .whitespaces)
            )
        }
    }

    /// Sanitize a SQL identifier to prevent injection. Allows only alphanumerics and underscores.
    private func sanitizeIdentifier(_ name: String) -> String {
        String(name.filter { $0.isLetter || $0.isNumber || $0 == "_" })
    }

    func loadColumns(for table: PGTable) async {
        let safeSchema = sanitizeIdentifier(table.schema)
        let safeName = sanitizeIdentifier(table.name)

        guard let output = await runPSQL([
            "--dbname", selectedDatabase,
            "--command", """
            SELECT c.column_name, c.data_type, c.is_nullable,
                   CASE WHEN tc.constraint_type = 'PRIMARY KEY' THEN 'YES' ELSE 'NO' END,
                   c.column_default,
                   CASE WHEN ccu.table_name IS NOT NULL
                        THEN ccu.table_name || '(' || ccu.column_name || ')'
                        ELSE '' END as fk_ref
            FROM information_schema.columns c
            LEFT JOIN information_schema.key_column_usage kcu
                ON c.table_name = kcu.table_name AND c.column_name = kcu.column_name
                AND c.table_schema = kcu.table_schema
            LEFT JOIN information_schema.table_constraints tc
                ON kcu.constraint_name = tc.constraint_name AND tc.constraint_type = 'PRIMARY KEY'
            LEFT JOIN information_schema.referential_constraints rc
                ON kcu.constraint_name = rc.constraint_name
            LEFT JOIN information_schema.constraint_column_usage ccu
                ON rc.unique_constraint_name = ccu.constraint_name
            WHERE c.table_schema = '\(safeSchema)' AND c.table_name = '\(safeName)'
            ORDER BY c.ordinal_position
            """,
            "--tuples-only", "--no-align", "--field-separator", "|"
        ]) else { return }

        columns = output.split(separator: "\n").compactMap { line in
            let parts = line.split(separator: "|", omittingEmptySubsequences: false).map(String.init)
            guard parts.count >= 4 else { return nil }
            return PGColumn(
                name: parts[0].trimmingCharacters(in: .whitespaces),
                dataType: parts[1].trimmingCharacters(in: .whitespaces),
                isNullable: parts[2].trimmingCharacters(in: .whitespaces) == "YES",
                isPrimaryKey: parts[3].trimmingCharacters(in: .whitespaces) == "YES",
                defaultValue: parts.count > 4 ? parts[4].trimmingCharacters(in: .whitespaces) : nil,
                foreignKey: parts.count > 5 && !parts[5].trimmingCharacters(in: .whitespaces).isEmpty
                    ? parts[5].trimmingCharacters(in: .whitespaces) : nil
            )
        }
    }

    func selectTable(_ table: PGTable) {
        selectedTable = table
        Task { await loadColumns(for: table) }
    }

    // MARK: - Query Execution

    func executeQuery() {
        let sql = queryText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !sql.isEmpty else { return }

        isLoading = true
        errorMessage = nil

        Task {
            let start = Date()
            guard let output = await runPSQL([
                "--dbname", selectedDatabase,
                "--command", sql,
                "--tuples-only", "--no-align", "--field-separator", "|",
                "--pset", "footer=off"
            ]) else {
                errorMessage = "Query failed"
                isLoading = false
                return
            }

            let elapsed = Date().timeIntervalSince(start)
            let lines = output.split(separator: "\n").map(String.init)

            // Get column names from a separate query
            var columnNames: [String] = []
            if let headerOutput = await runPSQL([
                "--dbname", selectedDatabase,
                "--command", sql,
                "--no-align", "--field-separator", "|",
                "--pset", "tuples_only=off", "--pset", "footer=off"
            ]) {
                if let firstLine = headerOutput.split(separator: "\n").first {
                    columnNames = firstLine.split(separator: "|").map {
                        $0.trimmingCharacters(in: .whitespaces)
                    }
                }
            }

            let rows = lines.map { line in
                line.split(separator: "|", omittingEmptySubsequences: false)
                    .map { $0.trimmingCharacters(in: .whitespaces) }
            }

            queryResult = PGQueryResult(
                columns: columnNames,
                rows: rows,
                affectedRows: rows.count,
                executionTime: elapsed
            )

            // Save to history
            if !queryHistory.contains(sql) {
                queryHistory.insert(sql, at: 0)
                if queryHistory.count > 50 { queryHistory.removeLast() }
            }

            isLoading = false
        }
    }

    // MARK: - Helpers

    private func runPSQL(_ args: [String]) async -> String? {
        let baseArgs = ["-h", "127.0.0.1", "-p", String(pgPort), "-U", "postgres"] + args
        let result = await CommandRunner.shared.run("psql", arguments: baseArgs)
        return result.succeeded ? result.output : nil
    }
}
