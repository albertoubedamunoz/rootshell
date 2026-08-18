//
//  VisorCarbonShim.swift
//  rootshell
//
//  Hand-rolled Carbon HIToolbox bindings.
//
//  We can't `import Carbon.HIToolbox` directly: in this Xcode 26.3 / macOS
//  26.x SDK combo, the Carbon umbrella header drags in a stale `KeychainHI.h`
//  whose `KCItemRef` type is undefined and the module fails to precompile
//  for the Mac Catalyst target. The functions we actually need
//  (RegisterEventHotKey, InstallEventHandler, GetApplicationEventTarget)
//  live in HIToolbox/CarbonEventsCore.h and are perfectly callable from
//  Catalyst — we just have to declare them ourselves and link Carbon at
//  the linker level.
//
//  The constants below are the stable values defined in HIToolbox/Events.h
//  (kVK_*) and MacTypes/Events.h (modifier masks). They've been the same
//  since Mac OS X 10.0.
//

#if STANDALONE && targetEnvironment(macCatalyst)

import Foundation

// MARK: - Carbon types

typealias VisorEventHandlerUPP = @convention(c) (
    OpaquePointer?,                 // EventHandlerCallRef
    OpaquePointer?,                 // EventRef
    UnsafeMutableRawPointer?        // userData
) -> OSStatus

struct EventHotKeyID {
    var signature: OSType
    var id: UInt32
}

struct EventTypeSpec {
    var eventClass: OSType
    var eventKind: UInt32
}

// MARK: - Carbon functions

@_silgen_name("RegisterEventHotKey")
nonisolated func RegisterEventHotKey(
    _ inHotKeyCode: UInt32,
    _ inHotKeyModifiers: UInt32,
    _ inHotKeyID: EventHotKeyID,
    _ inTarget: OpaquePointer,
    _ inOptions: UInt32,
    _ outRef: UnsafeMutablePointer<OpaquePointer?>
) -> OSStatus

@_silgen_name("UnregisterEventHotKey")
nonisolated func UnregisterEventHotKey(_ inHotKey: OpaquePointer) -> OSStatus

@_silgen_name("InstallEventHandler")
nonisolated func InstallEventHandler(
    _ inTarget: OpaquePointer,
    _ inHandler: VisorEventHandlerUPP,
    _ inNumTypes: UInt,
    _ inList: UnsafePointer<EventTypeSpec>,
    _ inUserData: UnsafeMutableRawPointer?,
    _ outRef: UnsafeMutablePointer<OpaquePointer?>
) -> OSStatus

@_silgen_name("RemoveEventHandler")
nonisolated func RemoveEventHandler(_ inHandlerRef: OpaquePointer) -> OSStatus

@_silgen_name("GetApplicationEventTarget")
nonisolated func GetApplicationEventTarget() -> OpaquePointer

// MARK: - Constants

// Carbon modifier masks (Events.h)
nonisolated let visorCmdKey: UInt32 = 0x100        // 256
nonisolated let visorShiftKey: UInt32 = 0x200      // 512
nonisolated let visorOptionKey: UInt32 = 0x800     // 2048
nonisolated let visorControlKey: UInt32 = 0x1000   // 4096

// Carbon event classes/kinds (CarbonEvents.h)
nonisolated let visorEventClassKeyboard: OSType = 0x6B657962  // 'keyb'
nonisolated let visorEventHotKeyPressed: UInt32 = 5
nonisolated let visorNoErr: OSStatus = 0

// Virtual key codes (HIToolbox/Events.h)
enum VK {
    static let ansi_A: Int = 0x00
    static let ansi_S: Int = 0x01
    static let ansi_D: Int = 0x02
    static let ansi_F: Int = 0x03
    static let ansi_H: Int = 0x04
    static let ansi_G: Int = 0x05
    static let ansi_Z: Int = 0x06
    static let ansi_X: Int = 0x07
    static let ansi_C: Int = 0x08
    static let ansi_V: Int = 0x09
    static let ansi_B: Int = 0x0B
    static let ansi_Q: Int = 0x0C
    static let ansi_W: Int = 0x0D
    static let ansi_E: Int = 0x0E
    static let ansi_R: Int = 0x0F
    static let ansi_Y: Int = 0x10
    static let ansi_T: Int = 0x11
    static let ansi_1: Int = 0x12
    static let ansi_2: Int = 0x13
    static let ansi_3: Int = 0x14
    static let ansi_4: Int = 0x15
    static let ansi_6: Int = 0x16
    static let ansi_5: Int = 0x17
    static let ansi_9: Int = 0x19
    static let ansi_7: Int = 0x1A
    static let ansi_8: Int = 0x1C
    static let ansi_0: Int = 0x1D
    static let ansi_O: Int = 0x1F
    static let ansi_U: Int = 0x20
    static let ansi_I: Int = 0x22
    static let ansi_P: Int = 0x23
    static let ansi_L: Int = 0x25
    static let ansi_J: Int = 0x26
    static let ansi_K: Int = 0x28
    static let ansi_Backslash: Int = 0x2A
    static let ansi_Slash: Int = 0x2C
    static let ansi_N: Int = 0x2D
    static let ansi_M: Int = 0x2E
    static let ansi_Grave: Int = 0x32
    static let `return`: Int = 0x24
    static let tab: Int = 0x30
    static let space: Int = 0x31
    static let delete: Int = 0x33
    static let escape: Int = 0x35
    static let f1: Int = 0x7A
    static let f2: Int = 0x78
    static let f3: Int = 0x63
    static let f4: Int = 0x76
    static let f5: Int = 0x60
    static let f6: Int = 0x61
    static let f7: Int = 0x62
    static let f8: Int = 0x64
    static let f9: Int = 0x65
    static let f10: Int = 0x6D
    static let f11: Int = 0x67
    static let f12: Int = 0x6F
}

#endif
