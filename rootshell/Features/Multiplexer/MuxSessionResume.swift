//
//  MuxSessionResume.swift
//  rootshell
//
//  Resume-or-focus: when a mux auto-start profile is opened while a live
//  attachment to the same host/session already exists, focus that UI instead
//  of spawning a second unrelated-looking control client.
//

import Foundation
import UIKit

@MainActor
enum MuxSessionResume {
    struct Match: Equatable {
        let windowId: String
        let tabID: UUID
        let displayName: String
    }

    /// Payload for the post-detach reconnect banner.
    struct ReconnectOffer: Equatable {
        let displayName: String
        let sshConfig: SSHConfig
        let connectionProtocol: ConnectionProtocol
        let profileID: UUID?
        let target: MuxSessionTarget
    }

    /// Find a live multiplexer attachment that matches this profile's auto-start
    /// target. Returns nil when the profile does not auto-start a mux, or when
    /// no matching attachment is open.
    static func findLiveAttachment(for config: SSHConfig) -> Match? {
        guard let target = autoStartTarget(for: config) else { return nil }
        let gatewayKey = TmuxGatewaySessionStore.connectionKey(
            host: config.host,
            port: config.port,
            username: config.username
        )

        for (windowId, model) in TmuxWindowRegistry.allWindows() {
            for tab in model.tabs {
                if let match = matchTmuxControl(
                    tab: tab,
                    model: model,
                    windowId: windowId,
                    gatewayKey: gatewayKey,
                    target: target
                ) {
                    return match
                }
                if let match = matchHerdrControl(
                    tab: tab,
                    model: model,
                    windowId: windowId,
                    gatewayKey: gatewayKey,
                    target: target
                ) {
                    return match
                }
                // A raw attachment cannot satisfy a request for native panes.
                if target.controlMode {
                    continue
                }
                if let match = matchRawOrPassthrough(
                    tab: tab,
                    windowId: windowId,
                    gatewayKey: gatewayKey,
                    target: target
                ) {
                    return match
                }
            }
        }
        return nil
    }

    /// Focus an existing attachment: activate its window scene if needed, then
    /// select the tab. Returns true when focus was requested.
    @discardableResult
    static func focus(
        _ match: Match,
        in currentWindowId: String,
        selectTab: (UUID) -> Void
    ) -> Bool {
        if match.windowId != currentWindowId,
           let sceneSessionId = TerminalWindowRegistry.sceneSessionId(for: match.windowId),
           let scene = UIApplication.shared.connectedScenes
               .compactMap({ $0 as? UIWindowScene })
               .first(where: { $0.session.persistentIdentifier == sceneSessionId }) {
            UIApplication.shared.requestSceneSessionActivation(
                scene.session,
                userActivity: nil,
                options: nil,
                errorHandler: nil
            )
            // Selecting across windows: ask the owning TabsModel directly.
            if let model = TmuxWindowRegistry.tabsModel(for: match.windowId) {
                model.selectedTabID = match.tabID
                return true
            }
        }
        selectTab(match.tabID)
        return true
    }

    // MARK: - Private

    private static func autoStartTarget(for config: SSHConfig) -> MuxSessionTarget? {
        if let target = config.muxResumeTarget { return target }
        if config.tmuxAutoEnable {
            return MuxSessionTarget(
                type: .tmux,
                sessionName: config.tmuxSessionNameForConnection,
                controlMode: config.tmuxAutoMode == .control
            )
        }
        if config.herdrAutoEnable {
            return MuxSessionTarget(
                type: .herdr,
                sessionName: config.herdrSessionNameForConnection,
                controlMode: config.herdrControlModeEnabled
            )
        }
        if config.zmxAutoEnable {
            return MuxSessionTarget(
                type: .zmx,
                sessionName: config.zmxSessionNameForConnection,
                controlMode: false
            )
        }
        return nil
    }

    private static func matchTmuxControl(
        tab: TabModel,
        model: TabsModel,
        windowId: String,
        gatewayKey: String,
        target: MuxSessionTarget
    ) -> Match? {
        guard target.type == .tmux, target.controlMode else { return nil }
        let controller =
            TmuxController.controller(forWindowTab: tab)
            ?? TmuxController.controller(forGatewayTab: tab)
            ?? tab.splitTree.terminalLeaves.first(where: { $0.tmuxController != nil })?.tmuxController
        guard let controller else { return nil }
        let attached = MuxSessionTarget(type: .tmux, sessionName: controller.currentSessionName, controlMode: true)
        guard target.matchesLiveAttachment(attached, connectionKey: controller.connectionKey,
                                           requestedConnectionKey: gatewayKey, isActive: controller.isActive) else { return nil }
        let ownerID = controller.ownerTerminalUUIDForNotifications
        let focusTab = model.tabs.first(where: {
            $0.isTmuxWindow
                && !$0.isHiddenTmuxWindow
                && $0.owningGatewayTerminalUUID == ownerID
        }) ?? model.tabs.first(where: {
            $0.isTmuxGateway
                && $0.splitTree.terminalLeaves.contains(where: { $0.tmuxController === controller })
        }) ?? tab
        let name = target.sessionName
        return Match(
            windowId: windowId,
            tabID: focusTab.id,
            displayName: "tmux “\(name)”"
        )
    }

    /// Live herdr control-mode family (gateway + projected tabs), analogous
    /// to `matchTmuxControl`. The gateway pty is a normal shell, so a raw
    /// herdr binding is not present.
    private static func matchHerdrControl(
        tab: TabModel,
        model: TabsModel,
        windowId: String,
        gatewayKey: String,
        target: MuxSessionTarget
    ) -> Match? {
        guard target.type == .herdr, target.controlMode,
              let controller = HerdrController.controller(forAnyTab: tab) else { return nil }
        let ssh = controller.gateway?.connectionConfig.sshConfigForHistory
            ?? controller.gateway?.connectionConfig.underlyingSSHConfig
        let connectionKey = ssh.map {
            TmuxGatewaySessionStore.connectionKey(host: $0.host, port: $0.port, username: $0.username)
        }
        let attached = MuxSessionTarget(type: .herdr, sessionName: controller.sessionName ?? "default", controlMode: true)
        guard target.matchesLiveAttachment(attached, connectionKey: connectionKey,
                                           requestedConnectionKey: gatewayKey, isActive: controller.isActive) else { return nil }
        let focusTab = model.tabs.first(where: {
            $0.isHerdrWindow
                && !$0.isHiddenTmuxWindow
                && $0.owningGatewayTerminalUUID == controller.gatewayUUID
        }) ?? model.tabs.first(where: {
            $0.isHerdrGateway
                && $0.splitTree.terminalLeaves.contains(where: { $0.herdrController === controller })
        }) ?? tab
        let name = target.sessionName
        return Match(
            windowId: windowId,
            tabID: focusTab.id,
            displayName: "herdr “\(name)”"
        )
    }

    private static func matchRawOrPassthrough(
        tab: TabModel,
        windowId: String,
        gatewayKey: String,
        target: MuxSessionTarget
    ) -> Match? {
        for view in tab.splitTree.terminalLeaves {
            // Configuration alone is not proof of an attachment: failed
            // connections and shells left after detach retain that config.
            guard view.herdrController == nil, view.tmuxController == nil,
                  let binding = view.rawMultiplexer ?? view.passthroughMultiplexer else { continue }
            let connectionKey = view.connectionConfig.sshConfigForHistory.map {
                TmuxGatewaySessionStore.connectionKey(host: $0.host, port: $0.port, username: $0.username)
            }
            let attached = MuxSessionTarget(type: binding.type, sessionName: binding.sessionName)
            guard target.matchesLiveAttachment(attached, connectionKey: connectionKey,
                                               requestedConnectionKey: gatewayKey,
                                               isActive: view.session?.isRunning == true) else { continue }
            return Match(windowId: windowId, tabID: tab.id,
                         displayName: "\(target.type.rawValue) “\(target.sessionName)”")
        }
        return nil
    }
}
