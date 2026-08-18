import Foundation

/// Per-session storage for `WasmRuntime` instances. Swift extensions cannot
/// add stored properties, so this side-table holds the association from
/// `LocalShellSession` (keyed by `ObjectIdentifier`) to its runtime. Each
/// tab is one session, so each tab gets its own WKWebView and process slot.
@MainActor
final class WasmRuntimeRegistry {
    static let shared = WasmRuntimeRegistry()

    private var runtimes: [ObjectIdentifier: WasmRuntime] = [:]

    private init() {}

    func get(for owner: ObjectIdentifier) -> WasmRuntime? {
        runtimes[owner]
    }

    func set(_ runtime: WasmRuntime, for owner: ObjectIdentifier) {
        runtimes[owner] = runtime
    }

    func remove(for owner: ObjectIdentifier) {
        runtimes.removeValue(forKey: owner)
    }
}
