//
//  AgentAttentionDeadlineQueue.swift
//  rootshell
//
//  A tiny event-driven deadline set used by AgentAttentionCenter. An empty
//  queue means there is no timer and therefore no idle wakeup.
//

import Foundation

struct AgentAttentionDeadlineQueue<Key: Hashable> {
    private var deadlines: [Key: Date] = [:]

    var isEmpty: Bool { deadlines.isEmpty }
    var nextDeadline: Date? { deadlines.values.min() }

    /// Coalesce repeated work for one key without pushing its first deadline
    /// back. This bounds latency during a continuous output stream.
    @discardableResult
    mutating func schedule(_ key: Key, at deadline: Date) -> Bool {
        if let current = deadlines[key], current <= deadline {
            return false
        }
        deadlines[key] = deadline
        return true
    }

    mutating func cancel(_ key: Key) {
        deadlines.removeValue(forKey: key)
    }

    mutating func removeAll() {
        deadlines.removeAll(keepingCapacity: true)
    }

    /// Removes every key whose deadline has arrived. The caller applies its
    /// own priority and work budget, then requeues any overflow.
    mutating func takeDue(at now: Date) -> [Key] {
        let due = deadlines.compactMap { key, deadline in
            deadline <= now ? key : nil
        }
        for key in due {
            deadlines.removeValue(forKey: key)
        }
        return due
    }
}
