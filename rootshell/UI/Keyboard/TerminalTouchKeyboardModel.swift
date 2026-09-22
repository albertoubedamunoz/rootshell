import Foundation
import CoreGraphics

/// One partition for the system toolbar and the touch keyboard. Runtime buttons
/// reserve main-row slots without changing the user's saved configuration.
nonisolated enum KeyboardToolbarOverflow {
    static func layout<Slot: Equatable>(main: [Slot], drawers: [[Slot]], capacity: Int,
                                       reservedSlots: Int = 0, drawerToggle: Slot,
                                       keepsDrawerToggleVisible: Bool) -> (main: [Slot], drawers: [[Slot]]) {
        let available = max(1, capacity - max(0, reservedSlots))
        var visible = Array(main.prefix(available))
        var overflow = Array(main.dropFirst(available))
        var rows = drawers.isEmpty ? [[]] : drawers
        let hasContent = (overflow + rows.flatMap { $0 }).contains { $0 != drawerToggle }
        if hasContent, keepsDrawerToggleVisible, !visible.contains(drawerToggle) {
            if visible.count == available { overflow.insert(visible.removeLast(), at: 0) }
            visible.append(drawerToggle)
        }
        rows[0] = overflow + rows[0]
        rows = rows.map { $0.filter { $0 != drawerToggle } }
        return (visible, rows)
    }
}

/// Platform-independent behavior shared by the touch surface and its tests.
nonisolated enum TerminalTouchKeyboardModel {
    /// Stable persisted identifiers; rendering implementations live in the style files.
    enum Style: String, CaseIterable, Sendable {
        case flat, sculpted

        var displayName: String {
            switch self {
            case .flat: String(localized: "Flat")
            case .sculpted: String(localized: "Sculpted")
            }
        }
    }

    enum BackgroundEffectPlacement: String, CaseIterable, Sendable {
        case off
        case toolbar
        case entireKeyboard = "entire-keyboard"

        var displayName: String {
            switch self {
            case .off: String(localized: "Off")
            case .toolbar: String(localized: "Toolbar Only")
            case .entireKeyboard: String(localized: "Entire Keyboard")
            }
        }
    }

    enum FloatingGlassStyle: String, CaseIterable, Sendable {
        case regular, clear, solid

        var displayName: String {
            switch self {
            case .regular: String(localized: "Regular")
            case .clear: String(localized: "Clear")
            case .solid: String(localized: "Solid")
            }
        }
    }

    /// Config files can supply values outside the slider's range.
    static func floatingGlassTintOpacity(_ value: Double) -> Double {
        value.isFinite ? min(1, max(0, value)) : 0.25
    }

    enum Modifier: Int, CaseIterable, Sendable {
        // Matches KeyModifiers without importing UIKit into the model.
        case control = 1, alt = 2, command = 4, shift = 8
    }

    struct Modifiers: Sendable {
        private(set) var oneShot: Set<Modifier> = []
        private(set) var locked: Set<Modifier> = []
        private var held: Set<Modifier> = []
        private var used: Set<Modifier> = []
        private var lastTap: [Modifier: TimeInterval] = [:]

        var rawValue: Int { oneShot.union(locked).union(held).reduce(0) { $0 | $1.rawValue } }
        func isActive(_ modifier: Modifier) -> Bool { rawValue & modifier.rawValue != 0 }

        mutating func begin(_ modifier: Modifier) {
            held.insert(modifier)
            used.remove(modifier)
        }

        mutating func end(_ modifier: Modifier, at time: TimeInterval, cancelled: Bool = false) {
            held.remove(modifier)
            defer { used.remove(modifier) }
            guard !cancelled, !used.contains(modifier) else { return }
            if locked.remove(modifier) != nil {
                lastTap[modifier] = nil
            } else if oneShot.contains(modifier), time - (lastTap[modifier] ?? -.infinity) < 0.5 {
                oneShot.remove(modifier)
                locked.insert(modifier)
                lastTap[modifier] = nil
            } else if oneShot.remove(modifier) == nil {
                oneShot.insert(modifier)
                lastTap[modifier] = time
            } else {
                lastTap[modifier] = nil
            }
        }

        mutating func consume(_ rawValue: Int? = nil) {
            let consumed = rawValue.map { value in Set(Modifier.allCases.filter { value & $0.rawValue != 0 }) }
                ?? oneShot.union(held)
            used.formUnion(held.intersection(consumed))
            oneShot.subtract(consumed)
            for modifier in consumed { lastTap[modifier] = nil }
        }

        mutating func cancelHeld() { held.removeAll(); used.removeAll() }
        mutating func reset() { self = Self() }
    }

    /// One store per window. Reference values let placement and keyboard-choice
    /// changes stay current without copying input-host state between terminals.
    struct StateStore<State> {
        private var shared: State?
        private var tabs: [UUID: State] = [:]
        private var lastState: State?
        private var perTab = false

        mutating func activate(tabID: UUID?, perTab: Bool, make: () -> State,
                               copyChoices: (State, State) -> Void) -> State {
            let selected = state(tabID: tabID, perTab: perTab, make: make)
            // A settings sheet may resign the terminal before changing scope.
            // Seed the new scope from the last displayed state on next focus.
            if self.perTab != perTab, let lastState { copyChoices(lastState, selected) }
            self.perTab = perTab
            lastState = selected
            return selected
        }

        mutating func state(tabID: UUID?, perTab: Bool, make: () -> State) -> State {
            guard perTab, let tabID else {
                if let shared { return shared }
                let state = make()
                shared = state
                return state
            }
            if let state = tabs[tabID] { return state }
            let state = make()
            tabs[tabID] = state
            return state
        }
    }

    /// Durable presentation choices. Touches, repeats, suggestions and prediction
    /// context belong to the input host and must never travel to another terminal.
    struct PresentationState {
        var modifiers = Modifiers()
        var page = Page.letters
        var preset = Preset.shell
        var toolPage = ToolPage.typing
        var toolbarDrawer = ToolbarDrawerState.closed
        var drawerOffset = CGPoint.zero
        var toolbarOffsets: [Int: CGPoint] = [:]

        func suspendingInput() -> Self {
            var result = self
            result.modifiers.cancelHeld()
            return result
        }
    }

    enum Page: CaseIterable { case letters, numbers, symbols }
    enum Action: Hashable {
        case text(String), key(String), modifier(Modifier)
        case page, switchKeyboard, drawer, dismiss, joystick, compose, paste, tabs
        case toolbar(String), custom(UUID)
    }

    struct Key: Hashable {
        let title: String
        let action: Action
        var symbol: String? = nil
        var weight: Double = 1
        var accessibility: String? = nil

        var isText: Bool { if case .text = action { return true }; return false }
        var letter: String? {
            guard case .text(let text) = action, text.count == 1,
                  text.first?.isASCII == true, text.first?.isLetter == true else { return nil }
            return text.lowercased()
        }
    }

    struct HitTarget {
        let key: Key
        let frame: CGRect
    }

    struct TypingGeometry {
        let targets: [HitTarget]
        let bounds: CGRect

        private func distance(_ point: CGPoint, to rect: CGRect) -> CGFloat {
            hypot(max(rect.minX - point.x, 0, point.x - rect.maxX),
                  max(rect.minY - point.y, 0, point.y - rect.maxY))
        }

        func hit(at point: CGPoint) -> Int? {
            guard point.x.isFinite, point.y.isFinite, bounds.contains(point) else { return nil }
            if let contained = targets.firstIndex(where: { $0.frame.contains(point) }) { return contained }
            // Recover unclaimed margins without enlarging action keys.
            return targets.indices.filter { targets[$0].key.isText && distance(point, to: targets[$0].frame) <= 17 }
                .min { distance(point, to: targets[$0].frame) < distance(point, to: targets[$1].frame) }
        }

        func textHit(at point: CGPoint) -> Int? {
            guard let index = hit(at: point), targets[index].key.isText else { return nil }
            return index
        }

        func predictedHit(at point: CGPoint, prior: LetterPrior?) -> Int? {
            guard let geometric = hit(at: point), let prior, !prior.isEmpty,
                  let letter = targets[geometric].key.letter else { return hit(at: point) }
            let base = targets[geometric].frame
            guard base.contains(point) else { return geometric }
            let boundaryDistance = min(point.x - base.minX, base.maxX - point.x,
                                       point.y - base.minY, base.maxY - point.y)
            func spatial(_ rect: CGRect) -> Double {
                // Model finger spread across half a cell; the boundary guard
                // separately protects deliberate taps in the interior.
                let x = (point.x - rect.midX) / max(1, rect.width * 0.5)
                let y = (point.y - rect.midY) / max(1, rect.height * 0.5)
                return Double(-0.5 * (x * x + y * y))
            }
            let baseScore = spatial(base)
            var best = geometric, bestScore = baseScore + 0.15
            for index in targets.indices where index != geometric {
                let candidate = targets[index]
                let isSpace = candidate.key.action == .text(" ")
                let next = isSpace ? " " : candidate.key.letter
                // Space tolerates a slightly deeper bottom-row miss after a
                // complete word. Other letter boundaries remain narrower.
                let allowance: CGFloat = isSpace ? min(10, base.height * 0.25) : 6
                guard let next, boundaryDistance <= allowance, distance(point, to: candidate.frame) <= allowance,
                      base.insetBy(dx: -0.01, dy: -0.01).intersects(candidate.frame) else { continue }
                let ratio = min(4, max(0.25, prior.weight(for: next) / prior.weight(for: letter)))
                guard ratio > 1 else { continue }
                let score = spatial(candidate.frame) + log(ratio)
                if score > bestScore { best = index; bestScore = score }
            }
            return best
        }
    }

    /// A contact keeps its selection until movement indicates a deliberate slide.
    struct TouchSelection {
        let initialPoint: CGPoint
        let modifiers: Int
        let prior: LetterPrior?
        private(set) var anchor: CGPoint
        private(set) var latestPoint: CGPoint
        private(set) var selected: Int?
        private(set) var dragged = false
        private(set) var consumed = false

        init(point: CGPoint, selected: Int, modifiers: Int, prior: LetterPrior? = nil) {
            initialPoint = point; anchor = point; latestPoint = point
            self.selected = selected; self.modifiers = modifiers
            self.prior = prior
        }

        @discardableResult
        mutating func move(to point: CGPoint, in geometry: TypingGeometry, dockedPad: Bool) -> Bool {
            guard !consumed else { return false }
            latestPoint = point
            let threshold: CGFloat = dockedPad ? (dragged ? 34 : 42) : (dragged ? 12 : 18)
            let displacement = max(abs(point.x - anchor.x), abs(point.y - anchor.y))
            // Fractional cell origins must not move an exact boundary below its threshold.
            guard displacement + 0.0001 >= threshold else { return false }
            let next = geometry.textHit(at: point) == nil ? nil : geometry.predictedHit(at: point, prior: prior)
            if let next, next != selected, selected != nil {
                let frame = geometry.targets[next].frame
                let interior = frame.insetBy(dx: min(10, frame.width * 0.25), dy: min(10, frame.height * 0.25))
                // Finger roll can travel far while barely entering another
                // cell. A slide must reach its interior before changing keys.
                guard interior.contains(point) else { return false }
            }
            anchor = point
            dragged = true
            selected = next
            return true
        }

        mutating func takeSelection() -> Int? {
            guard !consumed else { return nil }
            consumed = true
            return selected
        }

        mutating func finish(at point: CGPoint, in geometry: TypingGeometry, dockedPad: Bool,
                             cancelled: Bool = false) -> Int? {
            guard !cancelled, geometry.textHit(at: point) != nil else { cancel(); return nil }
            move(to: point, in: geometry, dockedPad: dockedPad)
            return takeSelection()
        }

        mutating func cancel() { consumed = true; selected = nil }
    }

    struct PredictionSnapshot: Equatable {
        let prefix: String
        let revision: UInt64
    }

    /// Read-only typing context, with no authority to replace terminal text.
    struct PredictionContext {
        private(set) var text = ""
        private(set) var revision: UInt64 = 0

        var snapshot: PredictionSnapshot? {
            let token = String(text.reversed().prefix { !$0.isWhitespace }.reversed())
            guard (1...32).contains(token.count), token.allSatisfy({ $0.isASCII && $0.isLetter }),
                  token.dropFirst().allSatisfy({ $0.isLowercase }) else { return nil }
            return PredictionSnapshot(prefix: token.lowercased(), revision: revision)
        }

        mutating func append(_ value: String) {
            guard !value.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else { reset(); return }
            text = String((text + value).suffix(128))
            revision &+= 1
        }

        mutating func backspace() {
            if !text.isEmpty { text.removeLast() }
            revision &+= 1
        }

        mutating func reset() { text = ""; revision &+= 1 }

        mutating func apply(_ mutation: TerminalCorrectionContext.Mutation, attributed: Bool) {
            switch mutation {
            case .text(let text, _) where attributed: append(text)
            case .backspace where attributed: backspace()
            default: reset()
            }
        }
    }

    struct LetterPrior {
        private var weights: [String: Double] = [:]
        var isEmpty: Bool { weights.isEmpty }

        init(prefix: String, completions: [String], isCompleteWord: Bool = false) {
            if isCompleteWord { weights[" "] = 1 }
            var seen = Set<String>()
            let matching = completions.map { $0.lowercased() }.filter {
                $0.hasPrefix(prefix) && $0.count > prefix.count && $0.allSatisfy { $0.isASCII && $0.isLetter }
                    && seen.insert($0).inserted
            }.prefix(32)
            for (rank, word) in matching.enumerated() {
                let letter = String(word[word.index(word.startIndex, offsetBy: prefix.count)])
                weights[letter, default: 0] += 1 / Double(rank + 1)
            }
        }

        func weight(for letter: String) -> Double { 0.1 + (weights[letter] ?? 0) }
    }

    struct PredictionCache {
        private var values: [String: LetterPrior] = [:]
        private var order: [String] = []

        subscript(prefix: String) -> LetterPrior? { values[prefix] }

        mutating func prior(for prefix: String, load: () -> LetterPrior) -> LetterPrior {
            if let cached = values[prefix] { return cached }
            let prior = load()
            values[prefix] = prior
            order.append(prefix)
            if order.count > 128 { values.removeValue(forKey: order.removeFirst()) }
            return prior
        }

        mutating func removeAll() { values.removeAll(); order.removeAll() }
    }

    enum ToolPage: Int, CaseIterable {
        case typing, symbols, navigation, shortcuts

        var title: String {
            switch self {
            case .typing: return String(localized: "Keyboard")
            case .symbols: return String(localized: "Symbols")
            case .navigation: return String(localized: "Navigation")
            case .shortcuts: return String(localized: "Shortcuts")
            }
        }

        func moved(by offset: Int) -> Self {
            let count = Self.allCases.count
            return Self(rawValue: (rawValue + offset % count + count) % count)!
        }
    }

    /// A deliberate horizontal stroke changes pages; ordinary key correction
    /// and vertical scrolling do not. The view excludes contacts owned by holds.
    static func pageSwipe(translation: CGPoint) -> Int? {
        guard abs(translation.x) >= 70, abs(translation.x) > abs(translation.y) * 2 else { return nil }
        return translation.x < 0 ? 1 : -1
    }

    enum ToolbarDrawerState: Equatable {
        case closed, stacked(Int), cycling(Int)

        func toggled(rowCount: Int, cycle: Bool) -> Self {
            guard rowCount > 0 else { return .closed }
            switch self {
            case .closed: return cycle ? .cycling(0) : .stacked(1)
            case .stacked(let count): return !cycle && count < rowCount ? .stacked(count + 1) : .closed
            case .cycling(let index): return cycle && index + 1 < rowCount ? .cycling(index + 1) : .closed
            }
        }

        func clamped(rowCount: Int) -> Self {
            guard rowCount > 0 else { return .closed }
            switch self {
            case .closed: return .closed
            case .stacked(let count): return .stacked(min(count, rowCount))
            case .cycling(let index): return .cycling(min(index, rowCount - 1))
            }
        }

        func visibleRows(rowCount: Int) -> [Int] {
            guard rowCount > 0 else { return [] }
            switch self {
            case .closed: return []
            case .stacked(let count): return Array((0..<min(count, rowCount)).reversed())
            case .cycling(let index): return [min(index, rowCount - 1)]
            }
        }
    }

    /// Keep configured rows intact. Main-row overflow joins the first drawer,
    /// including a button displaced to keep the drawer toggle reachable.
    static func toolbarKeys(main: [Key], drawers: [[Key]], width: CGFloat,
                            drawerToggle: Key? = nil) -> (main: [Key], drawers: [[Key]]) {
        KeyboardToolbarOverflow.layout(main: main, drawers: drawers,
            capacity: max(1, Int(max(0, width - 10) / 40)),
            drawerToggle: drawerToggle ?? Key(title: "…", action: .drawer),
            keepsDrawerToggleVisible: drawerToggle != nil)
    }

    /// Contrast is computed in linear light, after decoding the sRGB channels.
    struct RGB: Equatable {
        let red: Double
        let green: Double
        let blue: Double

        static let black = RGB(red: 0, green: 0, blue: 0)
        static let white = RGB(red: 1, green: 1, blue: 1)

        var luminance: Double {
            func linear(_ component: Double) -> Double {
                let value = min(1, max(0, component))
                return value <= 0.04045 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4)
            }
            return 0.2126 * linear(red) + 0.7152 * linear(green) + 0.0722 * linear(blue)
        }

        func contrast(against other: RGB) -> Double {
            (max(luminance, other.luminance) + 0.05) / (min(luminance, other.luminance) + 0.05)
        }

        func readableInk(preferred: RGB) -> RGB {
            if preferred.contrast(against: self) >= 4.5 { return preferred }
            return Self.white.contrast(against: self) > Self.black.contrast(against: self) ? .white : .black
        }
    }

    /// Paired neutral colors remain legible through keyboard-window trait changes.
    /// Both cap and ink must resolve from the same appearance, including Shift.
    static func keyColors(dark: Bool, character: Bool, pressed: Bool, selected: Bool) -> (background: Double, ink: Double) {
        if selected { return dark ? (0.96, 0.08) : (0.12, 1.0) }
        // Native dark keyboards use the same muted fill for letters and utilities.
        if dark { return (pressed ? 0.36 : 0.27, 1.0) }
        return (pressed ? 0.75 : (character ? 1.0 : 0.79), 0.08)
    }

    static func rows(page: Page) -> [[Key]] {
        func text(_ string: String) -> [Key] { string.map { Key(title: String($0), action: .text(String($0))) } }
        let shift = Key(title: "Shift", action: .modifier(.shift), symbol: "shift", weight: 1.5)
        let delete = Key(title: "Delete", action: .key("\u{7f}"), symbol: "delete.left", weight: 1.5)
        let first: [Key]
        let second: [Key]
        let third: [Key]
        switch page {
        case .letters:
            first = text("qwertyuiop")
            second = text("asdfghjkl")
            third = [shift] + text("zxcvbnm") + [delete]
        case .numbers:
            first = text("1234567890")
            second = text("-/:;()$&@\"")
            third = [Key(title: "#+=", action: .page, weight: 1.5)] + text(".,?!'[]") + [delete]
        case .symbols:
            first = text("[]{}#%^*+=")
            second = text("_\\|~<>€£¥•")
            third = [Key(title: "123", action: .page, weight: 1.5)] + text(".,?!'`;") + [delete]
        }
        return [first, second, third, [
            Key(title: page == .letters ? "123" : "ABC", action: .page, weight: 1.25),
            Key(title: "Apple Keyboard", action: .switchKeyboard, symbol: "keyboard", weight: 1.15),
            Key(title: "space", action: .text(" "), weight: 5.8, accessibility: "Space. Hold and drag to move the terminal cursor."),
            Key(title: "return", action: .key("\r"), symbol: "return", weight: 1.8)
        ]]
    }

    /// Full cells are hit targets; the visual caps are inset inside them.
    static func frames(keys: [Key], width: Double, y: Double, height: Double, inset: Double = 0) -> [CGRect] {
        let unit = max(0, width - inset * 2) / max(1, keys.reduce(0) { $0 + $1.weight })
        var x = inset
        return keys.map { key in
            defer { x += unit * key.weight }
            return CGRect(x: x, y: y, width: unit * key.weight, height: height)
        }
    }

    enum Placement: Equatable { case docked, floating }

    static func placementAfterPinch(_ scale: CGFloat, from placement: Placement) -> Placement {
        guard scale.isFinite else { return placement }
        switch placement {
        case .docked: return scale < 0.78 ? .floating : .docked
        case .floating: return scale > 1.22 ? .docked : .floating
        }
    }

    /// The anchor describes the available travel, not the screen coordinates,
    /// so a floating keyboard remains reachable after rotation/window resizing.
    static func floatingFrame(in available: CGRect, height: CGFloat, anchor: CGPoint) -> CGRect {
        let size = CGSize(width: min(320, max(0, available.width)), height: min(max(0, height), max(0, available.height)))
        let x = min(1, max(0, anchor.x.isFinite ? anchor.x : 1))
        let y = min(1, max(0, anchor.y.isFinite ? anchor.y : 1))
        return CGRect(x: available.minX + (available.width - size.width) * x,
                      y: available.minY + (available.height - size.height) * y, width: size.width, height: size.height)
    }

    static func floatingAnchor(for frame: CGRect, in available: CGRect) -> CGPoint {
        let travelX = available.width - frame.width, travelY = available.height - frame.height
        return CGPoint(x: travelX > 0 ? min(1, max(0, (frame.minX - available.minX) / travelX)) : 0.5,
                       y: travelY > 0 ? min(1, max(0, (frame.minY - available.minY) / travelY)) : 0.5)
    }

    static func shouldDockAfterDrag(_ frame: CGRect, in available: CGRect) -> Bool {
        frame.maxY >= available.maxY - 18 && abs(frame.midX - available.midX) < available.width * 0.2
    }

    /// Preserve UIKit's card size while keeping a dragged native panel on screen.
    static func clampedFloatingDragFrame(_ frame: CGRect, in available: CGRect) -> CGRect {
        guard !available.isEmpty, !frame.isEmpty else { return frame }
        return CGRect(x: min(max(frame.minX, available.minX), max(available.minX, available.maxX - frame.width)),
                      y: min(max(frame.minY, available.minY), max(available.minY, available.maxY - frame.height)),
                      width: frame.width, height: frame.height)
    }

    /// Detect an existing native floating input region.
    static func isFloatingInput(width: CGFloat, hostWidth: CGFloat, isPad: Bool) -> Bool {
        isPad && width > 0 && width <= 400 && width < hostWidth - 1
    }

    struct Shortcut {
        let title: String
        let key: String
        var modifiers: Int = 0
        var chord: String {
            (modifiers & 1 != 0 ? "⌃" : "") + (modifiers & 2 != 0 ? "⌥" : "")
                + (modifiers & 8 != 0 ? "⇧" : "")
                + (["\u{1b}": "Esc", "\t": "Tab", "\r": "Return"][key] ?? key)
        }
    }

    enum Preset: String, CaseIterable {
        case shell = "Shell", vim = "Vim", emacs = "Emacs", nano = "Nano", agent = "Agent"

        /// Insert literal text so commands can take arguments before Return.
        /// Availability depends on the coding agent running in the terminal.
        var slashCommands: [String] {
            guard self == .agent else { return [] }
            return ["/model", "/copy", "/help", "/clear", "/compact", "/resume",
                    "/status", "/diff", "/review", "/plan", "/init", "/exit"]
        }

        var shortcuts: [Shortcut] {
            func ctrl(_ title: String, _ key: String) -> Shortcut { Shortcut(title: title, key: key, modifiers: 1) }
            switch self {
            case .shell:
                return [ctrl("Interrupt", "c"), ctrl("EOF", "d"), ctrl("Clear", "l"), ctrl("History", "r"),
                        ctrl("Line start", "a"), ctrl("Line end", "e"), ctrl("Delete word", "w")]
            case .vim:
                return [Shortcut(title: "Normal mode", key: "\u{1b}"), Shortcut(title: "Command", key: ":"),
                        Shortcut(title: "Search", key: "/"), Shortcut(title: "Next match", key: "n"),
                        Shortcut(title: "Previous match", key: "N"), Shortcut(title: "Undo", key: "u"),
                        ctrl("Redo", "r"), ctrl("Half page down", "d"), ctrl("Half page up", "u")]
            case .emacs:
                return [ctrl("Cancel", "g"), ctrl("Prefix", "x"), Shortcut(title: "Command", key: "x", modifiers: 2),
                        ctrl("Search", "s"), ctrl("Line start", "a"), ctrl("Line end", "e"), ctrl("Kill line", "k"), ctrl("Yank", "y")]
            case .nano:
                return [ctrl("Write out", "o"), ctrl("Exit", "x"), ctrl("Search", "w"),
                        ctrl("Cut", "k"), ctrl("Uncut", "u"), ctrl("Help", "g")]
            case .agent:
                return [Shortcut(title: "Escape", key: "\u{1b}"), ctrl("Interrupt", "c"),
                        Shortcut(title: "Tab", key: "\t"), Shortcut(title: "Backtab", key: "\t", modifiers: 8),
                        Shortcut(title: "Shift-Return", key: "\r", modifiers: 8)]
            }
        }
    }

    static let accents: [String: String] = [
        "a": "àáâäæãåā", "e": "èéêëēėę", "i": "ìíîïīį", "o": "òóôöõøœō",
        "u": "ùúûüū", "c": "çćč", "n": "ñń", "s": "ßśš", "y": "ÿý", "z": "žźż"
    ]

    struct SuggestionContext: Equatable, Sendable {
        let document: String
        let generation: UInt64
        let documentGeneration: UInt64
        let range: NSRange
        var word: String { (document as NSString).substring(with: range) }

        init?(document: String, eligibleCount: Int, generation: UInt64, documentGeneration: UInt64) {
            let suffix = document.reversed().prefix { $0.isASCII && $0.isLetter }.reversed()
            let word = String(suffix)
            guard word.count >= 2, word.count <= 32, word.utf16.count <= eligibleCount else { return nil }
            let prefix = document.dropLast(word.count)
            // Never guess inside a path, identifier, flag, or shell expansion.
            guard prefix.isEmpty || prefix.last?.isWhitespace == true else { return nil }
            self.document = document
            self.generation = generation
            self.documentGeneration = documentGeneration
            self.range = NSRange(location: document.utf16.count - word.utf16.count, length: word.utf16.count)
        }
    }
}
