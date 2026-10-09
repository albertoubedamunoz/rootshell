//
//  PaneCardClip.swift
//  rootshell
//
//  Rounded Panes card clipping for SwiftUI columns
//

import SwiftUI

extension PaneCardStyle {
    static func shape(rounded: Bool) -> RoundedRectangle {
        RoundedRectangle(cornerRadius: rounded ? cornerRadius : 0, style: .continuous)
    }

    /// Right-hand docked columns always round their leading corners; cards
    /// round all four.
    static func trailingColumnShape(rounded: Bool) -> UnevenRoundedRectangle {
        let trailing: CGFloat = rounded ? cornerRadius : 0
        return UnevenRoundedRectangle(
            topLeadingRadius: 12, bottomLeadingRadius: 12,
            bottomTrailingRadius: trailing, topTrailingRadius: trailing,
            style: rounded ? .continuous : .circular)
    }
}

/// Clips to a card only while Rounded Panes is on, so the default layout
/// keeps drawing outside its bounds as before.
struct PaneCardClip: ViewModifier {
    let isEnabled: Bool

    func body(content: Content) -> some View {
        if isEnabled {
            content.clipShape(PaneCardStyle.shape(rounded: true))
        } else {
            content
        }
    }
}

extension View {
    func paneCardClip(_ isEnabled: Bool) -> some View {
        modifier(PaneCardClip(isEnabled: isEnabled))
    }
}

private struct PaneCardBackdropKey: EnvironmentKey {
    static let defaultValue: Color? = nil
}

extension EnvironmentValues {
    /// Translucent Rounded Panes backdrop that the split view paints only
    /// between its cards (Catalyst); nil when the window root fill covers it.
    var paneCardBackdrop: Color? {
        get { self[PaneCardBackdropKey.self] }
        set { self[PaneCardBackdropKey.self] = newValue }
    }
}

/// A rect with card-shaped holes, filled even-odd, so a translucent backdrop
/// never stacks beneath translucent cards.
struct PaneCardBackdropShape: Shape {
    struct Hole {
        let rect: CGRect
        let cornerRadius: CGFloat
    }

    let holes: [Hole]

    func path(in rect: CGRect) -> Path {
        var path = Path(rect)
        for hole in holes where !hole.rect.isEmpty {
            path.addRoundedRect(
                in: hole.rect,
                cornerSize: CGSize(width: hole.cornerRadius, height: hole.cornerRadius),
                style: .continuous)
        }
        return path
    }
}

/// The window-wide effect's docked sidebar card (when the effect spans it;
/// `sidebarWidth` includes its trailing gap) and terminal card.
struct PaneCardEffectShape: Shape {
    var sidebarWidth: CGFloat

    var animatableData: CGFloat {
        get { sidebarWidth }
        set { sidebarWidth = newValue }
    }

    func path(in rect: CGRect) -> Path {
        let corner = CGSize(width: PaneCardStyle.cornerRadius, height: PaneCardStyle.cornerRadius)
        var path = Path()
        let sidebarCard = CGRect(x: 0, y: 0, width: sidebarWidth - PaneCardStyle.gap, height: rect.height)
        if sidebarCard.width > 0 {
            path.addRoundedRect(in: sidebarCard, cornerSize: corner, style: .continuous)
        }
        let terminalCard = CGRect(x: sidebarWidth, y: 0, width: rect.width - sidebarWidth, height: rect.height)
        if terminalCard.width > 0 {
            path.addRoundedRect(in: terminalCard, cornerSize: corner, style: .continuous)
        }
        return path
    }
}

extension View {
    /// Clips the effect layer to its cards only while Rounded Panes is on.
    @ViewBuilder
    func paneCardEffectClip(_ isEnabled: Bool, sidebarWidth: CGFloat) -> some View {
        if isEnabled {
            clipShape(PaneCardEffectShape(sidebarWidth: sidebarWidth))
        } else {
            self
        }
    }
}
