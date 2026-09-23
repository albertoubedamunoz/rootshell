//
//  MainView+KeyboardChooser.swift
//  rootshell
//
//  Presents the one-time iPhone keyboard chooser over the whole window.
//

import SwiftUI

extension MainView {
    @ViewBuilder
    func applyKeyboardChooser<V: View>(_ view: V, sheetTheme: ResolvedSheetTheme) -> some View {
        #if !os(visionOS) && !targetEnvironment(macCatalyst)
        if UIDevice.current.userInterfaceIdiom == .phone {
            view
                .overlay {
                    if showKeyboardChooser {
                        keyboardChooser(sheetTheme: sheetTheme)
                            .transition(.opacity.combined(with: .scale(scale: 0.97)))
                    }
                }
                .onChange(of: keyboardChooserEligible, initial: true) { _, eligible in
                    guard eligible, !KeyboardChooserLaunch.didOffer else { return }
                    KeyboardChooserLaunch.didOffer = true
                    guard !SettingsStore.shared.value(Settings.Keyboard.touchChooserPresented) else { return }
                    withAnimation(.easeOut(duration: 0.35)) { showKeyboardChooser = true }
                }
                // Covers both Start/Skip and Open Settings: runs once nothing is presented.
                .onChange(of: isAnySheetPresented) { _, presented in
                    guard !presented, connectionSheetAwaitsKeyboardChooser else { return }
                    connectionSheetAwaitsKeyboardChooser = false
                    if terminals.isEmpty { addNewTab() }
                }
        } else {
            view
        }
        #else
        view
        #endif
    }

    /// Fresh iPhone launch: the chooser goes first, then the connection sheet.
    /// Returns true when the sheet was deferred.
    func deferConnectionSheetForKeyboardChooser() -> Bool {
        #if !os(visionOS) && !targetEnvironment(macCatalyst)
        guard UIDevice.current.userInterfaceIdiom == .phone, !isVisorWindow,
              !KeyboardChooserLaunch.didOffer,
              !SettingsStore.shared.value(Settings.Keyboard.touchChooserPresented) else { return false }
        connectionSheetAwaitsKeyboardChooser = true
        return true
        #else
        return false
        #endif
    }

    #if !os(visionOS) && !targetEnvironment(macCatalyst)
    /// Wait for a ready, active, unobstructed main window before offering.
    private var keyboardChooserEligible: Bool {
        !isVisorWindow && lifecycleScenePhase == .active && ghosttyApp.readiness == .ready && !isAnySheetPresented
    }

    private func keyboardChooser(sheetTheme: ResolvedSheetTheme) -> some View {
        // Environment, not preferredColorScheme: the latter would restyle the window.
        KeyboardChooserView(
            onFinish: {
                withAnimation(.easeInOut(duration: 0.3)) { showKeyboardChooser = false }
            },
            onOpenSettings: {
                showKeyboardChooser = false
                requestSettingsPresentation(destination: .touchKeyboard)
            }
        )
        .environment(\.sheetThemeColors, sheetTheme.themeColors)
        .tint(sheetTheme.accentColor)
        .transformEnvironment(\.colorScheme) { scheme in
            if let override = sheetTheme.colorScheme { scheme = override }
        }
    }
    #endif
}
