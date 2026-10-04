//
//  HostAddressCopyMenu.swift
//  rootshell
//
//  Shared long-press actions for copying host connection addresses.
//

import SwiftUI
import UIKit

/// Context-menu actions for the host addresses available on a row.
struct HostAddressCopyActions: View {
    let name: String?
    let hostname: String?
    let ipAddress: String?

    init(name: String? = nil, hostname: String? = nil, ipAddress: String? = nil) {
        self.name = Self.nonEmpty(name)
        self.hostname = Self.nonEmpty(hostname)
        self.ipAddress = Self.nonEmpty(ipAddress)
    }

    var body: some View {
        if let name, name != hostname {
            Button {
                UIPasteboard.general.string = name
            } label: {
                Label("Copy Name", systemImage: "doc.on.doc")
            }
        }

        if let hostname {
            Button {
                UIPasteboard.general.string = hostname
            } label: {
                Label("Copy Hostname", systemImage: "doc.on.doc")
            }
        }

        if let ipAddress, ipAddress != hostname {
            Button {
                UIPasteboard.general.string = ipAddress
            } label: {
                Label("Copy IP Address", systemImage: "doc.on.doc")
            }
        }
    }

    static func hasActions(name: String? = nil, hostname: String?, ipAddress: String?) -> Bool {
        nonEmpty(name) != nil || nonEmpty(hostname) != nil || nonEmpty(ipAddress) != nil
    }

    private static func nonEmpty(_ value: String?) -> String? {
        guard let value, !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return nil
        }
        return value
    }
}

private struct HostAddressCopyMenuModifier: ViewModifier {
    let name: String?
    let hostname: String?
    let ipAddress: String?

    @ViewBuilder
    func body(content: Content) -> some View {
        if HostAddressCopyActions.hasActions(name: name, hostname: hostname, ipAddress: ipAddress) {
            content.contextMenu {
                HostAddressCopyActions(name: name, hostname: hostname, ipAddress: ipAddress)
            }
        } else {
            content
        }
    }
}

extension View {
    /// Adds long-press/right-click copy actions when at least one address exists.
    func hostAddressCopyMenu(name: String? = nil, hostname: String? = nil, ipAddress: String? = nil) -> some View {
        modifier(HostAddressCopyMenuModifier(name: name, hostname: hostname, ipAddress: ipAddress))
    }
}
