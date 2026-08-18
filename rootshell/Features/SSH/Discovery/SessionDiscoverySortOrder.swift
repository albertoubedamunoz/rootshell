//
//  SessionDiscoverySortOrder.swift
//  rootshell
//
//  Sort order preference for multiplexer session discovery.
//

import Foundation

enum SessionDiscoverySortOrder: String, CaseIterable, Codable, Sendable {
    case attachedFirst
    case detachedFirst
    case alphabetical

    static let storageKey = "sessionDiscoverySortOrder"

    var displayName: String {
        switch self {
        case .attachedFirst: return "Attached First"
        case .detachedFirst: return "Detached First"
        case .alphabetical: return "Alphabetical"
        }
    }

    func compare(_ lhs: MultiplexerSession, _ rhs: MultiplexerSession) -> Bool {
        switch self {
        case .alphabetical:
            return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
        case .attachedFirst, .detachedFirst:
            if lhs.isExited != rhs.isExited {
                return !lhs.isExited
            }
            if lhs.isAttached != rhs.isAttached {
                return self == .attachedFirst ? lhs.isAttached : !lhs.isAttached
            }
            return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
        }
    }
}
