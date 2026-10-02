//
//  PanelPresentation.swift
//  rootshell
//
//  How a trailing panel (File Manager, HTTP Capture) is shown: docked in the
//  window's single trailing panel slot, or floating as an overlay.
//

import SwiftUI

enum PanelPresentation: String, CaseIterable, Codable, Sendable {
    case sidebar
    case overlay

    var title: String {
        switch self {
        case .sidebar: String(localized: "Sidebar", comment: "Panel presentation option")
        case .overlay: String(localized: "Overlay", comment: "Panel presentation option")
        }
    }

    var systemImage: String {
        self == .sidebar ? "sidebar.right" : "macwindow"
    }
}

/// Header menu that switches a panel between sidebar and overlay.
/// Equatable so panel and MainView renders skip this body and never rebuild
/// the menu while it is open. `onSwitch` is excluded; it acts on live state.
struct PanelPresentationMenu: View, Equatable {
    let current: PanelPresentation
    let onSwitch: (PanelPresentation) -> Void

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.current == rhs.current
    }

    var body: some View {
        Menu {
            ForEach(PanelPresentation.allCases, id: \.self) { presentation in
                Button {
                    onSwitch(presentation)
                } label: {
                    Label(presentation.title, systemImage: presentation.systemImage)
                }
            }
        } label: {
            Image(systemName: current.systemImage)
        }
        .accessibilityLabel(String(localized: "Presentation", comment: "Panel presentation menu"))
    }
}
