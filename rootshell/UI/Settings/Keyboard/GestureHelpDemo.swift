import SwiftUI

/// Small, noninteractive illustrations. Animation stays inside the canvas so
/// drawing a touch does not relayout the list or affect a real terminal.
struct GestureHelpDemo: View {
    enum Kind {
        case pinKeyboard, collapseToolbar, moveRestore, lockModifier
        case joystickMode, joystickMove, spaceCursor, keyboardPages, floatKeyboard, moveKeyboard
        case menuTwoFinger, menuDoubleTap, newConnection, fontSize, tabSwipe, selection, selectionMode
        case exposeReveal, exposePages, exposeResize, hoverPreview, sidebarReveal
        case equalizeSplits, rearrangePanes, sidebarReset, remoteTabs, pencil

        var summary: LocalizedStringKey {
            switch self {
            case .pinKeyboard: "Hold the chevron to keep the keyboard hidden."
            case .collapseToolbar: "Double-tap the chevron to collapse the toolbar."
            case .moveRestore: "Drag the floating button out of your way."
            case .lockModifier: "Double-tap to lock. Tap again to release."
            case .joystickMode: "Hold for 1.5 seconds to switch modes."
            case .joystickMove: "Drag and hold to repeat arrow keys."
            case .spaceCursor: "Hold Space, then slide to move the cursor."
            case .keyboardPages: "Swipe across the keys to change pages."
            case .floatKeyboard: "Pinch in to float. Spread to dock."
            case .moveKeyboard: "Drag the handle. Double-tap to dock."
            case .menuTwoFinger: "Tap with two fingers to open the menu."
            case .menuDoubleTap: "Double-tap with one finger for the menu."
            case .newConnection: "Hold two fingers to start a connection."
            case .fontSize: "Spread to enlarge text. Pinch to shrink."
            case .tabSwipe: "Swipe sideways to switch tabs by default."
            case .selection: "Hold, then drag to select text or send a mouse drag."
            case .selectionMode: "One finger selects. Two fingers scroll."
            case .exposeReveal: "Pull down from the tab bar for live previews."
            case .exposePages: "Swipe sideways to browse tab groups."
            case .exposeResize: "Pinch to resize the preview grid."
            case .hoverPreview: "Hover to preview. Pinch to resize. Click to open."
            case .sidebarReveal: "Swipe right from the left edge."
            case .equalizeSplits: "Double-tap a divider to balance panes."
            case .rearrangePanes: "Tap a divider, then drag a pane's handle."
            case .sidebarReset: "Double-tap a divider to reset its width."
            case .remoteTabs: "Swipe with three fingers to switch app tabs."
            case .pencil: "Double-tap the barrel for the menu or right-click."
            }
        }

        /// Brief prerequisites remain visible without opening the details.
        var badge: LocalizedStringKey? {
            switch self {
            case .menuTwoFinger, .newConnection, .fontSize, .selection: "Scroll Mode"
            case .selectionMode: "Scroll Mode off"
            case .tabSwipe:
                #if targetEnvironment(macCatalyst)
                "Trackpad"
                #else
                "Scroll Mode"
                #endif
            case .spaceCursor, .keyboardPages, .floatKeyboard, .moveKeyboard: "Terminal Keyboard"
            case .remoteTabs: "Screen Sharing"
            case .pencil: "Apple Pencil"
            default: nil
            }
        }

        var compactSummary: LocalizedStringKey {
            #if targetEnvironment(macCatalyst)
            switch self {
            case .equalizeSplits: return "Double-click a divider to balance panes."
            case .sidebarReset: return "Double-click a divider to reset its width."
            case .rearrangePanes: return "Hover near the top, then drag the pane handle."
            case .exposeReveal: return "Scroll down over the tab bar for live previews."
            default: return summary
            }
            #else
            return summary
            #endif
        }
    }

    let kind: Kind
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.sheetThemeColors) private var theme
    @State private var isVisible = false
    @State private var started = Date.now

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 24, paused: reduceMotion || !isVisible || scenePhase != .active)) { timeline in
            Canvas { context, size in
                var scaled = context
                scaled.scaleBy(x: size.width / 120, y: size.height / 88)
                let phase = reduceMotion ? 0.68 : timeline.date.timeIntervalSince(started).truncatingRemainder(dividingBy: 3.6) / 3.6
                GestureDemoDrawing(context: scaled, accent: theme?.accentColor ?? .accentColor,
                                   phase: phase, still: reduceMotion).draw(kind)
            }
        }
        .background(.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 12))
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .onScrollVisibilityChange(threshold: 0.2) { visible in
            if visible && !isVisible { started = .now }
            isVisible = visible
        }
        .onDisappear { isVisible = false }
        // The adjacent text is the accessible equivalent of the illustration.
        .accessibilityHidden(true)
        .allowsHitTesting(false)
    }
}

private struct GestureDemoDrawing {
    let context: GraphicsContext
    let accent: Color
    let phase: Double
    let still: Bool
    private let ink = Color.primary

    private var progress: CGFloat {
        let t = min(1, max(0, (phase - 0.23) / 0.40))
        return t * t * (3 - 2 * t)
    }

    func draw(_ kind: GestureHelpDemo.Kind) {
        switch kind {
        case .pinKeyboard, .collapseToolbar:
            terminal()
            let p = progress
            keyboard(CGRect(x: 14, y: 56 + 25 * p, width: 92, height: 22))
            if kind == .pinKeyboard {
                line(15, 53 + 22 * p, 105, 53 + 22 * p)
                symbol(p > 0.7 ? "keyboard.badge.ellipsis" : "chevron.down", 89, 46 + 22 * p, 13)
                touch(95, 53 + 22 * p, hold: true)
            } else {
                symbol(p > 0.7 ? "keyboard" : "chevron.down", 89, 48 + 20 * p, 14)
                touch(96, 55, doubleTap: true)
            }
        case .moveRestore:
            terminal()
            let x = 94 - 58 * progress
            trail(94, 66, 36, 38)
            box(CGRect(x: x - 11, y: 57 - 28 * progress, width: 22, height: 18), active: true)
            symbol("keyboard", x - 7, 60 - 28 * progress, 14)
            touch(x, 66 - 28 * progress)
        case .lockModifier:
            terminal()
            box(CGRect(x: 35, y: 43, width: 50, height: 27), active: progress > 0.5)
            text("⌃", 60, 56, 22)
            if progress > 0.5 { symbol("lock.fill", 77, 37, 12) }
            touch(61, 61, doubleTap: true)
        case .joystickMode, .joystickMove:
            terminal()
            box(CGRect(x: 41, y: 36, width: 38, height: 36), active: true)
            symbol(kind == .joystickMode && progress > 0.7 ? "chevron.up" : "arrow.up.and.down.and.arrow.left.and.right", 49, 43, 22)
            if kind == .joystickMode {
                touch(60, 57, hold: true)
            } else {
                trail(60, 57, 86, 57)
                touch(60 + 26 * progress, 57)
                text("› › ›", 85, 28, 12)
            }
        case .spaceCursor:
            terminal()
            box(CGRect(x: 24, y: 58, width: 72, height: 16), active: true)
            text("space", 60, 66, 8)
            rect(CGRect(x: 35 + 35 * progress, y: 31, width: 3, height: 10), accent)
            trail(40, 66, 80, 66)
            touch(40 + 40 * progress, 66, hold: phase < 0.23)
        case .keyboardPages:
            terminal()
            keyboard(CGRect(x: 15, y: 40, width: 90, height: 33))
            for index in 0..<4 {
                rect(CGRect(x: 44 + CGFloat(index) * 9, y: 78, width: 5, height: 3),
                     index == (progress > 0.5 ? 1 : 0) ? accent : ink.opacity(0.15))
            }
            trail(87, 56, 32, 56)
            touch(87 - 55 * progress, 56)
        case .floatKeyboard:
            terminal()
            let width = 90 - 38 * progress
            keyboard(CGRect(x: 60 - width / 2, y: 43 - 8 * progress, width: width, height: 31))
            pinch(inward: true)
        case .moveKeyboard:
            terminal()
            let x = 56 - 29 * progress
            let y = 45 - 15 * progress
            keyboard(CGRect(x: x, y: y, width: 46, height: 28))
            line(x + 17, y + 3, x + 29, y + 3)
            trail(79, 48, 50, 33)
            touch(x + 23, y + 3)
        case .menuTwoFinger, .menuDoubleTap, .newConnection:
            terminal()
            if progress > 0.45 {
                box(CGRect(x: 29, y: 24, width: 62, height: 27), active: true)
                if kind == .newConnection {
                    symbol("plus", 52, 29, 16)
                } else {
                    for y in [31.0, 38, 45] { line(38, y, 80, y) }
                }
            }
            touch(kind == .menuDoubleTap ? 60 : 48, 61,
                  hold: kind == .newConnection, doubleTap: kind == .menuDoubleTap)
            if kind != .menuDoubleTap { touch(72, 61, hold: kind == .newConnection) }
        case .fontSize:
            terminal(lines: false)
            text("Aa", 60, 40, 14 + 13 * progress)
            pinch(inward: false)
        case .tabSwipe, .remoteTabs, .exposePages:
            terminal(lines: kind != .exposePages)
            if kind == .exposePages { previews(scale: 1, offset: -24 * progress) }
            rect(CGRect(x: 21 + 30 * progress, y: 16, width: 22, height: 3), accent)
            trail(87, 56, 33, 56)
            let count = kind == .remoteTabs ? 3 : pointerSwipeCount
            for i in 0..<count { touch(87 - 54 * progress, 52 + CGFloat(i) * 12) }
        case .selection, .selectionMode:
            if kind == .selectionMode && phase > 0.5 && !still {
                terminal(lines: false)
                let scroll = CGFloat(min(1, (phase - 0.5) / 0.35))
                for i in 0..<3 { line(22, 43 + CGFloat(i) * 9 - 16 * scroll, 78, 43 + CGFloat(i) * 9 - 16 * scroll) }
                trail(52, 66, 52, 40)
                touch(52, 66 - 26 * scroll)
                touch(73, 66 - 26 * scroll)
            } else {
                terminal()
                rect(CGRect(x: 24, y: 31, width: 10 + 63 * progress, height: 9), accent.opacity(0.25))
                trail(28, 37, 88, 37)
                touch(28 + 60 * progress, 37, hold: kind == .selection && phase < 0.23)
            }
        case .exposeReveal:
            terminal(lines: false)
            previews(scale: 0.55 + 0.45 * progress, offset: 0)
            trail(60, 15, 60, 65)
            if pointerSwipeCount == 2 {
                touch(51, 15 + 50 * progress)
                touch(69, 15 + 50 * progress)
            } else {
                touch(60, 15 + 50 * progress)
            }
        case .exposeResize, .hoverPreview:
            terminal(lines: false)
            if kind == .exposeResize {
                previews(scale: 0.70 + 0.30 * progress, offset: 0)
            } else {
                let width = 40 + 32 * progress
                box(CGRect(x: 60 - width / 2, y: 30, width: width, height: width * 0.5), active: true)
                symbol("cursorarrow", 28, 13, 16)
            }
            pinch(inward: false)
        case .sidebarReveal:
            terminal()
            box(CGRect(x: 12, y: 23, width: 8 + 37 * progress, height: 51), active: true)
            trail(13, 49, 62, 49)
            touch(13 + 49 * progress, 49)
        case .equalizeSplits, .sidebarReset:
            terminal(lines: false)
            let divider = 39 + 21 * progress
            box(CGRect(x: 16, y: 26, width: divider - 20, height: 43), active: true)
            box(CGRect(x: divider + 4, y: 26, width: 100 - divider, height: 43))
            line(divider, 24, divider, 72)
            touch(divider, 49, doubleTap: true)
        case .rearrangePanes:
            terminal(lines: false)
            box(CGRect(x: 16, y: 26, width: 40, height: 44))
            box(CGRect(x: 64, y: 26, width: 40, height: 44), active: true)
            box(CGRect(x: 19 + 46 * progress, y: 29 + 8 * progress, width: 34, height: 34), active: true)
            line(29 + 46 * progress, 32 + 8 * progress, 43 + 46 * progress, 32 + 8 * progress)
            trail(36, 32, 82, 40)
            touch(36 + 46 * progress, 32 + 8 * progress)
        case .pencil:
            terminal()
            var pencil = Path()
            pencil.move(to: CGPoint(x: 30, y: 70))
            pencil.addLine(to: CGPoint(x: 86, y: 25))
            context.stroke(pencil, with: .color(ink.opacity(0.7)), style: StrokeStyle(lineWidth: 7, lineCap: .round))
            touch(62, 45, doubleTap: true)
            if progress > 0.5 { symbol("contextualmenu.and.cursorarrow", 28, 24, 20) }
        }
    }

    private var pointerSwipeCount: Int {
        #if targetEnvironment(macCatalyst) || os(visionOS)
        2
        #else
        1
        #endif
    }

    private func terminal(lines: Bool = true) {
        box(CGRect(x: 10, y: 10, width: 100, height: 68))
        for x in [20.0, 50, 80] { rect(CGRect(x: x, y: 15, width: 21, height: 4), ink.opacity(0.12)) }
        line(12, 23, 108, 23)
        if lines {
            for i in 0..<3 { line(22, 33 + CGFloat(i) * 9, 78 - CGFloat(i) * 12, 33 + CGFloat(i) * 9) }
        }
    }

    private func keyboard(_ frame: CGRect) {
        box(frame, active: true)
        for row in 0..<3 {
            for col in 0..<7 {
                rect(CGRect(x: frame.minX + 5 + CGFloat(col) * (frame.width - 10) / 7,
                            y: frame.minY + 5 + CGFloat(row) * (frame.height - 8) / 3,
                            width: max(2, (frame.width - 25) / 7), height: 3), ink.opacity(0.25))
            }
        }
    }

    private func previews(scale: CGFloat, offset: CGFloat) {
        for row in 0..<2 {
            for col in 0..<3 {
                box(CGRect(x: 20 + CGFloat(col) * 29 + offset, y: 30 + CGFloat(row) * 23,
                           width: 23 * scale, height: 17 * scale), active: row == 0 && col == 1)
            }
        }
    }

    private func pinch(inward: Bool) {
        let distance = inward ? 31 - 17 * progress : 14 + 17 * progress
        trail(inward ? 29 : 46, 60, inward ? 46 : 29, 60)
        trail(inward ? 91 : 74, 60, inward ? 74 : 91, 60)
        touch(60 - distance, 60)
        touch(60 + distance, 60)
    }

    private func touch(_ x: CGFloat, _ y: CGFloat, hold: Bool = false, doubleTap: Bool = false) {
        let center = CGPoint(x: x, y: y)
        let contact = Path(ellipseIn: CGRect(x: x - 5, y: y - 5, width: 10, height: 10))
        context.fill(contact, with: .color(accent.opacity(0.3)))
        context.stroke(contact, with: .color(accent), lineWidth: 1.5)
        if hold {
            let ring = Path(ellipseIn: CGRect(x: x - 9, y: y - 9, width: 18, height: 18))
            context.stroke(ring.trimmedPath(from: 0, to: still ? 0.85 : min(1, phase / 0.6)),
                           with: .color(accent), lineWidth: 2)
        } else {
            // Two distinct pulses for double-taps; one for initial contact.
            for start in doubleTap ? [0.10, 0.29] : [0.10] {
                let pulse = (phase - start) / 0.17
                if still || (pulse >= 0 && pulse <= 1) {
                    let radius = still ? (start < 0.2 ? 8.0 : 11.0) : 6 + 7 * pulse
                    let ring = Path(ellipseIn: CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2))
                    context.stroke(ring, with: .color(accent.opacity(still ? 0.5 : 1 - pulse)), lineWidth: 1.5)
                }
            }
        }
    }

    private func trail(_ x1: CGFloat, _ y1: CGFloat, _ x2: CGFloat, _ y2: CGFloat) {
        var path = Path()
        path.move(to: CGPoint(x: x1, y: y1))
        path.addLine(to: CGPoint(x: x2, y: y2))
        context.stroke(path, with: .color(accent.opacity(0.35)), style: StrokeStyle(lineWidth: 1.5, dash: [2, 3]))
        let angle = atan2(y2 - y1, x2 - x1)
        var head = Path()
        head.move(to: CGPoint(x: x2 - 5 * cos(angle - 0.5), y: y2 - 5 * sin(angle - 0.5)))
        head.addLine(to: CGPoint(x: x2, y: y2))
        head.addLine(to: CGPoint(x: x2 - 5 * cos(angle + 0.5), y: y2 - 5 * sin(angle + 0.5)))
        context.stroke(head, with: .color(accent.opacity(0.6)), lineWidth: 1.5)
    }

    private func box(_ frame: CGRect, active: Bool = false) {
        let path = Path(roundedRect: frame, cornerRadius: 4)
        context.fill(path, with: .color(active ? accent.opacity(0.12) : ink.opacity(0.035)))
        context.stroke(path, with: .color(active ? accent.opacity(0.6) : ink.opacity(0.18)), lineWidth: 1)
    }

    private func rect(_ frame: CGRect, _ color: Color) {
        context.fill(Path(roundedRect: frame, cornerRadius: 1), with: .color(color))
    }

    private func line(_ x1: CGFloat, _ y1: CGFloat, _ x2: CGFloat, _ y2: CGFloat) {
        var path = Path()
        path.move(to: CGPoint(x: x1, y: y1))
        path.addLine(to: CGPoint(x: x2, y: y2))
        context.stroke(path, with: .color(ink.opacity(0.2)), style: StrokeStyle(lineWidth: 2, lineCap: .round))
    }

    private func text(_ value: String, _ x: CGFloat, _ y: CGFloat, _ size: CGFloat) {
        context.draw(Text(verbatim: value).font(.system(size: size, weight: .medium, design: .monospaced)).foregroundColor(ink), at: CGPoint(x: x, y: y))
    }

    private func symbol(_ name: String, _ x: CGFloat, _ y: CGFloat, _ size: CGFloat) {
        var image = context.resolve(Image(systemName: name))
        image.shading = .color(ink.opacity(0.8))
        context.draw(image, in: CGRect(x: x, y: y, width: size, height: size))
    }
}
