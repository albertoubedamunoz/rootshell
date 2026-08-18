//
//  VTRenditions.swift
//  rootshell
//

import Foundation

struct VTRenditions: Equatable, Sendable {
    enum Attribute: UInt8 {
        case bold = 0
        case faint = 1
        case italic = 2
        case underlined = 3
        case blink = 4
        case inverse = 5
        case invisible = 6
    }

    private static let trueColorMask: UInt32 = 0x0100_0000

    private var foregroundColor: UInt32
    private var backgroundColor: UInt32
    private var attributes: UInt8

    init(backgroundColor: UInt32) {
        self.foregroundColor = 0
        self.backgroundColor = backgroundColor
        self.attributes = 0
    }

    mutating func setForegroundColor(_ num: Int) {
        if (0...255).contains(num) {
            foregroundColor = UInt32(30 + num)
        } else if VTRenditions.isTrueColor(UInt32(num)) {
            foregroundColor = UInt32(num)
        }
    }

    mutating func setBackgroundColor(_ num: Int) {
        if (0...255).contains(num) {
            backgroundColor = UInt32(40 + num)
        } else if VTRenditions.isTrueColor(UInt32(num)) {
            backgroundColor = UInt32(num)
        }
    }

    mutating func setRendition(_ num: UInt32) {
        if num == 0 {
            clearAttributes()
            foregroundColor = 0
            backgroundColor = 0
            return
        }

        if num == 39 {
            foregroundColor = 0
            return
        } else if num == 49 {
            backgroundColor = 0
            return
        }

        if (30...37).contains(Int(num)) {
            foregroundColor = num
            return
        } else if (40...47).contains(Int(num)) {
            backgroundColor = num
            return
        } else if (90...97).contains(Int(num)) {
            foregroundColor = UInt32(Int(num) - 90 + 38)
            return
        } else if (100...107).contains(Int(num)) {
            backgroundColor = UInt32(Int(num) - 100 + 48)
            return
        }

        let value = num < 9
        switch num {
        case 1, 22:
            setAttribute(.bold, value)
        case 3, 23:
            setAttribute(.italic, value)
        case 4, 24:
            setAttribute(.underlined, value)
        case 5, 25:
            setAttribute(.blink, value)
        case 7, 27:
            setAttribute(.inverse, value)
        case 8, 28:
            setAttribute(.invisible, value)
        default:
            break
        }
    }

    mutating func setAttribute(_ attr: Attribute, _ val: Bool) {
        if val {
            attributes = attributes | (1 << attr.rawValue)
        } else {
            attributes = attributes & ~(1 << attr.rawValue)
        }
    }

    func getAttribute(_ attr: Attribute) -> Bool {
        (attributes & (1 << attr.rawValue)) != 0
    }

    mutating func clearAttributes() {
        attributes = 0
    }

    func getBackgroundRendition() -> UInt32 {
        backgroundColor
    }

    static func makeTrueColor(_ r: UInt32, _ g: UInt32, _ b: UInt32) -> UInt32 {
        return trueColorMask | (r << 16) | (g << 8) | b
    }

    static func isTrueColor(_ color: UInt32) -> Bool {
        (color & trueColorMask) != 0
    }

    func sgr() -> String {
        var ret = "\u{1b}[0"
        if getAttribute(.bold) { ret += ";1" }
        if getAttribute(.italic) { ret += ";3" }
        if getAttribute(.underlined) { ret += ";4" }
        if getAttribute(.blink) { ret += ";5" }
        if getAttribute(.inverse) { ret += ";7" }
        if getAttribute(.invisible) { ret += ";8" }

        if foregroundColor != 0 {
            if VTRenditions.isTrueColor(foregroundColor) {
                let r = (foregroundColor >> 16) & 0xff
                let g = (foregroundColor >> 8) & 0xff
                let b = foregroundColor & 0xff
                ret += ";38;2;\(r);\(g);\(b)"
            } else if foregroundColor > 37 {
                ret += ";38;5;\(foregroundColor - 30)"
            } else {
                ret += ";\(foregroundColor)"
            }
        }

        if backgroundColor != 0 {
            if VTRenditions.isTrueColor(backgroundColor) {
                let r = (backgroundColor >> 16) & 0xff
                let g = (backgroundColor >> 8) & 0xff
                let b = backgroundColor & 0xff
                ret += ";48;2;\(r);\(g);\(b)"
            } else if backgroundColor > 47 {
                ret += ";48;5;\(backgroundColor - 40)"
            } else {
                ret += ";\(backgroundColor)"
            }
        }

        ret += "m"
        return ret
    }
}
