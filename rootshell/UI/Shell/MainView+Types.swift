//
//  MainView+Types.swift
//  rootshell
//
//  Nested types for MainView, extracted for build parallelization.
//
//  The previous `TerminalTab` value-type struct has been replaced by the
//  `TabModel` class defined in `TabsModel.swift` (with a `TerminalTab`
//  typealias for source compat). The change moves per-tab state from a
//  SwiftUI `@State` array — where any per-tab mutation invalidated all of
//  `MainView`'s body — to a per-tab `@Observable` class so SwiftUI tracks
//  reads at property granularity.
//

import SwiftUI
import Combine
import GhosttyKit

// MARK: - MainView Nested Types

extension MainView {

    // MARK: - Roam Protocol

    /// Protocol type for Roam connections (mosh/trzsz)
    enum RoamProtocol: Sendable {
        case none
        case mosh
        case trzsz
    }

    // MARK: - Validation Data

    /// Data for SSH host key validation alerts
    struct ValidationData {
        let alertTitle: String
        let message: String // Pre-formatted message to avoid Text concatenation
        let isKeyChanged: Bool
    }

    struct AppTabSwipeState: Equatable {
        let sourceTabID: UUID
        let targetTabID: UUID
        let direction: SwipeDirection
        /// Bottom space occupied by the source tab's keyboard toolbar when the
        /// swipe began. Both sliding tabs use this snapshot so the incoming tab
        /// cannot reveal a taller viewport simply because it is not yet first
        /// responder. Kept through settling so the focus handoff cannot resize
        /// either tab in the middle of the animation.
        let reservedBottomToolbarHeight: CGFloat
        var translationX: CGFloat
        var width: CGFloat
        var isSettling: Bool = false
        /// `CACurrentMediaTime()` of the last began/changed/ended event that
        /// touched this state. Staleness signal for the wedge heals: a state
        /// that stops receiving events without ever settling is an abandoned
        /// swipe (its Ended notification was lost) and must be force-cleared,
        /// or every tab except its source renders at opacity 0 forever.
        var lastEventAt: TimeInterval = 0

        var clampedTranslationX: CGFloat {
            let limit = max(width, 1)
            switch direction {
            case .left:
                return min(0, max(-limit, translationX))
            case .right:
                return max(0, min(limit, translationX))
            }
        }

        var targetEntryOffset: CGFloat {
            direction == .left ? width : -width
        }

        /// Returns the shared toolbar reservation for either tab participating
        /// in this swipe. Other tabs fall back to their normal live layout.
        func reservedBottomToolbarHeight(for tabID: UUID) -> CGFloat? {
            guard tabID == sourceTabID || tabID == targetTabID else { return nil }
            return reservedBottomToolbarHeight
        }
    }

    /// Storage behind `appTabSwipeState`, split so MainView.body observes only
    /// `phase`; the per-frame translation is read by AppTabSwipeOffsetModifier.
    @MainActor @Observable final class AppTabSwipeModel {
        struct Phase: Equatable {
            let sourceTabID: UUID
            let targetTabID: UUID
            let direction: SwipeDirection
            let reservedBottomToolbarHeight: CGFloat
            let isSettling: Bool

            func reservedBottomToolbarHeight(for tabID: UUID) -> CGFloat? {
                guard tabID == sourceTabID || tabID == targetTabID else { return nil }
                return reservedBottomToolbarHeight
            }
        }

        private(set) var phase: Phase?
        private(set) var translationX: CGFloat = 0
        private(set) var width: CGFloat = 1
        @ObservationIgnored private var lastEventAt: TimeInterval = 0

        /// The whole state, for handlers. Reads every field, so body code must use `phase`.
        var state: AppTabSwipeState? {
            get {
                guard let phase else { return nil }
                return AppTabSwipeState(
                    sourceTabID: phase.sourceTabID,
                    targetTabID: phase.targetTabID,
                    direction: phase.direction,
                    reservedBottomToolbarHeight: phase.reservedBottomToolbarHeight,
                    translationX: translationX,
                    width: width,
                    isSettling: phase.isSettling,
                    lastEventAt: lastEventAt
                )
            }
            set {
                guard let newValue else {
                    if phase != nil { phase = nil }
                    return
                }
                let newPhase = Phase(
                    sourceTabID: newValue.sourceTabID,
                    targetTabID: newValue.targetTabID,
                    direction: newValue.direction,
                    reservedBottomToolbarHeight: newValue.reservedBottomToolbarHeight,
                    isSettling: newValue.isSettling
                )
                if phase != newPhase { phase = newPhase }
                if translationX != newValue.translationX { translationX = newValue.translationX }
                if width != newValue.width { width = newValue.width }
                lastEventAt = newValue.lastEventAt
            }
        }
    }

    /// A tab's part in an in-flight app-tab swipe.
    enum AppTabSwipeRole {
        case source
        case target
        case none
    }

    /// Applies the swipe's horizontal slide. Only tabs taking part read the
    /// live translation, so a pan frame invalidates just these modifiers.
    struct AppTabSwipeOffsetModifier: ViewModifier {
        let swipe: AppTabSwipeModel
        let role: AppTabSwipeRole
        let width: CGFloat

        func body(content: Content) -> some View {
            content.offset(x: offsetX)
        }

        private var offsetX: CGFloat {
            guard role != .none, let phase = swipe.phase else { return 0 }
            let effectiveWidth = max(max(width, swipe.width), 1)
            let translation: CGFloat = switch phase.direction {
            case .left:
                min(0, max(-effectiveWidth, swipe.translationX))
            case .right:
                max(0, min(effectiveWidth, swipe.translationX))
            }
            guard role == .target else { return translation }
            return translation + (phase.direction == .left ? effectiveWidth : -effectiveWidth)
        }
    }

    // MARK: - Tab Drop Delegate

    /// Handles drag-and-drop reordering of tabs.
    ///
    /// Refactored to hold a reference to the `TabsModel` (an `@Observable`
    /// class) instead of taking `@Binding`s into a SwiftUI `@State` array.
    /// All reorder mutations go through the model directly, so per-tab views
    /// observing individual `TabModel` properties don't get invalidated by
    /// drop reorders that don't touch their data.
    struct TabDropDelegate: DropDelegate {
        let item: TerminalTab
        let tabsModel: TabsModel

        @MainActor
        func dropEntered(info: DropInfo) {
            if TabTransferCoordinator.shared.canAcceptActiveDrag(in: item.windowId) {
                return
            }
            guard let draggingID = tabsModel.draggingTabID,
                  draggingID != item.id,
                  tabsModel.tab(withID: draggingID) != nil
            else {
                return
            }

            let selectedID = tabsModel.selectedTabID ?? draggingID
            _ = tabsModel.moveTabInActiveOrder(movingID: draggingID, toTargetID: item.id)
            if tabsModel.tabs.contains(where: { $0.id == selectedID }) {
                tabsModel.selectedTabID = selectedID
            }
        }

        @MainActor
        func performDrop(info: DropInfo) -> Bool {
            if TabTransferCoordinator.shared.canAcceptActiveDrag(in: item.windowId) {
                let insertionIndex = tabsModel.index(of: item.id)
                let group = tabsModel.isGroupedModeEnabled ? tabsModel.effectiveGroupID(for: item) : nil
                return TabTransferCoordinator.shared.receiveActiveDrag(
                    in: item.windowId,
                    insertionIndex: insertionIndex,
                    groupOverride: group,
                    isDestinationWindowFocused: true
                )
            }
            // The incremental dropEntered moves above are local-only; commit
            // a dragged multiplexer tab's final position to the server once,
            // at drop time (user gesture, never reconcile-driven).
            if !tabsModel.isProjectGroupingActive,
               let draggingID = tabsModel.draggingTabID,
               let draggedTab = tabsModel.tabs.first(where: { $0.id == draggingID }) {
                TmuxController.syncWindowOrderAfterUserMove(of: draggedTab, in: tabsModel.tabs)
                HerdrController.syncTabOrderAfterUserMove(of: draggedTab, in: tabsModel)
            }
            tabsModel.draggingTabID = nil
            TabTransferCoordinator.shared.clearDrag()
            return true
        }

        func dropUpdated(info: DropInfo) -> DropProposal? {
            DropProposal(operation: .move)
        }

        func dropExited(info: DropInfo) {
            // Don't clear draggingTabID here - it might be entering another tab
            // The drag session ending will be handled by performDrop or validateDrop
        }

        @MainActor
        func validateDrop(info: DropInfo) -> Bool {
            if TabTransferCoordinator.shared.canAcceptActiveDrag(in: item.windowId) {
                return true
            }
            // If validation fails, clear the dragging state
            if tabsModel.draggingTabID == nil {
                return false
            }
            return true
        }
    }
}
