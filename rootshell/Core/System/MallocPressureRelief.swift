//
//  MallocPressureRelief.swift
//  rootshell
//
//  Returns freed-but-dirty malloc pages to the kernel after large temporary
//  work ends. A long-running app rarely sees the pressure that reclaims them.
//

import Foundation
import os

nonisolated enum MallocPressureRelief {
    private static let logger = Logger(subsystem: "com.rootshell", category: "Memory")
    private static let queue = DispatchQueue(label: "com.rootshell.malloc-relief", qos: .utility)
    /// Only touched on `queue`.
    nonisolated(unsafe) private static var scheduled = false

    /// Coalesces a burst of requests (closing many tabs) into one pass.
    static func request(after delay: TimeInterval = 2) {
        queue.async {
            guard !scheduled else { return }
            scheduled = true
            queue.asyncAfter(deadline: .now() + delay) {
                scheduled = false
                relieve()
            }
        }
    }

    /// Runs now; for backgrounding, where a delayed pass may land after suspension.
    static func requestNow() {
        queue.async { relieve() }
    }

    private static func relieve() {
        let freed = malloc_zone_pressure_relief(nil, 0)
        logger.info("Malloc pressure relief returned \(freed / 1_048_576, privacy: .public) MB")
    }
}
