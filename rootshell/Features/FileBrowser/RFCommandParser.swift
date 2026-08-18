#if !targetEnvironment(macCatalyst)

import Foundation

/// Parse result for the rf command.
enum RFParseResult {
    case launch(path: String)
    case help
    case error(String)
}

/// Parses "rf [path] [flags]" command line arguments.
enum RFCommandParser {
    static func parse(command: String, workingDirectory: String) -> RFParseResult {
        let args = tokenize(command)

        // Skip the command name itself
        let flags = args.dropFirst()

        if flags.isEmpty {
            return .launch(path: workingDirectory)
        }

        for arg in flags {
            if arg == "--help" || arg == "-h" {
                return .help
            }
        }

        // First non-flag argument is the path
        if let pathArg = flags.first(where: { !$0.hasPrefix("-") }) {
            var path = pathArg

            // Expand ~ (use Documents directory — matches shell's $HOME and
            // BookmarkedLocationsManager symlinks for ~BookmarkName)
            if path.hasPrefix("~") {
                let home = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].path
                path = home + path.dropFirst()
            }

            // Resolve relative paths
            if !path.hasPrefix("/") {
                path = (workingDirectory as NSString).appendingPathComponent(path)
            }

            path = (path as NSString).standardizingPath

            var isDir: ObjCBool = false
            if FileManager.default.fileExists(atPath: path, isDirectory: &isDir) {
                if isDir.boolValue {
                    return .launch(path: path)
                } else {
                    // Path is a file — open its parent directory
                    let dir = (path as NSString).deletingLastPathComponent
                    return .launch(path: dir)
                }
            } else {
                return .error("no such file or directory: \(pathArg)")
            }
        }

        return .launch(path: workingDirectory)
    }

    /// Simple tokenizer that handles quoted strings.
    private static func tokenize(_ command: String) -> [String] {
        var tokens: [String] = []
        var current = ""
        var inQuote: Character? = nil

        for char in command {
            if let q = inQuote {
                if char == q {
                    inQuote = nil
                } else {
                    current.append(char)
                }
            } else if char == "\"" || char == "'" {
                inQuote = char
            } else if char == " " {
                if !current.isEmpty {
                    tokens.append(current)
                    current = ""
                }
            } else {
                current.append(char)
            }
        }
        if !current.isEmpty {
            tokens.append(current)
        }
        return tokens
    }
}

#endif
