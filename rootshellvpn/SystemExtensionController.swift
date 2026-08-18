//
//  SystemExtensionController.swift
//  rootshellvpn (VPN host)
//
//  Activates the packet-tunnel system extension via OSSystemExtensionRequest.
//  Non-blocking: `activate()` submits the request and updates `state`; the app
//  polls `state` over the control socket and only starts the tunnel once it's
//  `.activated`. When macOS needs user approval we pop open the right System
//  Settings pane so the user isn't left guessing. The `.replace` hook lets a
//  Sparkle-updated host swap in a newer sysext.
//

import AppKit
import SystemExtensions
import os.log

@MainActor
final class SystemExtensionController: NSObject, OSSystemExtensionRequestDelegate {
    static let shared = SystemExtensionController()
    static let extensionBundleID = "com.kk2.rootshellvpn.tunnel"

    private let log = Logger(subsystem: "com.kk2.rootshellvpn.host", category: "sysext")

    enum State: String { case unknown, requesting, needsApproval, activated, failed, needsReboot }
    private(set) var state: State = .unknown

    /// Submit an activation request unless one is already in flight or done.
    /// Non-blocking — the delegate callbacks drive `state`.
    func activate() {
        if state == .activated || state == .requesting { return }
        state = .requesting
        let request = OSSystemExtensionRequest.activationRequest(
            forExtensionWithIdentifier: Self.extensionBundleID,
            queue: .main
        )
        request.delegate = self
        OSSystemExtensionManager.shared.submitRequest(request)
        log.info("submitted activation for \(Self.extensionBundleID, privacy: .public)")
    }

    private func openApprovalSettings() {
        // Login Items & Extensions is where packet-tunnel system extensions are
        // approved on modern macOS; fall back to opening System Settings.
        let candidates = [
            "x-apple.systempreferences:com.apple.LoginItems-Settings.extension",
            "x-apple.systempreferences:com.apple.ExtensionsPreferences",
        ]
        for string in candidates {
            if let url = URL(string: string), NSWorkspace.shared.open(url) { return }
        }
    }

    // MARK: OSSystemExtensionRequestDelegate

    nonisolated func request(
        _ request: OSSystemExtensionRequest,
        actionForReplacingExtension existing: OSSystemExtensionProperties,
        withExtension ext: OSSystemExtensionProperties
    ) -> OSSystemExtensionRequest.ReplacementAction {
        return .replace
    }

    nonisolated func requestNeedsUserApproval(_ request: OSSystemExtensionRequest) {
        Task { @MainActor in
            self.state = .needsApproval
            self.log.info("APPROVAL REQUIRED: opening System Settings → Login Items & Extensions → Network Extensions")
            self.openApprovalSettings()
        }
    }

    nonisolated func request(_ request: OSSystemExtensionRequest, didFinishWithResult result: OSSystemExtensionRequest.Result) {
        Task { @MainActor in
            self.state = (result == .completed) ? .activated : .needsReboot
            self.log.info("activation result: \(result.rawValue, privacy: .public)")
        }
    }

    nonisolated func request(_ request: OSSystemExtensionRequest, didFailWithError error: Error) {
        let msg = error.localizedDescription
        Task { @MainActor in
            self.state = .failed
            self.log.error("activation FAILED: \(msg, privacy: .public)")
        }
    }
}
