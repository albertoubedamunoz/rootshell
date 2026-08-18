//
//  AnyCodable.swift
//  rootshell
//
//  Type-erased Codable wrapper for JSON-RPC dynamic values
//
//  Copyright (c) 2025 Kit Knox / Rootshell LLC
//

import Foundation

/// Type-erased wrapper for any Codable value
/// Used for JSON-RPC params and results which can be any JSON type
struct MCPAnyCodable: Codable, Sendable, Equatable, Hashable {
    let value: MCPValue

    init(_ value: Any?) {
        self.value = MCPValue(value)
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        self.value = try MCPValue(from: container)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try value.encode(to: &container)
    }

    // Convenience accessors
    var isNull: Bool { value.isNull }
    var boolValue: Bool? { value.boolValue }
    var intValue: Int? { value.intValue }
    var doubleValue: Double? { value.doubleValue }
    var stringValue: String? { value.stringValue }
    var arrayValue: [MCPAnyCodable]? { value.arrayValue }
    var objectValue: [String: MCPAnyCodable]? { value.objectValue }

    // Subscript for object access
    subscript(key: String) -> MCPAnyCodable? {
        objectValue?[key]
    }

    // Subscript for array access
    subscript(index: Int) -> MCPAnyCodable? {
        guard let array = arrayValue, index >= 0, index < array.count else { return nil }
        return array[index]
    }

    static func == (lhs: MCPAnyCodable, rhs: MCPAnyCodable) -> Bool {
        lhs.value == rhs.value
    }

    func hash(into hasher: inout Hasher) {
        value.hash(into: &hasher)
    }
}

/// Internal representation of any JSON-compatible value
enum MCPValue: Sendable, Equatable, Hashable {
    case null
    case bool(Bool)
    case int(Int)
    case double(Double)
    case string(String)
    case array([MCPAnyCodable])
    case object([String: MCPAnyCodable])

    init(_ value: Any?) {
        guard let value = value else {
            self = .null
            return
        }

        switch value {
        case let bool as Bool:
            self = .bool(bool)
        case let int as Int:
            self = .int(int)
        case let double as Double:
            self = .double(double)
        case let string as String:
            self = .string(string)
        case let array as [Any]:
            self = .array(array.map { MCPAnyCodable($0) })
        case let dict as [String: Any]:
            self = .object(dict.mapValues { MCPAnyCodable($0) })
        case let codable as MCPAnyCodable:
            self = codable.value
        default:
            self = .null
        }
    }

    init(from container: SingleValueDecodingContainer) throws {
        if container.decodeNil() {
            self = .null
        } else if let bool = try? container.decode(Bool.self) {
            self = .bool(bool)
        } else if let int = try? container.decode(Int.self) {
            self = .int(int)
        } else if let double = try? container.decode(Double.self) {
            self = .double(double)
        } else if let string = try? container.decode(String.self) {
            self = .string(string)
        } else if let array = try? container.decode([MCPAnyCodable].self) {
            self = .array(array)
        } else if let object = try? container.decode([String: MCPAnyCodable].self) {
            self = .object(object)
        } else {
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Unable to decode MCPAnyCodable value"
            )
        }
    }

    func encode(to container: inout SingleValueEncodingContainer) throws {
        switch self {
        case .null:
            try container.encodeNil()
        case .bool(let value):
            try container.encode(value)
        case .int(let value):
            try container.encode(value)
        case .double(let value):
            try container.encode(value)
        case .string(let value):
            try container.encode(value)
        case .array(let value):
            try container.encode(value)
        case .object(let value):
            try container.encode(value)
        }
    }

    var isNull: Bool {
        if case .null = self { return true }
        return false
    }

    var boolValue: Bool? {
        if case .bool(let value) = self { return value }
        return nil
    }

    var intValue: Int? {
        if case .int(let value) = self { return value }
        return nil
    }

    var doubleValue: Double? {
        switch self {
        case .double(let value): return value
        case .int(let value): return Double(value)
        default: return nil
        }
    }

    var stringValue: String? {
        if case .string(let value) = self { return value }
        return nil
    }

    var arrayValue: [MCPAnyCodable]? {
        if case .array(let value) = self { return value }
        return nil
    }

    var objectValue: [String: MCPAnyCodable]? {
        if case .object(let value) = self { return value }
        return nil
    }
}

// MARK: - ExpressibleBy Literals

extension MCPAnyCodable: ExpressibleByNilLiteral {
    init(nilLiteral: ()) {
        self.init(nil)
    }
}

extension MCPAnyCodable: ExpressibleByBooleanLiteral {
    init(booleanLiteral value: Bool) {
        self.value = .bool(value)
    }
}

extension MCPAnyCodable: ExpressibleByIntegerLiteral {
    init(integerLiteral value: Int) {
        self.value = .int(value)
    }
}

extension MCPAnyCodable: ExpressibleByFloatLiteral {
    init(floatLiteral value: Double) {
        self.value = .double(value)
    }
}

extension MCPAnyCodable: ExpressibleByStringLiteral {
    init(stringLiteral value: String) {
        self.value = .string(value)
    }
}

extension MCPAnyCodable: ExpressibleByArrayLiteral {
    init(arrayLiteral elements: Any...) {
        self.value = .array(elements.map { MCPAnyCodable($0) })
    }
}

extension MCPAnyCodable: ExpressibleByDictionaryLiteral {
    init(dictionaryLiteral elements: (String, Any)...) {
        self.value = .object(Dictionary(uniqueKeysWithValues: elements.map { ($0.0, MCPAnyCodable($0.1)) }))
    }
}

// MARK: - CustomStringConvertible

extension MCPAnyCodable: CustomStringConvertible {
    var description: String {
        switch value {
        case .null: return "null"
        case .bool(let v): return String(v)
        case .int(let v): return String(v)
        case .double(let v): return String(v)
        case .string(let v): return "\"\(v)\""
        case .array(let v): return "[\(v.map(\.description).joined(separator: ", "))]"
        case .object(let v): return "{\(v.map { "\"\($0.key)\": \($0.value)" }.joined(separator: ", "))}"
        }
    }
}
