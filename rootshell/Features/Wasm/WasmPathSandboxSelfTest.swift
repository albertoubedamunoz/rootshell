import Foundation

/// Self-test runner for `WasmPathSandbox`. Invoked by the in-app `wasm test`
/// command (see `LocalShellSession+Wasm.swift`). Returns an array of
/// (name, passed, message) tuples so the caller can render them in the
/// terminal alongside the runtime/socket integration results.
///
/// We don't use XCTest here because the project has no test target wired up
/// and end-to-end coverage from inside the running app exercises the real
/// FileManager rather than a mock.
enum WasmPathSandboxSelfTest {
    struct Result {
        let name: String
        let passed: Bool
        let message: String
    }

    static func run() -> [Result] {
        var results: [Result] = []

        let tmp = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("wasm-sandbox-tests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let inner = tmp.appendingPathComponent("inner", isDirectory: true)
        try? FileManager.default.createDirectory(at: inner, withIntermediateDirectories: true)

        let sandbox = WasmPathSandbox(root: tmp, cwd: inner)

        results.append(check("relative path stays inside", expectAllowed: true) {
            sandbox.resolve("foo.txt")
        })
        results.append(check("absolute path treated as sandbox-relative", expectAllowed: true) {
            sandbox.resolve("/foo.txt")
        })
        results.append(check("..  back to root is fine", expectAllowed: true) {
            sandbox.resolve("..")
        })
        results.append(check("..  past root is denied", expectAllowed: false) {
            sandbox.resolve("../../etc/passwd")
        })
        results.append(check("/.. escapes (absolute past root)", expectAllowed: false) {
            sandbox.resolve("/../../etc/passwd")
        })
        results.append(check("empty path denied", expectAllowed: false) {
            sandbox.resolve("")
        })
        results.append(check("null byte denied", expectAllowed: false) {
            sandbox.resolve("foo\0bar")
        })
        results.append(check("nested relative ok", expectAllowed: true) {
            sandbox.resolve("a/b/c.txt")
        })
        results.append(check("dot-dot loop netting zero ok", expectAllowed: true) {
            sandbox.resolve("a/../b/../c.txt")
        })
        results.append(check("absolute /foo/../bar ok", expectAllowed: true) {
            sandbox.resolve("/foo/../bar")
        })

        if case .allowed(let url) = sandbox.resolve("a/b.txt") {
            let virt = sandbox.virtualPath(for: url) ?? "<none>"
            results.append(Result(
                name: "virtualPath round-trips",
                passed: virt == "/inner/a/b.txt",
                message: "got \(virt)"
            ))
        } else {
            results.append(Result(
                name: "virtualPath round-trips",
                passed: false,
                message: "resolve failed"
            ))
        }

        return results
    }

    private static func check(_ name: String, expectAllowed: Bool, _ body: () -> WasmPathSandbox.Resolution) -> Result {
        let outcome = body()
        let allowed: Bool
        let detail: String
        switch outcome {
        case .allowed(let url):
            allowed = true
            detail = url.path
        case .denied(let reason):
            allowed = false
            detail = reason
        }
        return Result(
            name: name,
            passed: allowed == expectAllowed,
            message: detail
        )
    }
}
