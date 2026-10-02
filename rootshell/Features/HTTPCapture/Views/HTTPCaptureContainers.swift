//
//  HTTPCaptureContainers.swift
//  rootshell
//
//  Hosts for HTTPCaptureView: a resizable column beside the terminal and a
//  draggable HUD over it, matching the file manager's containers.
//

#if !CHINA_BUILD

import SwiftUI

struct HTTPCaptureSidebarView: View {
    let model: HTTPCaptureModel
    @Binding var width: CGFloat
    @Binding var isDragging: Bool
    let totalWidth: CGFloat
    let theme: ResolvedSheetTheme
    let onClose: () -> Void
    let onSwitchPresentation: (PanelPresentation) -> Void

    static let minWidth: CGFloat = 320
    static let defaultWidth: CGFloat = 480
    private let maxWidthFraction: CGFloat = 0.7

    private var background: Color {
        theme.themeColors?.background ?? Color(uiColor: .systemBackground)
    }

    var body: some View {
        HStack(spacing: 0) {
            SidebarResizeDivider(
                side: .right,
                width: $width,
                isDragging: $isDragging,
                minWidth: Self.minWidth,
                maxWidth: max(Self.minWidth, totalWidth * maxWidthFraction),
                defaultWidth: Self.defaultWidth,
                backgroundColor: background,
                onCommit: { SettingsStore.shared.set(Settings.HTTPCapture.sidebarWidth, Double($0)) }
            )
            HTTPCaptureView(model: model, style: .sidebar, onClose: onClose, onSwitchPresentation: onSwitchPresentation)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(background)
                .clipShape(UnevenRoundedRectangle(topLeadingRadius: 12, bottomLeadingRadius: 12))
                .shadow(color: .black.opacity(0.15), radius: 8, x: -2, y: 0)
        }
        .background(background.ignoresSafeArea(.container, edges: .bottom))
        .fileManagerTheme(theme)
    }
}

struct HTTPCaptureHUD: View {
    let model: HTTPCaptureModel
    let theme: ResolvedSheetTheme
    let onClose: () -> Void
    let onSwitchPresentation: (PanelPresentation) -> Void

    var body: some View {
        DraggableHUDContainer(
            resizing: .httpCapture,
            dismissShortcuts: [.escape],
            forwardsHTTPCaptureToggle: true,
            onDismiss: onClose
        ) {
            HTTPCaptureView(model: model, style: .overlay, onClose: onClose, onSwitchPresentation: onSwitchPresentation)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                .floatingHUDPanelBackground()
                .fileManagerTheme(theme)
        }
    }
}

extension HUDResizing {
    static let httpCapture = HUDResizing(
        minSize: CGSize(width: 320, height: 320),
        widthKey: Settings.HTTPCapture.hudWidth,
        heightKey: Settings.HTTPCapture.hudHeight)
}

#endif
