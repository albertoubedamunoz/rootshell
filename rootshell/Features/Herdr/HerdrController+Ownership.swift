//
//  HerdrController+Ownership.swift
//  rootshell
//
//  Several clients on one session. Protocol 2 servers share terminals and
//  track one geometry owner per tab; older forks hold one owner per pane,
//  which surfaces here as paused panes with a Take Control action. Nothing
//  in this file evicts another client without the user asking.
//
//  Copyright (c) 2026 Kit Knox / Rootshell LLC
//

import Foundation
import os
import UIKit

extension Notification.Name {
    /// userInfo: "request" (MainAlertController.HerdrTakeControlRequest), "windowId" (String).
    static let herdrTakeControlRequested = Notification.Name("herdrTakeControlRequested")
}

/// Why a pane has no live attach of ours.
enum HerdrPaneControlState: Equatable {
    /// `terminal.attach` was refused: a single-owner server, someone else attached.
    case heldByOther
    /// Our attach was evicted by another client's takeover.
    case takenOver
}

extension HerdrController {

    // MARK: - Mobile activation

    var mobileWindowIsActive: Bool {
        guard !Ghostty.isAppBackgroundedAtomic,
              let tab = tabs.values.first(where: { $0.id == tabsModel.selectedTabID }),
              let window = tab.focusedTerminal?.window ?? tab.splitTree.terminalLeaves.first?.window else { return false }
        return window.isKeyWindow && window.windowScene?.activationState == .foregroundActive
    }

    func suspendMobileActivation() {
        #if !targetEnvironment(macCatalyst)
        mobileActivation.suspend()
        for session in paneSessions.values { session.mobileReadFence = nil }
        #endif
    }

    /// Called from selection and layout readiness, but only selection or a
    /// foreground/reconnect edge creates intent. Remote layouts cannot renew it.
    func reconcileMobileActivation() {
        #if !targetEnvironment(macCatalyst)
        guard !didEnd, mode == .raw, isActive, hasProcessedInitialFocus, capabilities.supportsSharedViewing else { return }
        guard let tab = tabs.values.first(where: { $0.id == tabsModel.selectedTabID }) else {
            mobileActivation.select(nil, panes: [])
            return
        }
        guard mobileWindowIsActive, let tabID = tab.herdrTabId else { return }
        mobileScene = (tab.focusedTerminal?.window ?? tab.splitTree.terminalLeaves.first?.window)?.windowScene
        let visibleTree = SplitTree<SplitPaneView>(root: tab.splitTree.zoomed ?? tab.splitTree.root, zoomed: nil)
        let visiblePanes = visibleTree.terminalLeaves.filter { $0.isHerdrPane }
        let terminalIDs = Set(visiblePanes.compactMap { $0.herdrPaneBinding?.terminalId })
        guard !terminalIDs.isEmpty else { return }
        guard mobileActivation.select(tabID, panes: terminalIDs) else { return }
        for session in paneSessions.values { session.mobileReadFence = nil }
        // Even a previously confirmed size must carry this new claim.
        tabGeometryStates[tabID, default: .init()].invalidate()
        for view in visiblePanes {
            view.prepareHerdrReturnToLive()
        }
        #endif
    }

    func mobileClaimGeneration(for tabID: String) -> UUID? {
        #if !targetEnvironment(macCatalyst)
        guard mobileWindowIsActive, mobileActivation.tabID == tabID,
              mobileActivation.needsClaim else { return nil }
        return mobileActivation.generation
        #else
        return nil
        #endif
    }

    func cancelMobileReturnToLive(terminalID: String) {
        mobileActivation.finishPane(terminalID)
        paneSessions[terminalID]?.mobileReadFence = nil
    }

    /// Queue the acknowledgement after replay and all output already received.
    /// A snapshot replacement changes the revision and invalidates old replies.
    func reconcileMobileReturnToLive() {
        #if !targetEnvironment(macCatalyst)
        guard !didEnd, isActive, capabilities.supportsSharedViewing, mobileWindowIsActive,
              !mobileActivation.needsClaim, let tabID = mobileActivation.tabID,
              tabs[tabID]?.id == tabsModel.selectedTabID,
              !layoutReleases.values.contains(where: { $0.tabId == tabID }) else { return }
        for terminalID in mobileActivation.pendingPanes {
            guard let session = paneSessions[terminalID], let attachID = session.attachId,
                  paneGeometryIsReady(terminalID), !panesNeedingSnapshot.contains(terminalID),
                  !snapshotRequestsInFlight.contains(attachID),
                  let revision = router.snapshotRevision(attachId: attachID) else { continue }
            if session.mobileReadFence?.snapshot == revision { continue }
            session.requestMobileReadFence(generation: mobileActivation.generation, snapshot: revision)
        }
        #endif
    }

    func mobileParserDidDrain(_ session: HerdrPaneSession, fence: HerdrPaneSession.MobileReadFence) {
        #if !targetEnvironment(macCatalyst)
        guard !didEnd, mobileWindowIsActive, !mobileActivation.needsClaim,
              paneSessions[session.terminalId] === session,
              mobileActivation.generation == fence.generation,
              mobileActivation.pendingPanes.contains(session.terminalId),
              isVisible(terminalId: session.terminalId), let attachID = session.attachId,
              router.snapshotRevision(attachId: attachID) == fence.snapshot,
              paneGeometryIsReady(session.terminalId),
              !panesNeedingSnapshot.contains(session.terminalId),
              !snapshotRequestsInFlight.contains(attachID),
              !layoutReleases.values.contains(where: { $0.tabId == mobileActivation.tabID }),
              let view = paneViews[session.terminalId],
              let tabID = mobileActivation.tabID, let tab = tabs[tabID],
              (tab.splitTree.zoomed ?? tab.splitTree.root)?.node(view: view) != nil else { return }
        mobileActivation.finishPane(session.terminalId)
        guard !view.isActivelySelecting else { return }
        view.finishHerdrReturnToLive()
        #endif
    }

    // MARK: - Geometry ownership (protocol 2)

    func ownership(of tabId: String) -> HerdrTabGeometryState.Ownership {
        tabGeometryStates[tabId]?.ownership ?? .unknown
    }

    func tabIsControlledElsewhere(_ tab: TabModel) -> Bool {
        guard let tabId = tab.herdrTabId else { return false }
        if tabGeometryStates[tabId]?.isOwnedElsewhere == true { return true }
        return paneInfos.values.contains { $0.tab_id == tabId && paneControlStates[$0.terminal_id] != nil }
    }

    /// Records who sizes `tabId` from a layout or event. `carried` is false
    /// for layouts without the field (protocol 1), which say nothing.
    func applyGeometryController(_ controller: HerdrControl.GeometryController?, tabId: String, carried: Bool) {
        guard carried, mode == .raw, tabs[tabId] != nil else { return }
        let ownership: HerdrTabGeometryState.Ownership
        switch controller?.kind {
        case nil, "none":
            ownership = .none
        case "control" where controller?.connection_id == controlOpened?.connection_id:
            ownership = .mine
        default:
            ownership = .other(connectionId: controller?.connection_id, kind: controller?.kind)
        }
        guard tabGeometryStates[tabId, default: .init()].setOwnership(ownership) else { return }
        Self.logger.info("herdr tab \(tabId) geometry owner -> \(String(describing: ownership))")
        // A hand-off to us applied our stored size already; do not re-send it.
        if ownership == .mine, let layout = controlLayouts[tabId],
           let desired = tabGeometryStates[tabId]?.desired,
           layout.area.width == desired.cols, layout.area.height == desired.rows {
            tabGeometryStates[tabId]?.noteServerApplied(desired)
        }
        syncControlledElsewhereBadge(tabId: tabId)
        for view in paneViews.values where view.herdrPaneBinding?.tabId == tabId {
            view.enclosingSplitHost?.setNeedsLayout()
        }
        if let tab = tabs[tabId], let view = tab.splitTree.terminalLeaves.first(where: { $0.isHerdrPane }) {
            scheduleGeometryPush(from: view)
        }
        pumpAttachQueue()
        requestSnapshotsForReadyPanes()
        publishSessionState()
    }

    func geometryControllerDidChange(_ change: HerdrControl.TabGeometryChangedData) {
        applyGeometryController(change.geometry_controller, tabId: change.tab_id, carried: true)
        refreshOtherConnections()
    }

    /// Cells the tab really has when another client sized it smaller or
    /// larger than our container; nil when we own it or nothing is known.
    func foreignAreaCells(for view: Ghostty.TerminalView) -> (cols: Int, rows: Int)? {
        guard let tabId = view.herdrPaneBinding?.tabId else { return nil }
        if mode == .legacy {
            // The endpoint frame's grid is the surface we asked for unless
            // another client resized it; then the tree's extent is the tab.
            guard tabId == endpointTabID, let layout = endpointLayouts[tabId], let asked = endpointSize,
                  layout.area.width != asked.cols || layout.area.height != asked.rows,
                  let tree = HerdrLayoutTree.build(layout) else { return nil }
            return (tree.extent(horizontal: true), tree.extent(horizontal: false))
        }
        guard tabGeometryStates[tabId]?.isOwnedElsewhere == true, let layout = controlLayouts[tabId] else { return nil }
        return (layout.area.width, layout.area.height)
    }

    /// "This client", the other client's label, or "None".
    func geometryOwnerDescription(_ tabId: String) -> String? {
        switch ownership(of: tabId) {
        case .unknown: return nil
        case .none: return String(localized: "None")
        case .mine: return String(localized: "This client")
        case .other(let id, let kind):
            if let id, let other = otherConnections.first(where: { $0.connection_id == id }) {
                return other.displayLabel
            }
            if kind == "client" { return String(localized: "herdr client") }
            return id.map { String(localized: "Connection #\($0)") } ?? String(localized: "Another client")
        }
    }

    // MARK: - Claims

    /// Explicit user intent to size the tab to this window: divider drag,
    /// Fit to This Window, or Take Control on a sharing server.
    func claimGeometry(tabId: String) {
        guard mode == .raw, channel != nil, capabilities.supportsSharedViewing, tabs[tabId] != nil else { return }
        // Send the measured size and the user's claim together, once. A
        // separate claim RPC plus a claiming resize can undo another client's
        // intervening handoff. Ownership changes only on the server's event.
        tabGeometryStates[tabId, default: .init()].requestClaim()
        Self.logger.info("herdr claim geometry \(tabId)")
        if let tab = tabs[tabId], let view = tab.splitTree.terminalLeaves.first(where: { $0.isHerdrPane }) {
            scheduleGeometryPush(from: view)
        }
    }

    func requestFitToWindow(_ tab: TabModel) {
        guard let tabId = tab.herdrTabId else { return }
        claimGeometry(tabId: tabId)
    }

    /// The user dragged a divider in a tab someone else sizes: they want it
    /// laid out here, so take the tab before the resize lands.
    func noteDividerDrag(in view: Ghostty.TerminalView) {
        guard let tabId = view.herdrPaneBinding?.tabId,
              tabGeometryStates[tabId]?.isOwnedElsewhere == true else { return }
        claimGeometry(tabId: tabId)
    }

    // MARK: - Single-owner servers

    func paneHeldByOther(terminalId: String, tabId: String?) {
        guard !didEnd else { return }
        paneControlStates[terminalId] = .heldByOther
        paneViews[terminalId]?.updateHerdrPaneControlOverlay()
        guard let tabId else { return }
        syncControlledElsewhereBadge(tabId: tabId)
        presentTakeControlPrompt(tabId: tabId)
    }

    func paneTakenOver(terminalId: String) {
        guard !didEnd else { return }
        paneControlStates[terminalId] = .takenOver
        paneViews[terminalId]?.updateHerdrPaneControlOverlay()
        if let tabId = paneViews[terminalId]?.herdrPaneBinding?.tabId {
            takeoverRequested.remove(tabId)
            syncControlledElsewhereBadge(tabId: tabId)
        }
        refreshOtherConnections()
        publishSessionState()
    }

    func paneDidAttach(terminalId: String, tabId: String?) {
        if paneControlStates.removeValue(forKey: terminalId) != nil {
            paneViews[terminalId]?.updateHerdrPaneControlOverlay()
        }
        guard let tabId else { return }
        let stillWaiting = paneInfos.values.contains {
            $0.tab_id == tabId && attachIds[$0.terminal_id] == nil && paneSessions[$0.terminal_id] != nil
        }
        if !stillWaiting { takeoverRequested.remove(tabId) }
        syncControlledElsewhereBadge(tabId: tabId)
    }

    func clearPaneControlStates() {
        let affected = paneControlStates.keys
        paneControlStates.removeAll()
        for terminalId in affected { paneViews[terminalId]?.updateHerdrPaneControlOverlay() }
        for tab in tabs.values where tab.herdrIsControlledElsewhere { tab.herdrIsControlledElsewhere = false }
    }

    private func presentTakeControlPrompt(tabId: String) {
        guard !takeControlPromptedTabs.contains(tabId), let tab = tabs[tabId] else { return }
        takeControlPromptedTabs.insert(tabId)
        let request = MainAlertController.HerdrTakeControlRequest(
            gatewayUUID: gatewayUUID, tabId: tabId, tabTitle: tab.title,
            evictsOtherClient: !capabilities.supportsSharedViewing
        )
        NotificationCenter.default.post(
            name: .herdrTakeControlRequested, object: gatewayUUID,
            userInfo: ["request": request, "windowId": hostWindowId]
        )
    }

    /// User asked for the tab. Sharing servers just need our geometry; older
    /// ones need the attaches re-issued with takeover.
    func requestTakeControl(tabId: String) {
        guard !didEnd, mode == .raw, tabs[tabId] != nil else { return }
        Self.logger.info("herdr take control \(tabId) shared=\(self.capabilities.supportsSharedViewing)")
        if capabilities.supportsSharedViewing {
            claimGeometry(tabId: tabId)
        } else {
            // The other client resized the tab under us; our old confirmation
            // would otherwise keep every attach waiting for a matching layout.
            tabGeometryStates[tabId]?.invalidate()
            geometryTasks.removeValue(forKey: tabId)?.cancel()
            if let tab = tabs[tabId], let view = tab.splitTree.terminalLeaves.first(where: { $0.isHerdrPane }) {
                scheduleGeometryPush(from: view)
            }
        }
        let waiting = paneInfos.values.filter { $0.tab_id == tabId && paneControlStates[$0.terminal_id] != nil }
        guard !waiting.isEmpty else { return }
        takeoverRequested.insert(tabId)
        takeControlPromptedTabs.remove(tabId)
        for pane in waiting {
            paneControlStates.removeValue(forKey: pane.terminal_id)
            paneViews[pane.terminal_id]?.updateHerdrPaneControlOverlay()
            enqueueAttach(pane.terminal_id, front: isVisible(terminalId: pane.terminal_id))
        }
        pumpAttachQueue()
    }

    private func syncControlledElsewhereBadge(tabId: String) {
        guard let tab = tabs[tabId] else { return }
        let flag = tabIsControlledElsewhere(tab)
        if tab.herdrIsControlledElsewhere != flag { tab.herdrIsControlledElsewhere = flag }
    }
}
