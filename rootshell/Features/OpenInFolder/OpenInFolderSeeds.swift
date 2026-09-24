//
//  OpenInFolderSeeds.swift
//  rootshell
//

import Foundation

/// Folders already open elsewhere on the same target, offered as candidates.
@MainActor
enum OpenInFolderSeeds {
    /// Working directories of every other pane whose connection lands on
    /// `targetKey`, across all windows, deduped, most relevant first.
    static func collect(targetKey: String, excluding focused: Ghostty.TerminalView?, currentDirectory: String?) -> [String] {
        var seen: Set<String> = []
        if let currentDirectory { seen.insert(PathCompletion.normalize(currentDirectory)) }
        var seeds: [String] = []
        for model in TmuxWindowRegistry.allTabsModels() {
            for tab in model.tabs {
                for terminal in tab.splitTree.terminalLeaves where terminal !== focused {
                    guard let owner = TerminalConnectionOwner.resolve(for: terminal),
                          TerminalConnectionOwner.targetKey(for: owner) == targetKey,
                          let pwd = terminal.pwd, pwd.hasPrefix("/")
                    else { continue }
                    let normalized = PathCompletion.normalize(pwd)
                    if seen.insert(normalized).inserted { seeds.append(normalized) }
                }
            }
        }
        return seeds
    }
}
