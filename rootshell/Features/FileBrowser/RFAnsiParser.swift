#if !targetEnvironment(macCatalyst)

import Foundation

/// Parses ANSI escape sequences from bat output into TUICell arrays.
/// Handles SGR (Select Graphic Rendition) sequences for colors and attributes.
///
/// Uses byte-level (`[UInt8]`) parsing with integer indices for O(n) performance.
/// The previous String.Index/Substring implementation was O(n²) because
/// `Substring.count` walks the entire remaining text on every escape sequence.
struct RFAnsiParser {

    /// Parse ANSI-escaped text into lines of styled cells.
    /// Each line is an array of TUICell values clipped to `maxWidth`.
    static func parse(_ text: String, maxWidth: Int) -> [[TUICell]] {
        let bytes = Array(text.utf8)
        let count = bytes.count
        var lines: [[TUICell]] = []
        var currentLine: [TUICell] = []
        var style = TUIStyle.plain
        var pos = 0

        while pos < count {
            let b = bytes[pos]

            // ESC (0x1B) — try to parse escape sequence
            if b == 0x1B {
                if let (newStyle, advance) = parseSGRBytes(bytes, at: pos, count: count, currentStyle: style) {
                    style = newStyle
                    pos += advance
                    continue
                }
                if let advance = skipEscapeBytes(bytes, at: pos, count: count) {
                    pos += advance
                    continue
                }
                // Bare ESC — skip it
                pos += 1
                continue
            }

            if b == 0x0A { // \n
                lines.append(currentLine)
                currentLine = []
                pos += 1
                continue
            }

            if b == 0x0D { // \r
                pos += 1
                continue
            }

            if b == 0x09 { // \t
                let spaces = 4 - (currentLine.count % 4)
                for _ in 0..<spaces {
                    guard currentLine.count < maxWidth else { break }
                    currentLine.append(TUICell(character: " ", style: style))
                }
                pos += 1
                continue
            }

            // (Tab and ASCII runs are width-1; wide glyphs are handled in the
            // visible-text run below, which appends a continuation cell so the
            // line's cell count stays equal to its display width.)

            // Visible text run — scan forward to find contiguous non-special bytes,
            // decode as a String once, then iterate its Characters to preserve
            // grapheme clusters (combining marks, flags, ZWJ emoji).
            let runStart = pos
            while pos < count {
                let rb = bytes[pos]
                if rb == 0x1B || rb == 0x0A || rb == 0x0D || rb == 0x09 { break }
                pos += 1
            }
            let run = String(decoding: bytes[runStart..<pos], as: UTF8.self)
            for ch in run {
                let w = RFWidth.width(of: ch)
                // Stop if this glyph (incl. its trailing half) won't fit.
                guard currentLine.count + w <= maxWidth else { break }
                currentLine.append(TUICell(character: ch, style: style))
                if w == 2 {
                    currentLine.append(TUICell.continuation(style: style))
                }
            }
        }

        if !currentLine.isEmpty {
            lines.append(currentLine)
        }

        return lines
    }

    // MARK: - SGR Parsing (byte-level)

    /// Parse an SGR escape sequence: ESC [ params m
    /// Returns the new style and the byte count consumed, or nil if not SGR.
    /// All SGR characters are ASCII so byte-level parsing is exact.
    private static func parseSGRBytes(
        _ bytes: [UInt8], at pos: Int, count: Int, currentStyle: TUIStyle
    ) -> (TUIStyle, Int)? {
        // Need at least ESC [ m (3 bytes)
        guard pos + 2 < count,
              bytes[pos] == 0x1B,
              bytes[pos + 1] == 0x5B /* [ */ else { return nil }

        var i = pos + 2
        let paramStart = i

        while i < count {
            let ch = bytes[i]
            if ch == 0x6D { // 'm' — end of SGR
                let newStyle = applySGRBytes(bytes, from: paramStart, to: i, style: currentStyle)
                return (newStyle, i - pos + 1)
            }
            // Valid SGR parameter bytes: 0-9 (0x30-0x39), ; (0x3B), : (0x3A)
            if (ch >= 0x30 && ch <= 0x39) || ch == 0x3B || ch == 0x3A {
                i += 1
            } else {
                return nil // Not an SGR sequence
            }
        }

        return nil
    }

    /// Apply SGR parameters to a style. Parses integers directly from bytes
    /// to avoid String allocation and split/compactMap overhead.
    private static func applySGRBytes(
        _ bytes: [UInt8], from: Int, to: Int, style: TUIStyle
    ) -> TUIStyle {
        // Parse semicolon-separated integers directly from bytes
        var params: [Int] = []
        params.reserveCapacity(8)
        var current = 0
        var hasDigit = false

        for i in from..<to {
            let b = bytes[i]
            if b >= 0x30 && b <= 0x39 { // digit
                current = current &* 10 &+ Int(b &- 0x30)
                hasDigit = true
            } else { // separator (; or :)
                if hasDigit { params.append(current) }
                current = 0
                hasDigit = false
            }
        }
        if hasDigit {
            params.append(current)
        }

        if params.isEmpty {
            // ESC[m = reset
            return .plain
        }

        var s = style
        var i = 0
        while i < params.count {
            let p = params[i]
            switch p {
            case 0:
                s = .plain
            case 1:
                s.attrs.insert(.bold)
            case 2:
                s.attrs.insert(.dim)
            case 3:
                s.attrs.insert(.italic)
            case 4:
                s.attrs.insert(.underline)
            case 7:
                s.attrs.insert(.reverse)
            case 9:
                s.attrs.insert(.strikethrough)
            case 22:
                s.attrs.remove(.bold)
                s.attrs.remove(.dim)
            case 23:
                s.attrs.remove(.italic)
            case 24:
                s.attrs.remove(.underline)
            case 27:
                s.attrs.remove(.reverse)
            case 29:
                s.attrs.remove(.strikethrough)

            // Foreground colors: 30-37 (standard), 90-97 (bright)
            case 30...37:
                s.fg = ansi256Color(p - 30)
            case 90...97:
                s.fg = ansi256Color(p - 90 + 8)
            case 39:
                s.fg = nil // default fg

            // Background colors: 40-47 (standard), 100-107 (bright)
            case 40...47:
                s.bg = ansi256Color(p - 40)
            case 100...107:
                s.bg = ansi256Color(p - 100 + 8)
            case 49:
                s.bg = nil // default bg

            // Extended color: 38;2;R;G;B (truecolor) or 38;5;N (256-color)
            case 38:
                if i + 1 < params.count {
                    if params[i + 1] == 2, i + 4 < params.count {
                        s.fg = (UInt8(clamping: params[i + 2]),
                                UInt8(clamping: params[i + 3]),
                                UInt8(clamping: params[i + 4]))
                        i += 4
                    } else if params[i + 1] == 5, i + 2 < params.count {
                        s.fg = ansi256Color(params[i + 2])
                        i += 2
                    }
                }

            // Extended background: 48;2;R;G;B or 48;5;N
            case 48:
                if i + 1 < params.count {
                    if params[i + 1] == 2, i + 4 < params.count {
                        s.bg = (UInt8(clamping: params[i + 2]),
                                UInt8(clamping: params[i + 3]),
                                UInt8(clamping: params[i + 4]))
                        i += 4
                    } else if params[i + 1] == 5, i + 2 < params.count {
                        s.bg = ansi256Color(params[i + 2])
                        i += 2
                    }
                }

            default:
                break
            }
            i += 1
        }

        return s
    }

    /// Skip a non-SGR escape sequence and return byte count consumed.
    private static func skipEscapeBytes(_ bytes: [UInt8], at pos: Int, count: Int) -> Int? {
        guard pos + 1 < count, bytes[pos] == 0x1B else { return nil }
        let second = bytes[pos + 1]

        // CSI sequence: ESC [ ... terminal_byte (0x40-0x7E)
        if second == 0x5B { // [
            var i = pos + 2
            while i < count {
                let ch = bytes[i]
                if ch >= 0x40 && ch <= 0x7E { // Terminal byte
                    return i - pos + 1
                }
                i += 1
            }
            return count - pos
        }

        // OSC sequence: ESC ] ... ST (ESC \ or BEL)
        if second == 0x5D { // ]
            var i = pos + 2
            while i < count {
                if bytes[i] == 0x07 { // BEL
                    return i - pos + 1
                }
                if bytes[i] == 0x1B && i + 1 < count && bytes[i + 1] == 0x5C { // ESC backslash
                    return i - pos + 2
                }
                i += 1
            }
            return count - pos
        }

        // Two-character escape
        return 2
    }

    // MARK: - 256-Color Table

    /// Convert an ANSI 256-color index to an RGB tuple.
    private static func ansi256Color(_ index: Int) -> (UInt8, UInt8, UInt8) {
        // Standard 16 colors (approximate)
        let standard: [(UInt8, UInt8, UInt8)] = [
            (0, 0, 0),       // 0: black
            (205, 49, 49),    // 1: red
            (13, 188, 121),   // 2: green
            (229, 229, 16),   // 3: yellow
            (36, 114, 200),   // 4: blue
            (188, 63, 188),   // 5: magenta
            (17, 168, 205),   // 6: cyan
            (229, 229, 229),  // 7: white
            (102, 102, 102),  // 8: bright black
            (241, 76, 76),    // 9: bright red
            (35, 209, 139),   // 10: bright green
            (245, 245, 67),   // 11: bright yellow
            (59, 142, 234),   // 12: bright blue
            (214, 112, 214),  // 13: bright magenta
            (41, 184, 219),   // 14: bright cyan
            (255, 255, 255),  // 15: bright white
        ]

        if index < 16 {
            return index >= 0 ? standard[index] : (0, 0, 0)
        }

        // 216-color cube (indices 16-231)
        if index < 232 {
            let i = index - 16
            let b = i % 6
            let g = (i / 6) % 6
            let r = i / 36
            return (
                r == 0 ? 0 : UInt8(55 + 40 * r),
                g == 0 ? 0 : UInt8(55 + 40 * g),
                b == 0 ? 0 : UInt8(55 + 40 * b)
            )
        }

        // Grayscale ramp (indices 232-255)
        if index < 256 {
            let v = UInt8(8 + 10 * (index - 232))
            return (v, v, v)
        }

        return (255, 255, 255)
    }
}

#endif
