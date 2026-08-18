import Foundation
import UserNotifications
import Combine
import os.log

// MARK: - Notification Names

extension Notification.Name {
    /// Posted when user taps a terminal notification to navigate to that terminal
    static let navigateToTerminal = Notification.Name("com.rootshell.navigateToTerminal")

    /// Posted when user responds to an MCP approval notification
    static let mcpApprovalResponse = Notification.Name("com.rootshell.mcpApprovalResponse")

    /// Posted when a terminal's restoration state changes
    /// Used to trigger SwiftUI updates since TerminalView is a class and @State doesn't observe its properties
    static let terminalRestorationStateChanged = Notification.Name("com.rootshell.terminalRestorationStateChanged")
}

@MainActor
class NotificationManager: NSObject, ObservableObject, UNUserNotificationCenterDelegate {
    static let shared = NotificationManager()

    // MARK: - Published Properties

    @Published var isEnabled: Bool = false {
        didSet {
            guard ProtectedDataGuard.isAvailable else { return }
            UserDefaults.standard.set(isEnabled, forKey: "ssh_notification_enabled")
        }
    }

    @Published var terminalNotificationsEnabled: Bool = false {
        didSet {
            guard ProtectedDataGuard.isAvailable else { return }
            UserDefaults.standard.set(terminalNotificationsEnabled, forKey: "terminal_notification_enabled")
        }
    }

    @Published private(set) var authorizationStatus: UNAuthorizationStatus = .notDetermined

    // MARK: - Private Properties

    private let logger = Logger(subsystem: "com.rootshell", category: "Notifications")
    private let notificationCenter = UNUserNotificationCenter.current()

    // Notification identifiers
    private let sshReminderIdentifier = "ssh-session-reminder"

    // Terminal notification category (matches macOS Ghostty)
    nonisolated private static let terminalNotificationCategory = "com.rootshell.terminalNotification"
    private static let terminalNotificationActionShow = "com.rootshell.terminalNotification.Show"

    // Fixed delay of 60 seconds before showing notification
    private let notificationDelay: TimeInterval = 60

    // MARK: - Initialization

    private override init() {
        super.init()

        // Load saved preferences from UserDefaults
        self.isEnabled = UserDefaults.standard.bool(forKey: "ssh_notification_enabled")
        self.terminalNotificationsEnabled = UserDefaults.standard.bool(forKey: "terminal_notification_enabled")

        // Set self as delegate for notification center
        notificationCenter.delegate = self

        // Note: We don't request permission here - we wait for the user to enable the toggle
        // This also avoids a race condition where init Task might overwrite authorizationStatus
    }

    /// Request notification permissions from the user
    /// Returns true if permission was granted, false otherwise
    @discardableResult
    func requestPermissions() async -> Bool {
        do {
            let granted = try await notificationCenter.requestAuthorization(options: [.alert, .sound, .badge])
            await updateAuthorizationStatus()

            if granted {
                logger.info("Notification permission granted")
            } else {
                logger.warning("Notification permission denied by user")
            }
            return granted
        } catch {
            logger.error("Failed to request notification permission: \(error.localizedDescription)")
            return false
        }
    }

    /// Update the current authorization status
    func updateAuthorizationStatus() async {
        let settings = await notificationCenter.notificationSettings()
        authorizationStatus = settings.authorizationStatus
    }

    /// Schedule a notification to remind user about active SSH sessions
    /// - Parameters:
    ///   - sessionCount: Number of active SSH sessions
    ///   - delay: Delay in seconds before showing notification (default: 60). Use 0 for immediate notification.
    func scheduleSSHReminder(sessionCount: Int, delay: TimeInterval? = nil) {
        logger.info("scheduleSSHReminder called - sessions: \(sessionCount), isEnabled: \(self.isEnabled), authStatus: \(self.authorizationStatus.rawValue)")

        guard isEnabled else {
            logger.warning("SSH notifications DISABLED - user needs to enable in Settings")
            return
        }

        guard authorizationStatus == .authorized else {
            logger.warning("Cannot schedule notification: authorization status is \(self.authorizationStatus.rawValue) (0=notDetermined, 1=denied, 2=authorized, 3=provisional, 4=ephemeral)")
            return
        }

        // Cancel any existing pending notifications first
        cancelPendingNotifications()

        let actualDelay = delay ?? notificationDelay
        logger.info("Proceeding to schedule notification with delay: \(actualDelay)s")

        // Create notification content
        let content = UNMutableNotificationContent()
        content.title = "Active SSH Sessions"

        if sessionCount == 1 {
            content.body = "You have 1 active SSH session. Return to the app or enable Location Diary to track your session."
        } else {
            content.body = "You have \(sessionCount) active SSH sessions. Return to the app or enable Location Diary to track your sessions."
        }

        content.sound = SoundManager.shared.currentNotificationSound
        content.categoryIdentifier = "SSH_REMINDER"

        // Create request with appropriate trigger
        let request: UNNotificationRequest
        if actualDelay > 0 {
            // Use time interval trigger for delayed notifications
            let trigger = UNTimeIntervalNotificationTrigger(timeInterval: actualDelay, repeats: false)
            request = UNNotificationRequest(
                identifier: sshReminderIdentifier,
                content: content,
                trigger: trigger
            )
        } else {
            // Immediate notification (no trigger)
            request = UNNotificationRequest(
                identifier: sshReminderIdentifier,
                content: content,
                trigger: nil
            )
        }

        // Schedule the notification
        notificationCenter.add(request) { [weak self] error in
            guard let self = self else { return }
            Task { @MainActor [logger = self.logger] in
                if let error = error {
                    logger.error("Failed to schedule SSH reminder: \(error.localizedDescription)")
                } else {
                    if actualDelay > 0 {
                        logger.info("Scheduled SSH reminder for \(sessionCount) session(s) in \(actualDelay) seconds")
                    } else {
                        logger.info("Fired immediate SSH reminder for \(sessionCount) session(s)")
                    }
                }
            }
        }
    }

    /// Cancel all pending SSH reminder notifications
    func cancelPendingNotifications() {
        notificationCenter.removePendingNotificationRequests(withIdentifiers: [sshReminderIdentifier])
        logger.debug("Cancelled pending SSH reminder notifications")
    }

    /// Register notification categories and actions
    func registerNotificationCategories() {
        // SSH Reminder category with Location Diary action
        let enableLocationAction = UNNotificationAction(
            identifier: "ENABLE_LOCATION_DIARY",
            title: "Enable Location Diary",
            options: [.foreground]
        )

        let sshReminderCategory = UNNotificationCategory(
            identifier: "SSH_REMINDER",
            actions: [enableLocationAction],
            intentIdentifiers: [],
            options: []
        )

        // Terminal notification category with Show action (matches macOS Ghostty)
        let showAction = UNNotificationAction(
            identifier: Self.terminalNotificationActionShow,
            title: "Show",
            options: [.foreground]
        )

        let terminalCategory = UNNotificationCategory(
            identifier: Self.terminalNotificationCategory,
            actions: [showAction],
            intentIdentifiers: [],
            options: [.customDismissAction]
        )

        // MCP approval notification category
        let mcpApproveAction = UNNotificationAction(
            identifier: "MCP_APPROVE",
            title: "Approve",
            options: [.foreground]
        )

        let mcpDenyAction = UNNotificationAction(
            identifier: "MCP_DENY",
            title: "Deny",
            options: [.destructive]
        )

        let mcpApprovalCategory = UNNotificationCategory(
            identifier: "MCP_APPROVAL",
            actions: [mcpApproveAction, mcpDenyAction],
            intentIdentifiers: [],
            options: [.customDismissAction]
        )

        // Register all categories
        notificationCenter.setNotificationCategories([sshReminderCategory, terminalCategory, mcpApprovalCategory])
        logger.debug("Registered notification categories")
    }

    /// Print diagnostic information about notification status
    func logDiagnostics() {
        logger.info("Notification Manager Diagnostics:")
        logger.info("  - isEnabled (SSH): \(self.isEnabled)")
        logger.info("  - terminalNotificationsEnabled: \(self.terminalNotificationsEnabled)")
        logger.info("  - authorizationStatus: \(self.authorizationStatus.rawValue) (0=notDetermined, 1=denied, 2=authorized)")

        Task {
            let pending = await notificationCenter.pendingNotificationRequests()
            let sshPending = pending.filter { $0.identifier == sshReminderIdentifier }
            logger.info("  - Pending SSH notifications: \(sshPending.count)")
            if let first = sshPending.first {
                if let trigger = first.trigger as? UNTimeIntervalNotificationTrigger {
                    logger.info("  - Next fire date: ~\(trigger.timeInterval)s from schedule time")
                } else {
                    logger.info("  - Immediate notification pending")
                }
            }
        }
    }

    // MARK: - Terminal Notifications

    /// Schedule a terminal notification (OSC 9 / OSC 777)
    /// - Parameters:
    ///   - title: Notification title
    ///   - body: Notification body text
    ///   - subtitle: Terminal title (shown as subtitle)
    ///   - tabID: UUID of the tab containing the terminal
    ///   - surfaceID: UUID of the terminal surface
    /// - Returns: Notification identifier for tracking, or nil if scheduling failed
    func scheduleTerminalNotification(
        title: String,
        body: String,
        subtitle: String,
        tabID: UUID,
        surfaceID: UUID
    ) -> String? {
        guard terminalNotificationsEnabled else {
            logger.debug("Terminal notifications disabled, skipping")
            return nil
        }

        guard authorizationStatus == .authorized else {
            logger.warning("Cannot schedule terminal notification: not authorized")
            return nil
        }

        let content = UNMutableNotificationContent()
        content.title = title
        content.subtitle = subtitle
        content.body = body
        let notifSound = SoundManager.shared.currentNotificationSound
        content.sound = notifSound
        logger.info("Notification sound preset: \(SoundManager.shared.notificationPreset.rawValue), sound=\(notifSound.debugDescription)")
        content.categoryIdentifier = Self.terminalNotificationCategory
        content.userInfo = [
            "tabID": tabID.uuidString,
            "surfaceID": surfaceID.uuidString
        ]

        let identifier = UUID().uuidString
        let request = UNNotificationRequest(
            identifier: identifier,
            content: content,
            trigger: nil  // Immediate notification
        )

        notificationCenter.add(request) { [weak self] error in
            guard let self = self else { return }
            Task { @MainActor [logger = self.logger] in
                if let error = error {
                    logger.error("Failed to schedule terminal notification: \(error.localizedDescription)")
                } else {
                    logger.debug("Scheduled terminal notification: \(identifier)")
                }
            }
        }

        return identifier
    }

    /// Schedule a coding-agent attention notification. Deliberately NOT
    /// gated on `terminalNotificationsEnabled` (an unrelated OSC 9/777
    /// preference defaulting to off): the agent notification policy in
    /// Settings > Terminal > Coding Agents is the user consent for
    /// these, and its picker requests authorization. Same category and
    /// deep-link payload as terminal notifications.
    ///
    /// `requestIdentifier` is the pane's, so a later event for the same pane
    /// replaces its banner; `threadIdentifier` groups a pane's notifications
    /// into one stack in Notification Center.
    func scheduleAgentNotification(
        title: String,
        body: String,
        subtitle: String,
        tabID: UUID,
        surfaceID: UUID,
        requestIdentifier: String,
        threadIdentifier: String? = nil,
        relevanceScore: Double = 0
    ) -> String? {
        guard authorizationStatus == .authorized else { return nil }

        let content = UNMutableNotificationContent()
        content.title = title
        content.subtitle = subtitle
        content.body = body
        content.sound = SoundManager.shared.currentNotificationSound
        content.categoryIdentifier = Self.terminalNotificationCategory
        if let threadIdentifier {
            content.threadIdentifier = threadIdentifier
        }
        content.relevanceScore = relevanceScore
        content.userInfo = [
            "tabID": tabID.uuidString,
            "surfaceID": surfaceID.uuidString
        ]

        let request = UNNotificationRequest(
            identifier: requestIdentifier,
            content: content,
            trigger: nil
        )
        notificationCenter.add(request) { [weak self] error in
            guard let self = self else { return }
            Task { @MainActor [logger = self.logger] in
                if let error = error {
                    logger.error("Failed to schedule agent notification: \(error.localizedDescription)")
                }
            }
        }
        return requestIdentifier
    }

    /// Remove notifications by their identifiers
    /// - Parameter identifiers: Array of notification identifiers to remove
    func removeNotifications(identifiers: [String]) {
        guard !identifiers.isEmpty else { return }
        notificationCenter.removeDeliveredNotifications(withIdentifiers: identifiers)
        notificationCenter.removePendingNotificationRequests(withIdentifiers: identifiers)
        logger.debug("Removed \(identifiers.count) notification(s)")
    }

    // MARK: - UNUserNotificationCenterDelegate

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        // For terminal notifications, we handle presentation logic via the caller
        // (TerminalView checks focus before scheduling)
        // So we always show if it gets this far.
        // Only include .sound when the notification has a sound set (respects "None" preset).
        var options: UNNotificationPresentationOptions = [.banner]
        if notification.request.content.sound != nil {
            options.insert(.sound)
        }
        completionHandler(options)
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        let userInfo = response.notification.request.content.userInfo
        let categoryId = response.notification.request.content.categoryIdentifier

        // Handle terminal notification taps
        if categoryId == Self.terminalNotificationCategory {
            if let tabIDString = userInfo["tabID"] as? String,
               let surfaceIDString = userInfo["surfaceID"] as? String,
               let tabID = UUID(uuidString: tabIDString),
               let surfaceID = UUID(uuidString: surfaceIDString) {

                // Post notification to navigate to the terminal
                Task { @MainActor in
                    NotificationCenter.default.post(
                        name: .navigateToTerminal,
                        object: nil,
                        userInfo: ["tabID": tabID, "surfaceID": surfaceID]
                    )
                }
            }
        }

        // Handle MCP approval notification responses
        if categoryId == "MCP_APPROVAL" {
            let actionId = response.actionIdentifier
            let approved = (actionId == "MCP_APPROVE")

            if let sessionIdString = userInfo["sessionId"] as? String,
               let sessionId = UUID(uuidString: sessionIdString) {
                // Post notification for MCP approval response
                Task { @MainActor in
                    NotificationCenter.default.post(
                        name: .mcpApprovalResponse,
                        object: nil,
                        userInfo: [
                            "sessionId": sessionId,
                            "approved": approved
                        ]
                    )
                }
            }
        }

        completionHandler()
    }
}
