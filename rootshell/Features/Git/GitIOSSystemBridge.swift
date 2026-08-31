#if !targetEnvironment(macCatalyst)

import Foundation
import OSLog

// MARK: - ios_system entry point

/// Entry point for `git` when invoked via ios_system.
/// ios_system calls this as `int git_main(int argc, char* argv[])` on a background thread
/// with `ios_get_thread_stdout()` already redirected to the appropriate pipe.
///
/// Unlike MtrIOSSystemBridge which needs a pipe pair (MtrCommand is @MainActor + async),
/// GitCommandDispatch.run() is a synchronous static function that works on any thread.
/// We call it directly and write output to thread_stdout.
@_cdecl("git_main")
func git_main(_ argc: Int32, _ argv: UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>?) -> Int32 {
    // Capture working directory early (safe from concurrent CWD changes)
    let workingDirectory: String
    if let cwd = getcwd(nil, 0) {
        workingDirectory = String(cString: cwd)
        free(cwd)
    } else {
        workingDirectory = FileManager.default.currentDirectoryPath
    }

    // Convert argc/argv directly to [String], preserving argument boundaries.
    // argv[0] is "git" — skip it and pass the rest to parseArgs.
    let args = gitExtractArgs(argc: argc, argv: argv)

    // Parse using the argv-based path (no string round-trip that would
    // break arguments containing spaces, e.g. git add "My File.swift")
    let parseResult = GitCommandParser.parseArgs(
        args,
        workingDirectory: workingDirectory
    )

    switch parseResult {
    case .error(let message):
        gitWriteError("git: \(message)\n")
        return 1

    case .help:
        gitWriteOutput(gitHelpText)
        return 0

    case .success(let config):
        // Auth flags require interactive mode (password prompts, Keychain access).
        // When invoked via ios_system, there's no way to interact with the user mid-command.
        if config.sshKeyName != nil || config.forcePassword || config.profileName != nil {
            gitWriteError("git: --ssh-key, --password, and --profile require interactive mode\n")
            gitWriteError("hint: run the command without piping or redirection\n")
            return 1
        }

        // Resolve color mode: auto → never (stdout is always a pipe in ios_system)
        let colorEnabled: Bool
        switch config.colorMode {
        case .always:
            colorEnabled = true
        case .never:
            colorEnabled = false
        case .auto:
            colorEnabled = false
        }

        return gitExecute(config: config, colorEnabled: colorEnabled)
    }
}

// MARK: - Execution

private let logger = Logger(subsystem: "com.kk2.rootshell", category: "git-bridge")

/// Nonisolated helpers for git bridge (runs on ios_system background threads).
private enum GitBridgeConstants {
    /// ANSI SGR sequence pattern for stripping color codes.
    nonisolated static let sgrPattern = try! NSRegularExpression(pattern: "\u{1b}\\[[0-9;]*m")
}

private func gitExecute(config: GitCommandParser.GitCommandConfig, colorEnabled: Bool) -> Int32 {
    // Ensure libgit2 is initialized
    _ = GitInitializer.initOnce

    // Per-invocation init/shutdown (ref-counted)
    git_libgit2_init()
    defer { git_libgit2_shutdown() }

    // Keep stdout and human-readable status/progress separate. ios_system's
    // pipeline executor forwards stdout downstream while leaving stderr on the
    // terminal unless the user explicitly redirects or merges it.
    guard let threadStdout = ios_get_thread_stdout() else {
        gitWriteOutput("git: no output stream available\n")
        return 1
    }
    let threadStderr = ios_get_thread_stderr() ?? threadStdout

    // Output callback: optionally strips ANSI codes, passes output to pipe.
    //
    // Line endings are NOT converted here. Git subcommands emit \r\n which
    // normalizePipeOutput handles correctly (only adds \r before lone \n).
    // Converting \r\n → \n would break when normalization is disabled by
    // ScreenControlDetector (triggered by progress bar \e[K sequences),
    // leaving lone \n that cascades in the terminal.
    let makeOutputCallback: (UnsafeMutablePointer<FILE>) -> @Sendable (String) -> Void = { stream in
        { text in
            var rendered = text

            // Strip ANSI SGR sequences when color is disabled. Terminal
            // progress controls are confined to stderr by this point.
            if !colorEnabled {
                let range = NSRange(rendered.startIndex..., in: rendered)
                rendered = GitBridgeConstants.sgrPattern.stringByReplacingMatches(
                    in: rendered,
                    range: range,
                    withTemplate: ""
                )
            }

            fputs(rendered, stream)
            fflush(stream)
        }
    }
    let outputCb = makeOutputCallback(threadStdout)
    let statusOutputCb = makeOutputCallback(threadStderr)

    let subcommand = config.subcommand

    // Handle "version" (not in GitCommandDispatch table)
    if subcommand == "version" {
        let major = UnsafeMutablePointer<Int32>.allocate(capacity: 1)
        let minor = UnsafeMutablePointer<Int32>.allocate(capacity: 1)
        let rev = UnsafeMutablePointer<Int32>.allocate(capacity: 1)
        defer { major.deallocate(); minor.deallocate(); rev.deallocate() }

        git_libgit2_version(major, minor, rev)
        outputCb("git (libgit2 \(major.pointee).\(minor.pointee).\(rev.pointee))\r\n")
        return 0
    }

    // Get terminal width from environment (set by ios_system session)
    let cols: UInt16 = UInt16(
        ProcessInfo.processInfo.environment["COLUMNS"]
            .flatMap(UInt16.init) ?? 80
    )

    let exitCode: Int32
    do {
        exitCode = try GitCommandDispatch.run(
            subcommand: subcommand,
            workingDirectory: config.workingDirectory,
            args: config.args,
            cols: cols,
            output: outputCb,
            statusOutput: statusOutputCb,
            progressDefault: false
        )
    } catch let error as GitError {
        if case .editorNeeded = error {
            // Editor flow can't work through ios_system (no interactive UI access)
            statusOutputCb("error: editor required for this operation\n")
            statusOutputCb("hint: use -m to specify a commit message, or run git commit interactively\n")
            return 1
        }
        statusOutputCb(error.styledDescription)
        return 1
    } catch {
        statusOutputCb("fatal: \(error.localizedDescription)\n")
        return 1
    }

    logger.debug("git \(subcommand) exited with code \(exitCode)")
    return exitCode
}

// MARK: - Helpers

private func gitWriteOutput(_ text: String) {
    if let stream = ios_get_thread_stdout() {
        fputs(text, stream)
        fflush(stream)
    } else if let stream = ios_get_thread_stderr() {
        fputs(text, stream)
        fflush(stream)
    }
}

private func gitWriteError(_ text: String) {
    if let stream = ios_get_thread_stderr() {
        fputs(text, stream)
        fflush(stream)
    } else if let stream = ios_get_thread_stdout() {
        fputs(text, stream)
        fflush(stream)
    }
}

/// Extract arguments from argc/argv, skipping argv[0] ("git").
/// Preserves original argument boundaries — no string joining/reparsing.
private func gitExtractArgs(
    argc: Int32,
    argv: UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>?
) -> [String] {
    let safeArgc = max(0, Int(argc))
    guard safeArgc > 1, let argv else { return [] }

    var args: [String] = []
    args.reserveCapacity(safeArgc - 1)

    for i in 1..<safeArgc {
        if let arg = argv[i], let decoded = String(validatingUTF8: arg) {
            args.append(decoded)
        }
    }

    return args
}

/// Help text matching the native interactive path.
private let gitHelpText = """
usage: git [<options>] <command> [<args>]

Options:
  --color=<when>      Colorize output (always, never, auto)
  --no-pager          Do not pipe output into a pager
  --ssh-key <name>    Use a specific SSH key for remote operations (interactive only)
  --password          Prompt for SSH password before connecting (interactive only)
  --profile <name>    Use a connection profile (interactive only)

Common commands:
  init        Create an empty Git repository
  clone       Clone a repository
  status      Show the working tree status
  add         Add file contents to the index
  rm          Remove files from the working tree and index
  mv          Move or rename a file
  commit      Record changes to the repository
  reset       Unstage files or reset HEAD
  revert      Create a commit that undoes a previous commit
  branch      List, create, or delete branches
  checkout    Switch branches or restore working tree files
  log         Show commit logs
  show        Show a commit's details and diff
  diff        Show changes between commits, commit and working tree, etc
  fetch       Download objects and refs from another repository
  pull        Fetch and merge from remote
  push        Update remote refs along with associated objects
  remote      Manage set of tracked repositories
  merge       Join two or more development histories together
  stash       Stash the changes in a dirty working directory
  tag         Create, list, delete or verify a tag object
  blame       Show what revision and author last modified each line
  config      Get and set repository or global options
  rev-parse   Pick out and massage parameters
  ls-files    Show information about files in the index
  general     Show libgit2 info and repo diagnostics

Run 'git <command> --help' for help on a specific command.

"""

#endif // !targetEnvironment(macCatalyst)
