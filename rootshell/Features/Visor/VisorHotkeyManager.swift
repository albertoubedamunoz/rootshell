//
//  VisorHotkeyManager.swift
//  rootshell
//
//  Global hotkey registration for the visor. Default backend is Carbon
//  RegisterEventHotKey (no permission prompt). Users can opt into a
//  CGEventTap backend that requires Accessibility but allows binding
//  combos Carbon can't express. On Accessibility denial we fall back to
//  Carbon so the user is never left without a working hotkey.
//

#if STANDALONE && targetEnvironment(macCatalyst)

import Foundation
import CoreGraphics
import Combine
import os

extension Notification.Name {
    // Posted from the Carbon / CGEventTap C callbacks, which are nonisolated.
    nonisolated static let visorHotkeyFired = Notification.Name("com.rootshell.visorHotkeyFired")
}

enum VisorHotkeyError: LocalizedError {
    case carbonRegistrationFailed(OSStatus)
    case eventTapDenied

    var errorDescription: String? {
        switch self {
        case .carbonRegistrationFailed(let status):
            return "Failed to register hotkey (Carbon status \(status))"
        case .eventTapDenied:
            return "Accessibility permission denied — falling back to Carbon hotkey"
        }
    }
}

// nonisolated so the backends' `deinit { unregister() }` stays legal.
nonisolated protocol HotkeyBackend: AnyObject {
    func register(keyCode: Int, modifiers: UInt32) throws
    func unregister()
}

@MainActor
final class VisorHotkeyManager: ObservableObject {
    static let shared = VisorHotkeyManager()

    @Published var lastError: VisorHotkeyError?

    private nonisolated static let logger = Logger(subsystem: "com.rootshell", category: "VisorHotkeyManager")

    private var backend: HotkeyBackend?
    private var observerToken: Any?
    private var settingsSubscription: AnyCancellable?

    private init() {
        observerToken = NotificationCenter.default.addObserver(
            forName: .visorHotkeyFired,
            object: nil,
            queue: .main
        ) { _ in
            Task { @MainActor in
                VisorController.shared.toggle()
            }
        }
    }

    /// Called from CatalystAppDelegate on launch. Subscribes to settings
    /// changes and registers the hotkey if it's enabled and configured.
    func registerIfEnabled() {
        settingsSubscription = VisorSettings.shared.hotkeyConfigPublisher
            .debounce(for: .milliseconds(250), scheduler: DispatchQueue.main)
            .sink { [weak self] cfg in
                self?.apply(config: cfg)
            }
    }

    private func apply(config: VisorSettings.HotkeyConfig) {
        // Tear down any existing registration first; new modifier/key combos
        // require a fresh registration.
        backend?.unregister()
        backend = nil
        lastError = nil

        guard config.enabled, config.keyCode >= 0 else { return }

        // Pick backend.
        if config.useEventTap {
            let tap = EventTapHotkeyBackend()
            do {
                try tap.register(keyCode: config.keyCode, modifiers: config.modifiers)
                backend = tap
                return
            } catch {
                Self.logger.warning("Event tap backend failed (\(String(describing: error))); falling back to Carbon")
                lastError = .eventTapDenied
                // Fall through to Carbon.
            }
        }

        let carbon = CarbonHotkeyBackend()
        do {
            try carbon.register(keyCode: config.keyCode, modifiers: config.modifiers)
            backend = carbon
        } catch {
            Self.logger.error("Carbon hotkey registration failed: \(String(describing: error))")
            if let visorErr = error as? VisorHotkeyError {
                lastError = visorErr
            }
        }
    }
}

// MARK: - Carbon backend

private nonisolated let visorCarbonSignature: OSType = OSType(0x7273767a)  // 'rsvz'

private nonisolated final class CarbonHotkeyBackend: HotkeyBackend {
    private var hotKeyRef: OpaquePointer?
    private var handlerRef: OpaquePointer?

    func register(keyCode: Int, modifiers: UInt32) throws {
        unregister()
        let hotKeyID = EventHotKeyID(signature: visorCarbonSignature, id: 1)
        var ref: OpaquePointer?
        let regStatus = RegisterEventHotKey(
            UInt32(keyCode),
            modifiers,
            hotKeyID,
            GetApplicationEventTarget(),
            0,
            &ref
        )
        guard regStatus == visorNoErr, let ref else {
            throw VisorHotkeyError.carbonRegistrationFailed(regStatus)
        }
        hotKeyRef = ref

        var spec = EventTypeSpec(
            eventClass: visorEventClassKeyboard,
            eventKind: visorEventHotKeyPressed
        )
        var handler: OpaquePointer?
        let installStatus = withUnsafePointer(to: &spec) { specPtr -> OSStatus in
            InstallEventHandler(
                GetApplicationEventTarget(),
                { _, _, _ in
                    NotificationCenter.default.post(name: .visorHotkeyFired, object: nil)
                    return visorNoErr
                },
                1,
                specPtr,
                nil,
                &handler
            )
        }
        if installStatus == visorNoErr {
            handlerRef = handler
        } else {
            _ = UnregisterEventHotKey(ref)
            hotKeyRef = nil
            throw VisorHotkeyError.carbonRegistrationFailed(installStatus)
        }
    }

    func unregister() {
        if let ref = hotKeyRef {
            _ = UnregisterEventHotKey(ref)
            hotKeyRef = nil
        }
        if let handler = handlerRef {
            _ = RemoveEventHandler(handler)
            handlerRef = nil
        }
    }

    deinit { unregister() }
}

// MARK: - CGEventTap backend

private nonisolated final class EventTapHotkeyBackend: HotkeyBackend {
    private var tap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var targetKeyCode: Int = -1
    private var targetCarbonModifiers: UInt32 = 0

    func register(keyCode: Int, modifiers: UInt32) throws {
        unregister()
        targetKeyCode = keyCode
        targetCarbonModifiers = modifiers

        let mask = (1 << CGEventType.keyDown.rawValue)
        let info = Unmanaged.passUnretained(self).toOpaque()

        let callback: CGEventTapCallBack = { _, type, event, refcon in
            guard type == .keyDown, let refcon else {
                return Unmanaged.passUnretained(event)
            }
            let backend = Unmanaged<EventTapHotkeyBackend>.fromOpaque(refcon).takeUnretainedValue()
            if backend.matches(event) {
                NotificationCenter.default.post(name: .visorHotkeyFired, object: nil)
                return nil  // swallow the keystroke
            }
            return Unmanaged.passUnretained(event)
        }

        guard let port = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: CGEventMask(mask),
            callback: callback,
            userInfo: info
        ) else {
            throw VisorHotkeyError.eventTapDenied
        }

        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, port, 0)
        CFRunLoopAddSource(CFRunLoopGetCurrent(), source, .commonModes)
        CGEvent.tapEnable(tap: port, enable: true)
        tap = port
        runLoopSource = source
    }

    func unregister() {
        if let source = runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetCurrent(), source, .commonModes)
            runLoopSource = nil
        }
        if let tap {
            CGEvent.tapEnable(tap: tap, enable: false)
            self.tap = nil
        }
        targetKeyCode = -1
        targetCarbonModifiers = 0
    }

    fileprivate func matches(_ event: CGEvent) -> Bool {
        let keyCode = Int(event.getIntegerValueField(.keyboardEventKeycode))
        guard keyCode == targetKeyCode else { return false }
        let cgFlags = event.flags
        let want = Self.cgFlagsForCarbonModifiers(targetCarbonModifiers)
        // Compare only the modifier bits we care about.
        let modifierMask: CGEventFlags = [.maskCommand, .maskShift, .maskAlternate, .maskControl]
        return (cgFlags.intersection(modifierMask)) == (want.intersection(modifierMask))
    }

    private static func cgFlagsForCarbonModifiers(_ mods: UInt32) -> CGEventFlags {
        var flags: CGEventFlags = []
        if mods & visorCmdKey != 0 { flags.insert(.maskCommand) }
        if mods & visorShiftKey != 0 { flags.insert(.maskShift) }
        if mods & visorOptionKey != 0 { flags.insert(.maskAlternate) }
        if mods & visorControlKey != 0 { flags.insert(.maskControl) }
        return flags
    }

    deinit { unregister() }
}

#endif
