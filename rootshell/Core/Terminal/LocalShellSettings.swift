//
//  LocalShellSettings.swift
//
//  The command launched for local shell tabs.
//

import Foundation

/// Resolves the shell command for local sessions.
///
/// A configured value is a whole command line, not just a path: the helper
/// interpolates it into `exec -l <value>` inside `bash -c`, so bash parses the
/// arguments and quoting. Unset means the helper falls back to the passwd login
/// shell, which is what `CreateShellRequest.shell == nil` already means.
///
/// Catalyst only; iOS local shells run the in-app interpreter and spawn nothing.
///
/// All members are `nonisolated` since session setup reads them off the main actor.
enum LocalShellSettings: Sendable {

    nonisolated static let commandKey = "localShellCommand"

    /// nil means "use the login shell".
    nonisolated static var command: String? {
        resolved(UserDefaults.standard.string(forKey: commandKey))
    }

    /// What a stored value actually launches. Invalid resolves to nil, so a bad
    /// entry falls back to the login shell instead of killing every new tab.
    nonisolated static func resolved(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, isValid(trimmed) else { return nil }
        return trimmed
    }

    /// Settings row summary: what will really be launched.
    nonisolated static var summary: String {
        command ?? String(localized: "Login Shell",
                          comment: "Local shell setting: use the login shell from the passwd database")
    }

    // MARK: - Validation

    /// Control characters are the only hard rejection: a newline would split the
    /// helper's `bash -c` string into a second command. Spaces, quotes, and flags
    /// are the point of the setting.
    nonisolated static func isValid(_ value: String) -> Bool {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.count <= 1024 else { return false }
        return !trimmed.unicodeScalars.contains { CharacterSet.controlCharacters.contains($0) }
    }

    /// Warning to surface under a custom value, or nil when it looks fine.
    /// Everything here is advisory; only `isValid` rejects.
    nonisolated static func warning(for value: String) -> String? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            return String(localized: "Empty, so the login shell will be used.",
                          comment: "Local shell warning: no value entered")
        }
        if !isValid(trimmed) {
            return String(localized: "Contains a line break or control character, so the login shell will be used.",
                          comment: "Local shell warning: illegal characters")
        }
        guard let executable = executablePath(in: trimmed) else {
            return String(localized: "Unbalanced quote.",
                          comment: "Local shell warning: quote is never closed")
        }
        if !executable.hasPrefix("/") {
            return String(localized: "Not an absolute path. The shell is launched with a minimal PATH, so a bare name may not be found.",
                          comment: "Local shell warning: relative command")
        }
        if !FileManager.default.isExecutableFile(atPath: executable) {
            return String(localized: "Nothing executable at that path. Sessions will fail to start.",
                          comment: "Local shell warning: binary is missing")
        }
        return nil
    }

    /// The executable from a command line, honouring a leading quoted path.
    /// Returns nil when a leading quote is never closed.
    nonisolated static func executablePath(in command: String) -> String? {
        var rest = Substring(command)
        if let quote = rest.first, quote == "\"" || quote == "'" {
            rest = rest.dropFirst()
            guard let end = rest.firstIndex(of: quote) else { return nil }
            return String(rest[..<end])
        }
        return rest.split(separator: " ", maxSplits: 1).first.map(String.init)
    }

    // MARK: - Presets

    /// Shells offered in the settings UI, in discovery order so the system ones
    /// lead. Computed once: this stats the filesystem.
    nonisolated static let presets: [String] = discoverShells()

    /// `/etc/shells` plus a probe for shells users deliberately keep out of it,
    /// which is the case this setting exists for. Only existing paths are offered,
    /// so a preset can never produce a tab that dies instantly.
    private nonisolated static func discoverShells() -> [String] {
        var found: [String] = []
        var seen = Set<String>()

        func add(_ path: String) {
            guard !seen.contains(path),
                  FileManager.default.isExecutableFile(atPath: path) else { return }
            seen.insert(path)
            found.append(path)
        }

        if let contents = try? String(contentsOfFile: "/etc/shells", encoding: .utf8) {
            for line in contents.split(separator: "\n") {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                guard trimmed.hasPrefix("/") else { continue }
                add(trimmed)
            }
        }

        let searchDirectories = [
            "/opt/homebrew/bin",
            "/usr/local/bin",
            NSHomeDirectory() + "/.cargo/bin"
        ]
        for directory in searchDirectories {
            for name in ["nu", "fish", "xonsh", "elvish"] {
                add(directory + "/" + name)
            }
        }

        return found.isEmpty ? ["/bin/zsh", "/bin/bash", "/bin/sh"] : found
    }

    // MARK: - Ghostty Config

    /// The `command = ...` line written into the generated ghostty config.
    ///
    /// A configured command is used verbatim: `-l` cannot be appended to a
    /// command line that already carries its own arguments.
    nonisolated static var ghosttyConfigCommand: String {
        if let command { return command }
        var shellPath = "/bin/zsh"
        if let shellEnv = getenv("SHELL"), let path = String(validatingUTF8: shellEnv) {
            shellPath = path
        }
        return "\(shellPath) -l"
    }
}
