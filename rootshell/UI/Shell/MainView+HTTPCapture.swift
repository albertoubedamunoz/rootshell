//
//  MainView+HTTPCapture.swift
//  rootshell
//
//  Presents HTTP capture like the file manager: a resizable column beside the
//  terminal, a HUD over it, or a sheet on iPhone. The two panels share the
//  trailing docked slot (and the overlay layer): opening one in a spot the
//  other occupies hides the other, keeping its state for next time.
//

import SwiftUI

/// Build-agnostic accessors for shared layout and keyboard code (China builds have no HTTP capture).
extension MainView {
    var httpCaptureHoldsKeyboard: Bool {
        #if !CHINA_BUILD
        httpCaptureOwnsKeyboard
        #else
        false
        #endif
    }

    var httpCaptureDockedWidth: CGFloat {
        #if !CHINA_BUILD
        httpCaptureSidebarCurrentWidth
        #else
        0
        #endif
    }
}

#if !CHINA_BUILD

extension MainView {
    var httpCaptureShowsSidebar: Bool {
        showHTTPCapture && !isPhone && httpCapturePresentation == .sidebar && httpCaptureModel != nil
    }

    var httpCaptureShowsOverlay: Bool {
        showHTTPCapture && !isPhone && httpCapturePresentation == .overlay && httpCaptureModel != nil
    }

    /// The HUD and the iPhone sheet own the keyboard; the sidebar shares the window with the terminal.
    var httpCaptureOwnsKeyboard: Bool {
        showHTTPCapture && (isPhone || httpCapturePresentation == .overlay)
    }

    var httpCaptureSidebarCurrentWidth: CGFloat {
        httpCaptureShowsSidebar ? httpCaptureSidebarWidth : 0
    }

    // MARK: - Toggle

    func toggleHTTPCapture() {
        if showHTTPCapture {
            closeHTTPCapture()
        } else {
            openHTTPCapture()
        }
    }

    func openHTTPCapture() {
        let model = httpCaptureModel ?? HTTPCaptureModel()
        httpCaptureModel = model

        // Floating tools yield first, as they do for the file manager.
        showThemePickerOverlay = false
        showClipboardManager = false
        showQuickSettingsOverlay = false
        showOpenInFolderOverlay = false
        showIPLookup = false
        yieldSlotToHTTPCapture(httpCapturePresentation)

        if isPhone {
            resignFirstResponderForSheetPresentation()
        } else if httpCapturePresentation == .sidebar {
            scheduleTerminalRelayout()
        }
        showHTTPCapture = true
        if httpCaptureOwnsKeyboard { setOverlayOwnsKeyboardForAllTerminals(true) }
    }

    func closeHTTPCapture() {
        guard showHTTPCapture else { return }
        let wasSidebar = httpCaptureShowsSidebar
        showHTTPCapture = false
        setOverlayOwnsKeyboardForAllTerminals(isAnySheetPresented)
        if wasSidebar {
            if terminals.indices.contains(selectedTabIndex) {
                _ = terminals[selectedTabIndex].focusedTerminal?.becomeFirstResponder()
            }
            scheduleTerminalRelayout()
        } else {
            restoreFirstResponderAfterSheetDismissal()
        }
    }

    func switchHTTPCapturePresentation(_ presentation: PanelPresentation) {
        guard presentation != httpCapturePresentation else { return }
        yieldSlotToHTTPCapture(presentation)
        httpCapturePresentation = presentation
        SettingsStore.shared.set(Settings.HTTPCapture.presentation, presentation)
        setOverlayOwnsKeyboardForAllTerminals(isAnySheetPresented || httpCaptureOwnsKeyboard || fileManagerOwnsKeyboard)
        scheduleTerminalRelayout()
    }

    /// HTTP capture is about to show as `presentation`: hide the file manager
    /// if it holds that spot (docked column or overlay).
    private func yieldSlotToHTTPCapture(_ presentation: PanelPresentation) {
        guard !isPhone, showFileManager, fileManagerPresentation == presentation else { return }
        closeFileManager()
    }

    /// The file manager is about to show as `presentation`: hide HTTP capture
    /// if it holds that spot.
    func yieldSlotToFileManager(_ presentation: PanelPresentation) {
        guard !isPhone, showHTTPCapture, httpCapturePresentation == presentation else { return }
        closeHTTPCapture()
    }

    // MARK: - Views

    @ViewBuilder
    func httpCaptureSidebarColumn(width: CGFloat, totalWidth: CGFloat) -> some View {
        if httpCaptureShowsSidebar, let model = httpCaptureModel {
            HTTPCaptureSidebarView(
                model: model,
                width: $httpCaptureSidebarWidth,
                isDragging: $httpCaptureSidebarIsDragging,
                totalWidth: totalWidth,
                theme: resolvedSheetTheme(),
                onClose: { closeHTTPCapture() },
                onSwitchPresentation: { switchHTTPCapturePresentation($0) }
            )
            .frame(width: width)
            .transition(.move(edge: .trailing))
        }
    }

    @ViewBuilder
    func httpCaptureOverlays() -> some View {
        if httpCaptureShowsOverlay, let model = httpCaptureModel {
            HTTPCaptureHUD(
                model: model,
                theme: resolvedSheetTheme(),
                onClose: { closeHTTPCapture() },
                onSwitchPresentation: { switchHTTPCapturePresentation($0) }
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    func httpCapturePhoneSheetModifier(sheetTheme: ResolvedSheetTheme) -> HTTPCapturePhoneSheetModifier {
        HTTPCapturePhoneSheetModifier(
            isPresented: Binding(
                get: { showHTTPCapture && isPhone },
                set: { if !$0 { closeHTTPCapture() } }
            ),
            model: httpCaptureModel,
            sheetTheme: sheetTheme,
            onClose: { closeHTTPCapture() }
        )
    }
}

struct HTTPCapturePhoneSheetModifier: ViewModifier {
    @Binding var isPresented: Bool
    let model: HTTPCaptureModel?
    let sheetTheme: ResolvedSheetTheme
    let onClose: () -> Void

    func body(content: Content) -> some View {
        content.sheet(isPresented: $isPresented) {
            if let model {
                HTTPCaptureView(model: model, style: .sheet, onClose: onClose, onSwitchPresentation: nil)
                    .presentationDetents([.large])
                    .themedSheet(themeColors: sheetTheme.themeColors, accentColor: sheetTheme.accentColor, colorScheme: sheetTheme.colorScheme)
            }
        }
    }
}

#endif
