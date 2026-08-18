//
//  VTParserStateMachine.swift
//  rootshell
//

import Foundation

struct VTParserTransition {
    let action: VTParserAction
    let nextState: VTParserState?

    init(action: VTParserAction = .ignore, nextState: VTParserState? = nil) {
        self.action = action
        self.nextState = nextState
    }
}

enum VTParserState: Sendable {
    case ground, escape, escapeIntermediate
    case csiEntry, csiParam, csiIntermediate, csiIgnore
    case dcsEntry, dcsParam, dcsIntermediate, dcsPassthrough, dcsIgnore
    case oscString, sosPmApcString

    var entryAction: VTParserAction {
        switch self {
        case .escape, .csiEntry, .dcsEntry: return .clear
        case .dcsPassthrough: return .hookDCS
        case .oscString: return .beginOSC
        default: return .ignore
        }
    }

    var exitAction: VTParserAction {
        switch self {
        case .dcsPassthrough: return .unhookDCS
        case .oscString: return .endOSC
        default: return .ignore
        }
    }

    func transition(for ch: UInt32) -> VTParserTransition {
        if let anywhere = globalTransition(for: ch), anywhere.nextState != nil {
            return anywhere
        }
        // Normalize high codepoints per ECMA-48: map C1 and above to 0x41 for state table lookup
        let normalized: UInt32 = ch >= 0xA0 ? 0x41 : ch
        return stateTransition(for: normalized)
    }

    // MARK: - Internal dispatch

    private func stateTransition(for ch: UInt32) -> VTParserTransition {
        switch self {
        case .ground:             return Self.groundTransition(ch)
        case .escape:             return Self.escapeTransition(ch)
        case .escapeIntermediate: return Self.escapeIntermediateTransition(ch)
        case .csiEntry:           return Self.csiEntryTransition(ch)
        case .csiParam:           return Self.csiParamTransition(ch)
        case .csiIntermediate:    return Self.csiIntermediateTransition(ch)
        case .csiIgnore:          return Self.csiIgnoreTransition(ch)
        case .dcsEntry:           return Self.dcsEntryTransition(ch)
        case .dcsParam:           return Self.dcsParamTransition(ch)
        case .dcsIntermediate:    return Self.dcsIntermediateTransition(ch)
        case .dcsPassthrough:     return Self.dcsPassthroughTransition(ch)
        case .dcsIgnore:          return Self.dcsIgnoreTransition(ch)
        case .oscString:          return Self.oscStringTransition(ch)
        case .sosPmApcString:     return Self.sosPmApcStringTransition(ch)
        }
    }

    private func globalTransition(for ch: UInt32) -> VTParserTransition? {
        if ch == 0x18 || ch == 0x1A || (0x80...0x8F).contains(ch) || (0x91...0x97).contains(ch) || ch == 0x99 || ch == 0x9A {
            return VTParserTransition(action: .execute, nextState: .ground)
        } else if ch == 0x9C {
            return VTParserTransition(action: .ignore, nextState: .ground)
        } else if ch == 0x1B {
            return VTParserTransition(action: .ignore, nextState: .escape)
        } else if ch == 0x98 || ch == 0x9E || ch == 0x9F {
            return VTParserTransition(action: .ignore, nextState: .sosPmApcString)
        } else if ch == 0x90 {
            return VTParserTransition(action: .ignore, nextState: .dcsEntry)
        } else if ch == 0x9D {
            return VTParserTransition(action: .ignore, nextState: .oscString)
        } else if ch == 0x9B {
            return VTParserTransition(action: .ignore, nextState: .csiEntry)
        }
        return nil
    }

    // MARK: - State transition tables

    private static func groundTransition(_ ch: UInt32) -> VTParserTransition {
        if isC0Control(ch) {
            return VTParserTransition(action: .execute)
        }
        if isGraphicChar(ch) {
            return VTParserTransition(action: .print)
        }
        return VTParserTransition()
    }

    private static func escapeTransition(_ ch: UInt32) -> VTParserTransition {
        if isC0Control(ch) {
            return VTParserTransition(action: .execute)
        }
        if (0x20...0x2F).contains(ch) {
            return VTParserTransition(action: .collectIntermediate, nextState: .escapeIntermediate)
        }
        if (0x30...0x4F).contains(ch) || (0x51...0x57).contains(ch) || ch == 0x59 || ch == 0x5A || ch == 0x5C || (0x60...0x7E).contains(ch) {
            return VTParserTransition(action: .dispatchEsc, nextState: .ground)
        }
        if ch == 0x5B {
            return VTParserTransition(action: .ignore, nextState: .csiEntry)
        }
        if ch == 0x5D {
            return VTParserTransition(action: .ignore, nextState: .oscString)
        }
        if ch == 0x50 {
            return VTParserTransition(action: .ignore, nextState: .dcsEntry)
        }
        if ch == 0x58 || ch == 0x5E || ch == 0x5F {
            return VTParserTransition(action: .ignore, nextState: .sosPmApcString)
        }
        return VTParserTransition()
    }

    private static func escapeIntermediateTransition(_ ch: UInt32) -> VTParserTransition {
        if isC0Control(ch) {
            return VTParserTransition(action: .execute)
        }
        if (0x20...0x2F).contains(ch) {
            return VTParserTransition(action: .collectIntermediate)
        }
        if (0x30...0x7E).contains(ch) {
            return VTParserTransition(action: .dispatchEsc, nextState: .ground)
        }
        return VTParserTransition()
    }

    private static func csiEntryTransition(_ ch: UInt32) -> VTParserTransition {
        if isC0Control(ch) {
            return VTParserTransition(action: .execute)
        }
        if (0x40...0x7E).contains(ch) {
            return VTParserTransition(action: .dispatchCSI, nextState: .ground)
        }
        if (0x30...0x39).contains(ch) || ch == 0x3B {
            return VTParserTransition(action: .collectParam, nextState: .csiParam)
        }
        if (0x3C...0x3F).contains(ch) {
            return VTParserTransition(action: .collectIntermediate, nextState: .csiParam)
        }
        if ch == 0x3A {
            return VTParserTransition(action: .ignore, nextState: .csiIgnore)
        }
        if (0x20...0x2F).contains(ch) {
            return VTParserTransition(action: .collectIntermediate, nextState: .csiIntermediate)
        }
        return VTParserTransition()
    }

    private static func csiParamTransition(_ ch: UInt32) -> VTParserTransition {
        if isC0Control(ch) {
            return VTParserTransition(action: .execute)
        }
        if (0x30...0x39).contains(ch) || ch == 0x3B {
            return VTParserTransition(action: .collectParam)
        }
        if ch == 0x3A || (0x3C...0x3F).contains(ch) {
            return VTParserTransition(action: .ignore, nextState: .csiIgnore)
        }
        if (0x20...0x2F).contains(ch) {
            return VTParserTransition(action: .collectIntermediate, nextState: .csiIntermediate)
        }
        if (0x40...0x7E).contains(ch) {
            return VTParserTransition(action: .dispatchCSI, nextState: .ground)
        }
        return VTParserTransition()
    }

    private static func csiIntermediateTransition(_ ch: UInt32) -> VTParserTransition {
        if isC0Control(ch) {
            return VTParserTransition(action: .execute)
        }
        if (0x20...0x2F).contains(ch) {
            return VTParserTransition(action: .collectIntermediate)
        }
        if (0x40...0x7E).contains(ch) {
            return VTParserTransition(action: .dispatchCSI, nextState: .ground)
        }
        if (0x30...0x3F).contains(ch) {
            return VTParserTransition(action: .ignore, nextState: .csiIgnore)
        }
        return VTParserTransition()
    }

    private static func csiIgnoreTransition(_ ch: UInt32) -> VTParserTransition {
        if isC0Control(ch) {
            return VTParserTransition(action: .execute)
        }
        if (0x40...0x7E).contains(ch) {
            return VTParserTransition(action: .ignore, nextState: .ground)
        }
        return VTParserTransition()
    }

    private static func dcsEntryTransition(_ ch: UInt32) -> VTParserTransition {
        if (0x20...0x2F).contains(ch) {
            return VTParserTransition(action: .collectIntermediate, nextState: .dcsIntermediate)
        }
        if ch == 0x3A {
            return VTParserTransition(action: .ignore, nextState: .dcsIgnore)
        }
        if (0x30...0x39).contains(ch) || ch == 0x3B {
            return VTParserTransition(action: .collectParam, nextState: .dcsParam)
        }
        if (0x3C...0x3F).contains(ch) {
            return VTParserTransition(action: .collectIntermediate, nextState: .dcsParam)
        }
        if (0x40...0x7E).contains(ch) {
            return VTParserTransition(action: .ignore, nextState: .dcsPassthrough)
        }
        return VTParserTransition()
    }

    private static func dcsParamTransition(_ ch: UInt32) -> VTParserTransition {
        if (0x30...0x39).contains(ch) || ch == 0x3B {
            return VTParserTransition(action: .collectParam)
        }
        if ch == 0x3A || (0x3C...0x3F).contains(ch) {
            return VTParserTransition(action: .ignore, nextState: .dcsIgnore)
        }
        if (0x20...0x2F).contains(ch) {
            return VTParserTransition(action: .collectIntermediate, nextState: .dcsIntermediate)
        }
        if (0x40...0x7E).contains(ch) {
            return VTParserTransition(action: .ignore, nextState: .dcsPassthrough)
        }
        return VTParserTransition()
    }

    private static func dcsIntermediateTransition(_ ch: UInt32) -> VTParserTransition {
        if (0x20...0x2F).contains(ch) {
            return VTParserTransition(action: .collectIntermediate)
        }
        if (0x40...0x7E).contains(ch) {
            return VTParserTransition(action: .ignore, nextState: .dcsPassthrough)
        }
        if (0x30...0x3F).contains(ch) {
            return VTParserTransition(action: .ignore, nextState: .dcsIgnore)
        }
        return VTParserTransition()
    }

    private static func dcsPassthroughTransition(_ ch: UInt32) -> VTParserTransition {
        if isC0Control(ch) || (0x20...0x7E).contains(ch) {
            return VTParserTransition(action: .putDCS)
        }
        if ch == 0x9C {
            return VTParserTransition(action: .ignore, nextState: .ground)
        }
        return VTParserTransition()
    }

    private static func dcsIgnoreTransition(_ ch: UInt32) -> VTParserTransition {
        if ch == 0x9C {
            return VTParserTransition(action: .ignore, nextState: .ground)
        }
        return VTParserTransition()
    }

    private static func oscStringTransition(_ ch: UInt32) -> VTParserTransition {
        if (0x20...0x7F).contains(ch) {
            return VTParserTransition(action: .feedOSC)
        }
        if ch == 0x9C || ch == 0x07 {
            return VTParserTransition(action: .ignore, nextState: .ground)
        }
        return VTParserTransition()
    }

    private static func sosPmApcStringTransition(_ ch: UInt32) -> VTParserTransition {
        if ch == 0x9C {
            return VTParserTransition(action: .ignore, nextState: .ground)
        }
        return VTParserTransition()
    }
}

/// C0 control character (excluding ESC 0x1B)
private func isC0Control(_ ch: UInt32) -> Bool {
    (ch <= 0x17) || ch == 0x19 || (0x1C...0x1F).contains(ch)
}

/// GL or GR graphic character
private func isGraphicChar(_ ch: UInt32) -> Bool {
    (0x20...0x7F).contains(ch) || (0xA0...0xFF).contains(ch)
}
