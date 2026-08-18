#if !targetEnvironment(macCatalyst)

import Foundation

/// CLI argument parser for the croc command.
/// Parses: `croc send [flags] [files]`, `croc [code]`, `croc relay [flags]`
nonisolated enum CrocCommandParser {

    enum ParseResult {
        case send(CrocOptions, paths: [String])
        case receive(CrocOptions)
        case relay(CrocOptions)
        case print(String, exitCode: Int32)
        case help
        case error(String)
    }

    /// Parse a croc command string.
    /// Global flags may appear before the subcommand, e.g.:
    /// `croc --relay 1.2.3.4:9009 send file.txt`
    static func parse(command: String) -> ParseResult {
        let tokens = tokenize(command)
        guard !tokens.isEmpty else { return .help }

        // Skip the "croc" command name
        let args = Array(tokens.dropFirst())
        if args.isEmpty { return .help }

        // Consume global flags that appear before the subcommand.
        // This allows `croc --relay addr send file.txt` to work correctly.
        var globalOptions = CrocOptions()
        var subcommandIndex: Int?
        var i = 0
        while i < args.count {
            let arg = args[i]
            if arg == "send" || arg == "relay" || arg == "help" {
                subcommandIndex = i
                break
            }
            if arg == "-h" || arg == "--help" { return .help }
            if arg == "--version" || arg == "-v" {
                let appVersion = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "unknown"
                let buildNumber = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "unknown"
                return .print("🐊 rootshell croc \(appVersion) (\(buildNumber)) (compatible with croc \(CrocConstants.version))\n", exitCode: 0)
            }
            // Try to consume as a global flag
            if arg.hasPrefix("-") {
                if applyGlobalFlag(arg, args: args, index: &i, options: &globalOptions) {
                    i += 1
                    continue
                }
            }
            // Not a flag and not a subcommand — must be a code phrase (receive)
            break
        }

        let remaining = Array(args[i...])

        if let idx = subcommandIndex {
            let afterSubcmd = Array(args[(idx + 1)...])
            switch args[idx] {
            case "send":
                return parseSend(afterSubcmd, globalOptions: globalOptions)
            case "relay":
                return parseRelay(afterSubcmd, globalOptions: globalOptions)
            case "help":
                return .help
            default:
                break
            }
        }

        // No subcommand found — treat remaining as receive
        return parseReceive(remaining, globalOptions: globalOptions)
    }

    // MARK: - Send

    private static func parseSend(_ args: [String], globalOptions: CrocOptions = CrocOptions()) -> ParseResult {
        var options = globalOptions
        options.isSender = true
        var paths: [String] = []
        var i = 0

        while i < args.count {
            let arg = args[i]
            switch arg {
            case "-h", "--help":
                return .help
            case "--zip":
                options.zipFolder = true
            case "-c", "--code":
                guard i + 1 < args.count else { return .error("--code requires a value") }
                i += 1
                options.sharedSecret = args[i]
            case "--hash":
                guard i + 1 < args.count else { return .error("--hash requires a value") }
                i += 1
                options.hashAlgorithm = args[i].lowercased()
            case "-t", "--text":
                guard i + 1 < args.count else { return .error("--text requires a value") }
                i += 1
                options.text = args[i]
                options.sendingText = true
            case "--git":
                options.gitIgnore = true
            case "--port":
                guard i + 1 < args.count, let port = Int(args[i + 1]) else { return .error("--port requires a number") }
                i += 1
                options.port = port
            case "--transfers":
                guard i + 1 < args.count, let t = Int(args[i + 1]) else { return .error("--transfers requires a number") }
                i += 1
                options.transfers = t
            case "--exclude":
                guard i + 1 < args.count else { return .error("--exclude requires a value") }
                i += 1
                options.exclude.append(contentsOf: args[i].components(separatedBy: ","))
            case "--socks5":
                guard i + 1 < args.count else { return .error("--socks5 requires a value") }
                i += 1
                options.socks5Proxy = args[i]
            case "--connect":
                guard i + 1 < args.count else { return .error("--connect requires a value") }
                i += 1
                options.httpProxy = args[i]
            case "--throttleUpload":
                guard i + 1 < args.count else { return .error("--throttleUpload requires a value") }
                i += 1
                options.throttleUpload = args[i]
            default:
                // Apply global flags
                if applyGlobalFlag(arg, args: args, index: &i, options: &options) {
                    break
                }
                // Treat as file path
                paths.append(arg)
            }
            i += 1
        }

        // Handle text mode
        if options.sendingText {
            return .send(options, paths: [])
        }

        if paths.isEmpty {
            return .error("croc send: no files specified")
        }

        return .send(options, paths: paths)
    }

    // MARK: - Receive

    private static func parseReceive(_ args: [String], globalOptions: CrocOptions = CrocOptions()) -> ParseResult {
        var options = globalOptions
        options.isSender = false
        var codeWords: [String] = []
        var i = 0

        while i < args.count {
            let arg = args[i]

            // Check for flags
            if arg.hasPrefix("-") {
                if applyGlobalFlag(arg, args: args, index: &i, options: &options) {
                    i += 1
                    continue
                }
                return .error("unknown flag: \(arg)")
            }

            // Collect code phrase words
            codeWords.append(arg)
            i += 1
        }

        if codeWords.isEmpty {
            return .help
        }

        // Code can be 1 word (full phrase) or multiple words (space-separated)
        options.sharedSecret = codeWords.joined(separator: "-")

        return .receive(options)
    }

    // MARK: - Relay

    private static func parseRelay(_ args: [String], globalOptions: CrocOptions = CrocOptions()) -> ParseResult {
        var options = globalOptions
        var i = 0

        while i < args.count {
            let arg = args[i]
            switch arg {
            case "-h", "--help":
                return .print(relayHelpText, exitCode: 0)
            case "--host":
                guard i + 1 < args.count else { return .error("--host requires a value") }
                i += 1
                options.relayAddress = args[i]
            case "--ports":
                guard i + 1 < args.count else { return .error("--ports requires a value") }
                i += 1
                options.relayPorts = args[i].components(separatedBy: ",")
            case "--port":
                guard i + 1 < args.count, let port = Int(args[i + 1]) else { return .error("--port requires a number") }
                i += 1
                options.port = port
            case "--transfers":
                guard i + 1 < args.count, let t = Int(args[i + 1]) else { return .error("--transfers requires a number") }
                i += 1
                options.transfers = t
            default:
                if !applyGlobalFlag(arg, args: args, index: &i, options: &options) {
                    return .error("unknown relay flag: \(arg)")
                }
            }
            i += 1
        }

        return .relay(options)
    }

    // MARK: - Global Flags

    @discardableResult
    private static func applyGlobalFlag(_ flag: String, args: [String], index: inout Int, options: inout CrocOptions) -> Bool {
        switch flag {
        case "--internal-dns":
            options.internalDNS = true
        case "--debug":
            options.debug = true
        case "--yes":
            options.noPrompt = true
        case "--stdout":
            options.stdout = true
        case "--no-compress":
            options.noCompress = true
        case "--no-local":
            options.disableLocal = true
        case "--no-multi":
            options.noMultiplexing = true
        case "--ask":
            options.ask = true
        case "--local":
            options.onlyLocal = true
        case "--ignore-stdin":
            options.ignoreStdin = true
        case "--overwrite":
            options.overwrite = true
        case "--qrcode", "--qr":
            options.showQrCode = true
        case "--quiet":
            options.quiet = true
        case "--disable-clipboard":
            options.disableClipboard = true
        case "--extended-clipboard":
            options.extendedClipboard = true
        case "--multicast":
            guard index + 1 < args.count else { return false }
            index += 1
            options.multicastAddress = args[index]
        case "--curve":
            guard index + 1 < args.count else { return false }
            index += 1
            options.curve = args[index]
        case "--hash":
            guard index + 1 < args.count else { return false }
            index += 1
            options.hashAlgorithm = args[index].lowercased()
        case "--ip":
            guard index + 1 < args.count else { return false }
            index += 1
            options.ip = args[index]
        case "--relay":
            guard index + 1 < args.count else { return false }
            index += 1
            options.relayAddress = args[index]
        case "--relay6":
            guard index + 1 < args.count else { return false }
            index += 1
            options.relayAddress6 = args[index]
        case "--out":
            guard index + 1 < args.count else { return false }
            index += 1
            options.outputFolder = args[index]
        case "--pass":
            guard index + 1 < args.count else { return false }
            index += 1
            options.relayPassword = args[index]
        case "--throttleUpload":
            guard index + 1 < args.count else { return false }
            index += 1
            options.throttleUpload = args[index]
        default:
            return false
        }
        return true
    }

    // MARK: - Tokenizer

    /// Split a command string into tokens, respecting quotes.
    private static func tokenize(_ command: String) -> [String] {
        var tokens: [String] = []
        var current = ""
        var inSingleQuote = false
        var inDoubleQuote = false
        var escaped = false

        for char in command {
            if escaped {
                current.append(char)
                escaped = false
                continue
            }
            if char == "\\" && !inSingleQuote {
                escaped = true
                continue
            }
            if char == "'" && !inDoubleQuote {
                inSingleQuote.toggle()
                continue
            }
            if char == "\"" && !inSingleQuote {
                inDoubleQuote.toggle()
                continue
            }
            if char == " " && !inSingleQuote && !inDoubleQuote {
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

    // MARK: - Help Text

    static let helpText = """
    🐊 usage: croc [flags] <command>

    Commands:
      croc send [flags] <file(s)/folder>    Send file(s) or folder
      croc [flags] <code>                   Receive using code phrase
      croc relay [flags]                    Start relay server

    Send flags:
      -c, --code <code>   Custom code phrase
      --hash <algo>       Hash algorithm (xxhash, md5, imohash, highway)
      -t, --text <text>   Send text instead of files
      --zip               Zip folder before sending
      --no-local          Disable local relay
      --no-multi          Disable multiplexing
      --git               Respect .gitignore
      --qrcode            Show QR code
      --exclude <list>    Exclude files (comma-separated)
      --throttleUpload    Throttle speed (e.g., 500k)

    Global flags:
      --relay <addr>      Relay address
      --pass <pass>       Relay password
      --curve <curve>     PAKE curve (p256, p384, p521, siec, ed25519)
      --yes               Auto-accept prompts
      --no-compress       Disable compression
      --no-local          Disable local relay
      --no-multi          Disable multiplexing
      --out <dir>         Output directory (receive)
      --overwrite         Skip overwrite prompts
      --debug             Debug logging
      --quiet             Suppress output
      --local             Force local-only
      --ip <addr>         Sender IP if known

    """

    static let relayHelpText = """
    usage: croc relay [flags]

    Relay flags:
      --host <addr>       Host to bind (default 0.0.0.0)
      --port <port>       Base relay port
      --ports <list>      Explicit relay ports (comma-separated)
      --transfers <n>     Number of transfer ports
      --pass <pass>       Relay password
      --debug             Debug logging
      --help              Show relay help

    """
}

#endif
