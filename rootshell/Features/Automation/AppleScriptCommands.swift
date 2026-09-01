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
import os

private let logger = Logger(subsystem: "com.rootshell", category: "Automation")

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

/// `open`: the `odoc` Apple event behind Finder's Open With, `open -b`, and a
/// Dock drop. Handling it here is what makes the folder open deterministic —
/// declaring the command in the sdef claims the event for Cocoa Scripting, so
/// without an implementation class the system dispatched it to a no-op.
@objc(RootshellOpenCommand)
final class RootshellOpenCommand: NSScriptCommand {
    override func performDefaultImplementation() -> Any? {
        let urls = Self.fileURLs(from: directParameter)
        guard !urls.isEmpty else {
            scriptErrorNumber = NSArgumentsWrongScriptError
            scriptErrorString = "Expected a file or folder to open."
            return nil
        }

        MainActor.assumeIsolated {
            logger.info("[urlopen] odoc items=\(urls.count)")
            var routed = false
            for url in urls {
                if CatalystAppDelegate.routeAutomationURL(url, source: "applescript.open") {
                    routed = true
                }
            }
            // No reopen event accompanies a document open, so with zero
            // regular windows the deposit would sit until Cmd-N. The new
            // window adopts it as its first tab.
            if routed {
                CatalystSceneDelegate.openMainWindowIfNoneConnected()
            }
        }
        return nil
    }

    /// The direct parameter arrives as a URL, a path string, or a list of either.
    private static func fileURLs(from parameter: Any?) -> [URL] {
        switch parameter {
        case let url as URL:
            return [url]
        case let path as String:
            let expanded = (path as NSString).expandingTildeInPath
            return expanded.isEmpty ? [] : [URL(fileURLWithPath: expanded)]
        case let list as [Any]:
            return list.flatMap { fileURLs(from: $0) }
        default:
            return []
        }
    }
}

#endif
