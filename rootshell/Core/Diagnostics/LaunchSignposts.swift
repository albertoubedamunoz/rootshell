import Foundation
import os

/// os_signpost intervals for cold-launch phases. Visible in Instruments under
/// subsystem `com.rootshell`, category `Launch`. Near-zero cost when not traced.
///
/// Also emits `Logger` info lines with wall-clock ms since process start so a
/// Console / lifecycle session can compare before/after without Instruments.
nonisolated enum LaunchSignposts {
    static let signposter = OSSignposter(subsystem: "com.rootshell", category: "Launch")
    private static let logger = Logger(subsystem: "com.rootshell", category: "Launch")

    /// Process-start reference for delta logging (CFAbsoluteTimeGetCurrent basis).
    private static let processStart = CFAbsoluteTimeGetCurrent()

    @inline(__always)
    static func begin(_ name: StaticString) -> OSSignpostIntervalState {
        log("begin", name)
        return signposter.beginInterval(name)
    }

    @inline(__always)
    static func end(_ name: StaticString, _ state: OSSignpostIntervalState) {
        log("end", name)
        signposter.endInterval(name, state)
    }

    /// Instantaneous event with time since process start.
    static func event(_ name: String) {
        let elapsedMs = Int((CFAbsoluteTimeGetCurrent() - processStart) * 1000)
        logger.info("event \(name, privacy: .public) +\(elapsedMs)ms")
    }

    /// First session-ready this process — primary cold-launch KPI
    /// (process start → interactive local shell). Safe to call from any thread.
    private static let interactiveLock = NSLock()
    private static var didMarkInteractive = false

    static func markInteractiveIfNeeded() {
        interactiveLock.lock()
        defer { interactiveLock.unlock() }
        guard !didMarkInteractive else { return }
        didMarkInteractive = true
        event("launch.interactive")
    }

    private static func log(_ phase: String, _ name: StaticString) {
        let elapsedMs = Int((CFAbsoluteTimeGetCurrent() - processStart) * 1000)
        let label = name.withUTF8Buffer { buf in
            String(decoding: buf, as: UTF8.self)
        }
        logger.info("\(phase, privacy: .public) \(label, privacy: .public) +\(elapsedMs)ms")
    }
}
