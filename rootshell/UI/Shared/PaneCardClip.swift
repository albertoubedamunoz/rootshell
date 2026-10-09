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
