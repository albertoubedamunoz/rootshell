//
//  RemoteAskpassProtocol.swift
//  rootshell
//
//  Wire format between `scripts/rootshell-askpass` and the app. One
//  request per connection:
//
//    ROOTSHELL-ASKPASS 1
//    PROMPT <text>
//    COMMAND <text>
//    END
//
//  Reply is `OK\n<value>` or `ERR <reason>\n`, then the app closes.
//
//  Copyright (c) 2026 Kit Knox / Rootshell LLC
//

import Foundation

nonisolated enum RemoteAskpassProtocol {
    static let header = "ROOTSHELL-ASKPASS 1"
    static let maxRequestBytes = 8 * 1024
    static let maxFieldLength = 512

    struct Request: Equatable, Sendable {
        var prompt: String
        var command: String
    }

    enum ParseError: Error, Equatable {
        case tooLarge
        case malformed
    }

    enum Failure: String, Sendable {
        case canceled
        case busy
        case timeout
        case protocolError = "protocol"
    }

    /// Parses buffered request bytes. Returns nil until the `END` line arrives.
    static func parse(_ data: Data) throws -> Request? {
        guard data.count <= maxRequestBytes else { throw ParseError.tooLarge }
        let text = String(decoding: data, as: UTF8.self)
        // The last element is an unterminated (partial) line.
        let lines = text.split(omittingEmptySubsequences: false) { $0 == "\n" || $0 == "\r\n" }.dropLast()
        guard let first = lines.first else { return nil }
        guard first == header else { throw ParseError.malformed }

        var request = Request(prompt: "", command: "")
        for line in lines.dropFirst() {
            if line == "END" { return request }
            let parts = line.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: false)
            let value = parts.count > 1 ? parts[1] : ""
            switch parts.first {
            case "PROMPT": request.prompt = sanitize(value)
            case "COMMAND": request.command = sanitize(value)
            default: continue  // Unknown keys are ignored for forward compatibility.
            }
        }
        return nil
    }

    static func success(_ value: String) -> Data {
        Data("OK\n".utf8) + Data(value.utf8)
    }

    static func failure(_ failure: Failure) -> Data {
        Data("ERR \(failure.rawValue)\n".utf8)
    }

    /// Drops control and format characters (including bidi overrides that
    /// could disguise a command), collapses whitespace, and truncates.
    static func sanitize(_ value: Substring) -> String {
        var scalars = String.UnicodeScalarView()
        for scalar in value.unicodeScalars {
            switch scalar.properties.generalCategory {
            case .control, .lineSeparator, .paragraphSeparator, .spaceSeparator:
                scalars.append(" ")
            case .format:
                continue
            default:
                scalars.append(scalar)
            }
        }
        let collapsed = String(scalars)
            .split(separator: " ", omittingEmptySubsequences: true)
            .joined(separator: " ")
        guard collapsed.count > maxFieldLength else { return collapsed }
        return String(collapsed.prefix(maxFieldLength)) + "…"
    }
}
