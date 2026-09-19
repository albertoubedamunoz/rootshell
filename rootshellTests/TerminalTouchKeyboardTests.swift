import CoreGraphics
import XCTest
#if canImport(UIKit)
import UIKit
#endif

final class TerminalTouchKeyboardTests: XCTestCase {
    private typealias Model = TerminalTouchKeyboardModel

    private final class KeyboardState {
        var presentation = Model.PresentationState()
    }

    func testKeyboardStateIsSharedAcrossTabsByDefault() {
        var store = Model.StateStore<KeyboardState>()
        let first = store.state(tabID: UUID(), perTab: false) { KeyboardState() }
        first.presentation.toolPage = .shortcuts
        first.presentation.preset = .vim
        first.presentation.toolbarDrawer = .stacked(2)
        let second = store.state(tabID: UUID(), perTab: false) { KeyboardState() }
        XCTAssertTrue(first === second)
        XCTAssertEqual(second.presentation.toolPage, .shortcuts)
        XCTAssertEqual(second.presentation.preset, .vim)
        XCTAssertEqual(second.presentation.toolbarDrawer, .stacked(2))
    }

    func testSeparateKeyboardStateFollowsTabsRatherThanPanes() {
        var store = Model.StateStore<KeyboardState>()
        let tab = UUID()
        let firstPane = store.state(tabID: tab, perTab: true) { KeyboardState() }
        firstPane.presentation.page = .symbols
        firstPane.presentation.toolPage = .navigation
        let otherTab = store.state(tabID: UUID(), perTab: true) { KeyboardState() }
        XCTAssertFalse(firstPane === otherTab)
        XCTAssertEqual(otherTab.presentation.page, .letters)
        XCTAssertEqual(otherTab.presentation.toolPage, .typing)
        let secondPane = store.state(tabID: tab, perTab: true) { KeyboardState() }
        XCTAssertTrue(firstPane === secondPane)
        XCTAssertEqual(secondPane.presentation.page, .symbols)
    }

    func testKeyboardStateDoesNotCrossWindows() {
        var firstWindow = Model.StateStore<KeyboardState>()
        var secondWindow = Model.StateStore<KeyboardState>()
        let first = firstWindow.state(tabID: nil, perTab: false) { KeyboardState() }
        first.presentation.preset = .emacs
        let second = secondWindow.state(tabID: nil, perTab: false) { KeyboardState() }
        XCTAssertFalse(first === second)
        XCTAssertEqual(second.presentation.preset, .shell)
    }

    func testChangingStateScopeKeepsLastDisplayedChoices() {
        var store = Model.StateStore<KeyboardState>()
        let firstTab = UUID(), secondTab = UUID()
        func copy(_ source: KeyboardState, _ destination: KeyboardState) {
            destination.presentation = source.presentation
        }
        let shared = store.activate(tabID: firstTab, perTab: false, make: { KeyboardState() }, copyChoices: copy)
        shared.presentation.preset = .vim
        let first = store.activate(tabID: firstTab, perTab: true, make: { KeyboardState() }, copyChoices: copy)
        XCTAssertFalse(first === shared)
        XCTAssertEqual(first.presentation.preset, .vim)
        let second = store.activate(tabID: secondTab, perTab: true, make: { KeyboardState() }, copyChoices: copy)
        XCTAssertEqual(second.presentation.preset, .shell)
        second.presentation.preset = .nano
        let merged = store.activate(tabID: secondTab, perTab: false, make: { KeyboardState() }, copyChoices: copy)
        XCTAssertTrue(merged === shared)
        XCTAssertEqual(merged.presentation.preset, .nano)
        XCTAssertEqual(first.presentation.preset, .vim)
    }

    func testTabHandoffPreservesStickyModifiersAndScrollButReleasesHeldKeys() {
        var state = Model.PresentationState()
        state.modifiers.begin(.control)
        state.modifiers.end(.control, at: 1)
        state.modifiers.begin(.shift)
        state.modifiers.end(.shift, at: 2)
        state.modifiers.begin(.shift)
        state.modifiers.end(.shift, at: 2.2)
        state.modifiers.begin(.alt)
        state.drawerOffset = CGPoint(x: 0, y: 120)
        state.toolbarOffsets = [0: CGPoint(x: 80, y: 0)]
        let saved = state.suspendingInput()
        XCTAssertTrue(saved.modifiers.oneShot.contains(.control))
        XCTAssertTrue(saved.modifiers.locked.contains(.shift))
        XCTAssertFalse(saved.modifiers.isActive(.alt))
        XCTAssertEqual(saved.drawerOffset, state.drawerOffset)
        XCTAssertEqual(saved.toolbarOffsets, state.toolbarOffsets)
        XCTAssertTrue(state.modifiers.isActive(.alt), "Saving must not mutate the outgoing value")
    }

    private func geometry(width: Double = 390, page: Model.Page = .letters, typingTop: Double = 0) -> Model.TypingGeometry {
        let targets = Model.rows(page: page).enumerated().flatMap { index, row in
            let frames = Model.frames(keys: row, width: width, y: typingTop + Double(index) * 54, height: 54,
                inset: page == .letters && index == 1 ? width / 20 + 2 : 2)
            return zip(row, frames).map { Model.HitTarget(key: $0.0, frame: $0.1) }
        }
        return .init(targets: targets, bounds: CGRect(x: 0, y: typingTop, width: width, height: 216))
    }

    func testSmallDriftAcrossLetterBoundaryKeepsOriginalSelectionAtRelease() {
        let g = geometry()
        let point = CGPoint(x: g.targets[0].frame.maxX - 1, y: 27)
        var contact = Model.TouchSelection(point: point, selected: 0, modifiers: 0)
        let end = CGPoint(x: point.x + 8, y: point.y + 8)
        XCTAssertFalse(contact.move(to: end, in: g, dockedPad: false))
        XCTAssertEqual(g.hit(at: end), 1)
        XCTAssertEqual(contact.finish(at: end, in: g, dockedPad: false), 0)
        XCTAssertNil(contact.finish(at: end, in: g, dockedPad: false))
    }

    func testSlideThresholdsUseLargestAxisAndResetAnchor() {
        let g = geometry()
        let point = CGPoint(x: g.targets[0].frame.maxX - 1, y: 27)
        var contact = Model.TouchSelection(point: point, selected: 0, modifiers: 0)
        XCTAssertFalse(contact.move(to: CGPoint(x: point.x + 17.9, y: point.y + 17.9), in: g, dockedPad: false))
        let slide = CGPoint(x: point.x + 18, y: point.y)
        XCTAssertTrue(contact.move(to: slide, in: g, dockedPad: false))
        XCTAssertEqual(contact.selected, 1)
        XCTAssertEqual(contact.anchor, slide)
        XCTAssertFalse(contact.move(to: CGPoint(x: slide.x + 11.9, y: slide.y), in: g, dockedPad: false))
        XCTAssertTrue(contact.move(to: CGPoint(x: slide.x + 12, y: slide.y), in: g, dockedPad: false))
    }

    func testFinalReleaseCanCompleteAnIntentionalSlide() {
        let g = geometry()
        var contact = Model.TouchSelection(point: CGPoint(x: 20, y: 27), selected: 0, modifiers: 8)
        XCTAssertEqual(contact.finish(at: CGPoint(x: 60, y: 27), in: g, dockedPad: false), 1)
        XCTAssertTrue(contact.dragged)
        XCTAssertEqual(contact.modifiers, 8)
    }

    func testDockedTabletUsesLargerSlideThresholds() {
        let g = geometry(width: 1024)
        var contact = Model.TouchSelection(point: CGPoint(x: 20, y: 27), selected: 0, modifiers: 0)
        XCTAssertFalse(contact.move(to: CGPoint(x: 61.9, y: 27), in: g, dockedPad: true))
        XCTAssertTrue(contact.move(to: CGPoint(x: 62, y: 27), in: g, dockedPad: true))
        XCTAssertFalse(contact.move(to: CGPoint(x: 95.9, y: 27), in: g, dockedPad: true))
        XCTAssertTrue(contact.move(to: CGPoint(x: 96, y: 27), in: g, dockedPad: true))
    }

    func testReleaseOutsideTypingAreaOrOnActionDoesNotEmitText() {
        let g = geometry()
        for end in [CGPoint(x: -1, y: 27), CGPoint(x: 20, y: -1), CGPoint(x: 20, y: 217),
                    CGPoint(x: 10, y: 135), CGPoint(x: 380, y: 135), CGPoint(x: 380, y: 189)] {
            var contact = Model.TouchSelection(point: CGPoint(x: 20, y: 27), selected: 0, modifiers: 0)
            XCTAssertNil(contact.finish(at: end, in: g, dockedPad: false))
            XCTAssertTrue(contact.consumed)
        }
    }

    func testCancelledAndEarlyCommittedContactsCannotEmitAgain() {
        let g = geometry()
        var first = Model.TouchSelection(point: CGPoint(x: 20, y: 27), selected: 0, modifiers: 1)
        var second = Model.TouchSelection(point: CGPoint(x: 60, y: 27), selected: 1, modifiers: 1)
        var output: [Int] = []
        output.append(first.takeSelection()!)
        output.append(second.finish(at: CGPoint(x: 60, y: 27), in: g, dockedPad: false)!)
        XCTAssertNil(first.finish(at: CGPoint(x: 20, y: 27), in: g, dockedPad: false))
        XCTAssertEqual(output, [0, 1])
        var cancelled = Model.TouchSelection(point: CGPoint(x: 20, y: 27), selected: 0, modifiers: 0)
        XCTAssertNil(cancelled.finish(at: CGPoint(x: 20, y: 27), in: g, dockedPad: false, cancelled: true))
        XCTAssertNil(cancelled.takeSelection())
    }

    func testLeavingAndReenteringTypingAreaCanSelectAgain() {
        let g = geometry()
        var contact = Model.TouchSelection(point: CGPoint(x: 20, y: 27), selected: 0, modifiers: 0)
        contact.move(to: CGPoint(x: -30, y: 27), in: g, dockedPad: false)
        XCTAssertNil(contact.selected)
        contact.move(to: CGPoint(x: 60, y: 27), in: g, dockedPad: false)
        XCTAssertEqual(contact.finish(at: CGPoint(x: 60, y: 27), in: g, dockedPad: false), 1)
    }

    func testSubthresholdExitRemainsCancellableBeforeRollover() {
        let g = geometry()
        var contact = Model.TouchSelection(point: CGPoint(x: 20, y: 2), selected: 0, modifiers: 0)
        XCTAssertFalse(contact.move(to: CGPoint(x: 20, y: -2), in: g, dockedPad: false))
        XCTAssertEqual(contact.selected, 0)
        XCTAssertNil(contact.finish(at: contact.latestPoint, in: g, dockedPad: false))
    }

    func testHitTargetsRecoverMarginsButNeverCrossActionCellsOrBounds() {
        let g = geometry()
        XCTAssertEqual(g.hit(at: CGPoint(x: 0, y: 27)), 0)
        XCTAssertEqual(g.hit(at: CGPoint(x: 8, y: 81)), 10)
        XCTAssertNil(g.hit(at: CGPoint(x: 0, y: 81)))
        XCTAssertNil(g.hit(at: CGPoint(x: CGFloat.nan, y: 20)))
        XCTAssertNil(g.textHit(at: CGPoint(x: 10, y: 135)))
        for width in [320.0, 375, 393, 440, 744, 1024] {
            for page in Model.Page.allCases {
                let layout = geometry(width: width, page: page)
                for (index, target) in layout.targets.enumerated() {
                    XCTAssertEqual(layout.hit(at: CGPoint(x: target.frame.midX, y: target.frame.midY)), index)
                }
            }
        }
    }

    func testPredictionOnlyChangesAmbiguousNeighboringLetterTaps() {
        let g = geometry()
        let prior = Model.LetterPrior(prefix: "th", completions: ["the", "there", "them", "then"])
        let w = g.targets[1].frame, e = g.targets[2].frame
        let boundary = CGPoint(x: w.maxX - 0.5, y: w.midY)
        XCTAssertEqual(g.hit(at: boundary), 1)
        XCTAssertEqual(g.predictedHit(at: boundary, prior: prior), 2)
        XCTAssertEqual(g.predictedHit(at: boundary, prior: nil), 1)
        XCTAssertEqual(g.predictedHit(at: boundary, prior: .init(prefix: "th", completions: [])), 1)
        XCTAssertEqual(g.predictedHit(at: CGPoint(x: w.midX, y: w.midY), prior: prior), 1)
        XCTAssertEqual(g.predictedHit(at: CGPoint(x: e.midX, y: e.midY), prior: prior), 2)
        for target in g.targets where target.key.letter == nil {
            let point = CGPoint(x: target.frame.minX + 0.5, y: target.frame.midY)
            XCTAssertEqual(g.predictedHit(at: point, prior: prior), g.hit(at: point))
        }
    }

    func testPredictionCannotPullFromDistantKeysOrOverrideDeliberateSlides() {
        let g = geometry()
        let prior = Model.LetterPrior(prefix: "th", completions: ["the", "there", "them"])
        XCTAssertEqual(g.predictedHit(at: CGPoint(x: 3, y: 27), prior: prior), 0)
        let point = CGPoint(x: g.targets[1].frame.maxX - 0.5, y: 27)
        var contact = Model.TouchSelection(point: point, selected: g.predictedHit(at: point, prior: prior)!, modifiers: 0)
        XCTAssertEqual(contact.finish(at: CGPoint(x: point.x - 18, y: 27), in: g, dockedPad: false), 1)
    }

    func testPredictionReachesVisibleKeyEdgesAcrossPhoneWidths() {
        let prior = Model.LetterPrior(prefix: "th", completions: ["the", "there", "them", "then"])
        for width in [320.0, 390, 430] {
            let g = geometry(width: width)
            let w = g.targets[1].frame
            for miss in [2.0, 4.0] {
                let point = CGPoint(x: w.maxX - miss, y: w.midY)
                XCTAssertEqual(g.hit(at: point), 1)
                XCTAssertEqual(g.predictedHit(at: point, prior: prior), 2, "width=\(width), miss=\(miss)")
            }
            let interior = CGPoint(x: w.maxX - 7, y: w.midY)
            XCTAssertEqual(g.predictedHit(at: interior, prior: prior), 1)
            for (index, target) in g.targets.enumerated() {
                let center = CGPoint(x: target.frame.midX, y: target.frame.midY)
                XCTAssertEqual(g.predictedHit(at: center, prior: prior), index)
            }
        }
    }

    func testPredictionCanResolveAnAdjacentRowWithoutPullingDistantLetters() {
        let g = geometry()
        let w = g.targets[1].frame
        let point = CGPoint(x: w.midX, y: w.maxY + 4)
        let prior = Model.LetterPrior(prefix: "ne", completions: ["new", "news"])
        XCTAssertNotEqual(g.hit(at: point), 1)
        XCTAssertEqual(g.predictedHit(at: point, prior: prior), 1)
        let unrelated = Model.LetterPrior(prefix: "th", completions: ["the", "there"])
        XCTAssertEqual(g.predictedHit(at: point, prior: unrelated), g.hit(at: point))
    }

    func testPredictionContextRejectsCodeAndUppercaseTokens() {
        for text in ["/usr/bi", "--ver", "$PA", "my_var", "git.st", "camelCase", "PATH", "g2", "🙂ab", String(repeating: "a", count: 33)] {
            var context = Model.PredictionContext()
            context.append(text)
            XCTAssertNil(context.snapshot, text)
        }
        for text in ["th", "Th", "please explain th"] {
            var context = Model.PredictionContext()
            context.append(text)
            XCTAssertEqual(context.snapshot?.prefix, "th")
        }
    }

    func testLoggedReleaseDriftKeepsInitialLetterWithoutDictionarySupport() {
        let g = geometry(width: 402, typingTop: 84)
        let traces: [(String, CGPoint, CGPoint)] = [
            ("i", CGPoint(x: 307.6667, y: 121), CGPoint(x: 303.3333, y: 139.3333)),
            ("o", CGPoint(x: 323.6667, y: 118.3333), CGPoint(x: 328.3333, y: 145.3333)),
            ("i", CGPoint(x: 306, y: 121.3333), CGPoint(x: 313, y: 143.6667))
        ]
        for (letter, start, end) in traces {
            let initial = g.hit(at: start)!
            XCTAssertEqual(g.targets[initial].key.letter, letter)
            XCTAssertEqual(g.targets[g.hit(at: end)!].key.letter, "k")
            for prior in [nil, Model.LetterPrior(prefix: "ttp", completions: [])] {
                var contact = Model.TouchSelection(point: start, selected: initial, modifiers: 0, prior: prior)
                XCTAssertEqual(contact.finish(at: end, in: g, dockedPad: false), initial)
            }
        }
    }

    func testDeliberateSlideCanContinueFromBoundaryIntoNextKey() {
        let g = geometry(width: 402, typingTop: 84)
        let start = CGPoint(x: 306, y: 121.3333)
        let initial = g.hit(at: start)!
        let k = g.targets.firstIndex { $0.key.letter == "k" }!
        var contact = Model.TouchSelection(point: start, selected: initial, modifiers: 0)
        XCTAssertFalse(contact.move(to: CGPoint(x: 313, y: 143.6667), in: g, dockedPad: false))
        let center = CGPoint(x: g.targets[k].frame.midX, y: g.targets[k].frame.midY)
        XCTAssertEqual(contact.finish(at: center, in: g, dockedPad: false), k)
    }

    func testLoggedSpaceMissAfterIsAndExistingCorrections() {
        let g = geometry(width: 402, typingTop: 84)
        let samples: [(CGPoint, Model.LetterPrior, Model.Action)] = [
            (CGPoint(x: 253.3333, y: 238.3333), .init(prefix: "is", completions: [], isCompleteWord: true), .text(" ")),
            (CGPoint(x: 240.6667, y: 242.6667), .init(prefix: "this", completions: [], isCompleteWord: true), .text(" ")),
            (CGPoint(x: 123, y: 108.3333), .init(prefix: "th", completions: ["the", "there"]), .text("e")),
            (CGPoint(x: 138, y: 205), .init(prefix: "logi", completions: ["logic", "logical"]), .text("c"))
        ]
        for (point, prior, expected) in samples {
            XCTAssertEqual(g.targets[g.predictedHit(at: point, prior: prior)!].key.action, expected)
        }
        let b = g.targets.first { $0.key.letter == "b" }!.frame
        let word = Model.LetterPrior(prefix: "is", completions: [], isCompleteWord: true)
        XCTAssertEqual(g.targets[g.predictedHit(at: CGPoint(x: b.midX, y: b.maxY - 12), prior: word)!].key.letter, "b")
    }

    func testPredictionStartsAfterFirstLetter() {
        var context = Model.PredictionContext()
        context.append("o")
        XCTAssertEqual(context.snapshot?.prefix, "o")
        let g = geometry(width: 402, typingTop: 84)
        let prior = Model.LetterPrior(prefix: "o", completions: ["of", "off", "offer"])
        let point = CGPoint(x: 136.6667, y: 171.3333)
        XCTAssertEqual(g.targets[g.hit(at: point)!].key.letter, "d")
        XCTAssertEqual(g.targets[g.predictedHit(at: point, prior: prior)!].key.letter, "f")
    }

    func testCompletedWordCanResolveBottomRowMissToSpace() {
        let g = geometry()
        let n = g.targets.firstIndex { $0.key.letter == "n" }!
        let space = g.targets.firstIndex { $0.key.action == .text(" ") }!
        let frame = g.targets[n].frame
        let point = CGPoint(x: frame.midX, y: frame.maxY - 4)
        let prior = Model.LetterPrior(prefix: "hello", completions: [], isCompleteWord: true)
        XCTAssertEqual(g.hit(at: point), n)
        XCTAssertEqual(g.predictedHit(at: point, prior: prior), space)
        XCTAssertEqual(g.predictedHit(at: point, prior: .init(prefix: "hell", completions: ["hello"])), n)
        XCTAssertEqual(g.predictedHit(at: CGPoint(x: frame.midX, y: frame.midY), prior: prior), n)
        let spaceFrame = g.targets[space].frame
        XCTAssertEqual(g.predictedHit(at: CGPoint(x: spaceFrame.midX, y: spaceFrame.minY + 1), prior: prior), space)

        var context = Model.PredictionContext()
        context.append("hello")
        if case .text(let text) = g.targets[g.predictedHit(at: point, prior: prior)!].key.action {
            context.append(text)
        }
        context.append("this")
        XCTAssertEqual(context.text, "hello this")
        XCTAssertEqual(context.snapshot?.prefix, "this")
    }

    func testPredictionSurvivesMovementFromIIntoKEdge() {
        let g = geometry()
        let i = g.targets.firstIndex { $0.key.letter == "i" }!
        let k = g.targets.firstIndex { $0.key.letter == "k" }!
        let frame = g.targets[i].frame
        let start = CGPoint(x: frame.midX, y: frame.maxY - 18)
        let end = CGPoint(x: frame.midX, y: frame.maxY + 4)
        let prior = Model.LetterPrior(prefix: "typ", completions: ["typing"])
        XCTAssertEqual(g.hit(at: end), k)
        var contact = Model.TouchSelection(point: start, selected: i, modifiers: 0, prior: prior)
        XCTAssertTrue(contact.move(to: end, in: g, dockedPad: false))
        XCTAssertEqual(contact.finish(at: end, in: g, dockedPad: false), i)

        var deliberate = Model.TouchSelection(point: start, selected: i, modifiers: 0, prior: prior)
        let center = CGPoint(x: g.targets[k].frame.midX, y: g.targets[k].frame.midY)
        XCTAssertEqual(deliberate.finish(at: center, in: g, dockedPad: false), k)
    }

    func testColdPredictionCacheResolvesBeforeNextTouchAndReusesResult() {
        var context = Model.PredictionContext()
        context.append("t")
        // The preceding contact commits during the next touch-down event.
        context.append("h")
        let prefix = context.snapshot!.prefix
        var cache = Model.PredictionCache()
        XCTAssertNil(cache[prefix])
        var loads = 0
        let prior = cache.prior(for: prefix) {
            loads += 1
            return .init(prefix: prefix, completions: ["the", "there"])
        }
        let g = geometry()
        let w = g.targets[1].frame
        let point = CGPoint(x: w.maxX - 4, y: w.midY)
        XCTAssertEqual(g.predictedHit(at: point, prior: prior), 2)
        _ = cache.prior(for: prefix) {
            loads += 1
            return .init(prefix: prefix, completions: [])
        }
        XCTAssertEqual(loads, 1)
    }

    func testPredictionCacheBoundsAndCachesEmptyResults() {
        var cache = Model.PredictionCache()
        for index in 0..<129 {
            _ = cache.prior(for: String(index)) { .init(prefix: "zz", completions: []) }
        }
        XCTAssertNil(cache["0"])
        XCTAssertNotNil(cache["1"])
        XCTAssertEqual(cache["128"]?.isEmpty, true)
        cache.removeAll()
        XCTAssertNil(cache["128"])
    }

    func testPredictionContextIsIndependentOfCorrectionEligibilityAndRejectsStaleSnapshots() {
        var context = Model.PredictionContext()
        context.apply(.text("th", eligible: false), attributed: true)
        let old = context.snapshot
        XCTAssertNotNil(old)
        context.apply(.text("e", eligible: false), attributed: true)
        XCTAssertNotEqual(old, context.snapshot)
        context.apply(.backspace(eligible: false), attributed: true)
        XCTAssertEqual(context.snapshot?.prefix, "th")
        XCTAssertNotEqual(old, context.snapshot)
        for mutation in [TerminalCorrectionContext.Mutation.invalidate, .reset, .dictationBegan, .legacyDocument("th")] {
            context.append(" th")
            context.apply(mutation, attributed: false)
            XCTAssertNil(context.snapshot)
        }
        context.append("th")
        context.apply(.text("e", eligible: true), attributed: false)
        XCTAssertNil(context.snapshot)
    }

    func testCompletionWeightsFilterAndBoundCandidates() {
        let prior = Model.LetterPrior(prefix: "th", completions: ["the", "the", "other", "th", "th!", "thus"])
        XCTAssertEqual(prior.weight(for: "e"), 1.1, accuracy: 0.00001)
        XCTAssertEqual(prior.weight(for: "u"), 0.6, accuracy: 0.00001)
        XCTAssertEqual(prior.weight(for: "q"), 0.1, accuracy: 0.00001)
    }

    func testCapturedModifiersDoNotConsumeLaterModifierTap() {
        var state = Model.Modifiers()
        state.begin(.control)
        state.end(.control, at: 1)
        state.consume(0)
        XCTAssertTrue(state.oneShot.contains(.control))
        state.consume(1)
        XCTAssertEqual(state.rawValue, 0)
    }

    #if canImport(UIKit)
    @MainActor
    func testEnglishCompletionProviderSuppliesLetterPredictions() throws {
        guard let language = UITextChecker.availableLanguages.first(where: { $0.hasPrefix("en") }) else {
            throw XCTSkip("An English spelling dictionary is unavailable")
        }
        let checker = UITextChecker()
        let completions = checker.completions(forPartialWordRange: NSRange(location: 0, length: 2),
                                               in: "th", language: language) ?? []
        let prior = Model.LetterPrior(prefix: "th", completions: completions)
        XCTAssertFalse(prior.isEmpty)
        XCTAssertGreaterThan(prior.weight(for: "e"), prior.weight(for: "z"))
        let g = geometry()
        let w = g.targets[1].frame
        XCTAssertEqual(g.predictedHit(at: CGPoint(x: w.maxX - 4, y: w.midY), prior: prior), 2)
        let word = "hello"
        let range = NSRange(location: 0, length: word.utf16.count)
        let isWord = checker.rangeOfMisspelledWord(in: word, range: range, startingAt: 0,
                                                  wrap: false, language: language).location == NSNotFound
        XCTAssertTrue(isWord)
        let complete = Model.LetterPrior(prefix: word, completions: checker.completions(
            forPartialWordRange: range, in: word, language: language) ?? [], isCompleteWord: isWord)
        let n = g.targets.first { $0.key.letter == "n" }!.frame
        let predicted = g.predictedHit(at: CGPoint(x: n.midX, y: n.maxY - 4), prior: complete)!
        XCTAssertEqual(g.targets[predicted].key.action, .text(" "))
        let shortRange = NSRange(location: 0, length: 1)
        let shortCompletions = checker.completions(forPartialWordRange: shortRange, in: "o", language: language) ?? []
        let shortPrior = Model.LetterPrior(prefix: "o", completions: shortCompletions)
        let logged = geometry(width: 402, typingTop: 84)
        let shortHit = logged.predictedHit(at: CGPoint(x: 136.6667, y: 171.3333), prior: shortPrior)!
        XCTAssertEqual(logged.targets[shortHit].key.letter, "f", "Candidates: \(shortCompletions)")
    }
    #endif

    func testThemeContrastDecodesSRGBBeforeChoosingInk() {
        let gray = Model.RGB(red: 0.5, green: 0.5, blue: 0.5)
        XCTAssertEqual(gray.luminance, 0.214041, accuracy: 0.000001)
        XCTAssertEqual(Model.RGB.white.contrast(against: .black), 21, accuracy: 0.000001)
        // Screenshot regression: the old gamma-encoded brightness calculation
        // rejected the terminal foreground and chose black on these dark keys.
        let key = Model.RGB(red: 44 / 255, green: 44 / 255, blue: 68 / 255)
        let foreground = Model.RGB(red: 205 / 255, green: 214 / 255, blue: 244 / 255)
        XCTAssertEqual(key.readableInk(preferred: foreground), foreground)
        XCTAssertGreaterThan(foreground.contrast(against: key), 9)
        XCTAssertLessThan(Model.RGB.black.contrast(against: key), 2)
    }

    func testThemedInkRemainsReadableForDarkLightPressedAndSelectedKeys() {
        for background in [Model.RGB(red: 30 / 255, green: 30 / 255, blue: 46 / 255),
                           Model.RGB(red: 44 / 255, green: 44 / 255, blue: 68 / 255),
                           Model.RGB(red: 0.28, green: 0.3, blue: 0.38),
                           Model.RGB(red: 0.94, green: 0.92, blue: 0.86),
                           Model.RGB(red: 0.5, green: 0.5, blue: 0.5)] {
            for preferred in [Model.RGB.white, .black, background] {
                let ink = background.readableInk(preferred: preferred)
                XCTAssertGreaterThanOrEqual(ink.contrast(against: background), 4.5)
                // Locked modifiers reverse the fill and ink.
                XCTAssertGreaterThanOrEqual(background.contrast(against: ink), 4.5)
            }
        }
    }

    func testPinchRequiresDeliberateMotionInTheCorrectDirection() {
        XCTAssertEqual(Model.placementAfterPinch(0.7, from: .docked), .floating)
        XCTAssertEqual(Model.placementAfterPinch(1.3, from: .floating), .docked)
        XCTAssertEqual(Model.placementAfterPinch(0.95, from: .docked), .docked)
        XCTAssertEqual(Model.placementAfterPinch(1.05, from: .floating), .floating)
        XCTAssertEqual(Model.placementAfterPinch(1.4, from: .docked), .docked)
        XCTAssertEqual(Model.placementAfterPinch(0.6, from: .floating), .floating)
        XCTAssertEqual(Model.placementAfterPinch(.nan, from: .floating), .floating)
    }

    func testFloatingKeyboardFitsRotatedAndNarrowWindows() {
        for size in [CGSize(width: 810, height: 1080), CGSize(width: 1080, height: 810),
                     CGSize(width: 320, height: 500), CGSize(width: 260, height: 260)] {
            let available = CGRect(origin: CGPoint(x: 12, y: 36), size: size)
            for anchor in [CGPoint.zero, CGPoint(x: 1, y: 1), CGPoint(x: -2, y: 4)] {
                let frame = Model.floatingFrame(in: available, height: 376, anchor: anchor)
                XCTAssertTrue(available.contains(frame))
                XCTAssertLessThanOrEqual(frame.width, 320)
                XCTAssertGreaterThan(frame.height, 0)
            }
        }
    }

    func testFloatingDragAnchorClampsAndSurvivesResize() {
        let available = CGRect(x: 12, y: 36, width: 1000, height: 700)
        let original = Model.floatingFrame(in: available, height: 252, anchor: CGPoint(x: 0.3, y: 0.8))
        let anchor = Model.floatingAnchor(for: original, in: available)
        XCTAssertEqual(anchor.x, 0.3, accuracy: 0.001)
        XCTAssertEqual(anchor.y, 0.8, accuracy: 0.001)
        let moved = original.offsetBy(dx: 5000, dy: -5000)
        XCTAssertEqual(Model.floatingAnchor(for: moved, in: available), CGPoint(x: 1, y: 0))
        let resized = CGRect(x: 12, y: 36, width: 330, height: 480)
        XCTAssertTrue(resized.contains(Model.floatingFrame(in: resized, height: 376, anchor: anchor)))
    }

    func testDraggingToBottomCenterDocksButBottomCornerDoesNot() {
        let available = CGRect(x: 12, y: 36, width: 1000, height: 700)
        let centered = Model.floatingFrame(in: available, height: 252, anchor: CGPoint(x: 0.5, y: 1))
        XCTAssertTrue(Model.shouldDockAfterDrag(centered, in: available))
        XCTAssertFalse(Model.shouldDockAfterDrag(centered.offsetBy(dx: 0, dy: -80), in: available))
        let corner = Model.floatingFrame(in: available, height: 252, anchor: CGPoint(x: 1, y: 1))
        XCTAssertFalse(Model.shouldDockAfterDrag(corner, in: available))
    }

    func testSystemFloatingDragPreservesNativeSizeAndClampsToKeyboardWindow() {
        let screen = CGRect(x: 12, y: 36, width: 1000, height: 700)
        let native = CGRect(x: 1200, y: -300, width: 342, height: 286)
        let moved = Model.clampedFloatingDragFrame(native, in: screen)
        XCTAssertEqual(moved, CGRect(x: 670, y: 36, width: 342, height: 286))
        XCTAssertTrue(screen.contains(moved))
        // A smaller app window must not be used as the native drag boundary.
        XCTAssertGreaterThan(moved.maxX, 500)
        let rotated = CGRect(x: 12, y: 36, width: 600, height: 900)
        XCTAssertTrue(rotated.contains(Model.clampedFloatingDragFrame(moved, in: rotated)))
        let short = CGRect(x: 12, y: 36, width: 300, height: 200)
        XCTAssertEqual(Model.clampedFloatingDragFrame(native, in: short).origin, short.origin)
    }

    func testSystemFloatingWidthAdaptsWithoutMistakingNarrowDockedWindows() {
        XCTAssertTrue(Model.isFloatingInput(width: 320, hostWidth: 834, isPad: true))
        XCTAssertTrue(Model.isFloatingInput(width: 320, hostWidth: 375, isPad: true))
        XCTAssertFalse(Model.isFloatingInput(width: 834, hostWidth: 834, isPad: true))
        XCTAssertFalse(Model.isFloatingInput(width: 320, hostWidth: 320, isPad: true))
        XCTAssertFalse(Model.isFloatingInput(width: 320, hostWidth: 834, isPad: false))
        XCTAssertFalse(Model.isFloatingInput(width: 0, hostWidth: 834, isPad: true))
    }

    func testToolbarRetainsConfiguredRowsAndMovesOverflowToFirstDrawer() {
        let main = (0..<12).map { Model.Key(title: "Key \($0)", action: .custom(UUID())) }
        let drawers = [[Model.Key(title: "Ctrl", action: .modifier(.control))],
                       [Model.Key(title: "Paste", action: .paste)]]
        for width: CGFloat in [0, 320, 390, 1024] {
            let layout = Model.toolbarKeys(main: main, drawers: drawers, width: width)
            XCTAssertEqual(layout.main + layout.drawers.flatMap { $0 }, main + drawers.flatMap { $0 })
            XCTAssertLessThanOrEqual(layout.main.count, max(1, Int(max(0, width - 10) / 40)))
        }
        let empty = Model.toolbarKeys(main: [], drawers: [[]], width: 390)
        XCTAssertTrue(empty.main.isEmpty)
        XCTAssertEqual(empty.drawers, [[]])
    }

    func testDrawerToggleDisplacesButDoesNotLoseLastVisibleCustomKey() {
        let main = (0..<12).map { Model.Key(title: "Key \($0)", action: .custom(UUID())) }
        let drawers = [[Model.Key(title: "Ctrl", action: .modifier(.control))],
                       [Model.Key(title: "Paste", action: .paste)]]
        let toggle = Model.Key(title: "…", action: .drawer)
        let layout = Model.toolbarKeys(main: main, drawers: drawers, width: 320, drawerToggle: toggle)
        XCTAssertEqual(layout.main.last, toggle)
        XCTAssertEqual(layout.drawers[0], Array(main.dropFirst(layout.main.count - 1)) + drawers[0])
        XCTAssertEqual(layout.drawers[1], drawers[1])
        XCTAssertEqual(layout.main.filter { $0 != toggle } + layout.drawers.flatMap { $0 }, main + drawers.flatMap { $0 })
        let hiddenToggle = Model.toolbarKeys(main: main, drawers: drawers, width: 320)
        XCTAssertFalse(hiddenToggle.main.contains(toggle))
    }

    func testSystemKeyboardSwitchReservesOneSlotWithoutLosingDisplacedKeys() {
        let main = ["Escape", "Control", "Paste", "Custom icon", "More"]
        let drawers = [["Tab", "Alt"], ["Command", "Custom sequence"]]
        let normal = KeyboardToolbarOverflow.layout(main: main, drawers: drawers, capacity: 5,
            drawerToggle: "More", keepsDrawerToggleVisible: true)
        XCTAssertEqual(normal.main, main)
        XCTAssertEqual(normal.drawers, drawers)
        let withSwitch = KeyboardToolbarOverflow.layout(main: main, drawers: drawers, capacity: 5,
            reservedSlots: 1, drawerToggle: "More", keepsDrawerToggleVisible: true)
        XCTAssertEqual(withSwitch.main, ["Escape", "Control", "Paste", "More"])
        XCTAssertEqual(withSwitch.drawers, [["Custom icon", "Tab", "Alt"], drawers[1]])
        // Showing/hiding the runtime switch and resizing must preserve every
        // key exactly once, in order, without rewriting the configured rows.
        for capacity in 2...8 {
            for reserved in [0, 1, 0] {
                let layout = KeyboardToolbarOverflow.layout(main: main, drawers: drawers, capacity: capacity,
                    reservedSlots: reserved, drawerToggle: "More", keepsDrawerToggleVisible: true)
                XCTAssertEqual((layout.main + layout.drawers.flatMap { $0 }).filter { $0 != "More" },
                               main.filter { $0 != "More" } + drawers.flatMap { $0 })
                XCTAssertEqual(layout.drawers[1], drawers[1])
                XCTAssertEqual(layout.main.filter { $0 == "More" }.count, 1)
                XCTAssertLessThanOrEqual(layout.main.count + reserved, capacity)
            }
        }
    }

    func testCustomDrawersStackAboveFirstRowThenClose() {
        var state = Model.ToolbarDrawerState.closed
        for expected in [[0], [1, 0], [2, 1, 0], []] {
            state = state.toggled(rowCount: 3, cycle: false)
            XCTAssertEqual(state.visibleRows(rowCount: 3), expected)
        }
        XCTAssertEqual(state, .closed)
    }

    func testCustomDrawersCycleAndAdaptToSettingsChanges() {
        var state = Model.ToolbarDrawerState.closed
        for expected in [[0], [1], [2], []] {
            state = state.toggled(rowCount: 3, cycle: true)
            XCTAssertEqual(state.visibleRows(rowCount: 3), expected)
        }
        XCTAssertEqual(Model.ToolbarDrawerState.cycling(2).clamped(rowCount: 1), .cycling(0))
        XCTAssertEqual(Model.ToolbarDrawerState.stacked(3).clamped(rowCount: 1), .stacked(1))
        XCTAssertEqual(Model.ToolbarDrawerState.cycling(2).visibleRows(rowCount: 1), [0])
        XCTAssertEqual(Model.ToolbarDrawerState.stacked(3).visibleRows(rowCount: 1), [0])
        XCTAssertEqual(Model.ToolbarDrawerState.stacked(2).toggled(rowCount: 3, cycle: true), .closed)
        XCTAssertEqual(Model.ToolbarDrawerState.cycling(1).toggled(rowCount: 3, cycle: false), .closed)
    }

    func testKeyboardPagesAreReachableInBothDirections() {
        var page = Model.ToolPage.typing
        var visited = Set<Int>()
        for _ in Model.ToolPage.allCases {
            visited.insert(page.rawValue)
            page = page.moved(by: 1)
        }
        XCTAssertEqual(page, .typing)
        XCTAssertEqual(visited.count, Model.ToolPage.allCases.count)
        XCTAssertEqual(Model.ToolPage.typing.moved(by: -1), .shortcuts)
        XCTAssertEqual(Model.ToolPage.navigation.moved(by: -1), .symbols)
    }

    func testPageSwipeRequiresDeliberateHorizontalMovement() {
        XCTAssertEqual(Model.pageSwipe(translation: CGPoint(x: -100, y: 10)), 1)
        XCTAssertEqual(Model.pageSwipe(translation: CGPoint(x: 100, y: -10)), -1)
        XCTAssertNil(Model.pageSwipe(translation: CGPoint(x: 40, y: 0)))
        XCTAssertNil(Model.pageSwipe(translation: CGPoint(x: 100, y: 70)))
        XCTAssertEqual(Model.pageSwipe(translation: CGPoint(x: 100, y: 0)), -1)
        XCTAssertNil(Model.pageSwipe(translation: CGPoint(x: 0, y: 100)))
    }

    func testChangingPagesKeepsLatchedModifiersButReleasesHeldTouches() {
        var modifiers = Model.Modifiers()
        modifiers.begin(.control)
        modifiers.end(.control, at: 1)
        modifiers.begin(.alt)
        modifiers.end(.alt, at: 2)
        modifiers.begin(.alt)
        modifiers.end(.alt, at: 2.2)
        modifiers.begin(.shift)
        modifiers.cancelHeld()
        XCTAssertTrue(modifiers.isActive(.control))
        XCTAssertTrue(modifiers.locked.contains(.alt))
        XCTAssertFalse(modifiers.isActive(.shift))
        modifiers.consume()
        XCTAssertFalse(modifiers.isActive(.control))
        XCTAssertTrue(modifiers.isActive(.alt))
    }

    func testKeyContrastAcrossAppearancePressedAndLockedStates() {
        func luminance(_ white: Double) -> Double {
            white <= 0.04045 ? white / 12.92 : pow((white + 0.055) / 1.055, 2.4)
        }
        for dark in [false, true] {
            for character in [false, true] {
                for pressed in [false, true] {
                    for selected in [false, true] {
                        let colors = Model.keyColors(dark: dark, character: character, pressed: pressed, selected: selected)
                        let a = luminance(colors.background), b = luminance(colors.ink)
                        XCTAssertGreaterThanOrEqual((max(a, b) + 0.05) / (min(a, b) + 0.05), 4.5)
                    }
                }
            }
        }
    }

    func testDoubleTapTimingMatchesOriginalToolbar() {
        var state = Model.Modifiers()
        state.begin(.control); state.end(.control, at: 1)
        state.begin(.control); state.end(.control, at: 1.45)
        XCTAssertEqual(state.locked, [.control])
        state.consume()
        XCTAssertEqual(state.rawValue, 1)
        state.begin(.control); state.end(.control, at: 2)
        XCTAssertEqual(state.rawValue, 0)
    }

    func testModifierTapIsOneShot() {
        var state = Model.Modifiers()
        state.begin(.control)
        state.end(.control, at: 1)
        XCTAssertEqual(state.rawValue, 1)
        state.consume()
        XCTAssertEqual(state.rawValue, 0)
    }

    func testDoubleTapLocksUntilTappedAgain() {
        var state = Model.Modifiers()
        state.begin(.shift); state.end(.shift, at: 1)
        state.begin(.shift); state.end(.shift, at: 1.2)
        state.consume()
        XCTAssertEqual(state.locked, [.shift])
        state.begin(.shift); state.end(.shift, at: 2)
        XCTAssertEqual(state.rawValue, 0)
    }

    func testHeldChordRemainsActiveAcrossLettersAndDoesNotLatch() {
        var state = Model.Modifiers()
        state.begin(.control); state.begin(.alt)
        XCTAssertEqual(state.rawValue, 3)
        state.consume(); state.consume()
        XCTAssertEqual(state.rawValue, 3)
        state.end(.control, at: 2); state.end(.alt, at: 2)
        XCTAssertEqual(state.rawValue, 0)
    }

    func testCancelledModifierDoesNotLatch() {
        var state = Model.Modifiers()
        state.begin(.control); state.end(.control, at: 1, cancelled: true)
        XCTAssertEqual(state.rawValue, 0)
    }

    func testConsumedModifierCannotAccidentallyBecomeLockedOnNextTap() {
        var state = Model.Modifiers()
        state.begin(.control); state.end(.control, at: 1)
        state.consume()
        state.begin(.control); state.end(.control, at: 1.1)
        XCTAssertTrue(state.locked.isEmpty)
        XCTAssertEqual(state.oneShot, [.control])
    }

    func testResetClearsEveryModifierState() {
        var state = Model.Modifiers()
        state.begin(.shift); state.end(.shift, at: 1)
        state.begin(.shift); state.end(.shift, at: 1.1)
        state.begin(.control)
        state.reset()
        XCTAssertEqual(state.rawValue, 0)
        state.end(.control, at: 1.2, cancelled: true)
        XCTAssertEqual(state.rawValue, 0)
    }

    func testTypingRowsFillTheirBoundsWithoutOverlapping() {
        for width in [320.0, 375, 393, 440, 568, 744, 1024, 1366] {
            for page in Model.Page.allCases {
                let rows = Model.rows(page: page)
                XCTAssertEqual(rows.count, 4)
                for (row, keys) in rows.enumerated() {
                    let inset = page == .letters && row == 1 ? width / 20 : 2
                    let frames = Model.frames(keys: keys, width: width, y: Double(row) * 54, height: 54, inset: inset)
                    XCTAssertEqual(frames.count, keys.count)
                    XCTAssertEqual(frames.first!.minX, inset, accuracy: 0.001)
                    XCTAssertEqual(frames.last!.maxX, width - inset, accuracy: 0.001)
                    for (left, right) in zip(frames, frames.dropFirst()) {
                        XCTAssertEqual(left.maxX, right.minX, accuracy: 0.001)
                        XCTAssertGreaterThan(left.width, 25)
                    }
                }
            }
        }
    }

    func testQWERTYOrderAndSpaceWidth() {
        let rows = Model.rows(page: .letters)
        XCTAssertEqual(rows[0].map(\.title).joined(), "qwertyuiop")
        XCTAssertEqual(rows[1].map(\.title).joined(), "asdfghjkl")
        XCTAssertEqual(rows[2].dropFirst().dropLast().map(\.title).joined(), "zxcvbnm")
        XCTAssertGreaterThan(rows[3][2].weight, 5)
        XCTAssertEqual(rows[3][1].action, .switchKeyboard)
    }

    func testAllCodingPunctuationIsReachable() {
        let characters = Set(Model.Page.allCases.flatMap { Model.rows(page: $0).flatMap { $0 }.compactMap { key -> String? in
            if case .text(let text) = key.action { return text }; return nil
        } }.joined())
        for value in "0123456789`~!@#$%^&*()-_=+[]{}\\|;:'\",.<>/?" {
            XCTAssertTrue(characters.contains(value), "Missing \(value)")
        }
    }

    func testPresetsExposeExactKeysAndNeverEmbedCommands() {
        XCTAssertEqual(Model.Preset.shell.shortcuts.first?.key, "c")
        XCTAssertEqual(Model.Preset.shell.shortcuts.first?.modifiers, 1)
        XCTAssertEqual(Model.Preset.vim.shortcuts.first?.key, "\u{1b}")
        let backtab = Model.Preset.agent.shortcuts.first { $0.title == "Backtab" }
        XCTAssertEqual(backtab?.key, "\t")
        XCTAssertEqual(backtab?.modifiers, 8)
        for preset in Model.Preset.allCases {
            XCTAssertTrue(preset.shortcuts.allSatisfy { $0.key.count == 1 })
        }
    }

    func testSuggestionsRejectCodeTokensAndUntrackedSuffixes() {
        for value in ["/usr/bni", "--verbose", "my_var", "$PATH", "git.staus", "echo x", ""] {
            XCTAssertNil(Model.SuggestionContext(document: value, eligibleCount: value.utf16.count, generation: 0, documentGeneration: 0), value)
        }
        XCTAssertNil(Model.SuggestionContext(document: "hello", eligibleCount: 2, generation: 0, documentGeneration: 0))
        XCTAssertNotNil(Model.SuggestionContext(document: "please explai", eligibleCount: 6, generation: 0, documentGeneration: 0))
    }

    func testSuggestionSnapshotChangesEvenWhenAppendKeepsGeneration() {
        var document = TerminalCorrectionContext()
        document.apply(.text("hel", eligible: true))
        let old = context(document)
        document.apply(.text("p", eligible: true))
        XCTAssertNotEqual(old, context(document))
    }

    func testSuggestionReplacementIsLiteralAndCannotCrossInvalidation() {
        var document = TerminalCorrectionContext()
        document.apply(.text("explain teh", eligible: true))
        let snapshot = context(document)!
        let replacement = document.replacement(in: snapshot.range, with: "the ", generation: snapshot.generation)!
        XCTAssertEqual(Array(replacement.payload), [127, 127, 127] + Array("the ".utf8))
        document.apply(.invalidate)
        XCTAssertNil(context(document))
        XCTAssertFalse(document.apply(.correction(replacement)))
    }

    func testSuggestionWithTrailingSpaceStartsANewWord() {
        var document = TerminalCorrectionContext()
        document.apply(.text("explain teh", eligible: true))
        let snapshot = context(document)!
        let replacement = document.replacement(in: snapshot.range, with: "the ", generation: snapshot.generation)!
        XCTAssertTrue(document.apply(.correction(replacement)))
        XCTAssertEqual(document.document, "explain the ")
        XCTAssertNil(context(document))
        document.apply(.text("next", eligible: true))
        XCTAssertEqual(document.document, "explain the next")
        XCTAssertEqual(context(document)?.word, "next")
    }

    func testSuggestionReplacementDoesNotEraseComplexGraphemes() {
        var document = TerminalCorrectionContext()
        document.apply(.text("🙂 teh", eligible: true))
        let snapshot = context(document)!
        XCTAssertEqual(snapshot.range, NSRange(location: 3, length: 3))
        XCTAssertNotNil(document.replacement(in: snapshot.range, with: "the", generation: snapshot.generation))
    }

    private func context(_ document: TerminalCorrectionContext) -> Model.SuggestionContext? {
        Model.SuggestionContext(document: document.document, eligibleCount: document.eligibleUTF16Count,
                                generation: document.generation, documentGeneration: document.documentGeneration)
    }
}
