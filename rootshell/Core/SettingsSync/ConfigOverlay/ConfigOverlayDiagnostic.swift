//
//  ConfigOverlayDiagnostic.swift
//  rootshell
//
//  One message about the text config: unknown key, bad value, include problem.
//

import Foundation

nonisolated struct ConfigOverlayDiagnostic: Identifiable, Sendable, Hashable {
    enum Severity: Int, Sendable, Comparable {
        case info, warning, error
        static func < (lhs: Severity, rhs: Severity) -> Bool { lhs.rawValue < rhs.rawValue }
    }

    let severity: Severity
    let file: URL?
    let line: Int?
    let key: String?
    let message: String

    var id: String { "\(severity.rawValue)|\(file?.path ?? "")|\(line ?? 0)|\(key ?? "")|\(message)" }

    var location: String? {
        guard let file else { return nil }
        if let line { return "\(file.lastPathComponent):\(line)" }
        return file.lastPathComponent
    }
}
