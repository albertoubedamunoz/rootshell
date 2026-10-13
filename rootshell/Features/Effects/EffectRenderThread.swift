// EffectRenderThread.swift
// rootshell

import Foundation

/// One run-loop thread for Metal effects, so their frames never wait on the
/// main thread or delay its scroll and touch callbacks.
nonisolated final class EffectRenderThread: Thread, @unchecked Sendable {
    static let shared: EffectRenderThread = {
        let thread = EffectRenderThread()
        thread.start()
        thread.ready.wait()
        return thread
    }()

    private let ready = DispatchSemaphore(value: 0)
    /// Set before `ready` signals, then only used to schedule work on this thread.
    private(set) var runLoop: RunLoop!
    private var cfRunLoop: CFRunLoop!

    override init() {
        super.init()
        name = "Effect render"
        qualityOfService = .userInteractive
    }

    override func main() {
        runLoop = RunLoop.current
        cfRunLoop = CFRunLoopGetCurrent()
        // A port keeps the loop alive while nothing else is scheduled.
        runLoop.add(NSMachPort(), forMode: .default)
        ready.signal()
        while true { _ = runLoop.run(mode: .default, before: .distantFuture) }
    }

    func perform(_ block: @escaping @Sendable () -> Void) {
        CFRunLoopPerformBlock(cfRunLoop, CFRunLoopMode.defaultMode.rawValue, block)
        CFRunLoopWakeUp(cfRunLoop)
    }
}
