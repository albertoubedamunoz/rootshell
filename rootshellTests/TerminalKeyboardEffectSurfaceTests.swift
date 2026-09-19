#if !os(visionOS) && !targetEnvironment(macCatalyst)
import SwiftUI
import UIKit
import XCTest

@MainActor
final class TerminalKeyboardEffectSurfaceTests: XCTestCase {
    private final class RendererProbe {
        var creations = 0
        var appearances = 0
        var presentationIDs: [UUID] = []
        weak var view: UIView?
    }

    private struct EffectProbe: UIViewRepresentable {
        let probe: RendererProbe
        func makeUIView(context: Context) -> UIView {
            probe.creations += 1
            let view = UIView()
            probe.view = view
            return view
        }
        func updateUIView(_ view: UIView, context: Context) {}
    }

    private struct Background: View {
        @ObservedObject var appearance: TerminalKeyboardEffectSurface.Appearance
        @State private var presentationID = UUID()
        let probe: RendererProbe
        var body: some View {
            ZStack {
                Color(uiColor: appearance.backgroundColor)
                EffectProbe(probe: probe)
            }
            .onAppear {
                probe.appearances += 1
                probe.presentationIDs.append(presentationID)
            }
        }
    }

    private func keyboard(in window: UIWindow) -> (UIView, UIView) {
        let keyboard = UIView(frame: window.bounds)
        let background = UIView(frame: keyboard.bounds)
        keyboard.addSubview(background)
        window.addSubview(keyboard)
        return (keyboard, background)
    }

    private func render(_ surface: TerminalKeyboardEffectSurface, in keyboard: UIView) async {
        surface.contentView?.frame = keyboard.bounds
        keyboard.layoutIfNeeded()
        // Let SwiftUI process appearance and representable updates.
        try? await Task.sleep(for: .milliseconds(50))
        keyboard.layoutIfNeeded()
    }

    func testRendererSurvivesTabHandoffAppearanceUpdatesAndLateDetach() async throws {
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 300))
        window.isHidden = false
        defer { window.isHidden = true }
        let (first, firstBackground) = keyboard(in: window)
        let (second, secondBackground) = keyboard(in: window)
        let surface = TerminalKeyboardEffectSurface()
        let probe = RendererProbe()
        let content = { AnyView(Background(appearance: surface.appearance, probe: probe)) }
        surface.attach(to: first, above: firstBackground, effectID: "test", backgroundColor: .black, makeContent: content)
        await render(surface, in: first)
        let renderer = try XCTUnwrap(probe.view)
        let hostingView = try XCTUnwrap(surface.contentView)
        XCTAssertEqual(probe.creations, 1)

        // UIKit removes the outgoing keyboard before installing the new one.
        surface.detach(from: first)
        first.removeFromSuperview()
        await render(surface, in: first)
        surface.attach(to: second, above: secondBackground, effectID: "test", backgroundColor: .blue, makeContent: content)
        await render(surface, in: second)
        XCTAssertTrue(surface.contentView === hostingView)
        XCTAssertTrue(probe.view === renderer)
        XCTAssertEqual(probe.creations, 1, "Tab switches must not recreate the animation/player")

        surface.detach(from: first)
        XCTAssertTrue(hostingView.superview === second, "Late outgoing callbacks must not remove the incoming effect")
        surface.attach(to: second, above: secondBackground, effectID: "test", backgroundColor: .red, makeContent: content)
        await render(surface, in: second)
        XCTAssertEqual(probe.creations, 1, "Appearance refreshes must keep the renderer")
        XCTAssertEqual(probe.appearances, 2, "SwiftUI reappears on reattachment; effects must resume retained state")
        XCTAssertEqual(Set(probe.presentationIDs).count, 1, "SwiftUI animation state must survive the handoff")
        XCTAssertEqual(surface.appearance.backgroundColor, .red)
    }

    func testChangingEffectReplacesRendererAndSeparateSurfacesStayIndependent() async throws {
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 300))
        window.isHidden = false
        defer { window.isHidden = true }
        let (keyboard, background) = keyboard(in: window)
        let surface = TerminalKeyboardEffectSurface()
        let probe = RendererProbe()
        surface.attach(to: keyboard, above: background, effectID: "first", backgroundColor: .black) {
            AnyView(EffectProbe(probe: probe))
        }
        await render(surface, in: keyboard)
        let original = try XCTUnwrap(surface.contentView)
        surface.attach(to: keyboard, above: background, effectID: "second", backgroundColor: .black) {
            AnyView(EffectProbe(probe: probe))
        }
        await render(surface, in: keyboard)
        XCTAssertFalse(surface.contentView === original)
        XCTAssertNil(original.superview)
        XCTAssertEqual(probe.creations, 2)

        let separate = TerminalKeyboardEffectSurface()
        XCTAssertNil(separate.contentView)
        separate.detach(from: keyboard)
        XCTAssertTrue(surface.contentView?.superview === keyboard)
    }
}
#endif
