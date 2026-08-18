#if !targetEnvironment(macCatalyst)

import Foundation

/// Result of parsing a `hx` command line
enum HelixParseResult {
    /// Launch the editor with the given configuration
    case launch(HelixLaunchConfig)
    /// Print help text (handled by Swift)
    case help
    /// Print version (handled by Swift via helix_version FFI)
    case version
    /// Parse error
    case error(String)
}

/// Configuration for launching a Helix editor instance
struct HelixLaunchConfig {
    /// Raw tokenized args after "hx", passed as argc/argv to FFI.
    /// Includes "hx" as argv[0].
    var args: [String]

    /// Working directory for the editor
    var workingDirectory: String

    /// Compute a display title for the tab
    var displayTitle: String {
        // Look for the first positional arg (non-flag) to use as title
        var skipNext = false
        for arg in args.dropFirst() {
            if skipNext {
                skipNext = false
                continue
            }
            // Flags that consume a following argument
            if arg == "-c" || arg == "--config" || arg == "--log" ||
               arg == "-w" || arg == "--working-dir" ||
               arg == "-g" || arg == "--grammar" {
                skipNext = true
                continue
            }
            if arg == "--" { continue }
            if arg.hasPrefix("-") { continue }
            // This is a positional arg (file path or +N)
            if arg.hasPrefix("+") { continue }
            // It's a file path
            let name = (arg as NSString).lastPathComponent
            return String(name.prefix(30))
        }
        // Check for --tutor
        if args.contains("--tutor") {
            return "tutor"
        }
        return "[scratch]"
    }
}

/// Parses `hx [flags] [file]` command lines
enum HelixCommandParser {
    static func parse(command: String, workingDirectory: String? = nil) -> HelixParseResult {
        let tokens = tokenize(command)

        guard !tokens.isEmpty else {
            return .error("empty command")
        }

        let args = Array(tokens.dropFirst())
        let cwd = workingDirectory ?? FileManager.default.currentDirectoryPath

        // Pre-scan tokens for flags that Swift handles directly
        // (print-and-exit flags that should never reach Rust)
        var i = 0
        while i < args.count {
            let arg = args[i]
            switch arg {
            case "-h", "--help":
                return .help
            case "-V", "--version":
                return .version
            case "-g", "--grammar":
                // Pass through to Rust which handles fetch/build/list
                var grammarArgs = ["hx", arg]
                if i + 1 < args.count {
                    grammarArgs.append(args[i + 1])
                }
                return .launch(HelixLaunchConfig(args: grammarArgs, workingDirectory: cwd))
            case "--health":
                // Pass through to Rust which runs the full health check
                var healthArgs = ["hx", "--health"]
                if i + 1 < args.count && !args[i + 1].hasPrefix("-") {
                    healthArgs.append(args[i + 1])
                }
                return .launch(HelixLaunchConfig(args: healthArgs, workingDirectory: cwd))
            default:
                break
            }
            // Check for short arg combos containing h or V (e.g. -vVh)
            if arg.hasPrefix("-") && !arg.hasPrefix("--") && arg.count > 1 {
                let flags = arg.dropFirst()
                if flags.contains("h") {
                    return .help
                }
                if flags.contains("V") {
                    return .version
                }
            }
            i += 1
        }

        // Build the full argv for Rust. Resolve relative file paths to absolute.
        var rustArgs: [String] = ["hx"]
        var skipNextArg = false
        for (idx, arg) in args.enumerated() {
            if skipNextArg {
                skipNextArg = false
                // The previous flag consumed this arg — pass it through as-is
                // (except for -c/--config and --log which might be relative paths)
                if idx > 0 {
                    let prev = args[idx - 1]
                    if prev == "-c" || prev == "--config" || prev == "--log" ||
                       prev == "-w" || prev == "--working-dir" {
                        // Resolve relative/tilde paths for config/log/working-dir
                        let expanded = expandTilde(arg)
                        if !expanded.hasPrefix("/") {
                            rustArgs.append((cwd as NSString).appendingPathComponent(expanded))
                            continue
                        }
                        rustArgs.append(expanded)
                        continue
                    }
                }
                rustArgs.append(arg)
                continue
            }

            // Flags that consume the next argument
            if arg == "-c" || arg == "--config" || arg == "--log" ||
               arg == "-w" || arg == "--working-dir" ||
               arg == "-g" || arg == "--grammar" {
                rustArgs.append(arg)
                skipNextArg = true
                continue
            }

            // Pass through all flags
            if arg.hasPrefix("-") || arg.hasPrefix("+") || arg == "--" {
                rustArgs.append(arg)
                continue
            }

            // Positional argument (file path) — expand ~ and resolve relative paths
            var filePath = expandTilde(arg)
            if !filePath.hasPrefix("/") {
                filePath = (cwd as NSString).appendingPathComponent(filePath)
            }
            rustArgs.append(filePath)
        }

        // Inject -w if not explicitly provided, so the Rust FFI sets CWD
        // correctly for the file picker. Without this, Helix uses a stale
        // process-global CWD cached from the first launch.
        if !rustArgs.contains("-w") && !rustArgs.contains("--working-dir") {
            // Find the first positional arg (non-flag, non-+N) to check if it's a directory
            var firstPositional: String?
            var skip = false
            for rustArg in rustArgs.dropFirst() {
                if skip { skip = false; continue }
                if rustArg == "-c" || rustArg == "--config" || rustArg == "--log" ||
                   rustArg == "-g" || rustArg == "--grammar" {
                    skip = true
                    continue
                }
                if rustArg.hasPrefix("-") || rustArg.hasPrefix("+") || rustArg == "--" { continue }
                firstPositional = rustArg
                break
            }

            let workDir: String
            if let pos = firstPositional {
                var isDir: ObjCBool = false
                if FileManager.default.fileExists(atPath: pos, isDirectory: &isDir), isDir.boolValue {
                    workDir = pos
                } else {
                    workDir = cwd
                }
            } else {
                workDir = cwd
            }

            rustArgs.insert(workDir, at: 1)
            rustArgs.insert("-w", at: 1)
        }

        return .launch(HelixLaunchConfig(
            args: rustArgs,
            workingDirectory: cwd
        ))
    }

    /// Expand leading `~` to the user's home directory (Documents on iOS)
    private static func expandTilde(_ path: String) -> String {
        guard path.hasPrefix("~/") || path == "~" else { return path }
        let home = ProcessInfo.processInfo.environment["HOME"] ?? NSHomeDirectory()
        return home + path.dropFirst()
    }

    /// Simple tokenizer that handles basic quoting
    private static func tokenize(_ input: String) -> [String] {
        var tokens: [String] = []
        var current = ""
        var inSingle = false
        var inDouble = false
        var escaped = false

        for char in input {
            if escaped {
                current.append(char)
                escaped = false
                continue
            }

            if char == "\\" && !inSingle {
                escaped = true
                continue
            }

            if char == "'" && !inDouble {
                inSingle.toggle()
                continue
            }

            if char == "\"" && !inSingle {
                inDouble.toggle()
                continue
            }

            if char == " " && !inSingle && !inDouble {
                if !current.isEmpty {
                    tokens.append(current)
                    current = ""
                }
                continue
            }

            current.append(char)
        }

        if !current.isEmpty {
            tokens.append(current)
        }

        return tokens
    }
}

#endif // !targetEnvironment(macCatalyst)
