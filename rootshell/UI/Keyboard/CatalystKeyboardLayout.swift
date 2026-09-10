//
//  CatalystKeyboardLayout.swift
//  rootshell
//
//  Provides keyboard layout translation on Mac Catalyst via dynamically
//  loaded Carbon APIs (UCKeyTranslate). These are public macOS APIs not
//  exposed in the Catalyst SDK headers but available at runtime.
//
//  Falls back gracefully if the symbols can't be loaded.
//

#if targetEnvironment(macCatalyst)
import Foundation
import os

/// Translates physical key codes to characters using the current keyboard layout
/// on Mac Catalyst. Uses dlsym to load UCKeyTranslate from Carbon.framework.
@MainActor
final class CatalystKeyboardLayout {
    private static let logger = Logger(subsystem: "com.rootshell", category: "CatalystKeyboardLayout")

    static let shared = CatalystKeyboardLayout()

    // MARK: - Carbon function types

    private typealias TISCopyCurrentKeyboardLayoutInputSourceFn = @convention(c) () -> Unmanaged<AnyObject>?
    private typealias TISGetInputSourcePropertyFn = @convention(c) (AnyObject, CFString) -> Unmanaged<CFData>?
    // UCKeyTranslate signature:
    //   (layoutData, keyCode, action, modifierState, keyboardType, options,
    //    deadKeyState, maxLength, actualLength, unicodeString) -> OSStatus
    private typealias UCKeyTranslateFn = @convention(c) (
        UnsafeRawPointer, UInt16, UInt16, UInt32, UInt32, UInt32,
        UnsafeMutablePointer<UInt32>, Int, UnsafeMutablePointer<Int>, UnsafeMutablePointer<UInt16>
    ) -> Int32
    private typealias LMGetKbdTypeFn = @convention(c) () -> UInt8

    // MARK: - Loaded function pointers

    private let tisGetSource: TISCopyCurrentKeyboardLayoutInputSourceFn?
    private let tisGetProperty: TISGetInputSourcePropertyFn?
    private let ucKeyTranslate: UCKeyTranslateFn?
    private let lmGetKbdType: LMGetKbdTypeFn?
    private let kTISPropertyUnicodeKeyLayoutData: CFString?

    /// Whether all required Carbon functions were loaded successfully.
    var isAvailable: Bool {
        tisGetSource != nil && tisGetProperty != nil
            && ucKeyTranslate != nil && lmGetKbdType != nil
            && kTISPropertyUnicodeKeyLayoutData != nil
    }

    // MARK: - Init (load via dlsym)

    private init() {
        guard let carbon = dlopen("/System/Library/Frameworks/Carbon.framework/Carbon", RTLD_LAZY) else {
            Self.logger.info("Carbon.framework not available — keyboard layout translation disabled")
            tisGetSource = nil; tisGetProperty = nil; ucKeyTranslate = nil
            lmGetKbdType = nil; kTISPropertyUnicodeKeyLayoutData = nil
            return
        }

        tisGetSource = dlsym(carbon, "TISCopyCurrentKeyboardLayoutInputSource")
            .map { unsafeBitCast($0, to: TISCopyCurrentKeyboardLayoutInputSourceFn.self) }

        tisGetProperty = dlsym(carbon, "TISGetInputSourceProperty")
            .map { unsafeBitCast($0, to: TISGetInputSourcePropertyFn.self) }

        ucKeyTranslate = dlsym(carbon, "UCKeyTranslate")
            .map { unsafeBitCast($0, to: UCKeyTranslateFn.self) }

        lmGetKbdType = dlsym(carbon, "LMGetKbdType")
            .map { unsafeBitCast($0, to: LMGetKbdTypeFn.self) }

        // Load the constant string for the layout data property key
        if let sym = dlsym(carbon, "kTISPropertyUnicodeKeyLayoutData") {
            kTISPropertyUnicodeKeyLayoutData = sym.load(as: CFString.self)
        } else {
            kTISPropertyUnicodeKeyLayoutData = nil
        }

        if isAvailable {
            Self.logger.info("Carbon keyboard layout APIs loaded successfully")
        } else {
            Self.logger.info("Some Carbon keyboard layout APIs failed to load — using fallback")
        }
        // Don't dlclose — keep Carbon loaded for the process lifetime
    }

    // MARK: - Public API

    /// Translate a macOS CGKeyCode to a character string for the current keyboard layout.
    /// - Parameters:
    ///   - keyCode: Native macOS CGKeyCode (NOT HID usage code)
    ///   - shift: Whether Shift is held
    ///   - command: Whether to use the layout's Command-specific mapping
    /// - Returns: The character the key produces, or nil if translation fails.
    func translateKey(cgKeyCode: UInt16, shift: Bool, command: Bool = false) -> String? {
        guard let tisGetSource, let tisGetProperty, let ucKeyTranslate,
              let lmGetKbdType, let kTISPropertyUnicodeKeyLayoutData else {
            return nil
        }

        // Get current keyboard layout
        guard let sourceRef = tisGetSource() else { return nil }
        let source = sourceRef.takeRetainedValue()

        guard let dataRef = tisGetProperty(source, kTISPropertyUnicodeKeyLayoutData) else {
            return nil
        }
        let layoutData = dataRef.takeUnretainedValue() as CFData
        let layoutPtr = CFDataGetBytePtr(layoutData)!

        // Carbon has Command at bit 8 and Shift at bit 9. UCKeyTranslate
        // expects the event modifier bits shifted right by 8.
        let modifierState: UInt32 = (command ? 0x01 : 0) | (shift ? 0x02 : 0)

        let kbdType = UInt32(lmGetKbdType())
        let kUCKeyActionDown: UInt16 = 0
        let kUCKeyTranslateNoDeadKeysMask: UInt32 = 1

        var deadKeyState: UInt32 = 0
        var actualLength: Int = 0
        var chars: [UInt16] = [0, 0, 0, 0]

        let status = ucKeyTranslate(
            layoutPtr,
            cgKeyCode,
            kUCKeyActionDown,
            modifierState,
            kbdType,
            kUCKeyTranslateNoDeadKeysMask,
            &deadKeyState,
            4,
            &actualLength,
            &chars
        )

        guard status == 0, actualLength > 0 else { return nil }
        return String(utf16CodeUnits: chars, count: actualLength)
    }
}
#endif
