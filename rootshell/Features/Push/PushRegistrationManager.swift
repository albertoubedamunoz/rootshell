//
//  PushRegistrationManager.swift
//  rootshell
//
//  Device side of encrypted push. The relay is stateless: the device holds
//  its sealed credential, the list of computers it paired, and its revocations.
//

import Foundation
import Observation
import RootshellPushKit
import UIKit
import os

/// A computer this device handed a sender credential to.
struct PushPairedSender: Codable, Identifiable, Equatable, Sendable {
    var id: String
    var label: String
    var createdAt: Date
    /// Set when the device re-registered after this pairing; its credential
    /// carries the old device id and its pushes are dropped.
    var stale: Bool
}

@MainActor
@Observable
final class PushRegistrationManager {
    static let shared = PushRegistrationManager()
    private static let logger = Logger(subsystem: "com.rootshell", category: "Push")

    static let enabledKey = "pushNotificationsEnabled"
    static let sendersKey = "pushPairedSenders"
    static let revokedKey = "pushRevokedSenders"
    static let backgroundOnlyKey = "pushAgentBackgroundOnly"
    static let agentLogosKey = "pushAgentLogosEnabled"

    enum State: Equatable {
        case disabled
        case waitingForToken
        case registered
        case failed(String)
    }

    private(set) var isEnabled: Bool
    private(set) var state: State = .disabled
    private(set) var senders: [PushPairedSender] = []
    private(set) var isBusy = false
    /// Agent pushes are dropped while the app is foreground; explicit sends still show.
    var agentBackgroundOnly: Bool {
        didSet {
            guard !isReloading else { return }
            SettingsStore.shared.set(Settings.Notifications.pushAgentBackgroundOnly, agentBackgroundOnly)
        }
    }
    /// Adds bundled Claude/Codex artwork to agent pushes when supported.
    var agentLogosEnabled: Bool {
        didSet {
            if !isReloading {
                SettingsStore.shared.set(Settings.Notifications.pushAgentLogos, agentLogosEnabled)
            }
            publishPolicy()
        }
    }

    @ObservationIgnored private let keychain = PushConfiguration.keychain
    @ObservationIgnored private var apnsToken: Data?
    @ObservationIgnored private var registrationTask: Task<Void, Never>?
    @ObservationIgnored private var revoked: Set<String>
    @ObservationIgnored private var isReloading = false

    private init() {
        let defaults = UserDefaults.standard
        isEnabled = defaults.bool(forKey: Self.enabledKey)
        agentBackgroundOnly = SettingsStore.shared.get(Settings.Notifications.pushAgentBackgroundOnly)
        agentLogosEnabled = SettingsStore.shared.get(Settings.Notifications.pushAgentLogos)
        senders = (defaults.data(forKey: Self.sendersKey)).flatMap { try? JSONDecoder().decode([PushPairedSender].self, from: $0) } ?? []
        revoked = Set(defaults.stringArray(forKey: Self.revokedKey) ?? [])
        if isEnabled { state = credentials == nil ? .waitingForToken : .registered }
        publishPolicy()
        SettingsRefreshHub.shared.register(keys: [
            Settings.Notifications.pushAgentBackgroundOnly.name, Settings.Notifications.pushAgentLogos.name,
        ]) { [weak self] keys in self?.reload(keys: keys) }
    }

    private func reload(keys: Set<String>) {
        isReloading = true
        defer { isReloading = false }
        if keys.contains(Settings.Notifications.pushAgentBackgroundOnly.name) {
            agentBackgroundOnly = SettingsStore.shared.get(Settings.Notifications.pushAgentBackgroundOnly)
        }
        if keys.contains(Settings.Notifications.pushAgentLogos.name) {
            agentLogosEnabled = SettingsStore.shared.get(Settings.Notifications.pushAgentLogos)
        }
    }

    var credentials: PushCredentials? { try? keychain.loadCredentials() }

    static var environment: String {
        #if DEBUG
        return "sandbox"
        #else
        return "production"
        #endif
    }

    static var platform: String {
        #if targetEnvironment(macCatalyst)
        return "macos"
        #elseif os(visionOS)
        return "visionos"
        #else
        return "ios"
        #endif
    }

    var deviceLabel: String {
        #if targetEnvironment(macCatalyst)
        // UIDevice reports "iPad" under Catalyst; use the Mac's host name.
        let host = ProcessInfo.processInfo.hostName
        return host.hasSuffix(".local") ? String(host.dropLast(6)) : host
        #else
        return UIDevice.current.name
        #endif
    }

    // MARK: - Enable / disable

    func enable() async -> Bool {
        guard await NotificationManager.shared.requestPermissions() else { return false }
        do {
            if try keychain.loadPrivateKey() == nil {
                try keychain.save(try XWing.PrivateKey())
            }
        } catch {
            state = .failed(String(describing: error))
            return false
        }
        isEnabled = true
        persistEnabled(true)
        publishPolicy()
        state = credentials == nil ? .waitingForToken : .registered
        UIApplication.shared.registerForRemoteNotifications()
        if apnsToken != nil { scheduleRegistration() }
        return true
    }

    func disable() {
        isEnabled = false
        persistEnabled(false)
        registrationTask?.cancel()
        try? keychain.deleteAll()
        PushSharedState().clear()
        senders = []
        revoked = []
        persistSenders()
        // Pushes for the old registration may still arrive; both the extension
        // and the router silence them until push is enabled again.
        PushSharedState().save(PushAcceptancePolicy(enabled: false,
                                                    deviceID: nil,
                                                    showsAgentLogos: agentLogosEnabled))
        state = .disabled
    }

    private func persistEnabled(_ value: Bool) {
        guard ProtectedDataGuard.isAvailable else { return }
        UserDefaults.standard.set(value, forKey: Self.enabledKey)
    }

    private func persistSenders() {
        guard ProtectedDataGuard.isAvailable else { return }
        UserDefaults.standard.set(try? JSONEncoder().encode(senders), forKey: Self.sendersKey)
        UserDefaults.standard.set(Array(revoked), forKey: Self.revokedKey)
        publishPolicy()
    }

    /// Shares the acceptance policy with the notification extension.
    func publishPolicy() {
        PushSharedState().save(PushAcceptancePolicy(enabled: isEnabled,
                                                    deviceID: credentials?.deviceID,
                                                    revokedSenderIDs: revoked,
                                                    showsAgentLogos: agentLogosEnabled))
    }

    // MARK: - APNs token

    func didReceiveAPNsToken(_ token: Data) {
        apnsToken = token
        guard isEnabled else { return }
        // Credentials embed the APNs token; a new token needs a new registration.
        if let creds = credentials, creds.apnsToken == token, creds.environment == Self.environment {
            state = .registered
            return
        }
        scheduleRegistration()
    }

    private func scheduleRegistration() {
        registrationTask?.cancel()
        registrationTask = Task { await register() }
    }

    private func register() async {
        guard let token = apnsToken else { return }
        let hadCredentials = credentials != nil
        do {
            let reg = try await PushAPIClient(server: PushConfiguration.server)
                .registerDevice(apnsToken: token, topic: PushConfiguration.topic, environment: Self.environment, platform: Self.platform)
            try keychain.save(PushCredentials(server: PushConfiguration.server.absoluteString, deviceID: reg.deviceID,
                                              deviceCred: reg.deviceCred, apnsToken: token, environment: Self.environment))
            if hadCredentials {
                for i in senders.indices { senders[i].stale = true }
            }
            persistSenders()
            state = .registered
        } catch is CancellationError {
        } catch let error as URLError where error.code == .cancelled {
        } catch {
            Self.logger.error("push registration failed: \(String(describing: error), privacy: .public)")
            state = .failed(Self.describe(error))
        }
    }

    // MARK: - Senders

    func createPairing(label: String) async throws -> PairingBundle {
        guard let creds = credentials, let key = try keychain.loadPrivateKey() else {
            throw PushAPIError(status: 0, code: "not_registered", message: nil)
        }
        isBusy = true
        defer { isBusy = false }
        let created = try await PushAPIClient(server: PushConfiguration.server).createSender(credentials: creds, label: label)
        // Re-pairing the same computer supersedes its previous credential.
        if let previous = senders.first(where: { $0.label == label }) {
            revoked.insert(previous.id)
            senders.removeAll { $0.id == previous.id }
        }
        senders.append(PushPairedSender(id: created.senderID, label: label, createdAt: Date(), stale: false))
        persistSenders()
        return PairingBundle(server: creds.server, label: deviceLabel, senderCred: created.senderCred,
                             publicKey: key.publicKey.rawRepresentation)
    }

    func revokeSender(id: String) {
        revoked.insert(id)
        senders.removeAll { $0.id == id }
        persistSenders()
    }

    static func describe(_ error: Error) -> String {
        if let api = error as? PushAPIError { return api.message ?? api.code }
        return error.localizedDescription
    }
}
