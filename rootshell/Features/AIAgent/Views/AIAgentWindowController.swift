#if !CHINA_BUILD
//
//  AIAgentWindowController.swift
//  rootshell
//
//  UIViewController wrapper that handles keyboard shortcuts for the AI Agent window.
//  Uses the same patterns as TerminalView for reliable Mac Catalyst keyboard handling:
//  - UIKeyCommands with wantsPriorityOverSystemBehavior
//  - pressesBegan workaround for macOS Sequoia
//

import UIKit
import SwiftUI

/// UIViewControllerRepresentable wrapper for use in SwiftUI WindowGroup
struct AIAgentWindowControllerRepresentable: UIViewControllerRepresentable {
    func makeUIViewController(context: Context) -> AIAgentWindowController {
        AIAgentWindowController()
    }

    func updateUIViewController(_ uiViewController: AIAgentWindowController, context: Context) {
        // No updates needed - state is managed by AIAgentWindowState singleton
    }
}

/// UIViewController that handles keyboard shortcuts for the AI Agent window
/// Embeds AIAgentWindowView as a child hosting controller
@MainActor
class AIAgentWindowController: UIViewController {
    private var hostingController: UIHostingController<AIAgentWindowContentView>!

    override var canBecomeFirstResponder: Bool { true }

    override func viewDidLoad() {
        super.viewDidLoad()

        // Create hosting controller with the window content
        hostingController = UIHostingController(rootView: AIAgentWindowContentView())
        addChild(hostingController)
        view.addSubview(hostingController.view)
        hostingController.view.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            hostingController.view.topAnchor.constraint(equalTo: view.topAnchor),
            hostingController.view.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            hostingController.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            hostingController.view.trailingAnchor.constraint(equalTo: view.trailingAnchor)
        ])
        hostingController.didMove(toParent: self)
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        // Become first responder to receive key commands
        becomeFirstResponder()
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        AIAgentWindowState.shared.isWindowOpen = true
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        AIAgentWindowState.shared.isWindowOpen = false
    }

    // MARK: - Key Commands

    override var keyCommands: [UIKeyCommand]? {
        // Built from the user's live bindings so remaps are honored (defaults:
        // Cmd+[ prev, Cmd+] next, Cmd+W close, Cmd+1-9 select).
        let manager = KeybindManager.shared
        var commands: [UIKeyCommand] = [
            manager.keyCommand(for: .previous_tab, selector: #selector(menuPreviousTab(_:)), wantsPriority: true),
            manager.keyCommand(for: .next_tab, selector: #selector(menuNextTab(_:)), wantsPriority: true),
            manager.keyCommand(for: .close_tab, selector: #selector(menuCloseTab(_:)), wantsPriority: true),
        ].compactMap { $0 }

        // A dedicated selector per tab (menuSelectTab1...9) carries the tab number, so
        // a remapped select-tab key resolves correctly without parsing the input char.
        for (index, action) in Self.selectTabActions.enumerated() {
            if let command = manager.keyCommand(for: action, selector: Self.selectTabSelectors[index]) {
                commands.append(command)
            }
        }
        return commands
    }

    private static let selectTabActions: [KeybindAction] = [
        .select_tab_1, .select_tab_2, .select_tab_3, .select_tab_4, .select_tab_5,
        .select_tab_6, .select_tab_7, .select_tab_8, .select_tab_9,
    ]

    private static let selectTabSelectors: [Selector] = [
        #selector(menuSelectTab1(_:)), #selector(menuSelectTab2(_:)), #selector(menuSelectTab3(_:)),
        #selector(menuSelectTab4(_:)), #selector(menuSelectTab5(_:)), #selector(menuSelectTab6(_:)),
        #selector(menuSelectTab7(_:)), #selector(menuSelectTab8(_:)), #selector(menuSelectTab9(_:)),
    ]

    // MARK: - Mac Catalyst pressesBegan Workaround

    #if targetEnvironment(macCatalyst)
    override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        for press in presses {
            guard let key = press.key else { continue }
            if handleTabNavPress(key) { return }
        }
        super.pressesBegan(presses, with: event)
    }

    /// Match the press against the live tab-nav bindings (honors remaps) rather than
    /// the hardcoded chords. keyCommands don't always fire in this window on Catalyst.
    private func handleTabNavPress(_ key: UIKey) -> Bool {
        let manager = KeybindManager.shared
        func matches(_ action: KeybindAction) -> Bool {
            guard let trigger = manager.keybind(for: action)?.sequence.first else { return false }
            return key.modifierFlags == trigger.uiModifierFlags
                && key.characters.lowercased() == trigger.uiKeyInput.lowercased()
        }
        if matches(.close_tab) { handleCloseTab(); return true }
        if matches(.previous_tab) { handlePreviousTab(); return true }
        if matches(.next_tab) { handleNextTab(); return true }
        for (index, action) in Self.selectTabActions.enumerated() where matches(action) {
            handleSelectTab(index + 1)
            return true
        }
        return false
    }
    #endif

    // MARK: - Menu Action Handlers (for responder chain from AppCommands)

    @objc func menuPreviousTab(_ sender: Any?) {
        handlePreviousTab()
    }

    @objc func menuNextTab(_ sender: Any?) {
        handleNextTab()
    }

    @objc func menuCloseTab(_ sender: Any?) {
        handleCloseTab()
    }

    @objc func menuSelectTab(_ command: UIKeyCommand) {
        if let input = command.input, let num = Int(input) {
            handleSelectTab(num)
        }
    }

    // Also support the menu action names from AppCommands
    @objc func menuSelectTab1(_ sender: Any?) { handleSelectTab(1) }
    @objc func menuSelectTab2(_ sender: Any?) { handleSelectTab(2) }
    @objc func menuSelectTab3(_ sender: Any?) { handleSelectTab(3) }
    @objc func menuSelectTab4(_ sender: Any?) { handleSelectTab(4) }
    @objc func menuSelectTab5(_ sender: Any?) { handleSelectTab(5) }
    @objc func menuSelectTab6(_ sender: Any?) { handleSelectTab(6) }
    @objc func menuSelectTab7(_ sender: Any?) { handleSelectTab(7) }
    @objc func menuSelectTab8(_ sender: Any?) { handleSelectTab(8) }
    @objc func menuSelectTab9(_ sender: Any?) { handleSelectTab(9) }

    // MARK: - Private Handlers

    private func handlePreviousTab() {
        withAnimation(TabAnimation.selection) {
            AIAgentWindowState.shared.previousSession()
        }
    }

    private func handleNextTab() {
        withAnimation(TabAnimation.selection) {
            AIAgentWindowState.shared.nextSession()
        }
    }

    private func handleCloseTab() {
        if AIAgentWindowState.shared.closeCurrentSession() {
            // Last session closed - close the window
            closeWindow()
        }
    }

    private func closeWindow() {
        guard let windowScene = view.window?.windowScene else { return }
        let options = UIWindowSceneDestructionRequestOptions()
        options.windowDismissalAnimation = .standard
        UIApplication.shared.requestSceneSessionDestruction(
            windowScene.session,
            options: options
        )
    }

    private func handleSelectTab(_ index: Int) {
        withAnimation(TabAnimation.selection) {
            AIAgentWindowState.shared.selectSession(at: index)
        }
    }
}

// MARK: - Window Content View

/// The actual content of the AI Agent window (moved from AIAgentWindowView)
/// This is the SwiftUI content that gets hosted inside AIAgentWindowController
struct AIAgentWindowContentView: View {
    @State private var windowState = AIAgentWindowState.shared
    var themeManager = ThemeManager.shared
    @Namespace private var tabNamespace

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                // Session picker header (when multiple sessions)
                if windowState.sessionCount > 1 {
                    sessionPicker
                        .transition(.move(edge: .top).combined(with: .opacity))
                }

                // Current session content
                if let tabID = windowState.selectedSessionTabID,
                   let session = windowState.currentSession {
                    AIAgentOverlayView(
                        isPresented: .constant(true),
                        session: session,
                        tabID: tabID,
                        showCloseButton: false,
                        useWindowThemeColors: true
                    )
                } else {
                    noSessionsView
                }
            }
            .animation(TabAnimation.appearance, value: windowState.sessionCount)
            .animation(TabAnimation.selection, value: windowState.selectedSessionTabID)
            #if targetEnvironment(macCatalyst)
            .navigationTitle(windowTitle)
            .navigationBarTitleDisplayMode(.inline)
            #else
            .toolbar {
                ToolbarItem(placement: .principal) {
                    if windowState.sessionCount <= 1 {
                        Text(windowTitle)
                            .font(.headline)
                    }
                }
            }
            #endif
        }
    }

    // MARK: - Computed Properties

    private var windowTitle: String {
        guard let session = windowState.currentSession else {
            return "AI Agent"
        }
        return session.displayName
    }

    // MARK: - Theme-Adaptive Tab Colors

    private var selectedTabBackgroundColor: Color {
        if let themeColors = themeManager.currentThemeInfo?.colors,
           let baseColor = Color(hex: themeColors.background) {
            if baseColor.isLight {
                return baseColor.blendedWithBlack(0.20)
            } else {
                return baseColor.blendedWithWhite(0.18)
            }
        }
        return Color(uiColor: .secondarySystemBackground)
    }

    private var unselectedTabBackgroundColor: Color {
        if let themeColors = themeManager.currentThemeInfo?.colors,
           let baseColor = Color(hex: themeColors.background) {
            if baseColor.isLight {
                return baseColor.blendedWithBlack(0.08)
            } else {
                return baseColor.blendedWithWhite(0.08)
            }
        }
        return Color(uiColor: .tertiarySystemBackground)
    }

    private var tabTextColor: Color {
        if let themeColors = themeManager.currentThemeInfo?.colors,
           let baseColor = Color(hex: themeColors.background) {
            return baseColor.isLight ? Color(white: 0.1) : Color(white: 0.95)
        }
        return .primary
    }

    private var tabSecondaryTextColor: Color {
        if let themeColors = themeManager.currentThemeInfo?.colors,
           let baseColor = Color(hex: themeColors.background) {
            return baseColor.isLight ? Color(white: 0.4) : Color(white: 0.6)
        }
        return .secondary
    }

    private var tabBarBackgroundColor: Color {
        if let themeColors = themeManager.currentThemeInfo?.colors,
           let baseColor = Color(hex: themeColors.background) {
            return baseColor
        }
        return Color(uiColor: .systemBackground)
    }

    private var isLightTheme: Bool {
        if let themeColors = themeManager.currentThemeInfo?.colors,
           let baseColor = Color(hex: themeColors.background) {
            return baseColor.isLight
        }
        return false
    }

    // MARK: - Views

    @ViewBuilder
    private var sessionPicker: some View {
        VStack(spacing: 0) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(windowState.orderedTabIDs, id: \.self) { tabID in
                        TabButton(
                            id: tabID,
                            title: windowState.displayName(for: tabID),
                            isSelected: tabID == windowState.selectedSessionTabID,
                            selectedBackgroundColor: selectedTabBackgroundColor,
                            unselectedBackgroundColor: unselectedTabBackgroundColor,
                            textColor: tabTextColor,
                            secondaryTextColor: tabSecondaryTextColor,
                            isLightTheme: isLightTheme,
                            namespace: tabNamespace,
                            onTap: {
                                withAnimation(TabAnimation.selection) {
                                    windowState.selectSession(tabID: tabID)
                                }
                            },
                            onClose: {
                                withAnimation(TabAnimation.selection) {
                                    _ = windowState.closeCurrentSession()
                                }
                            },
                            connectionHealth: nil,
                            showHealthIndicator: false,
                            trackFrame: false
                        )
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
            }

            Divider()
        }
        .background(tabBarBackgroundColor)
        .modifier(GlassEffectContainerModifier())
    }

    @ViewBuilder
    private var noSessionsView: some View {
        VStack(spacing: 16) {
            Spacer()

            Image(systemName: "bubble.left.and.bubble.right")
                .font(.system(size: 48))
                .foregroundColor(.secondary)

            Text("No Active Sessions")
                .font(.headline)

            Text("Press Cmd+I in a terminal tab to start an AI Agent session")
                .font(.subheadline)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)

            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(uiColor: .systemGroupedBackground))
    }
}
#endif
