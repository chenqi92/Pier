import AppKit

/// Tokenizes and applies syntax highlighting to shell input.
struct ShellHighlighter {

    /// Token types for shell syntax.
    enum TokenKind {
        case command
        case argument
        case flag
        case string
        case pipe
        case redirect
        case comment
        case variable
        case number
        case unknown
    }

    /// A highlighted token with range and kind.
    struct Token {
        let text: String
        let kind: TokenKind
        let range: Range<String.Index>
    }

    /// Known shell built-in commands.
    private static let builtins: Set<String> = [
        "cd", "echo", "export", "alias", "unalias", "source", "eval",
        "exec", "exit", "set", "unset", "shift", "return", "break",
        "continue", "test", "true", "false", "read", "printf",
        "type", "hash", "wait", "trap", "bg", "fg", "jobs",
        "if", "then", "else", "elif", "fi", "for", "while", "do",
        "done", "case", "esac", "in", "function", "select", "until",
    ]

    /// Available commands (from PATH). Updated externally.
    var knownCommands: Set<String> = []

    // MARK: - Tokenize

    /// Tokenize a shell input line into colored tokens.
    func tokenize(_ input: String) -> [Token] {
        var tokens: [Token] = []
        var index = input.startIndex
        var isFirstWord = true

        while index < input.endIndex {
            let ch = input[index]

            // Skip whitespace
            if ch.isWhitespace {
                let start = index
                while index < input.endIndex && input[index].isWhitespace {
                    index = input.index(after: index)
                }
                tokens.append(Token(text: String(input[start..<index]), kind: .unknown, range: start..<index))
                continue
            }

            // Comment
            if ch == "#" {
                let start = index
                index = input.endIndex
                tokens.append(Token(text: String(input[start..<index]), kind: .comment, range: start..<index))
                continue
            }

            // Pipe or logical operators
            if ch == "|" || ch == "&" || ch == ";" {
                let start = index
                index = input.index(after: index)
                // Handle || or &&
                if index < input.endIndex && input[index] == ch {
                    index = input.index(after: index)
                }
                tokens.append(Token(text: String(input[start..<index]), kind: .pipe, range: start..<index))
                isFirstWord = true
                continue
            }

            // Redirect
            if ch == ">" || ch == "<" {
                let start = index
                index = input.index(after: index)
                if index < input.endIndex && input[index] == ch {
                    index = input.index(after: index)
                }
                tokens.append(Token(text: String(input[start..<index]), kind: .redirect, range: start..<index))
                continue
            }

            // Quoted string
            if ch == "\"" || ch == "'" {
                let quote = ch
                let start = index
                index = input.index(after: index)
                while index < input.endIndex && input[index] != quote {
                    if input[index] == "\\" && quote == "\"" {
                        index = input.index(after: index)
                        if index < input.endIndex {
                            index = input.index(after: index)
                        }
                    } else {
                        index = input.index(after: index)
                    }
                }
                if index < input.endIndex {
                    index = input.index(after: index) // consume closing quote
                }
                tokens.append(Token(text: String(input[start..<index]), kind: .string, range: start..<index))
                isFirstWord = false
                continue
            }

            // Variable ($VAR or ${VAR})
            if ch == "$" {
                let start = index
                index = input.index(after: index)
                if index < input.endIndex && input[index] == "{" {
                    while index < input.endIndex && input[index] != "}" {
                        index = input.index(after: index)
                    }
                    if index < input.endIndex {
                        index = input.index(after: index)
                    }
                } else {
                    while index < input.endIndex && (input[index].isLetter || input[index] == "_" || input[index].isNumber) {
                        index = input.index(after: index)
                    }
                }
                tokens.append(Token(text: String(input[start..<index]), kind: .variable, range: start..<index))
                isFirstWord = false
                continue
            }

            // Word (command, arg, flag)
            let start = index
            while index < input.endIndex && !input[index].isWhitespace &&
                  input[index] != "|" && input[index] != "&" && input[index] != ";" &&
                  input[index] != ">" && input[index] != "<" && input[index] != "#" {
                index = input.index(after: index)
            }

            let word = String(input[start..<index])

            if isFirstWord {
                tokens.append(Token(text: word, kind: .command, range: start..<index))
                isFirstWord = false
            } else if word.hasPrefix("-") {
                tokens.append(Token(text: word, kind: .flag, range: start..<index))
            } else if word.allSatisfy({ $0.isNumber || $0 == "." }) {
                tokens.append(Token(text: word, kind: .number, range: start..<index))
            } else {
                tokens.append(Token(text: word, kind: .argument, range: start..<index))
            }
        }

        return tokens
    }

    // MARK: - Colorize

    /// Convert tokens to an attributed string with colors.
    func highlight(_ input: String, theme: TerminalTheme? = nil) -> NSAttributedString {
        let tokens = tokenize(input)
        let result = NSMutableAttributedString()

        let font = NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)

        for token in tokens {
            let color = colorForToken(token.kind)
            let attrs: [NSAttributedString.Key: Any] = [
                .font: font,
                .foregroundColor: color,
            ]
            result.append(NSAttributedString(string: token.text, attributes: attrs))
        }

        return result
    }

    /// Map token kind to NSColor.
    func colorForToken(_ kind: TokenKind) -> NSColor {
        switch kind {
        case .command:   return NSColor.systemGreen
        case .argument:  return NSColor.textColor
        case .flag:      return NSColor.systemCyan
        case .string:    return NSColor.systemYellow
        case .pipe:      return NSColor.systemPurple
        case .redirect:  return NSColor.systemPurple
        case .comment:   return NSColor.systemGray
        case .variable:  return NSColor.systemOrange
        case .number:    return NSColor.systemBlue
        case .unknown:   return NSColor.textColor
        }
    }

    /// Check if a command is valid (exists in PATH or is a builtin).
    func isValidCommand(_ command: String) -> Bool {
        return Self.builtins.contains(command) || knownCommands.contains(command)
    }
}
