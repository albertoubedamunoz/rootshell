//
//  ShellIntegration.swift
//  rootshell-helper
//
//  Shell integration script injection.
//  Based on ghostty/src/termio/Exec.zig:749-803
//

import Foundation

/// Handles shell integration script injection
class ShellIntegration {

    /// Wraps a login command with shell integration
    /// Returns modified command arguments if integration is available
    /// Returns nil if integration is not available for this shell
    static func wrapLoginCommand(
        _ args: [String],
        shell: String,
        integrationPath: String?
    ) -> [String]? {
        guard let integrationPath = integrationPath else {
            return nil
        }

        let shellType = EnvironmentBuilder.detectShellType(from: shell)

        guard let scriptName = shellType.integrationScriptName else {
            return nil
        }

        let scriptPath = (integrationPath as NSString).appendingPathComponent(scriptName)

        guard FileManager.default.fileExists(atPath: scriptPath) else {
            return nil
        }

        // Wrap the command based on shell type
        switch shellType {
        case .bash:
            return wrapBashCommand(args, scriptPath: scriptPath)
        case .zsh:
            return wrapZshCommand(args, scriptPath: scriptPath)
        case .fish:
            return wrapFishCommand(args, scriptPath: scriptPath)
        case .elvish:
            return wrapElvishCommand(args, scriptPath: scriptPath)
        case .unknown:
            return nil
        }
    }

    private static func wrapBashCommand(_ args: [String], scriptPath: String) -> [String] {
        // For bash, we can use --rcfile to source our integration script
        // The login command already uses bash with --noprofile --norc
        // We need to modify the exec command to source our script first

        var newArgs = args

        // Find the "-c" argument and modify the exec command
        if let cIndex = newArgs.firstIndex(of: "-c"),
           cIndex + 1 < newArgs.count {
            let execCmd = newArgs[cIndex + 1]

            // Prepend source command
            let wrappedCmd = "source \"\(scriptPath)\"; \(execCmd)"
            newArgs[cIndex + 1] = wrappedCmd
        }

        return newArgs
    }

    private static func wrapZshCommand(_ args: [String], scriptPath: String) -> [String] {
        // For zsh, similar approach: source integration before exec
        var newArgs = args

        if let cIndex = newArgs.firstIndex(of: "-c"),
           cIndex + 1 < newArgs.count {
            let execCmd = newArgs[cIndex + 1]

            // Prepend source command (zsh uses "source" or ".")
            let wrappedCmd = "source \"\(scriptPath)\"; \(execCmd)"
            newArgs[cIndex + 1] = wrappedCmd
        }

        return newArgs
    }

    private static func wrapFishCommand(_ args: [String], scriptPath: String) -> [String] {
        // For fish, use "source" before exec
        var newArgs = args

        if let cIndex = newArgs.firstIndex(of: "-c"),
           cIndex + 1 < newArgs.count {
            let execCmd = newArgs[cIndex + 1]

            // Fish uses "source" as well
            let wrappedCmd = "source \"\(scriptPath)\"; \(execCmd)"
            newArgs[cIndex + 1] = wrappedCmd
        }

        return newArgs
    }

    private static func wrapElvishCommand(_ args: [String], scriptPath: String) -> [String] {
        // For elvish, use "use" or "-c" with source equivalent
        var newArgs = args

        if let cIndex = newArgs.firstIndex(of: "-c"),
           cIndex + 1 < newArgs.count {
            let execCmd = newArgs[cIndex + 1]

            // Elvish uses different syntax, but we can use -c
            let wrappedCmd = "-c \"\(scriptPath)\"; \(execCmd)"
            newArgs[cIndex + 1] = wrappedCmd
        }

        return newArgs
    }

    /// Modifies environment to enable shell integration
    static func modifyEnvironmentForIntegration(
        _ env: inout [String: String],
        shell: String,
        integrationPath: String
    ) {
        let shellType = EnvironmentBuilder.detectShellType(from: shell)

        // Set common integration variables
        env["GHOSTTY_SHELL_INTEGRATION"] = "1"
        env["GHOSTTY_SHELL_INTEGRATION_DIR"] = integrationPath

        // Shell-specific environment variables
        switch shellType {
        case .bash:
            // Bash can use BASH_ENV for non-interactive shells
            // but we're using sourcing in the command instead
            break
        case .zsh:
            // Similar for zsh
            break
        case .fish:
            // Fish has XDG_CONFIG_HOME/fish/conf.d/
            // but we're sourcing directly
            break
        case .elvish:
            break
        case .unknown:
            break
        }
    }
}
