import XCTest

final class MenuKeyEquivalentPolicyTests: XCTestCase {
    private func releases(_ itemAction: String?, owners: [String],
                          leadsSequence: Bool = false, isRecording: Bool = false) -> Bool {
        MenuKeyEquivalentPolicy.releasesKeyEquivalent(
            itemAction: itemAction, owners: owners,
            leadsSequence: leadsSequence, isRecording: isRecording)
    }

    func testUnboundChordStaysWithMenuItem() {
        // Cmd-Q, Cmd-H, Cmd-M have no default binding: Quit/Hide/Minimize keep them.
        XCTAssertFalse(releases(nil, owners: []))
        XCTAssertFalse(releases("copy_to_clipboard", owners: []))
    }

    func testAnyBindingClaimsChordFromItemWithoutEquivalent() {
        // keybind = cmd+q=text:\x1Bq
        XCTAssertTrue(releases(nil, owners: ["text"]))
        // A rootshell action bound to Cmd-H (e.g. close_tab) also wins over Hide.
        XCTAssertTrue(releases(nil, owners: ["close_tab"]))
    }

    func testEditItemKeepsChordWhileBoundToItsOwnAction() {
        let copy = MenuKeyEquivalentPolicy.editItemActions["copy:"]
        let paste = MenuKeyEquivalentPolicy.editItemActions["paste:"]
        let selectAll = MenuKeyEquivalentPolicy.editItemActions["selectAll:"]
        // Default Cmd-C / Cmd-V / Cmd-A bindings.
        XCTAssertFalse(releases(copy, owners: ["copy_to_clipboard"]))
        XCTAssertFalse(releases(paste, owners: ["paste_from_clipboard"]))
        XCTAssertFalse(releases(selectAll, owners: ["select_all"]))
    }

    func testEditItemReleasesChordRemappedToAnotherAction() {
        let paste = MenuKeyEquivalentPolicy.editItemActions["paste:"]
        // keybind = cmd+v=text:\x1Bv
        XCTAssertTrue(releases(paste, owners: ["text"]))
        // Cut, Undo, and friends have no rootshell equivalent.
        XCTAssertNil(MenuKeyEquivalentPolicy.editItemActions["cut:"])
        XCTAssertTrue(releases(nil, owners: ["text"]))
    }

    func testSequenceLeaderClaimsChordEvenForTheSameAction() {
        let copy = MenuKeyEquivalentPolicy.editItemActions["copy:"]
        // cmd+c>x=copy_to_clipboard: the menu would fire on the bare leader.
        XCTAssertTrue(releases(copy, owners: ["copy_to_clipboard"], leadsSequence: true))
    }

    func testRecordingReleasesEveryChord() {
        XCTAssertTrue(releases(nil, owners: [], isRecording: true))
        let copy = MenuKeyEquivalentPolicy.editItemActions["copy:"]
        XCTAssertTrue(releases(copy, owners: ["copy_to_clipboard"], isRecording: true))
    }

    private func resolution(_ selector: String, owners: [String]) -> MenuKeyEquivalentPolicy.Resolution {
        MenuKeyEquivalentPolicy.resolution(
            selector: selector, owners: owners, leadsSequence: false, isRecording: false)
    }

    func testClaimedStockItemReleasesItsKeyEquivalent() {
        // keybind = cmd+q=text:\x1Bq
        XCTAssertEqual(resolution("terminate:", owners: ["text"]), .releaseKeyEquivalent)
        XCTAssertEqual(resolution("hide:", owners: ["text"]), .releaseKeyEquivalent)
        XCTAssertEqual(resolution("terminate:", owners: []), .keep)
    }

    func testEditItemResolutionUsesItsOwnAction() {
        XCTAssertEqual(resolution("paste:", owners: ["paste_from_clipboard"]), .keep)
        XCTAssertEqual(resolution("paste:", owners: ["text"]), .releaseKeyEquivalent)
    }

    func testClaimedMinimizeIsRemovedBecauseAppKitRestoresCommandM() {
        // keybind = cmd+m=text:\x1Bm — a keyless Minimize still gets Cmd-M back.
        XCTAssertEqual(resolution("performMiniaturize:", owners: ["text"]), .remove)
        XCTAssertEqual(resolution("performMiniaturize:", owners: []), .keep)
    }

    func testEditItemActionsOnlyCoverHandledEditSelectors() {
        XCTAssertTrue(Set(MenuKeyEquivalentPolicy.editItemActions.keys)
            .isSubset(of: MenuKeyEquivalentPolicy.editSelectors))
    }
}
