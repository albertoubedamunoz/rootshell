//
//  KeyboardChooserView.swift
//  rootshell
//
//  One-time iPhone onboarding: choose the system keyboard or a Terminal Keyboard
//  style, learn page swiping, and where to change it later.
//

#if !os(visionOS) && !targetEnvironment(macCatalyst)
import SwiftUI
import UIKit

/// Process-lifetime guard so the chooser offers itself at most once per launch.
enum KeyboardChooserLaunch {
    static var didOffer = false

    /// Debug reset: offer again on the next eligible moment.
    static func reset() {
        SettingsStore.shared.reset(Settings.Keyboard.touchChooserPresented)
        didOffer = false
    }
}

enum KeyboardChoice: Hashable {
    case system
    case custom(TerminalTouchKeyboardModel.Style)

    static let all: [KeyboardChoice] = [.system] + TerminalTouchKeyboardModel.Style.allCases.map { .custom($0) }

    static var current: KeyboardChoice {
        SettingsStore.shared.value(Settings.Keyboard.touchEnabled)
            ? .custom(SettingsStore.shared.value(Settings.Keyboard.touchStyle)) : .system
    }

    var title: String {
        switch self {
        case .system: String(localized: "System Keyboard")
        case .custom(let style): style.displayName
        }
    }

    var tagline: String {
        switch self {
        case .system:
            String(localized: "Every language, dictation, swipe typing, and emoji, with rootshell’s toolbar above it.")
        case .custom(.flat):
            String(localized: "The original terminal keyboard. Clean, quiet, and theme-matched.")
        case .custom(.sculpted):
            String(localized: "Raised keycaps with depth and soft shadows.")
        case .custom(.steampunk):
            String(localized: "Brass-rimmed instrument keys and a mechanical drive that responds to touch.")
        case .custom(.phosphor):
            String(localized: "Glowing keys on a dark CRT screen.")
        case .custom(.beigeBox):
            String(localized: "Tall keys like a classic office keyboard.")
        case .custom(.neonGrid):
            String(localized: "Glowing keys over a synthwave horizon that moves as you type.")
        case .custom(.circuitBoard):
            String(localized: "A pulse runs along the board’s traces with each key press.")
        }
    }

    var style: TerminalTouchKeyboardModel.Style? {
        if case .custom(let style) = self { return style }
        return nil
    }
}

struct KeyboardChooserView: View {
    let onFinish: () -> Void
    let onOpenSettings: () -> Void

    private enum Step: Int { case choose, swipe, finish }

    @Environment(\.sheetThemeColors) private var themeColors
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var step: Step = .choose
    @State private var forward = true
    @State private var chosen: KeyboardChoice = .current
    @State private var selection: KeyboardChoice? = .current

    private var steps: [Step] { chosen == .system ? [.choose, .finish] : [.choose, .swipe, .finish] }

    var body: some View {
        VStack(spacing: 0) {
            header
            Group {
                switch step {
                case .choose:
                    ChooseStep(selection: $selection, current: chosen) { choice in
                        save(choice)
                        advance(to: choice == .system ? .finish : .swipe)
                    }
                case .swipe:
                    if let style = chosen.style {
                        SwipeStep(style: style) { advance(to: .finish) } onBack: { back(to: .choose) }
                    }
                case .finish:
                    FinishStep(choice: chosen, onStart: finish, onOpenSettings: {
                        markPresented()
                        onOpenSettings()
                    }, onBack: { back(to: chosen == .system ? .choose : .swipe) })
                }
            }
            .id(step)
            .transition(stepTransition)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(background.ignoresSafeArea())
        .accessibilityAddTraits(.isModal)
    }

    private var header: some View {
        ZStack {
            HStack(spacing: 6) {
                ForEach(steps, id: \.self) { item in
                    Capsule()
                        .fill(item == step ? Color.accentColor : Color.secondary.opacity(0.3))
                        .frame(width: item == step ? 22 : 8, height: 8)
                }
            }
            .animation(.snappy, value: step)
            .accessibilityElement()
            .accessibilityLabel("Step \((steps.firstIndex(of: step) ?? 0) + 1) of \(steps.count)")

            HStack {
                Spacer()
                if step != .finish {
                    Button("Skip", action: finish)
                        .font(.body.weight(.medium))
                        .frame(minWidth: 44, minHeight: 44)
                        .accessibilityHint("Keeps your current keyboard. You can change it later in Settings.")
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 4)
    }

    private var background: some View {
        let base = themeColors?.background ?? Color(.systemGroupedBackground)
        return base.overlay {
            RadialGradient(
                colors: [Color.accentColor.opacity(0.22), .clear],
                center: .top, startRadius: 0, endRadius: 520)
        }
    }

    private var stepTransition: AnyTransition {
        guard !reduceMotion else { return .opacity }
        return .asymmetric(
            insertion: .move(edge: forward ? .trailing : .leading).combined(with: .opacity),
            removal: .move(edge: forward ? .leading : .trailing).combined(with: .opacity))
    }

    private func save(_ choice: KeyboardChoice) {
        chosen = choice
        switch choice {
        case .system:
            SettingsStore.shared.set(Settings.Keyboard.touchEnabled, false)
        case .custom(let style):
            SettingsStore.shared.set(Settings.Keyboard.touchStyle, style)
            SettingsStore.shared.set(Settings.Keyboard.touchEnabled, true)
        }
    }

    private func advance(to next: Step) {
        forward = true
        withAnimation(reduceMotion ? .easeInOut(duration: 0.2) : .spring(duration: 0.45)) { step = next }
    }

    private func back(to previous: Step) {
        forward = false
        withAnimation(reduceMotion ? .easeInOut(duration: 0.2) : .spring(duration: 0.45)) { step = previous }
    }

    private func markPresented() {
        SettingsStore.shared.set(Settings.Keyboard.touchChooserPresented, true)
    }

    private func finish() {
        markPresented()
        onFinish()
    }
}

// MARK: - Step 1: choose

private struct ChooseStep: View {
    @Binding var selection: KeyboardChoice?
    let current: KeyboardChoice
    let onChoose: (KeyboardChoice) -> Void

    private var selected: KeyboardChoice { selection ?? current }
    private var index: Int { KeyboardChoice.all.firstIndex(of: selected) ?? 0 }

    var body: some View {
        VStack(spacing: 16) {
            VStack(spacing: 8) {
                Text("Choose Your Keyboard")
                    .font(.largeTitle.bold())
                    .accessibilityAddTraits(.isHeader)
                Text("rootshell’s Terminal Keyboard is optimized for terminal use and more compact, leaving more room for your terminal. Swipe across the keys for its Symbols, Navigation, and Shortcuts pages. Or keep the system keyboard.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            .multilineTextAlignment(.center)
            .minimumScaleFactor(0.8)
            .padding(.horizontal, 24)
            .padding(.top, 8)

            carousel

            PageDots(count: KeyboardChoice.all.count, index: index) { newIndex in
                withAnimation(.snappy) { selection = KeyboardChoice.all[newIndex] }
            }

            Button {
                onChoose(selected)
            } label: {
                Text("Use \(selected.title)")
                    .font(.headline)
                    .contentTransition(.interpolate)
                    .frame(maxWidth: .infinity, minHeight: 50)
            }
            .buttonStyle(.borderedProminent)
            .buttonBorderShape(.capsule)
            .padding(.horizontal, 24)
            .padding(.bottom, 12)
            .animation(.snappy, value: selected)
        }
    }

    private var carousel: some View {
        ScrollView(.horizontal) {
            LazyHStack(spacing: 0) {
                ForEach(KeyboardChoice.all, id: \.self) { choice in
                    KeyboardChoiceCard(choice: choice, isCurrent: choice == current)
                        .padding(.horizontal, 20)
                        .containerRelativeFrame(.horizontal)
                        .scrollTransition(.interactive, axis: .horizontal) { content, phase in
                            content
                                .scaleEffect(phase.isIdentity ? 1 : 0.9)
                                .opacity(phase.isIdentity ? 1 : 0.55)
                        }
                }
            }
            .scrollTargetLayout()
        }
        .scrollTargetBehavior(.paging)
        .scrollPosition(id: $selection)
        .scrollIndicators(.hidden)
        .sensoryFeedback(.selection, trigger: selection)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Keyboard style")
        .accessibilityValue("\(selected.title), \(index + 1) of \(KeyboardChoice.all.count). \(selected.tagline)")
        .accessibilityHint("Swipe up or down to change. Double-tap Use to choose.")
        .accessibilityAdjustableAction { direction in
            let all = KeyboardChoice.all
            switch direction {
            case .increment: selection = all[min(all.count - 1, index + 1)]
            case .decrement: selection = all[max(0, index - 1)]
            @unknown default: break
            }
        }
    }
}

private struct KeyboardChoiceCard: View {
    let choice: KeyboardChoice
    let isCurrent: Bool
    @State private var previewHeight: CGFloat = 280

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .firstTextBaseline) {
                    Text(choice.title)
                        .font(.title2.bold())
                    Spacer()
                    if isCurrent {
                        Text("Current")
                            .font(.caption.weight(.semibold))
                            .padding(.horizontal, 8)
                            .padding(.vertical, 3)
                            .background(Color.accentColor.opacity(0.18), in: Capsule())
                            .foregroundStyle(Color.accentColor)
                    }
                }
                Text(choice.tagline)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(18)

            Spacer(minLength: 8)

            GeometryReader { geometry in
                let scale = min(1, geometry.size.height / max(1, previewHeight))
                preview
                    .frame(width: geometry.size.width / scale, height: previewHeight)
                    .scaleEffect(scale, anchor: .bottom)
                    .frame(width: geometry.size.width, height: geometry.size.height, alignment: .bottom)
            }
            .frame(maxHeight: previewHeight)
            .layoutPriority(1)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
        }
        .frame(maxHeight: .infinity)
        .clipShape(RoundedRectangle(cornerRadius: 28, style: .continuous))
        .chooserCardBackground(cornerRadius: 28)
    }

    @ViewBuilder
    private var preview: some View {
        switch choice {
        case .system:
            SystemKeyboardMock()
        case .custom(let style):
            TerminalTouchKeyboardPreview(
                sample: .constant(""), height: $previewHeight, floating: false, style: style)
        }
    }
}

private struct PageDots: View {
    let count: Int
    let index: Int
    let onSelect: (Int) -> Void

    var body: some View {
        HStack(spacing: 8) {
            ForEach(0..<count, id: \.self) { dot in
                Circle()
                    .fill(dot == index ? Color.accentColor : Color.secondary.opacity(0.3))
                    .frame(width: 7, height: 7)
                    .scaleEffect(dot == index ? 1.25 : 1)
                    .frame(width: 16, height: 24)
                    .contentShape(Rectangle())
                    .onTapGesture { onSelect(dot) }
            }
        }
        .animation(.snappy, value: index)
        .accessibilityHidden(true)
    }
}

/// A stylized stand-in for the system keyboard (the real one cannot be rendered).
private struct SystemKeyboardMock: View {
    @Environment(\.colorScheme) private var colorScheme

    private let rows: [[String]] = [
        Array("qwertyuiop").map(String.init),
        Array("asdfghjkl").map(String.init),
        ["⇧"] + Array("zxcvbnm").map(String.init) + ["⌫"],
    ]
    private var keyFill: Color { colorScheme == .dark ? Color(white: 0.42) : .white }
    private var specialFill: Color { colorScheme == .dark ? Color(white: 0.27) : Color(white: 0.68) }
    private var plate: Color { colorScheme == .dark ? Color(white: 0.17) : Color(white: 0.82) }

    var body: some View {
        VStack(spacing: 0) {
            // The real toolbar, so the preview matches the user's saved layout.
            ToolbarPreview()
                .frame(height: KeyboardSizes.current().toolbar.height)

            VStack(spacing: 11) {
                ForEach(rows.indices, id: \.self) { row in
                    HStack(spacing: 6) {
                        ForEach(rows[row], id: \.self) { key in
                            let special = key == "⇧" || key == "⌫"
                            keycap(key, special: special)
                                .frame(maxWidth: special ? 42 : .infinity)
                        }
                    }
                    .padding(.horizontal, row == 1 ? 18 : 0)
                }
                HStack(spacing: 6) {
                    keycap("123", special: true).frame(width: 46)
                    keycap("🙂", special: true).frame(width: 40)
                    keycap("space", special: false)
                    keycap("return", special: true).frame(width: 88)
                }
                HStack {
                    Image(systemName: "globe")
                    Spacer()
                    Image(systemName: "mic")
                }
                .font(.system(size: 20))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 18)
                .padding(.bottom, 10)
            }
            .padding(.horizontal, 4)
            .padding(.top, 10)
        }
        .background(plate)
    }

    private func keycap(_ label: String, special: Bool) -> some View {
        Text(label)
            .font(.system(size: label.count > 1 ? 15 : 22))
            .foregroundStyle(.primary)
            .frame(maxWidth: .infinity, minHeight: 42)
            .background(special ? specialFill : keyFill, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
            .shadow(color: .black.opacity(0.25), radius: 0, y: 1)
    }
}

/// Non-interactive `KeyboardToolbarView`; it builds its buttons once it has a width.
private struct ToolbarPreview: UIViewRepresentable {
    func makeUIView(context: Context) -> KeyboardToolbarView {
        let toolbar = KeyboardToolbarView(sizes: .current())
        toolbar.isUserInteractionEnabled = false
        return toolbar
    }

    func updateUIView(_ toolbar: KeyboardToolbarView, context: Context) {}
}

// MARK: - Step 2: swipe tutorial

private struct SwipeStep: View {
    let style: TerminalTouchKeyboardModel.Style
    let onContinue: () -> Void
    let onBack: () -> Void

    private typealias Page = TerminalTouchKeyboardModel.ToolPage
    @State private var visited: Set<Page> = [.typing]
    @State private var currentPage: Page = .typing
    @State private var sample = ""
    @State private var previewHeight: CGFloat = 280
    @State private var hintOffset: CGFloat = 0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var allVisited: Bool { visited.count == Page.allCases.count }

    var body: some View {
        VStack(spacing: 0) {
            ScrollView(.vertical) {
                VStack(spacing: 18) {
                    VStack(spacing: 8) {
                        Text("Swipe Between Pages")
                            .font(.largeTitle.bold())
                            .accessibilityAddTraits(.isHeader)
                        Text("Swipe left or right across the keys to reach Symbols, Navigation, and Shortcuts. Try it below.")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    .multilineTextAlignment(.center)

                    swipeHint

                    HStack(spacing: 8) {
                        ForEach(Page.allCases, id: \.self) { page in
                            PageChip(title: page.title, visited: visited.contains(page), current: page == currentPage)
                        }
                    }

                    Label("Hold Space and drag to move the cursor.", systemImage: "hand.draw")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal, 24)
                .padding(.top, 8)
                .padding(.bottom, 12)
                .frame(maxWidth: .infinity)
            }
            .scrollBounceBehavior(.basedOnSize)

            HStack(spacing: 12) {
                Button("Back", action: onBack)
                    .frame(minWidth: 64, minHeight: 50)
                Button(action: onContinue) {
                    Text(allVisited ? "Continue" : "Skip Tutorial")
                        .font(.headline)
                        .contentTransition(.interpolate)
                        .frame(maxWidth: .infinity, minHeight: 50)
                }
                .buttonStyle(.borderedProminent)
                .buttonBorderShape(.capsule)
            }
            .padding(.horizontal, 24)
            .padding(.bottom, 12)
            .animation(.snappy, value: allVisited)

            VStack(spacing: 0) {
                HStack(spacing: 8) {
                    Text("❯").foregroundStyle(.secondary)
                    Text(sample.isEmpty ? "Type here to try it…" : sample)
                        .foregroundStyle(sample.isEmpty ? .secondary : .primary)
                        .lineLimit(1)
                        .truncationMode(.head)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .font(.system(.body, design: .monospaced))
                .padding(.horizontal, 16)
                .frame(height: 44)
                TerminalTouchKeyboardPreview(
                    sample: $sample, height: $previewHeight, floating: false, style: style,
                    onPageChanged: { page in
                        currentPage = page
                        visited.insert(page)
                    })
                    .frame(height: previewHeight)
            }
            .background(.bar)
        }
        .ignoresSafeArea(.container, edges: .bottom)
        .sensoryFeedback(.success, trigger: allVisited) { _, done in done }
        .sensoryFeedback(.selection, trigger: currentPage)
    }

    private var swipeHint: some View {
        HStack(spacing: 14) {
            Image(systemName: "chevron.left")
            Image(systemName: "hand.point.up.left.fill")
                .font(.system(size: 34))
                .offset(x: hintOffset)
            Image(systemName: "chevron.right")
        }
        .font(.title3.weight(.semibold))
        .foregroundStyle(Color.accentColor)
        .frame(height: 56)
        .accessibilityHidden(true)
        .opacity(allVisited ? 0.35 : 1)
        .task {
            guard !reduceMotion else { return }
            withAnimation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true)) { hintOffset = 22 }
        }
    }
}

private struct PageChip: View {
    let title: String
    let visited: Bool
    let current: Bool

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: visited ? "checkmark.circle.fill" : "circle")
                .contentTransition(.symbolEffect(.replace))
            Text(title)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
        .font(.caption.weight(.semibold))
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity)
        .foregroundStyle(visited ? Color.accentColor : Color.secondary)
        .background(Color.accentColor.opacity(current ? 0.2 : visited ? 0.1 : 0), in: Capsule())
        .overlay(Capsule().strokeBorder(Color.secondary.opacity(visited ? 0 : 0.3)))
        .animation(.snappy, value: visited)
        .animation(.snappy, value: current)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(title)
        .accessibilityValue(visited ? String(localized: "Visited") : String(localized: "Not visited"))
    }
}

// MARK: - Step 3: finish

private struct FinishStep: View {
    let choice: KeyboardChoice
    let onStart: () -> Void
    let onOpenSettings: () -> Void
    let onBack: () -> Void

    @State private var appeared = false

    var body: some View {
        VStack(spacing: 0) {
            ScrollView(.vertical) {
                VStack(spacing: 20) {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 64))
                        .foregroundStyle(Color.accentColor)
                        .symbolEffect(.bounce, value: appeared)
                        .padding(.top, 12)
                        .accessibilityHidden(true)

                    VStack(spacing: 6) {
                        Text("You’re All Set")
                            .font(.largeTitle.bold())
                            .accessibilityAddTraits(.isHeader)
                        Text("Your keyboard: \(choice.title)")
                            .font(.headline)
                            .foregroundStyle(.secondary)
                    }
                    .multilineTextAlignment(.center)

                    settingsCard

                    VStack(alignment: .leading, spacing: 14) {
                        ForEach(tips.indices, id: \.self) { index in
                            TipRow(symbol: tips[index].symbol, text: tips[index].text)
                        }
                    }
                    .padding(18)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .chooserCardBackground(cornerRadius: 22)
                }
                .padding(.horizontal, 24)
                .padding(.bottom, 12)
            }
            .scrollBounceBehavior(.basedOnSize)

            HStack(spacing: 12) {
                Button("Back", action: onBack)
                    .frame(minWidth: 64, minHeight: 50)
                Button(action: onStart) {
                    Text("Start Using rootshell")
                        .font(.headline)
                        .frame(maxWidth: .infinity, minHeight: 50)
                }
                .buttonStyle(.borderedProminent)
                .buttonBorderShape(.capsule)
            }
            .padding(.horizontal, 24)
            .padding(.bottom, 12)
        }
        .onAppear { appeared = true }
    }

    private var settingsCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Change it any time", systemImage: "gearshape")
                .font(.headline)
            SettingsPath(components: [
                String(localized: "Settings"), String(localized: "Terminal"), String(localized: "Terminal Keyboard"),
            ])
            (choice == .system
                ? Text("Turn on Terminal Keyboard there to switch, and pick a style under Appearance.")
                : Text("Pick another style under Appearance, or turn Terminal Keyboard off to use the system keyboard."))
                .font(.footnote)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Button(action: onOpenSettings) {
                Label("Open Keyboard Settings", systemImage: "arrow.up.forward.app")
                    .font(.subheadline.weight(.semibold))
                    .frame(minHeight: 44)
            }
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .chooserCardBackground(cornerRadius: 22)
    }

    private var tips: [(symbol: String, text: LocalizedStringKey)] {
        switch choice {
        case .system:
            [
                ("keyboard.badge.ellipsis", "The toolbar above the system keyboard has Esc, Ctrl, Tab, and arrow keys."),            ]
        case .custom:
            [
                ("hand.draw", "Swipe left or right across the keys for Symbols, Navigation, and Shortcuts."),
                ("keyboard", "Tap the keyboard key beside 123 to use the system keyboard for dictation, emoji, or other languages. It switches for this session only."),
                ("arrow.left.and.right", "Hold Space and drag to move the cursor."),
            ]
        }
    }
}

private struct SettingsPath: View {
    let components: [String]

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 6) { chips }
            VStack(alignment: .leading, spacing: 6) { chips }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(components.joined(separator: ", "))
    }

    @ViewBuilder
    private var chips: some View {
        ForEach(components.indices, id: \.self) { index in
            HStack(spacing: 6) {
                if index > 0 {
                    Image(systemName: "chevron.right")
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(.tertiary)
                }
                Text(components[index])
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(Color.accentColor.opacity(0.14), in: Capsule())
            }
        }
    }
}

private struct TipRow: View {
    let symbol: String
    let text: LocalizedStringKey

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Image(systemName: symbol)
                .foregroundStyle(Color.accentColor)
                .frame(width: 24)
                .accessibilityHidden(true)
            Text(text)
                .font(.subheadline)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

private extension View {
    @ViewBuilder
    func chooserCardBackground(cornerRadius: CGFloat) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        if #available(iOS 26.0, *) {
            glassEffect(.regular, in: shape)
        } else {
            background(.ultraThinMaterial, in: shape)
        }
    }
}

#endif
