//
//  VTParserAction.swift
//  rootshell
//

import Foundation

/// Actions emitted by the terminal parser.
enum VTParserAction: Equatable, Sendable {
    case ignore
    case print
    case execute
    case clear
    case collectParam
    case collectIntermediate
    case dispatchEsc
    case dispatchCSI
    case hookDCS
    case putDCS
    case unhookDCS
    case beginOSC
    case feedOSC
    case endOSC
    case userByte(UInt8)
    case resize(width: Int, height: Int)
}

/// Combines a parser action with the codepoint that triggered it.
struct VTParserEvent {
    let action: VTParserAction
    var codepoint: UInt32 = 0
    var hasCodepoint: Bool = false
}
