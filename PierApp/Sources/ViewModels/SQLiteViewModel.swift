import SwiftUI
import Combine

// MARK: - Data Models

struct SQLiteTable: Identifiable {
    let name: String
    let type: String  // "table" or "view"
    let rowCount: Int

    var id: String { name }
}

struct SQLiteColumn: Identifiable {
    let cid: Int
    let name: String
    let type: String
    let notNull: Bool
    let primaryKey: Bool
    let defaultValue: String?

    var id: Int { cid }
}

struct SQLiteQueryResult {
    let columns: [String]
    let rows: [[String]]
    let affectedRows: Int
    let executionTime: TimeInterval
}

// MARK: - ViewModel

@MainActor
class SQLiteViewModel: ObservableObject {
    @Published var isConnected = false
    @Published var isLoading = false
    @Published var filePath: String = ""
    @Published var tables: [SQLiteTable] = []
    @Published var selectedTable: SQLiteTable?
    @Published var columns: [SQLiteColumn] = []
    @Published var queryText: String = ""
    @Published var queryResult: SQLiteQueryResult?
    @Published var errorMessage: String?
    @Published var queryHistory: [String] = []

    // MARK: - Open Database

    func openDatabase(path: String) {
        filePath = path
        isLoading = true
        errorMessage = nil

        Task {
            // Verify file exists and is valid SQLite
            let result = await runSQLite(["SELECT sqlite_version()"])
            if result != nil {
                isConnected = true
                await loadTables()
            } else {
                errorMessage = String(localized: "sqlite.openFailed")
            }
            isLoading = false
        }
    }

    func closeDatabase() {
        isConnected = false
        filePath = ""
        tables = []
        selectedTable = nil
        columns = []
        queryResult = nil
    }

    // MARK: - Browse File

    func browseFile() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.database, .data]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.message = String(localized: "sqlite.selectFile")

        if panel.runModal() == .OK, let url = panel.url {
            openDatabase(path: url.path)
        }
    }

    // MARK: - Table Operations

    func loadTables() async {
        guard let output = await runSQLite([
            "SELECT name, type FROM sqlite_master WHERE type IN ('table','view') AND name NOT LIKE 'sqlite_%' ORDER BY name"
        ]) else { return }

        var loadedTables: [SQLiteTable] = []
        for line in output.split(separator: "\n") {
            let parts = line.split(separator: "|", omittingEmptySubsequences: false).map(String.init)
            guard parts.count >= 2 else { continue }
            let name = parts[0].trimmingCharacters(in: .whitespaces)
            let type = parts[1].trimmingCharacters(in: .whitespaces)

            // Get row count
            let countStr = await runSQLite(["SELECT COUNT(*) FROM \"\(name)\""])
            let count = Int(countStr?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "0") ?? 0

            loadedTables.append(SQLiteTable(name: name, type: type, rowCount: count))
        }

        tables = loadedTables
    }

    func loadColumns(for table: SQLiteTable) async {
        guard let output = await runSQLite(["PRAGMA table_info(\"\(table.name)\")"]) else { return }

        columns = output.split(separator: "\n").compactMap { line in
            let parts = line.split(separator: "|", omittingEmptySubsequences: false).map(String.init)
            guard parts.count >= 6 else { return nil }
            return SQLiteColumn(
                cid: Int(parts[0]) ?? 0,
                name: parts[1].trimmingCharacters(in: .whitespaces),
                type: parts[2].trimmingCharacters(in: .whitespaces),
                notNull: parts[3].trimmingCharacters(in: .whitespaces) == "1",
                primaryKey: parts[5].trimmingCharacters(in: .whitespaces) == "1",
                defaultValue: parts[4].trimmingCharacters(in: .whitespaces).isEmpty ? nil : parts[4].trimmingCharacters(in: .whitespaces)
            )
        }
    }

    func selectTable(_ table: SQLiteTable) {
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

            // Get header
            guard let headerOutput = await runSQLite(["-header", sql]) else {
                errorMessage = "Query failed"
                isLoading = false
                return
            }

            let elapsed = Date().timeIntervalSince(start)
            let lines = headerOutput.split(separator: "\n").map(String.init)

            var columnNames: [String] = []
            var rows: [[String]] = []

            if let first = lines.first {
                columnNames = first.split(separator: "|").map { $0.trimmingCharacters(in: .whitespaces) }
            }

            for line in lines.dropFirst() {
                let cells = line.split(separator: "|", omittingEmptySubsequences: false)
                    .map { $0.trimmingCharacters(in: .whitespaces) }
                rows.append(cells)
            }

            queryResult = SQLiteQueryResult(
                columns: columnNames,
                rows: rows,
                affectedRows: rows.count,
                executionTime: elapsed
            )

            if !queryHistory.contains(sql) {
                queryHistory.insert(sql, at: 0)
                if queryHistory.count > 50 { queryHistory.removeLast() }
            }

            isLoading = false
        }
    }

    // MARK: - Helpers

    private func runSQLite(_ args: [String]) async -> String? {
        guard !filePath.isEmpty else { return nil }
        let baseArgs = [filePath, "-separator", "|"] + args
        let result = await CommandRunner.shared.run("sqlite3", arguments: baseArgs)
        return result.succeeded ? result.output : nil
    }
}
