//
//  NotificationService.swift
//  PushNotificationService
//
//  Decrypts rootshell push envelopes before display. Falls back to a generic
//  notification if anything fails within the extension's time budget.
//

import RootshellPushKit
import UserNotifications
import os

final class NotificationService: UNNotificationServiceExtension {
    private static let logger = Logger(subsystem: "com.rootshell", category: "PushNSE")
    private static let containingAppBundle: Bundle? = {
        var candidate = Bundle.main.bundleURL.deletingLastPathComponent()
        while candidate.pathExtension != "app" {
            let parent = candidate.deletingLastPathComponent()
            guard parent != candidate else { return nil }
            candidate = parent
        }
        return Bundle(url: candidate)
    }()

    private var contentHandler: ((UNNotificationContent) -> Void)?
    private var content: UNMutableNotificationContent?

    override func didReceive(_ request: UNNotificationRequest,
                             withContentHandler contentHandler: @escaping (UNNotificationContent) -> Void) {
        self.contentHandler = contentHandler
        let content = (request.content.mutableCopy() as? UNMutableNotificationContent) ?? UNMutableNotificationContent()
        self.content = content

        guard let envelope = PushEnvelope(userInfo: request.content.userInfo) else {
            finish(fallback(content))
            return
        }
        do {
            try decorate(content, envelope: envelope)
            finish(content)
        } catch {
            Self.logger.error("push decrypt failed: \(String(describing: error), privacy: .public)")
            finish(fallback(content))
        }
    }

    override func serviceExtensionTimeWillExpire() {
        if let content { finish(fallback(content)) }
    }

    private func finish(_ content: UNNotificationContent) {
        guard let handler = contentHandler else { return }
        contentHandler = nil
        handler(content)
    }

    private func fallback(_ content: UNMutableNotificationContent) -> UNNotificationContent {
        content.title = "rootshell"
        content.body = String(localized: "Encrypted notification. Open rootshell to view.")
        content.categoryIdentifier = PushConfiguration.categoryIdentifier
        return content
    }

    /// The relay keeps no state, so revoked senders and stale registrations
    /// are filtered here. A rejected push is blanked; the app removes it.
    private func silence(_ content: UNMutableNotificationContent) -> UNNotificationContent {
        content.title = ""
        content.subtitle = ""
        content.body = ""
        content.sound = nil
        content.badge = nil
        content.categoryIdentifier = PushConfiguration.categoryIdentifier
        content.userInfo = [PushConfiguration.rejectedUserInfoKey: true]
        return content
    }

    private func decorate(_ content: UNMutableNotificationContent, envelope: PushEnvelope) throws {
        let shared = PushSharedState()
        let policy = shared.loadPolicy()
        guard policy.accepts(envelope) else {
            finish(silence(content))
            return
        }
        let keychain = PushConfiguration.keychain
        guard let key = try keychain.loadPrivateKey() else { throw PushCryptoError.badKeySize }
        let header = try envelope.open(with: key)
        if header.kind == "agent", !policy.allowsAgentStatus(header.status) {
            finish(silence(content))
            return
        }

        content.title = header.title
        content.body = header.body ?? ""
        content.subtitle = header.statusSubtitle ?? ""
        content.threadIdentifier = "push-\(header.thread ?? envelope.eid)"
        content.categoryIdentifier = PushConfiguration.categoryIdentifier
        content.relevanceScore = header.status == "blocked" ? 1 : 0.5
        if header.status == "blocked" { content.interruptionLevel = .timeSensitive }
        if header.kind == "agent",
           let appBundle = Self.containingAppBundle,
           let logo = PushAgentLogoAttachment.attachment(
               for: header.agent,
               assetBundle: appBundle
           ) {
            content.attachments = [logo]
        }

        var info = content.userInfo
        info[PushConfiguration.headerUserInfoKey] = try header.userInfoDictionary()
        content.userInfo = info

        // Relay retries and replays carry the same eid; only the first copy is shown.
        guard shared.claim(PushEventRecord(header: header, eid: envelope.eid)) else {
            finish(silence(content))
            return
        }
    }
}
