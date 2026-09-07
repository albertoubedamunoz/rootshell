import Foundation

/// Gives the first terminal priority over launch maintenance on MainActor.
/// A connection picker, failed restore, or background launch may never create
/// a ready session, so maintenance must also be released by a bounded fallback.
@MainActor
final class LaunchMaintenanceGate {
    static let shared = LaunchMaintenanceGate()

    private var released = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private var fallback: DispatchWorkItem?

    func wait() async {
        guard !released else { return }
        await withCheckedContinuation { continuation in
            waiters.append(continuation)
            guard fallback == nil else { return }
            let work = DispatchWorkItem { [weak self] in
                self?.release()
            }
            fallback = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 1, execute: work)
        }
    }

    func release() {
        guard !released else { return }
        released = true
        fallback?.cancel()
        fallback = nil
        let pending = waiters
        waiters.removeAll()
        for continuation in pending {
            continuation.resume()
        }
    }
}
