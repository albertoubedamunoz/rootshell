//
//  MainView+OpenInFolder.swift
//  rootshell
//
//  Open a new tab or split on the focused pane's target, starting in a folder
//  the user picked in the Open in Folder palette.
//

import SwiftUI

/// Snapshot of the focused pane's target, taken when the palette opens so a
/// later focus change cannot retarget it.
struct OpenInFolderTarget {
    let request: NewTabRequest
    let sourcePaneID: UUID
    let targetKey: String
    let support: InitialDirectorySupport
    let lister: DirectoryListerResolution
    /// The pane's own working directory when known (OSC 7, herdr, probe).
    let currentDirectory: String?
    let displayName: String
    /// Working directories of other open panes on the same target.
    let seedDirectories: [String]
    /// herdr only splits right/down.
    let supportsLeftUpSplits: Bool

    var availablePlacements: [OpenInFolderPlacement] {
        OpenInFolderPlacement.available(supportsLeftUp: supportsLeftUpSplits)
    }
}

/// A placement chord that arrived via the menu rail while the palette was up.
struct OpenInFolderShortcut: Equatable {
    let placement: OpenInFolderPlacement
    let serial: Int
}

extension MainView {
    /// A target the palette can show but never open: the HUD still answers
    /// the chord, with a message instead of folders.
    func unsupportedOpenInFolderTarget() -> OpenInFolderTarget {
        let pane = terminals.indices.contains(selectedTabIndex) ? terminals[selectedTabIndex].focusedTerminal : nil
        return OpenInFolderTarget(
            request: NewTabRequest(target: .connections, localDirectory: nil),
            sourcePaneID: pane?.uuid ?? UUID(),
            targetKey: "unsupported",
            support: .unsupported,
            lister: .unavailable(.unsupportedTarget),
            currentDirectory: nil,
            displayName: pane?.connectionConfig.displayName ?? String(localized: "This pane", comment: "Open in Folder subtitle"),
            seedDirectories: [],
            supportsLeftUpSplits: true
        )
    }

    /// While the palette is up, the app's split / new-tab chords choose its
    /// placement instead of acting on the terminal. nil direction = new tab.
    func redirectToOpenInFolder(direction: SplitTree<SplitPaneView>.NewDirection?) -> Bool {
        guard showOpenInFolderOverlay else { return false }
        let placement: OpenInFolderPlacement
        switch direction {
        case nil: placement = .newTab
        case .right?: placement = .splitRight
        case .down?: placement = .splitDown
        case .left?: placement = .splitLeft
        case .up?: placement = .splitUp
        }
        openInFolderShortcut = OpenInFolderShortcut(placement: placement, serial: (openInFolderShortcut?.serial ?? 0) + 1)
        return true
    }

    /// nil when the focused pane has no browsable target (VNC, Kubernetes,
    /// consoles, an unconsumed transfer, or no pane at all).
    func captureOpenInFolderTarget() -> OpenInFolderTarget? {
        guard terminals.indices.contains(selectedTabIndex),
              let terminal = terminals[selectedTabIndex].focusedTerminal
        else { return nil }
        let request = captureNewTabRequest()
        let support: InitialDirectorySupport
        switch request.target {
        case .connections:
            return nil
        case .connection(let config, _):
            guard config.forNewSplit().startingIn(directory: "/") != nil else { return nil }
            support = config.initialDirectorySupport
        case .local, .tmux, .herdr:
            support = .full
        }
        guard let owner = TerminalConnectionOwner.resolve(for: terminal) else { return nil }
        let targetKey = TerminalConnectionOwner.targetKey(for: owner)
        let currentDirectory = terminal.pwd.flatMap { $0.hasPrefix("/") ? PathCompletion.normalize($0) : nil }
        return OpenInFolderTarget(
            request: request,
            sourcePaneID: terminal.uuid,
            targetKey: targetKey,
            support: support,
            lister: DirectoryListerFactory.make(for: owner),
            currentDirectory: currentDirectory,
            displayName: owner.connectionConfig.displayName,
            seedDirectories: OpenInFolderSeeds.collect(
                targetKey: targetKey, excluding: terminal, currentDirectory: currentDirectory
            ),
            supportsLeftUpSplits: !terminal.isHerdrPane
        )
    }

    /// Opens the new pane. false when the captured target is gone.
    @discardableResult
    func openInFolder(_ target: OpenInFolderTarget, directory: String, placement: OpenInFolderPlacement) -> Bool {
        guard InitialDirectoryCommand.isSupportedDirectory(directory) else { return false }
        let opened: Bool
        if placement.isSplit {
            opened = openInFolderSplit(target, directory: directory, placement: placement)
        } else {
            opened = openInFolderTab(target, directory: directory)
        }
        if opened {
            OpenInFolderRecentsStore.record(directory, targetKey: target.targetKey)
            OpenInFolderRecentsStore.placement = placement
        }
        return opened
    }

    private func openInFolderTab(_ target: OpenInFolderTarget, directory: String) -> Bool {
        switch target.request.target {
        case .local:
            openConnectionTab(.local(workingDirectory: directory), sourceProfileID: nil)
            return true
        case .connections:
            return false
        case .tmux(let terminalID, let controller):
            guard controller.isActive else { return false }
            let panes = terminals.flatMap { $0.splitTree.terminalLeaves }
            // Same fallback ladder as duplicating a tmux tab (see runNewTabDuplicate).
            if let original = panes.first(where: { $0.uuid == terminalID }),
               requestNewTmuxWindow(on: original, ownedBy: controller, startDirectory: directory) { return true }
            if let gateway = TmuxWindowRegistry.gatewayView(ownerTerminalUUID: controller.ownerTerminalUUIDForNotifications),
               requestNewTmuxWindow(on: gateway, ownedBy: controller, startDirectory: directory) { return true }
            for pane in panes where pane.uuid != terminalID {
                if requestNewTmuxWindow(on: pane, ownedBy: controller, startDirectory: directory) { return true }
            }
            return false
        case .herdr(let controller, let workspaceID, let afterTabID):
            return controller.requestNewTab(workspaceID: workspaceID, afterTabID: afterTabID, cwd: directory)
        case .connection(let original, let profileID):
            guard let config = original.forNewSplit().startingIn(directory: directory) else { return false }
            openConnectionTab(config, sourceProfileID: profileID)
            return true
        }
    }

    private func openInFolderSplit(_ target: OpenInFolderTarget, directory: String, placement: OpenInFolderPlacement) -> Bool {
        guard let direction = placement.splitDirection else { return false }
        // Anchor on the captured pane: a focus change since the palette opened
        // must not split some other pane.
        guard let tabIndex = terminals.firstIndex(where: { tab in
            tab.splitTree.terminalLeaves.contains { $0.uuid == target.sourcePaneID }
        }), let pane = terminals[tabIndex].splitTree.terminalLeaves.first(where: { $0.uuid == target.sourcePaneID })
        else { return false }
        if tabIndex != selectedTabIndex { selectedTabIndex = tabIndex }
        setFocusedTerminal(pane, inTab: tabIndex)
        createSplit(direction: direction, startDirectory: directory)
        return true
    }
}

extension OpenInFolderPlacement {
    var splitDirection: SplitTree<SplitPaneView>.NewDirection? {
        switch self {
        case .newTab: return nil
        case .splitRight: return .right
        case .splitDown: return .down
        case .splitLeft: return .left
        case .splitUp: return .up
        }
    }
}
