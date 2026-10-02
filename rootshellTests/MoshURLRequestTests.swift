import Foundation
import XCTest

nonisolated final class MoshURLRequestTests: XCTestCase {
    private func wire(id: String) -> String {
        let envelope = "\(TerminalClipboardURLRequest.prefix)1000:\(id):https://example.com"
        return "\u{1b}]52;c;\(Data(envelope.utf8).base64EncodedString())\u{7}"
    }

    func testClipboardEnvelopeSurvivesMoshFramebufferRendering() {
        MainActor.assumeIsolated {
            let emulator = VTEmulator(width: 20, height: 4)
            let baseline = emulator.framebuffer.copy()
            let parser = VTUTF8Parser()
            let request = wire(id: String(repeating: "a", count: 32))
            for byte in request.utf8 {
                var events: [VTParserEvent] = []
                parser.input(byte, events: &events)
                for event in events { emulator.handle(event) }
            }
            let renderer = VTDisplayRenderer(useEnvironment: false)
            let delta = renderer.renderDelta(initialized: true, last: baseline, f: emulator.framebuffer)
            XCTAssertTrue(delta.contains(request))
            let noChange = renderer.renderDelta(initialized: true, last: emulator.framebuffer.copy(), f: emulator.framebuffer)
            XCTAssertFalse(noChange.contains("\u{1b}]52;"))
        }
    }

    func testNewRequestIDKeepsRepeatedURLVisibleToMosh() {
        MainActor.assumeIsolated {
            let emulator = VTEmulator(width: 20, height: 4)
            let parser = VTUTF8Parser()
            @MainActor func apply(_ wire: String) {
                for byte in wire.utf8 {
                    var events: [VTParserEvent] = []
                    parser.input(byte, events: &events)
                    for event in events { emulator.handle(event) }
                }
            }
            apply(wire(id: String(repeating: "a", count: 32)))
            let baseline = emulator.framebuffer.copy()
            let second = wire(id: String(repeating: "b", count: 32))
            apply(second)
            let delta = VTDisplayRenderer(useEnvironment: false).renderDelta(initialized: true, last: baseline, f: emulator.framebuffer)
            XCTAssertTrue(delta.contains(second))
        }
    }

    func testSuppressedURLStateDoesNotOpenOnLaterFocus() {
        MainActor.assumeIsolated {
            let remote = VTFramebuffer(width: 20, height: 4)
            let local = remote.copy()
            let envelope = "\(TerminalClipboardURLRequest.prefix)1000:\(String(repeating: "a", count: 32)):https://example.com"
            remote.setClipboard(Array(Data(envelope.utf8).base64EncodedString().unicodeScalars))
            local.suppressProgramURLRequest(from: remote)
            let delta = VTDisplayRenderer(useEnvironment: false).renderDelta(initialized: true, last: local, f: remote)
            XCTAssertFalse(delta.contains("\u{1b}]52;"))
        }
    }

    func testOrdinaryClipboardUpdatesStillRenderAfterSuppression() {
        MainActor.assumeIsolated {
            let remote = VTFramebuffer(width: 20, height: 4)
            let local = remote.copy()
            let encoded = Data("ordinary clipboard text".utf8).base64EncodedString()
            remote.setClipboard(Array(encoded.unicodeScalars))
            local.suppressProgramURLRequest(from: remote)
            let delta = VTDisplayRenderer(useEnvironment: false).renderDelta(initialized: true, last: local, f: remote)
            XCTAssertTrue(delta.contains("\u{1b}]52;c;\(encoded)\u{7}"))
        }
    }
}
