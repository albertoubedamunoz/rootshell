//
//  OSDisplayHelper.swift
//  rootshell
//
//  Maps an operating-system identifier (as reported by Tailscale / NetBird /
//  cloud-provider APIs) to a human-friendly name and an SF Symbol, and provides
//  a small reusable view for the inline device-metadata badges shown in rows.
//

import SwiftUI

/// Display helpers for an OS-family string (e.g. Tailscale's `os` field:
/// "linux", "macOS", "iOS", "windows", "android", "freebsd", …).
enum OSDisplay {
    /// Human-friendly OS name. Passes through already-cased Apple values
    /// (macOS / iOS / iPadOS / tvOS) and canonicalises lowercase identifiers.
    /// Returns nil for an empty / missing value.
    static func name(for os: String?) -> String? {
        guard let raw = os?.trimmingCharacters(in: .whitespaces), !raw.isEmpty else { return nil }
        switch raw.lowercased() {
        case "linux": return "Linux"
        case "windows": return "Windows"
        case "macos": return "macOS"
        case "ios": return "iOS"
        case "ipados": return "iPadOS"
        case "tvos": return "tvOS"
        case "android": return "Android"
        case "freebsd": return "FreeBSD"
        case "openbsd": return "OpenBSD"
        default: return raw
        }
    }

    /// SF Symbol representing the OS family. Falls back to a generic computer.
    static func icon(for os: String?) -> String {
        guard let raw = os?.lowercased(), !raw.isEmpty else { return "desktopcomputer" }
        if raw.contains("ipados") { return "ipad" }
        if raw.contains("macos") { return "macbook" }
        if raw.contains("tvos") { return "appletv" }
        if raw.contains("ios") { return "iphone" }
        if raw.contains("windows") { return "pc" }
        if raw.contains("android") { return "candybarphone" }
        if raw.contains("linux") || raw.contains("bsd") || raw.contains("unix") { return "terminal" }
        // Cloud image strings sometimes carry a distro name instead of a family.
        let distros = ["ubuntu", "debian", "fedora", "centos", "rhel", "alpine", "arch", "suse", "rocky", "alma"]
        if distros.contains(where: { raw.contains($0) }) { return "terminal" }
        return "desktopcomputer"
    }
}

/// Compact inline metadata (OS + mesh badges) for a network-device row.
/// Designed to be dropped into an existing caption-styled `HStack`; it inherits
/// the surrounding font/color and renders nothing for non-network-device
/// instances or when no metadata is available.
struct NetworkDeviceInlineBadges: View {
    let instance: CloudInstance

    var body: some View {
        if instance.isNetworkDevice {
            if let osName = OSDisplay.name(for: instance.image) {
                Label(osName, systemImage: OSDisplay.icon(for: instance.image))
                    .labelStyle(.titleAndIcon)
            }
            if instance.isExitNode {
                Label("Exit", systemImage: "arrow.up.forward")
                    .labelStyle(.titleAndIcon)
            }
            if instance.isExternal == true {
                Image(systemName: "person.2")
            }
            if instance.updateAvailable == true {
                Image(systemName: "arrow.up.circle")
            }
        }
    }
}
