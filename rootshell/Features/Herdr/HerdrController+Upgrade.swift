//
//  HerdrController+Upgrade.swift
//  rootshell
//
//  Upgrade prompts and the "who else is here" list. Alerts belong to the
//  window's MainAlertController, reached through notifications keyed by
//  window id.
//
//  Copyright (c) 2026 Kit Knox / Rootshell LLC
//

import Foundation

extension Notification.Name {
    /// userInfo: "prompt" (HerdrUpgradePrompt), "windowId" (String).
    static let herdrUpgradePromptRequested = Notification.Name("herdrUpgradePromptRequested")
}

extension HerdrController {

    func setUpgradePrompt(_ prompt: HerdrUpgradePrompt?) {
        guard upgradePrompt != prompt else { return }
        upgradePrompt = prompt
        publishSessionState()
    }

    /// Hard refusals have no card left to explain themselves; ask the window
    /// for an alert with the install command.
    func presentUpgradeAlert(_ prompt: HerdrUpgradePrompt) {
        NotificationCenter.default.post(
            name: .herdrUpgradePromptRequested, object: gatewayUUID,
            userInfo: ["prompt": prompt, "windowId": hostWindowId]
        )
    }

    /// Refreshes `otherConnections` from `control.list` when the server has it.
    func refreshOtherConnections() {
        guard capabilities.supports(.controlList), let channel else {
            if !otherConnections.isEmpty {
                otherConnections = []
                publishSessionState()
            }
            return
        }
        let generation = streamGeneration
        Task { [weak self] in
            guard let result = try? await channel.request(
                "control.list", HerdrControl.EmptyParams(), as: HerdrControl.ControlListResult.self
            ) else { return }
            guard let self, self.streamGeneration == generation, self.channel === channel else { return }
            let mine = result.self_connection_id ?? self.controlOpened?.connection_id
            let others = result.connections.filter { $0.connection_id != mine }
            guard others != self.otherConnections else { return }
            self.otherConnections = others
            self.publishSessionState()
        }
    }
}
