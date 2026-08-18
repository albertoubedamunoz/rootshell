#if !targetEnvironment(macCatalyst)

import Foundation

/// `git config [--global|--local|--system] [--list] <key> [<value>]` — git configuration.
enum GitConfig: GitSubcommand {
    static var helpText: String {
        "usage: git config [<options>] [<name> [<value>]]\r\n\r\n    Get and set repository or global options\r\n\r\nOptions:\r\n    --global             Use global config file\r\n    --local              Use repository config file\r\n    --system             Use system config file\r\n    -l, --list           List all config variables\r\n    --unset <name>       Remove a variable\r\n"
    }

    static func run(repo: OpaquePointer?, args: [String], cols: UInt16, output: @escaping @Sendable (String) -> Void) throws -> Int32 {
        // Parse flags
        var scope: ConfigScope = .default_
        var list = false
        var unset = false
        var positional: [String] = []

        for arg in args {
            switch arg {
            case "--global": scope = .global
            case "--local": scope = .local
            case "--system": scope = .system
            case "--list", "-l": list = true
            case "--unset": unset = true
            default:
                if !arg.hasPrefix("-") {
                    positional.append(arg)
                }
            }
        }

        if list {
            return try listConfig(repo: repo, scope: scope, output: output)
        }

        if unset {
            guard let key = positional.first else {
                output("usage: git config --unset <key>\r\n")
                return 1
            }
            return try unsetConfig(repo: repo, scope: scope, key: key, output: output)
        }

        guard let key = positional.first else {
            output("usage: git config [--global|--local] <key> [<value>]\r\n")
            output("       git config [--global|--local] --list\r\n")
            return 1
        }

        if positional.count >= 2 {
            // Set value
            return try setConfig(repo: repo, scope: scope, key: key, value: positional[1], output: output)
        } else {
            // Get value
            return try getConfig(repo: repo, scope: scope, key: key, output: output)
        }
    }

    // MARK: - Config scope

    private enum ConfigScope {
        case default_
        case global
        case local
        case system
    }

    // MARK: - Open config

    private static func openConfig(repo: OpaquePointer?, scope: ConfigScope) throws -> OpaquePointer {
        var config: OpaquePointer?

        switch scope {
        case .global:
            // Open global config directly
            var defaultCfg: OpaquePointer?
            try lg2Check(git_config_open_default(&defaultCfg), "failed to open config")
            guard let defaultCfg else {
                throw GitError.invalidArguments("failed to open default config")
            }
            defer { git_config_free(defaultCfg) }

            try lg2Check(
                git_config_open_level(&config, defaultCfg, GIT_CONFIG_LEVEL_GLOBAL),
                "failed to open global config"
            )

        case .system:
            var defaultCfg: OpaquePointer?
            try lg2Check(git_config_open_default(&defaultCfg), "failed to open config")
            guard let defaultCfg else {
                throw GitError.invalidArguments("failed to open default config")
            }
            defer { git_config_free(defaultCfg) }

            try lg2Check(
                git_config_open_level(&config, defaultCfg, GIT_CONFIG_LEVEL_SYSTEM),
                "failed to open system config"
            )

        case .local:
            guard let repo else {
                throw GitError.notARepository
            }
            var repoCfg: OpaquePointer?
            try lg2Check(git_repository_config(&repoCfg, repo), "failed to open repo config")
            guard let repoCfg else {
                throw GitError.invalidArguments("failed to open repo config")
            }
            defer { git_config_free(repoCfg) }

            try lg2Check(
                git_config_open_level(&config, repoCfg, GIT_CONFIG_LEVEL_LOCAL),
                "failed to open local config"
            )

        case .default_:
            // Use repo config if available, otherwise default
            if let repo {
                try lg2Check(git_repository_config(&config, repo), "failed to open config")
            } else {
                try lg2Check(git_config_open_default(&config), "failed to open config")
            }
        }

        guard let config else {
            throw GitError.invalidArguments("failed to open config")
        }

        return config
    }

    // MARK: - Get config value

    private static func getConfig(repo: OpaquePointer?, scope: ConfigScope, key: String, output: @escaping @Sendable (String) -> Void) throws -> Int32 {
        let config: OpaquePointer
        do {
            config = try openConfig(repo: repo, scope: scope)
        } catch {
            // For explicit scopes (--local, --global, --system), propagate the error
            // Only fall back to merged config for the default (no scope flag) case
            guard case .default_ = scope, let repo else {
                throw error
            }
            var cfg: OpaquePointer?
            try lg2Check(git_repository_config(&cfg, repo), "failed to open config")
            guard let cfg else { return 1 }
            config = cfg
        }
        defer { git_config_free(config) }

        var entry: UnsafeMutablePointer<git_config_entry>?
        let result = git_config_get_entry(&entry, config, key)

        if result == GIT_ENOTFOUND.rawValue {
            // Key not found — exit silently like real git (exit code 1)
            return 1
        }

        try lg2Check(result, "failed to get config value")

        guard let entry else { return 1 }
        defer { git_config_entry_free(entry) }

        let value = entry.pointee.value.map { String(cString: $0) } ?? ""
        output("\(value)\r\n")
        return 0
    }

    // MARK: - Set config value

    private static func setConfig(repo: OpaquePointer?, scope: ConfigScope, key: String, value: String, output: @escaping @Sendable (String) -> Void) throws -> Int32 {
        let config = try openConfig(repo: repo, scope: scope)
        defer { git_config_free(config) }

        try lg2Check(git_config_set_string(config, key, value), "failed to set config value")
        return 0
    }

    // MARK: - Unset config value

    private static func unsetConfig(repo: OpaquePointer?, scope: ConfigScope, key: String, output: @escaping @Sendable (String) -> Void) throws -> Int32 {
        let config = try openConfig(repo: repo, scope: scope)
        defer { git_config_free(config) }

        try lg2Check(git_config_delete_entry(config, key), "failed to unset config value")
        return 0
    }

    // MARK: - List all config entries

    private static func listConfig(repo: OpaquePointer?, scope: ConfigScope, output: @escaping @Sendable (String) -> Void) throws -> Int32 {
        let config: OpaquePointer
        do {
            config = try openConfig(repo: repo, scope: scope)
        } catch {
            // For explicit scopes (--local, --global, --system), propagate the error
            // Only fall back to merged config for the default (no scope flag) case
            guard case .default_ = scope else {
                throw error
            }
            if let repo {
                var cfg: OpaquePointer?
                try lg2Check(git_repository_config(&cfg, repo), "failed to open config")
                guard let cfg else { return 1 }
                config = cfg
            } else {
                var cfg: OpaquePointer?
                try lg2Check(git_config_open_default(&cfg), "failed to open config")
                guard let cfg else { return 1 }
                config = cfg
            }
        }
        defer { git_config_free(config) }

        var out = GitOutput(write: output)

        var iter: OpaquePointer?
        try lg2Check(git_config_iterator_new(&iter, config), "failed to create config iterator")
        guard let iter else { return 1 }
        defer { git_config_iterator_free(iter) }

        var entry: UnsafeMutablePointer<git_config_entry>?

        while git_config_next(&entry, iter) == 0 {
            guard let entry else { continue }
            let name = entry.pointee.name.map { String(cString: $0) } ?? ""
            let value = entry.pointee.value.map { String(cString: $0) } ?? ""

            out.raw(GitStyle.fg(GitStyle.info, name))
            out.raw("=")
            out.raw(value)
            out.line()
        }

        out.flush()
        return 0
    }
}

#endif
