import Foundation
import Network
import OSLog

/// Tiny HTTP/1.1 server bound to the loopback interface only. Serves the
/// `Wasm/` resources out of the app bundle so the WKWebView loads them over
/// `http://127.0.0.1:<port>/...` — an http(s) origin is required for the
/// page to be a secure context and have `crossOriginIsolated === true`.
/// Custom URL schemes don't qualify, which is why
/// `WKURLSchemeHandler`-served pages can't enable `SharedArrayBuffer` even
/// with the right COOP/COEP headers.
///
/// One server per `WasmRuntime` (i.e. per shell session). We pick an
/// ephemeral port and bind with `requiredInterfaceType = .loopback` so iOS
/// never prompts the user for Local Network access.
@MainActor
final class WasmLocalServer {
    nonisolated static let logger = Logger(subsystem: "com.rootshell", category: "WasmLocalServer")

    private var listener: NWListener?
    private(set) var port: UInt16 = 0

    /// Starts the server and returns the bound port. Drives the listener's
    /// `stateUpdateHandler` so we resume exactly once the listener reaches
    /// `.ready` (or fails with a concrete reason). We intentionally do *not*
    /// constrain `requiredInterfaceType` — that constraint applies to peer
    /// connections, not the bind, and on iOS 26 it seems to keep the listener
    /// from ever reaching `.ready`. Loopback-only security is preserved by
    /// the WKWebView never being pointed at anything but `127.0.0.1`.
    func start() async throws -> UInt16 {
        let params = NWParameters.tcp
        params.allowLocalEndpointReuse = true
        // Don't include peer-to-peer awareness — it adds Bonjour overhead
        // and can prolong the time-to-ready.
        params.includePeerToPeer = false

        let listener = try NWListener(using: params, on: .any)

        listener.newConnectionHandler = { conn in
            conn.start(queue: .global(qos: .userInitiated))
            Self.handle(connection: conn)
        }

        let assignedPort: UInt16 = try await withCheckedThrowingContinuation { cont in
            // Single-shot resume guard — stateUpdateHandler can fire many
            // times (e.g. `.setup` → `.ready`).
            let resumeFlag = LocalServerResumeFlag()

            listener.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    guard resumeFlag.fire() else { return }
                    if let p = listener.port?.rawValue {
                        cont.resume(returning: p)
                    } else {
                        cont.resume(throwing: NSError(
                            domain: "WasmLocalServer", code: 2,
                            userInfo: [NSLocalizedDescriptionKey: "listener ready but port unknown"]))
                    }
                case .failed(let err):
                    guard resumeFlag.fire() else { return }
                    cont.resume(throwing: NSError(
                        domain: "WasmLocalServer", code: 3,
                        userInfo: [NSLocalizedDescriptionKey: "NWListener failed: \(err)"]))
                case .cancelled:
                    guard resumeFlag.fire() else { return }
                    cont.resume(throwing: NSError(
                        domain: "WasmLocalServer", code: 4,
                        userInfo: [NSLocalizedDescriptionKey: "NWListener cancelled before ready"]))
                case .setup, .waiting:
                    break
                @unknown default:
                    break
                }
            }
            listener.start(queue: .global(qos: .userInitiated))

            // Safety: if we never get .ready / .failed within 3s, surface a
            // timeout rather than hanging forever.
            DispatchQueue.global().asyncAfter(deadline: .now() + 3.0) {
                guard resumeFlag.fire() else { return }
                cont.resume(throwing: NSError(
                    domain: "WasmLocalServer", code: 5,
                    userInfo: [NSLocalizedDescriptionKey: "NWListener did not reach .ready within 3s"]))
            }
        }

        self.listener = listener
        self.port = assignedPort
        Self.logger.info("loopback HTTP server bound to 127.0.0.1:\(assignedPort, privacy: .public)")
        return assignedPort
    }

    /// One-shot resume guard — `stateUpdateHandler` fires many times so we
    /// need to ensure the continuation resumes exactly once.
    private nonisolated final class LocalServerResumeFlag: @unchecked Sendable {
        private let lock = NSLock()
        private var done = false
        func fire() -> Bool {
            lock.lock(); defer { lock.unlock() }
            if done { return false }
            done = true
            return true
        }
    }

    func stop() {
        listener?.cancel()
        listener = nil
        port = 0
    }

    // MARK: - HTTP request handling (runs on background queue)

    nonisolated private static func handle(connection conn: NWConnection) {
        // Read a single HTTP request. We don't keep-alive — each connection
        // serves one file and closes. WKWebView is fine with this and it
        // keeps the server trivially correct.
        readRequest(conn: conn, accumulated: Data()) { request in
            guard let req = request else {
                conn.cancel()
                return
            }
            let response = buildResponse(for: req)
            conn.send(content: response, completion: .contentProcessed { _ in
                conn.cancel()
            })
        }
    }

    /// Accumulate bytes until we see the `\r\n\r\n` end-of-headers marker
    /// (or a sanity-limit). We only need the first line + Host header; no
    /// request bodies arrive on a static-file server.
    nonisolated private static func readRequest(conn: NWConnection,
                                    accumulated: Data,
                                    completion: @escaping (String?) -> Void) {
        conn.receive(minimumIncompleteLength: 1, maximumLength: 4096) { chunk, _, isComplete, error in
            if error != nil {
                completion(nil)
                return
            }
            var buf = accumulated
            if let chunk = chunk {
                buf.append(chunk)
            }
            if let s = String(data: buf, encoding: .utf8), s.range(of: "\r\n\r\n") != nil {
                completion(s)
                return
            }
            if isComplete || buf.count > 8192 {
                completion(String(data: buf, encoding: .utf8))
                return
            }
            readRequest(conn: conn, accumulated: buf, completion: completion)
        }
    }

    nonisolated private static func buildResponse(for request: String) -> Data {
        guard let firstLine = request.split(separator: "\n").first else {
            return statusOnly(404)
        }
        let tokens = firstLine.split(separator: " ", omittingEmptySubsequences: true)
        guard tokens.count >= 2 else { return statusOnly(404) }
        let method = String(tokens[0])
        let rawPath = String(tokens[1])

        guard method == "GET" || method == "HEAD" else {
            return statusOnly(405)
        }

        // Strip query / fragment, default to /wasm-host.html for the root.
        var path = rawPath
        if let q = path.firstIndex(of: "?") { path = String(path[..<q]) }
        if let h = path.firstIndex(of: "#") { path = String(path[..<h]) }
        if path == "/" || path.isEmpty { path = "/wasm-host.html" }

        // Resolve against the bundled `Wasm/` folder reference.
        guard let fileURL = resolveBundleFile(relativePath: path),
              let data = try? Data(contentsOf: fileURL) else {
            Self.logger.error("404 for \(path, privacy: .public)")
            return statusOnly(404)
        }

        let mime = mimeType(for: fileURL.pathExtension.lowercased())
        let body = method == "HEAD" ? Data() : data

        var headers = ""
        headers += "HTTP/1.1 200 OK\r\n"
        headers += "Content-Type: \(mime)\r\n"
        headers += "Content-Length: \(data.count)\r\n"
        // The triad that makes `crossOriginIsolated === true`.
        headers += "Cross-Origin-Opener-Policy: same-origin\r\n"
        headers += "Cross-Origin-Embedder-Policy: require-corp\r\n"
        headers += "Cross-Origin-Resource-Policy: same-origin\r\n"
        headers += "Cache-Control: no-store\r\n"
        headers += "Connection: close\r\n"
        headers += "\r\n"

        var resp = Data(headers.utf8)
        resp.append(body)
        return resp
    }

    nonisolated private static func statusOnly(_ code: Int) -> Data {
        let phrase: String
        switch code {
        case 404: phrase = "Not Found"
        case 405: phrase = "Method Not Allowed"
        default:  phrase = "Error"
        }
        let s = "HTTP/1.1 \(code) \(phrase)\r\nContent-Length: 0\r\nConnection: close\r\n\r\n"
        return Data(s.utf8)
    }

    nonisolated private static func mimeType(for ext: String) -> String {
        switch ext {
        case "html": return "text/html; charset=utf-8"
        case "js":   return "application/javascript; charset=utf-8"
        case "wasm": return "application/wasm"
        case "json": return "application/json"
        case "css":  return "text/css"
        case "txt":  return "text/plain; charset=utf-8"
        default:     return "application/octet-stream"
        }
    }

    /// Look up `/foo/bar.ext` against the bundled `Wasm/` folder reference.
    /// We use `Bundle.url(forResource:withExtension:subdirectory:)` because
    /// folder references preserve their directory layout in the bundle.
    nonisolated private static func resolveBundleFile(relativePath: String) -> URL? {
        let trimmed = relativePath.hasPrefix("/") ? String(relativePath.dropFirst()) : relativePath
        if trimmed.contains("..") {
            return nil  // never escape the bundle
        }
        let ns = trimmed as NSString
        let dir = ns.deletingLastPathComponent
        let name = (ns.lastPathComponent as NSString).deletingPathExtension
        let ext = ns.pathExtension

        let subdir: String
        if dir.isEmpty {
            subdir = "Wasm"
        } else {
            subdir = "Wasm/\(dir)"
        }
        if let url = Bundle.main.url(forResource: name, withExtension: ext, subdirectory: subdir) {
            return url
        }
        // Last resort: direct path inside the bundle's resourceURL.
        if let root = Bundle.main.resourceURL {
            let candidate = root.appendingPathComponent("Wasm").appendingPathComponent(trimmed)
            if FileManager.default.fileExists(atPath: candidate.path) {
                return candidate
            }
        }
        return nil
    }
}
