//
//  PushAgentLogoAttachment.swift
//  RootshellPushKit
//
//  Runtime-rendered agent artwork for hook-notification thumbnails.
//  Attachments are best-effort: an unavailable asset or filesystem failure
//  must never prevent delivery.
//

import Foundation
import UserNotifications
#if canImport(UIKit)
import UIKit
#endif

public enum PushAgentLogoAttachment {
    private static let assetNames = [
        "claude-code": "ClaudeLogo",
        "codex": "CodexLogo",
    ]

    static func assetName(for agent: String?) -> String? {
        agent.flatMap { assetNames[$0] }
    }

#if canImport(UIKit)
    /// Renders the matching asset-catalog image to a temporary PNG and wraps it
    /// as a system notification attachment. No generated image is stored in an
    /// application or extension bundle.
    public static func attachment(
        for agent: String?,
        assetBundle: Bundle,
        temporaryDirectory: URL = FileManager.default.temporaryDirectory
    ) -> UNNotificationAttachment? {
        guard let agent,
              let assetName = assetName(for: agent),
              let image = UIImage(named: assetName, in: assetBundle, compatibleWith: nil),
              let data = image.pngData()
        else { return nil }

        let directory = temporaryDirectory.appendingPathComponent(
            "rootshell-notification-logos",
            isDirectory: true
        )
        let url = directory.appendingPathComponent(
            "\(assetName)-\(UUID().uuidString).png"
        )

        do {
            try FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: true
            )
            try data.write(to: url, options: .atomic)
            return try UNNotificationAttachment(
                identifier: "agent-logo-\(agent)",
                url: url
            )
        } catch {
            return nil
        }
    }
#endif
}
