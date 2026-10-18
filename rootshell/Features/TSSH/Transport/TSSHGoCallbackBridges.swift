//
//  TSSHGoCallbackBridges.swift
//  rootshell
//
//  Reverse-binding bridges for the Go→Swift callback direction. Go goroutines
//  call into these classes synchronously via gomobile; the bridges hop the
//  payload onto the appropriate sink (`OutputSink`, deferred-event queue, or
//  `ResumeDebugLogger`).
//
//  These bridges DO NOT make Swift→Go calls. They are exempt from the
//  `TSSHCallGate` chokepoint by design — see TSSHCallGate.swift for the
//  invariant.
//

import Foundation
import os
import OSLog
@preconcurrency import TrzszSSH

#if targetEnvironment(macCatalyst)
import IOKit
#endif

/// Bridges Go's `TSSHOutputCallback` interface to a `TrzszGoTransport`.
/// Calls land on background goroutine threads; the transport's nonisolated
/// hooks own the dispatch back onto Swift's main actor / output sinks.
nonisolated final class TrzszGoOutputBridge: NSObject, IosbridgeTSSHOutputCallbackProtocol, @unchecked Sendable {
    private weak var transport: TrzszGoTransport?

    init(transport: TrzszGoTransport) {
        self.transport = transport
        super.init()
    }

    func onOutput(_ data: Data?) {
        guard let data, let transport else { return }
        transport.emitOutputFromGoCallback(data)
    }

    func onError(_ message: String?) {
        guard let message, let transport else { return }
        transport.deferGoCallbackEvent(.error(message))
    }

    func onExit(_ exitCode: Int) {
        guard let transport else { return }
        transport.deferGoCallbackEvent(.exit(exitCode))
    }

    func onClose() {
        guard let transport else { return }
        transport.deferGoCallbackEvent(.close)
    }
}

/// Routes Go tsshd debug/warning messages to `ResumeDebugLogger` for
/// file-based persistence. Stateless; safe to instantiate per-connect.
nonisolated final class TrzszGoDebugLoggerBridge: NSObject, IosbridgeDebugLoggerProtocol, @unchecked Sendable {
    func onDebug(_ msg: String?) {
        guard let msg else { return }
        guard !Ghostty.isAppBackgroundedAtomic else { return }
        ResumeDebugLogger.shared.log(msg, source: "tsshd")
    }
}

/// Bridges Go's `DiscardNotifier` interface to a `TrzszGoTransport`. tsshd
/// reports when it dropped buffered terminal data on a lossy reconnect (the
/// server's bounded output cache overflowed, or pending input was discarded).
/// Calls land on a background goroutine; the transport's nonisolated hook hops
/// to the main actor and forwards to the session so a tmux -CC gateway can do a
/// full surface reset + recapture. Counts only — no payload crosses.
nonisolated final class TrzszGoDiscardBridge: NSObject, IosbridgeDiscardNotifierProtocol, @unchecked Sendable {
    private weak var transport: TrzszGoTransport?

    init(transport: TrzszGoTransport) {
        self.transport = transport
        super.init()
    }

    // gomobile selector: first param unlabeled, subsequent params labeled by
    // their Go names — `onDiscard(_:outputLines:outputBytes:)`.
    func onDiscard(_ inputBytes: Int, outputLines: Int, outputBytes: Int) {
        guard let transport else { return }
        transport.handleDiscardFromGoCallback(
            inputBytes: inputBytes, outputLines: outputLines, outputBytes: outputBytes)
    }
}

/// Bridges Go's `HealthNotifier` interface to a `TrzszGoTransport`. tsshd's
/// heartbeat checker pushes timeout/recovery transitions so Swift never has
/// to poll `GetLastActiveTime`. Calls land on a background goroutine; the
/// transport's nonisolated hook stamps the activity cache and hops to the
/// main actor.
nonisolated final class TrzszGoHealthBridge: NSObject, IosbridgeHealthNotifierProtocol, @unchecked Sendable {
    private weak var transport: TrzszGoTransport?

    init(transport: TrzszGoTransport) {
        self.transport = transport
        super.init()
    }

    func onHealthTimeout(_ lastActiveMs: Int64) {
        transport?.handleHealthTransitionFromGoCallback(isTimeout: true, lastActiveMs: lastActiveMs)
    }

    func onHealthRecovered(_ lastActiveMs: Int64) {
        transport?.handleHealthTransitionFromGoCallback(isTimeout: false, lastActiveMs: lastActiveMs)
    }
}

#if targetEnvironment(macCatalyst)
/// Holds tsshd reconnects while macOS lacks the Graphics capability (Dark
/// Wake), so a sleeping Mac doesn't reconnect and resize a shared tmux window.
nonisolated final class TrzszGoDarkWakePauser: NSObject, IosbridgeReconnectPauserProtocol, @unchecked Sendable {
    static let shared = TrzszGoDarkWakePauser()

    /// kIOPMSystemCapabilityGraphics in IOPMrootDomain's "System Capabilities".
    private static let graphicsCapability: UInt64 = 0x02
    private let rootDomain = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOPMrootDomain"))

    func pauseReason() -> String {
        // An unreadable value never blocks reconnects.
        guard rootDomain != IO_OBJECT_NULL,
              let capabilities = IORegistryEntryCreateCFProperty(
                rootDomain, "System Capabilities" as CFString, kCFAllocatorDefault, 0
              )?.takeRetainedValue() as? NSNumber,
              capabilities.uint64Value & Self.graphicsCapability == 0
        else { return "" }
        return "macOS Graphics capability is unavailable (possibly Dark Wake)"
    }
}
#endif
