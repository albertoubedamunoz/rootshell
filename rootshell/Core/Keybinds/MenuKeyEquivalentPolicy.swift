//
//  MenuKeyEquivalentPolicy.swift
//  rootshell
//
//  Decides when a stock macOS menu item must give up its key equivalent.
//  AppKit dispatches menu key equivalents before any responder UIKeyCommand,
//  so an item that keeps a chord the user rebound (Cmd-Q, Cmd-H, Cmd-M, …)
//  swallows the binding.
//

import Foundation

/// Shared by the app and its standalone test target.
nonisolated enum MenuKeyEquivalentPolicy {
    /// Stock Edit menu selectors whose items may give up their key equivalent.
    /// Other items in the Edit menus (rootshell's own commands) are left alone.
    static let editSelectors: Set<String> = [
        "undo:", "redo:",
        "cut:", "copy:", "paste:", "pasteAndMatchStyle:", "delete:", "selectAll:",
    ]

    /// Keybind actions (raw values) that perform the same thing as a stock Edit
    /// item, by selector. The item keeps its chord while bound to that action,
    /// which preserves the system Cmd-V paste path and its pasteboard intent.
    static let editItemActions: [String: String] = [
        "copy:": "copy_to_clipboard",
        "paste:": "paste_from_clipboard",
        "selectAll:": "select_all",
    ]

    /// Stock items whose key equivalent AppKit restores on Catalyst even when
    /// UIKit supplies the item without one: Minimize gets Cmd-M back. A claimed
    /// Minimize is removed instead; the window's minimize button remains.
    static let appKitRekeyedSelectors: Set<String> = ["performMiniaturize:"]

    enum Resolution: Equatable {
        case keep
        case releaseKeyEquivalent
        case remove
    }

    /// What to do with a stock menu item holding a chord. `selector` is the
    /// item's action; the other parameters are as for releasesKeyEquivalent.
    static func resolution(
        selector: String,
        owners: [String],
        leadsSequence: Bool,
        isRecording: Bool
    ) -> Resolution {
        guard releasesKeyEquivalent(
            itemAction: editItemActions[selector],
            owners: owners,
            leadsSequence: leadsSequence,
            isRecording: isRecording
        ) else { return .keep }
        return appKitRekeyedSelectors.contains(selector) ? .remove : .releaseKeyEquivalent
    }

    /// Whether a stock menu item must drop its key equivalent.
    /// - Parameters:
    ///   - itemAction: the keybind action the item already performs, if any.
    ///   - owners: actions of every binding whose first chord is the item's.
    ///   - leadsSequence: whether any of those bindings is a multi-key
    ///     sequence; the menu would fire on its leader before the tracker.
    ///   - isRecording: whether a shortcut recorder needs the physical chord.
    static func releasesKeyEquivalent(
        itemAction: String?,
        owners: [String],
        leadsSequence: Bool,
        isRecording: Bool
    ) -> Bool {
        isRecording || leadsSequence || owners.contains { $0 != itemAction }
    }
}
