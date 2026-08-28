//
//  AppleScriptCommands.swift
//  rootshell
//
//  Cocoa Scripting handlers for Rootshell.sdef (macOS only). Each command
//  builds an AppIntentCoordinator request, so AppleScript shares the tab /
//  profile plumbing that Shortcuts and ssh:// URLs already use.
//
//    tell application "rootshell" to create tab with command "htop"
//    tell application "rootshell" to create window in directory "~/src"
//    tell application "rootshell" to create tab using profile "prod" with command "uptime"
//

import Foundation

extension URL {
    /// True for a file URL whose path exists and is a directory.
    var isExistingDirectory: Bool {
        guard isFileURL else { return false }
        var isDir: ObjCBool = false
        return FileManager.default.fileExists(atPath: path, isDirectory: &isDir) && isDir.boolValue
    }
}

#if targetEnvironment(macCatalyst)

@MainActor
enum AutomationRequestBuilder {
    enum Failure: Error {
        case profileNotFound(String)

        var message: String {
            switch self {
            case .profileNotFound(let name):
                return "No connection profile named \u{201C}\(name)\u{201D}."
            }
        }
    }

    /// Maps the sdef parameters (`command`, `directory`, `profile`) to a
    /// coordinator request. Profile names match case-insensitively.
    static func makeRequest(arguments: [String: Any]?) throws -> AppIntentCoordinator.IntentRequest {
        let command = nonEmpty(arguments?["command"])
        let directory = nonEmpty(arguments?["directory"])

        guard let profileName = nonEmpty(arguments?["profile"]) else {
            return .openLocalShell(directory: directory, command: command)
        }

        guard let profile = ConnectionProfileManager.shared.profiles.first(where: {
            $0.name.caseInsensitiveCompare(profileName) == .orderedSame
        }) else {
            throw Failure.profileNotFound(profileName)
        }

        let launchCommand = OpenConnectionProfileIntent.composeLaunchCommand(
            directory: directory,
            command: command,
            executeInShell: true
        )
        return .openProfile(ProfileIntentRequest(
            profileID: profile.id,
            launchCommandOverride: launchCommand
        ))
    }

    private static func nonEmpty(_ value: Any?) -> String? {
        guard let text = (value as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !text.isEmpty else { return nil }
        return text
    }
}

/// Shared perform: build the request on the main actor, report failures as
/// script errors (AppleScript surfaces `scriptErrorString` to the caller).
private func performAutomationCommand(
    _ command: NSScriptCommand,
    deliver: @MainActor (AppIntentCoordinator.IntentRequest) -> Void
) {
    MainActor.assumeIsolated {
        do {
            let request = try AutomationRequestBuilder.makeRequest(arguments: command.evaluatedArguments)
            deliver(request)
        } catch let failure as AutomationRequestBuilder.Failure {
            command.scriptErrorNumber = NSCannotCreateScriptCommandError
            command.scriptErrorString = failure.message
        } catch {
            command.scriptErrorNumber = NSInternalScriptError
            command.scriptErrorString = error.localizedDescription
        }
    }
}

/// `create tab`: opens in the front (key) window via the buffered path.
@objc(RootshellCreateTabCommand)
final class RootshellCreateTabCommand: NSScriptCommand {
    override func performDefaultImplementation() -> Any? {
        performAutomationCommand(self) { AppIntentCoordinator.shared.deposit($0) }
        return nil
    }
}

/// `create window`: stages the request and requests a new scene; the new
/// window claims it instead of opening its default shell.
@objc(RootshellCreateWindowCommand)
final class RootshellCreateWindowCommand: NSScriptCommand {
    override func performDefaultImplementation() -> Any? {
        performAutomationCommand(self) { AppIntentCoordinator.shared.depositForNewWindow($0) }
        return nil
    }
}

#endif
