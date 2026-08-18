//
//  VTCell.swift
//  rootshell
//

import Foundation
import GhosttyKit

struct VTCell: Equatable, Sendable {
    private var contents: Data
    private var renditions: VTRenditions
    private var wide: Bool
    private var fallback: Bool
    private var wrap: Bool

    init(backgroundColor: UInt32) {
        self.contents = Data()
        self.renditions = VTRenditions(backgroundColor: backgroundColor)
        self.wide = false
        self.fallback = false
        self.wrap = false
    }

    mutating func reset(backgroundColor: UInt32) {
        contents.removeAll(keepingCapacity: true)
        renditions = VTRenditions(backgroundColor: backgroundColor)
        wide = false
        fallback = false
        wrap = false
    }

    var isEmpty: Bool { contents.isEmpty }

    var isFull: Bool { contents.count >= 32 }

    mutating func clear() { contents.removeAll(keepingCapacity: true) }

    func isBlank() -> Bool {
        if contents.isEmpty { return true }
        // Check for space (0x20) or non-breaking space (0xC2 0xA0) without allocating Data
        if contents.count == 1 && contents[contents.startIndex] == 0x20 { return true }
        if contents.count == 2 {
            let start = contents.startIndex
            if contents[start] == 0xC2 && contents[contents.index(after: start)] == 0xA0 {
                return true
            }
        }
        return false
    }

    func hasSameVisualContent(as other: VTCell) -> Bool {
        (isBlank() && other.isBlank()) || (contents == other.contents)
    }

    mutating func append(_ scalar: UInt32) {
        if scalar <= 0x7F {
            contents.append(UInt8(scalar))
            return
        }
        if let uni = UnicodeScalar(scalar) {
            let str = String(uni)
            contents.append(contentsOf: str.utf8)
        }
    }

    func appendVisualContent(to output: inout String) {
        if contents.isEmpty {
            output.append(" ")
            return
        }
        if fallback {
            output.append("\u{00A0}")
        }
        output.append(String(decoding: contents, as: UTF8.self))
    }

    static func appendToString(_ output: inout String, scalar: UInt32) {
        if scalar <= 0x7F {
            output.append(Character(UnicodeScalar(UInt8(scalar))))
        } else if let uni = UnicodeScalar(scalar) {
            output.append(Character(uni))
        }
    }

    static func isVisibleLatin1Char(_ scalar: UInt32) -> Bool {
        (scalar <= 0xff && scalar >= 0xa0) || (scalar <= 0x7e && scalar >= 0x20)
    }

    static func displayWidth(_ scalar: UInt32) -> Int {
        Int(ghostty_simd_codepoint_width(scalar))
    }

    func debugContents() -> String {
        if contents.isEmpty { return "'_' ()" }
        var chars = "'"
        var grapheme = ""
        appendVisualContent(to: &grapheme)
        chars += grapheme
        chars += "' ["
        var lazy = ""
        for byte in contents {
            chars += "\(lazy)0x\(String(format: "%02x", byte))"
            lazy = ", "
        }
        chars += "]"
        return chars
    }

    func hasDifferences(from other: VTCell) -> Bool {
        // Compare bytes directly without allocating strings
        if contents != other.contents { return true }
        if fallback != other.fallback { return true }
        if wide != other.wide { return true }
        if renditions != other.renditions { return true }
        if wrap != other.wrap { return true }
        return false
    }

    var renditionsValue: VTRenditions {
        get { renditions }
        set { renditions = newValue }
    }

    mutating func setRenditions(_ r: VTRenditions) { renditions = r }

    func getRenditions() -> VTRenditions { renditions }

    func getWide() -> Bool { wide }
    mutating func setWide(_ w: Bool) { wide = w }

    func getWidth() -> Int { wide ? 2 : 1 }

    func getFallback() -> Bool { fallback }
    mutating func setFallback(_ f: Bool) { fallback = f }

    func getWrap() -> Bool { wrap }
    mutating func setWrap(_ f: Bool) { wrap = f }
}
