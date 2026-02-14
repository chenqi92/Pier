import AppKit

/// SQL syntax highlighter for query editors.
struct SQLHighlighter {

    /// SQL token types.
    enum TokenKind {
        case keyword
        case function
        case string
        case number
        case comment
        case identifier
        case operator_
        case whitespace
    }

    /// SQL keywords (uppercase canonical).
    private static let keywords: Set<String> = [
        "SELECT", "FROM", "WHERE", "AND", "OR", "NOT", "IN", "EXISTS",
        "INSERT", "INTO", "VALUES", "UPDATE", "SET", "DELETE",
        "CREATE", "ALTER", "DROP", "TABLE", "INDEX", "VIEW",
        "JOIN", "INNER", "LEFT", "RIGHT", "OUTER", "CROSS", "ON",
        "GROUP", "BY", "ORDER", "ASC", "DESC", "HAVING",
        "LIMIT", "OFFSET", "DISTINCT", "AS", "CASE", "WHEN", "THEN",
        "ELSE", "END", "NULL", "IS", "LIKE", "BETWEEN",
        "UNION", "ALL", "INTERSECT", "EXCEPT",
        "BEGIN", "COMMIT", "ROLLBACK", "TRANSACTION",
        "PRIMARY", "KEY", "FOREIGN", "REFERENCES", "CONSTRAINT",
        "DEFAULT", "CHECK", "UNIQUE", "CASCADE",
        "IF", "REPLACE", "EXPLAIN", "ANALYZE", "PRAGMA",
        "SCHEMA", "DATABASE", "USE", "SHOW", "DESCRIBE",
        "TRUE", "FALSE", "WITH", "RECURSIVE",
    ]

    /// SQL built-in functions.
    private static let functions: Set<String> = [
        "COUNT", "SUM", "AVG", "MIN", "MAX",
        "COALESCE", "NULLIF", "CAST", "CONVERT",
        "UPPER", "LOWER", "LENGTH", "SUBSTRING", "TRIM",
        "CONCAT", "REPLACE", "ROUND", "ABS", "CEIL", "FLOOR",
        "NOW", "DATE", "TIME", "DATETIME", "STRFTIME",
        "IFNULL", "IIF", "TYPEOF", "TOTAL",
        "GROUP_CONCAT", "JSON", "JSON_EXTRACT",
        "PG_SIZE_PRETTY", "PG_TOTAL_RELATION_SIZE",
        "ROW_NUMBER", "RANK", "DENSE_RANK", "LAG", "LEAD",
    ]

    /// Highlight SQL text to attributed string.
    func highlight(_ input: String) -> NSAttributedString {
        let result = NSMutableAttributedString()
        let font = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)

        var index = input.startIndex

        while index < input.endIndex {
            let ch = input[index]

            // Whitespace
            if ch.isWhitespace {
                let start = index
                while index < input.endIndex && input[index].isWhitespace {
                    index = input.index(after: index)
                }
                result.append(NSAttributedString(
                    string: String(input[start..<index]),
                    attributes: [.font: font, .foregroundColor: NSColor.textColor]
                ))
                continue
            }

            // Single-line comment --
            if ch == "-" && index < input.index(before: input.endIndex) &&
               input[input.index(after: index)] == "-" {
                let start = index
                while index < input.endIndex && input[index] != "\n" {
                    index = input.index(after: index)
                }
                result.append(NSAttributedString(
                    string: String(input[start..<index]),
                    attributes: [.font: font, .foregroundColor: NSColor.systemGray]
                ))
                continue
            }

            // Block comment /* ... */
            if ch == "/" && index < input.index(before: input.endIndex) &&
               input[input.index(after: index)] == "*" {
                let start = index
                index = input.index(index, offsetBy: 2)
                while index < input.endIndex {
                    if input[index] == "*" && input.index(after: index) < input.endIndex &&
                       input[input.index(after: index)] == "/" {
                        index = input.index(index, offsetBy: 2)
                        break
                    }
                    index = input.index(after: index)
                }
                result.append(NSAttributedString(
                    string: String(input[start..<index]),
                    attributes: [.font: font, .foregroundColor: NSColor.systemGray]
                ))
                continue
            }

            // String literal
            if ch == "'" || ch == "\"" {
                let quote = ch
                let start = index
                index = input.index(after: index)
                while index < input.endIndex && input[index] != quote {
                    if input[index] == "\\" {
                        index = input.index(after: index)
                    }
                    if index < input.endIndex {
                        index = input.index(after: index)
                    }
                }
                if index < input.endIndex {
                    index = input.index(after: index)
                }
                result.append(NSAttributedString(
                    string: String(input[start..<index]),
                    attributes: [.font: font, .foregroundColor: NSColor.systemYellow]
                ))
                continue
            }

            // Number
            if ch.isNumber || (ch == "." && index < input.index(before: input.endIndex) && input[input.index(after: index)].isNumber) {
                let start = index
                while index < input.endIndex && (input[index].isNumber || input[index] == ".") {
                    index = input.index(after: index)
                }
                result.append(NSAttributedString(
                    string: String(input[start..<index]),
                    attributes: [.font: font, .foregroundColor: NSColor.systemCyan]
                ))
                continue
            }

            // Word (keyword, function, identifier)
            if ch.isLetter || ch == "_" {
                let start = index
                while index < input.endIndex && (input[index].isLetter || input[index].isNumber || input[index] == "_") {
                    index = input.index(after: index)
                }
                let word = String(input[start..<index])
                let upper = word.uppercased()

                let color: NSColor
                if Self.keywords.contains(upper) {
                    color = .systemBlue
                } else if Self.functions.contains(upper) {
                    color = .systemPurple
                } else {
                    color = .textColor
                }
                result.append(NSAttributedString(
                    string: word,
                    attributes: [.font: font, .foregroundColor: color]
                ))
                continue
            }

            // Operators and other characters
            let start = index
            index = input.index(after: index)
            let opColor: NSColor = (ch == "(" || ch == ")" || ch == "," || ch == ";")
                ? .secondaryLabelColor : .systemPurple
            result.append(NSAttributedString(
                string: String(input[start..<index]),
                attributes: [.font: font, .foregroundColor: opColor]
            ))
        }

        return result
    }
}
