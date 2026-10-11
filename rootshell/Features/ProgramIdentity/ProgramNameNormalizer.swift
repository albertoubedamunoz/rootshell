//
//  ProgramNameNormalizer.swift
//  rootshell
//
//  Reduces a process name and its arguments to the program the user would
//  name: `-zsh` is zsh, `/usr/bin/htop` is htop, `sudo -u root htop` is
//  htop, `python3.12` is python.
//

import Foundation

nonisolated enum ProgramNameNormalizer {
    /// Launchers that run another program. The value lists the options that
    /// consume the next argument.
    private static let wrappers: [String: Set<String>] = [
        "sudo": ["-u", "-g", "-h", "-p", "-C", "-D", "-R", "-T", "-U", "-r", "-t"],
        "doas": ["-u", "-C"],
        "env": ["-u", "-C", "-S", "-P"],
        "nice": ["-n"],
        "nohup": [],
        "time": ["-o", "-f"],
        "exec": ["-a"],
        "command": [],
        "caffeinate": ["-t", "-w"],
    ]

    /// Interpreters whose versioned binaries (`python3.12`) share one identity.
    private static let versionedInterpreters = ["python", "ruby", "perl", "php", "lua", "pip", "node"]

    /// `arguments` is the full argv including argv0; empty when the source
    /// only knows the name.
    static func normalize(name: String, arguments: [String] = []) -> String? {
        var tokens = arguments.isEmpty ? [name] : arguments
        // `FOO=1 make` from a shell's command line.
        if let first = tokens.firstIndex(where: { !isAssignment($0) }), first > 0 {
            tokens = Array(tokens[first...])
        }
        var index = 0
        while index < tokens.count {
            let base = basename(tokens[index])
            guard let valueOptions = wrappers[base], index + 1 < tokens.count else { break }
            // `command -v x` and `env` alone print rather than run.
            if base == "command", tokens[index + 1].hasPrefix("-v") || tokens[index + 1].hasPrefix("-V") { break }
            var next = index + 1
            while next < tokens.count {
                let token = tokens[next]
                if token == "--" { next += 1; break }
                if valueOptions.contains(token) { next += 2; continue }
                if token.hasPrefix("-") || (base == "env" && token.contains("=")) {
                    next += 1
                    continue
                }
                break
            }
            guard next < tokens.count else { break }
            tokens = Array(tokens[next...])
            index = 0
        }
        let result = collapseVersion(basename(tokens.first ?? name))
        return result.isEmpty ? nil : result
    }

    /// Splits a shell command line into words for `normalize`. Quoting is
    /// ignored: only the leading words matter and they are rarely quoted.
    static func words(of commandLine: String) -> [String] {
        commandLine.split(whereSeparator: \.isWhitespace).map(String.init)
    }

    private static func isAssignment(_ token: String) -> Bool {
        guard let equals = token.firstIndex(of: "="), equals != token.startIndex else { return false }
        let key = token[..<equals]
        return key.first.map { $0.isLetter || $0 == "_" } == true
            && key.allSatisfy { $0.isLetter || $0.isNumber || $0 == "_" }
    }

    private static func basename(_ token: String) -> String {
        var name = token.trimmingCharacters(in: .whitespacesAndNewlines)
        // Login shells run as `-zsh`.
        while name.hasPrefix("-") { name.removeFirst() }
        if let slash = name.lastIndex(of: "/") {
            name = String(name[name.index(after: slash)...])
        }
        return name
    }

    private static func collapseVersion(_ name: String) -> String {
        // macOS framework builds re-exec `python3` as `Python.app/Contents/MacOS/Python`.
        if name == "Python" { return "python" }
        // Versioned binaries the unversioned name links to: `emacs-31.1`, `gcc-14`.
        if let dash = name.lastIndex(of: "-"), dash != name.startIndex {
            let version = name[name.index(after: dash)...]
            if version.first?.isNumber == true, version.allSatisfy({ $0.isNumber || $0 == "." }) {
                return String(name[..<dash])
            }
        }
        for interpreter in versionedInterpreters where name.hasPrefix(interpreter) {
            let suffix = name.dropFirst(interpreter.count)
            if suffix.allSatisfy({ $0.isNumber || $0 == "." }) { return interpreter }
        }
        return name
    }
}
