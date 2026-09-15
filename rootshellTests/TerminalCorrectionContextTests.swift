import Foundation
import XCTest

final class TerminalCorrectionContextTests: XCTestCase {
    private typealias Context = TerminalCorrectionContext

    private func bytes(_ replacement: Context.Replacement?) -> [UInt8]? {
        replacement.map { Array($0.payload) }
    }

    private func region(_ context: Context) -> NSRange? { context.dictationRegion }

    // MARK: Session lifecycle

    func testBeganRecordsRegionStartAndRevokesQuickType() {
        var context = Context()
        context.apply(.text("ls ", eligible: true))
        XCTAssertEqual(context.eligibleUTF16Count, 3)
        context.apply(.dictationBegan)
        XCTAssertEqual(context.dictation?.phase, .receiving)
        XCTAssertEqual(context.dictation?.regionStart, 3)
        XCTAssertEqual(context.eligibleUTF16Count, 0)
        XCTAssertEqual(region(context), NSRange(location: 3, length: 0))
    }

    func testDictationTextOpensAndExtends() {
        var context = Context()
        context.apply(.dictationText("git status"))
        let id = context.dictation?.id
        XCTAssertNotNil(id)
        XCTAssertEqual(context.document, "git status")
        XCTAssertEqual(region(context), NSRange(location: 0, length: 10))
        context.apply(.text("x", eligible: true))
        XCTAssertEqual(context.dictation?.id, id)
        XCTAssertEqual(context.eligibleUTF16Count, 0)
        XCTAssertEqual(region(context), NSRange(location: 0, length: 11))
    }

    func testSettlingMultiCharExtendsAndSingleCharCloses() {
        var context = Context()
        context.apply(.dictationText("make"))
        context.apply(.dictationSettling)
        XCTAssertEqual(context.dictation?.phase, .settling)
        XCTAssertFalse(context.plainTextClosesDictation("hello "))
        context.apply(.text("hello ", eligible: true))
        XCTAssertNotNil(context.dictation)
        XCTAssertEqual(region(context), NSRange(location: 0, length: 10))
        XCTAssertTrue(context.plainTextClosesDictation("h"))
        let identity = context.documentGeneration
        context.apply(.text("h", eligible: true))
        XCTAssertNil(context.dictation)
        XCTAssertNotEqual(context.documentGeneration, identity)
        XCTAssertEqual(context.eligibleUTF16Count, 1)
        XCTAssertEqual(context.document, "makehello h")
    }

    func testReceivingSingleCharDoesNotClose() {
        var context = Context()
        context.apply(.dictationBegan)
        XCTAssertFalse(context.plainTextClosesDictation("a"))
        context.apply(.text("a", eligible: true))
        XCTAssertEqual(context.dictation?.phase, .receiving)
        XCTAssertEqual(context.eligibleUTF16Count, 0)
    }

    func testBeganWhileSettlingRearmsAndKeepsRegion() {
        var context = Context()
        context.apply(.text("cd ", eligible: false))
        context.apply(.dictationText("docs"))
        let id = context.dictation?.id
        context.apply(.dictationSettling)
        context.apply(.dictationBegan)
        XCTAssertEqual(context.dictation?.id, id)
        XCTAssertEqual(context.dictation?.phase, .receiving)
        XCTAssertEqual(context.dictation?.regionStart, 3)
    }

    func testEndedBumpsIdentityAndSubsequentBeganMintsNewID() {
        var context = Context()
        context.apply(.dictationText("one"))
        let first = context.dictation?.id
        let identity = context.documentGeneration
        context.apply(.dictationEnded)
        XCTAssertNil(context.dictation)
        XCTAssertNotEqual(context.documentGeneration, identity)
        context.apply(.dictationEnded)
        context.apply(.dictationBegan)
        XCTAssertNotEqual(context.dictation?.id, first)
        XCTAssertEqual(context.dictation?.regionStart, 3)
    }

    // MARK: Replacement

    func testReplacementWithinRegion() {
        var context = Context()
        context.apply(.text("cd ", eligible: false))
        context.apply(.dictationText("docs"))
        let id = context.dictation!.id
        let replacement = context.dictationReplacement(in: NSRange(location: 3, length: 4), with: "Docs", session: id)
        XCTAssertEqual(bytes(replacement), [0x7F, 0x7F, 0x7F, 0x7F] + Array("Docs".utf8))
        XCTAssertEqual(replacement?.dictationID, id)
        XCTAssertTrue(context.apply(.correction(replacement!)))
        XCTAssertEqual(context.document, "cd Docs")
        XCTAssertEqual(context.dictation?.id, id)
        XCTAssertEqual(region(context), NSRange(location: 3, length: 4))
        XCTAssertEqual(context.eligibleUTF16Count, 0)
    }

    func testReplacementConvertsNewlineAndReplaysSuffix() {
        var context = Context()
        context.apply(.dictationText("echo hi there"))
        let id = context.dictation!.id
        let replacement = context.dictationReplacement(in: NSRange(location: 5, length: 2), with: "bye\n", session: id)
        XCTAssertEqual(bytes(replacement), Array(repeating: 0x7F, count: 8) + Array("bye\r there".utf8))
        XCTAssertEqual(replacement?.document, "echo bye\n there")
    }

    func testReplacementOutsideRegionRefused() {
        var context = Context()
        context.apply(.text("cd ", eligible: false))
        context.apply(.dictationText("docs"))
        let id = context.dictation!.id
        XCTAssertNil(context.dictationReplacement(in: NSRange(location: 0, length: 7), with: "x", session: id))
        XCTAssertNil(context.dictationReplacement(in: NSRange(location: 2, length: 5), with: "x", session: id))
        XCTAssertNil(context.dictationReplacement(in: NSRange(location: 3, length: 5), with: "x", session: id))
        XCTAssertNotNil(context.dictationReplacement(in: NSRange(location: 3, length: 0), with: "x", session: id))
        XCTAssertNotNil(context.dictationReplacement(in: NSRange(location: 7, length: 0), with: "!", session: id))
    }

    func testStaleSessionRefused() {
        var context = Context()
        context.apply(.dictationText("docs"))
        let old = context.dictation!.id
        context.apply(.dictationEnded)
        XCTAssertNil(context.dictationReplacement(in: NSRange(location: 0, length: 4), with: "x", session: old))
        context.apply(.dictationBegan)
        XCTAssertNil(context.dictationReplacement(in: NSRange(location: 0, length: 4), with: "x", session: old))
        XCTAssertNil(context.dictationReplacement(in: NSRange(location: 0, length: 4), with: "x", session: context.dictation!.id))
    }

    func testReplacementBuiltBeforeBackspaceFailsCommit() {
        var context = Context()
        context.apply(.dictationText("docs"))
        let id = context.dictation!.id
        let replacement = context.dictationReplacement(in: NSRange(location: 0, length: 4), with: "Docs", session: id)!
        context.apply(.backspace(eligible: false))
        XCTAssertFalse(context.apply(.correction(replacement)))
        XCTAssertEqual(context.document, "doc")
    }

    func testReplacementBuiltBeforeEndFailsCommit() {
        var context = Context()
        context.apply(.dictationText("docs"))
        let id = context.dictation!.id
        let replacement = context.dictationReplacement(in: NSRange(location: 0, length: 4), with: "Docs", session: id)!
        context.apply(.dictationEnded)
        XCTAssertFalse(context.apply(.correction(replacement)))
    }

    func testQuickTypeReplacementUnaffectedWithoutSession() {
        var context = Context()
        context.apply(.text("teh ", eligible: true))
        let replacement = context.replacement(in: NSRange(location: 0, length: 3), with: "the", generation: context.generation)
        XCTAssertEqual(bytes(replacement), [0x7F, 0x7F, 0x7F, 0x7F] + Array("the ".utf8))
        XCTAssertNil(replacement?.dictationID)
        XCTAssertTrue(context.apply(.correction(replacement!)))
        XCTAssertEqual(context.document, "the ")
        XCTAssertEqual(context.eligibleUTF16Count, 4)
    }

    func testQuickTypeReplacementRefusedWhileSessionOpen() {
        var context = Context()
        context.apply(.text("teh ", eligible: true))
        let generation = context.generation
        context.apply(.dictationBegan)
        XCTAssertNil(context.replacement(in: NSRange(location: 0, length: 3), with: "the", generation: generation))
    }

    // MARK: Boundaries

    func testNewlineResetAndLegacyClose() {
        for mutation in [Context.Mutation.text("\r", eligible: false), .text("\n", eligible: false),
                         .dictationText("\n"), .reset, .legacyDocument("x")] {
            var context = Context()
            context.apply(.dictationText("make"))
            context.apply(mutation)
            XCTAssertNil(context.dictation)
        }
        var context = Context()
        context.apply(.dictationText("make"))
        context.apply(.invalidate)
        XCTAssertNotNil(context.dictation)
        context.apply(.text("\r", eligible: false))
        XCTAssertEqual(context.document, "")
    }

    func testNonPrintableCloses() {
        var context = Context()
        context.apply(.dictationText("make"))
        XCTAssertTrue(context.plainTextClosesDictation("\t"))
        context.apply(.text("\t", eligible: false))
        XCTAssertNil(context.dictation)
        XCTAssertEqual(context.document, "make\t")
    }

    func testBackspaceShrinksRegionAndClosesWhenCrossingStart() {
        var context = Context()
        context.apply(.text("ab", eligible: false))
        context.apply(.dictationBegan)
        context.apply(.dictationText("cd"))
        context.apply(.backspace(eligible: false))
        XCTAssertEqual(region(context), NSRange(location: 2, length: 1))
        context.apply(.backspace(eligible: false))
        XCTAssertEqual(region(context), NSRange(location: 2, length: 0))
        XCTAssertNotNil(context.dictation)
        context.apply(.backspace(eligible: false))
        XCTAssertNil(context.dictation)
        XCTAssertEqual(context.document, "a")
    }

    func testKoreanCommitBeforeOpenLiesOutsideRegion() {
        var context = Context()
        context.apply(.text("한", eligible: false))
        context.apply(.dictationBegan)
        let id = context.dictation!.id
        XCTAssertEqual(context.dictation?.regionStart, 1)
        XCTAssertNil(context.dictationReplacement(in: NSRange(location: 0, length: 1), with: "x", session: id))
        XCTAssertNotNil(context.dictationReplacement(in: NSRange(location: 1, length: 0), with: "x", session: id))
    }

    // MARK: Signal-free adoption (iPadOS live dictation)

    func testAdoptionOpensSessionAtRecentInsert() {
        var context = Context()
        context.apply(.text(" ddd d ", eligible: false))
        context.apply(.text("h", eligible: true))
        XCTAssertEqual(context.recentEditRange, NSRange(location: 7, length: 1))
        XCTAssertTrue(context.canAdoptDictation(in: NSRange(location: 7, length: 1)))
        XCTAssertFalse(context.canAdoptDictation(in: NSRange(location: 6, length: 2)))
        XCTAssertFalse(context.canAdoptDictation(in: NSRange(location: 7, length: 2)))
        XCTAssertFalse(context.canAdoptDictation(in: NSRange(location: 7, length: 0)))
        XCTAssertTrue(context.apply(.dictationAdopt(NSRange(location: 7, length: 1))))
        XCTAssertEqual(context.dictation?.regionStart, 7)
        XCTAssertEqual(context.eligibleUTF16Count, 0)
        let id = context.dictation!.id
        let replacement = context.dictationReplacement(in: NSRange(location: 7, length: 1), with: "hel", session: id)
        XCTAssertEqual(bytes(replacement), [0x7F] + Array("hel".utf8))
        XCTAssertTrue(context.apply(.correction(replacement!)))
        XCTAssertEqual(context.document, " ddd d hel")
        XCTAssertEqual(context.recentEditRange, NSRange(location: 7, length: 3))
    }

    func testAdoptionChainsThroughCorrectionsAndInserts() {
        var context = Context()
        context.apply(.text("h", eligible: true))
        context.apply(.dictationAdopt(NSRange(location: 0, length: 1)))
        let id = context.dictation!.id
        context.apply(.correction(context.dictationReplacement(in: NSRange(location: 0, length: 1), with: "hel", session: id)!))
        context.apply(.dictationSettling)
        context.apply(.text(" h", eligible: true))
        XCTAssertEqual(context.dictation?.id, id)
        XCTAssertEqual(context.recentEditRange, NSRange(location: 3, length: 2))
        XCTAssertNotNil(context.dictationReplacement(in: NSRange(location: 3, length: 2), with: " hel", session: id))
    }

    func testAdoptionRefusedAfterOtherEditsOrWithOpenSession() {
        var context = Context()
        context.apply(.text("h", eligible: true))
        context.apply(.backspace(eligible: true))
        XCTAssertNil(context.recentEditRange)
        XCTAssertFalse(context.apply(.dictationAdopt(NSRange(location: 0, length: 0))))
        context.apply(.text("hi", eligible: true))
        context.apply(.invalidate)
        XCTAssertEqual(context.recentEditRange, NSRange(location: 0, length: 2))
        context.apply(.dictationBegan)
        XCTAssertFalse(context.canAdoptDictation(in: NSRange(location: 0, length: 2)))
        context.apply(.dictationEnded)
        XCTAssertNil(context.recentEditRange)
    }

    func testEndedWithoutSessionRevokesAdoptionCandidate() {
        var context = Context()
        context.apply(.text("i", eligible: true))
        XCTAssertTrue(context.canAdoptDictation(in: NSRange(location: 0, length: 1)))
        let identity = context.documentGeneration
        context.apply(.dictationEnded)
        XCTAssertNil(context.recentEditRange)
        XCTAssertFalse(context.canAdoptDictation(in: NSRange(location: 0, length: 1)))
        XCTAssertEqual(context.documentGeneration, identity)
    }

    func testAdoptionRefusesMultiScalarOrNonPrintableErase() {
        var context = Context()
        context.apply(.text("👨‍👩‍👧", eligible: false))
        XCTAssertFalse(context.canAdoptDictation(in: NSRange(location: 0, length: context.document.utf16.count)))
        var tab = Context()
        tab.apply(.text("a\t", eligible: false))
        XCTAssertNil(tab.recentEditRange)
        var long = Context()
        long.apply(.text(String(repeating: "word ", count: 20), eligible: false))
        XCTAssertTrue(long.canAdoptDictation(in: NSRange(location: 0, length: 100)))
    }

    func testQuickTypeCorrectionAlsoRecordsRecentEdit() {
        var context = Context()
        context.apply(.text("teh ", eligible: true))
        let replacement = context.replacement(in: NSRange(location: 0, length: 3), with: "the", generation: context.generation)!
        XCTAssertEqual(replacement.replayRange, NSRange(location: 0, length: 4))
        context.apply(.correction(replacement))
        XCTAssertEqual(context.recentEditRange, NSRange(location: 0, length: 4))
    }

    func testTruncationCloses() {
        var context = Context()
        context.apply(.dictationText(String(repeating: "a", count: 4097)))
        XCTAssertNil(context.dictation)
        XCTAssertEqual(context.document.utf16.count, 2048)
    }
}
