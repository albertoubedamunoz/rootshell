//
//  ConfigOverlayCodec.swift
//  rootshell
//
//  Text form of setting values for the config file. Scalars are one
//  `key = value` line; string lists repeat the key; blobs are never written.
//  A few ghostty-named keys use ghostty's vocabulary instead of raw values.
//

import Foundation

nonisolated enum ConfigOverlayCodec {
    enum DecodeError: Error, Equatable {
        case invalid(String)
    }

    /// Lines (values only) for `value`, or nil when the type cannot be represented.
    static func encode(_ value: CodableValue, for def: AnySettingDefinition) -> [String]? {
        guard let configKey = def.configKey else { return nil }
        switch value {
        case .bool(let b):
            return [b ? "true" : "false"]
        case .int(let i):
            return [String(i)]
        case .double(let d):
            if configKey == "background-blur" { return [String(Int(d.rounded()))] }
            return [d.rounded() == d ? String(Int(d)) : String(d)]
        case .string(let s):
            if configKey == "macos-option-as-alt" {
                switch s {
                case "on": return ["true"]
                case "off": return ["false"]
                default: return [quoteIfNeeded(s)]
                }
            }
            return [quoteIfNeeded(s)]
        case .stringArray(let items):
            return items.map(quoteIfNeeded)
        case .data:
            return nil
        }
    }

    /// Parse the accumulated raw values for one key. `nil` means "empty value: reset to default".
    static func decode(_ rawValues: [String], for def: AnySettingDefinition) throws -> CodableValue? {
        guard let valueType = def.valueType, let configKey = def.configKey else {
            throw DecodeError.invalid("not editable in the config file")
        }
        if valueType == .stringArray {
            if let last = rawValues.last, last.isEmpty {
                // Ghostty semantics: an empty repeatable value clears the list.
                return .stringArray([])
            }
            return .stringArray(rawValues.filter { !$0.isEmpty })
        }
        guard let raw = rawValues.last else { return nil }
        if raw.isEmpty { return nil }

        let value: CodableValue
        switch valueType {
        case .bool:
            guard let b = parseBool(raw) else { throw DecodeError.invalid("expected true or false") }
            value = .bool(b)
        case .int:
            guard let i = Int(raw) else { throw DecodeError.invalid("expected a whole number") }
            value = .int(i)
        case .double:
            if configKey == "background-blur", let b = parseBool(raw) {
                value = .double(b ? 30 : 0)
            } else if let d = Double(raw) {
                value = .double(d)
            } else {
                throw DecodeError.invalid("expected a number")
            }
        case .string:
            if configKey == "theme", raw.contains(":"), raw.contains(",") {
                throw DecodeError.invalid("use day-night-theme-day-theme and day-night-theme-night-theme for light/dark pairs")
            }
            if configKey == "macos-option-as-alt", let b = parseBool(raw) {
                value = .string(b ? "on" : "off")
            } else {
                value = .string(raw)
            }
        case .stringArray, .data:
            throw DecodeError.invalid("unsupported value type")
        }
        guard def.validate(value) else {
            throw DecodeError.invalid("\(raw) is not a valid value for \(configKey)")
        }
        return value
    }

    static func parseBool(_ raw: String) -> Bool? {
        switch raw.lowercased() {
        case "true", "yes", "on", "1": return true
        case "false", "no", "off", "0": return false
        default: return nil
        }
    }

    static func quoteIfNeeded(_ s: String) -> String {
        if s.isEmpty || s.first?.isWhitespace == true || s.last?.isWhitespace == true || s.hasPrefix("\"") {
            return "\"\(s)\""
        }
        return s
    }

    static func line(configKey: String, value: String) -> String {
        "\(configKey) = \(value)"
    }
}
