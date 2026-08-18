// LocalShellSession is iOS/visionOS-only (Mac Catalyst uses CatalystLocalShellSession,
// which doesn't host the WasmRuntime). Skip this file on Catalyst.
#if !targetEnvironment(macCatalyst)

import Foundation
import Network

/// End-to-end runner driven by the in-app `wasm test` command. Spins up
/// loopback servers, invokes the bundled `wasm-demo.wasm` against them, and
/// asserts the output. Runs from inside the live app rather than as XCTests
/// so it exercises the actual `WasmRuntime` + `LocalShellSession` paths.
@MainActor
final class WasmIntegrationRunner {
    private weak var session: LocalShellSession?
    private let demoURL: URL
    private let runtime: WasmRuntime

    init(session: LocalShellSession, demoURL: URL, runtime: WasmRuntime) {
        self.session = session
        self.demoURL = demoURL
        self.runtime = runtime
    }

    /// Runs every test case in sequence. Returns true if all passed.
    func runAll() async -> Bool {
        var passed = true

        passed = await runCase(name: "hello", argv: ["hello"]) { output in
            output.contains("hello from wasm-demo")
        } && passed

        passed = await runCase(name: "fs-write", argv: ["fs-write", "/tmp/wasm-test.txt"]) { output in
            output.contains("wrote 15 bytes")
        } && passed

        passed = await runCase(name: "fs-read", argv: ["fs-read", "/tmp/wasm-test.txt"]) { output in
            output.contains("hello, wasm fs")
        } && passed

        passed = await runCase(name: "fs-escape (negative)", argv: ["fs-escape", "../../etc/passwd"]) { output in
            output.contains("open failed")
        } && passed

        // TCP client — hit www.google.com:80. Returns a 301 redirect to
        // https but that's still a valid HTTP/1.x response, which is all we
        // need to confirm the TCP path works end to end.
        passed = await runCase(
            name: "tcp-client",
            argv: ["tcp-client", "www.google.com", "80"]
        ) { output in
            output.contains("HTTP/1.")
        } && passed

        // DNS query — hand-rolled UDP DNS packet to a public resolver. This
        // replaces the old loopback udp-echo case: hitting real DNS exercises
        // the same UDP path (sendto/recvfrom + peer-addr return) while also
        // validating that name resolution works end to end.
        passed = await runCase(
            name: "dns-query",
            argv: ["dns-query", "google.com", "1.1.1.1"]
        ) { output in
            output.contains("google.com A ")
        } && passed

        // TCP listen — connect a loopback client after the WASM listener is up.
        passed = await runListenCase() && passed

        return passed
    }

    private func runCase(name: String,
                         argv: [String],
                         expect: @escaping (String) -> Bool) async -> Bool {
        var captured = ""
        let code = await launchDemo(argv: argv) { chunk in
            captured += chunk
        }
        let ok = code == 0 && expect(captured)
        emit("  [\(ok ? "ok" : "FAIL")] \(name) — exit=\(code)\n")
        if !ok, !captured.isEmpty {
            emit("       output: \(captured.prefix(200).replacingOccurrences(of: "\n", with: " "))\n")
        }
        return ok
    }

    private func runListenCase() async -> Bool {
        // The WASM listener picks port from argv. We pre-pick a port likely
        // free, kick off the demo, and connect after a short delay.
        let port: UInt16 = UInt16.random(in: 30_000..<40_000)
        var captured = ""
        let task = Task<Int32, Never> { [weak self] in
            guard let self else { return 1 }
            return await self.launchDemo(argv: ["tcp-listen", String(port)]) { chunk in
                captured += chunk
            }
        }

        try? await Task.sleep(nanoseconds: 300_000_000) // 300ms for bind/listen

        // Client side: connect, send "hi", read reply.
        let clientOK = await sendOneLine(host: "127.0.0.1", port: port, payload: "hi\n")
        let code = await task.value
        let ok = code == 0 && clientOK && captured.contains("served one client")
        emit("  [\(ok ? "ok" : "FAIL")] tcp-listen — exit=\(code), client=\(clientOK)\n")
        return ok
    }

    private func launchDemo(argv: [String], onChunk: @escaping (String) -> Void) async -> Int32 {
        guard let session else { return 1 }
        _ = session
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let cwd = docs

        var env: [String: String] = [
            "HOME": docs.path,
            "PWD":  cwd.path,
            "COLUMNS": "80",
            "LINES":   "24",
        ]
        if let path = ProcessInfo.processInfo.environment["PATH"] {
            env["PATH"] = path
        }
        return await runtime.run(
            wasmURL: demoURL,
            argv: [demoURL.lastPathComponent] + argv,
            env: env,
            cwd: cwd,
            sandboxRoot: docs,
            onStdout: { data in
                if let s = String(data: data, encoding: .utf8) { onChunk(s) }
            },
            onStderr: { data in
                if let s = String(data: data, encoding: .utf8) { onChunk(s) }
            }
        )
    }

    // MARK: - Tiny loopback servers

    private var pendingListeners: [NWListener] = []
    private var pendingConnections: [NWConnection] = []

    private func sendOneLine(host: String, port: UInt16, payload: String) async -> Bool {
        guard let nwPort = NWEndpoint.Port(rawValue: port) else { return false }
        // Network.framework callbacks fire on its own queue, so we need an
        // explicit Sendable+locked flag rather than a captured `var`.
        let flag = AtomicResumeFlag()
        return await withCheckedContinuation { (cont: CheckedContinuation<Bool, Never>) in
            let conn = NWConnection(host: NWEndpoint.Host(host), port: nwPort, using: .tcp)
            conn.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    conn.send(content: Data(payload.utf8), completion: .contentProcessed { _ in
                        conn.receive(minimumIncompleteLength: 1, maximumLength: 256) { _, _, _, _ in
                            if flag.tryResume() { cont.resume(returning: true) }
                            conn.cancel()
                        }
                    })
                case .failed:
                    if flag.tryResume() { cont.resume(returning: false) }
                default:
                    break
                }
            }
            conn.start(queue: .global())
            DispatchQueue.global().asyncAfter(deadline: .now() + 2.0) {
                if flag.tryResume() {
                    cont.resume(returning: false)
                    conn.cancel()
                }
            }
        }
    }

    private func emit(_ s: String) {
        session?.onOutput?(s.replacingOccurrences(of: "\n", with: "\r\n"))
    }
}

/// One-shot resume guard used by `sendOneLine` to make sure the continuation
/// is resumed exactly once even when multiple Network.framework callbacks
/// race. `@unchecked Sendable` is fine here — all mutation goes through the
/// lock.
private nonisolated final class AtomicResumeFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var fired = false
    func tryResume() -> Bool {
        lock.lock(); defer { lock.unlock() }
        if fired { return false }
        fired = true
        return true
    }
}

#endif
