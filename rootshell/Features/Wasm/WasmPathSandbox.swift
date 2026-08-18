import Foundation

/// Canonicalises paths coming from WASM against a sandbox root, refusing any
/// path that resolves outside the root. Pure value-type so it is trivial to
/// unit-test without a running runtime.
struct WasmPathSandbox: Sendable {
    enum Resolution: Equatable {
        case allowed(URL)
        case denied(reason: String)
    }

    /// The hard boundary. Anything resolving outside this is denied.
    let root: URL
    /// The working directory the WASM process was launched with. Used to
    /// resolve relative paths. Must itself be inside `root`.
    let cwd: URL

    init(root: URL, cwd: URL) {
        let normalisedRoot = Self.absoluteStandardised(root)
        let normalisedCwd = Self.absoluteStandardised(cwd)
        self.root = normalisedRoot
        self.cwd = normalisedCwd.path.hasPrefix(normalisedRoot.path)
            ? normalisedCwd
            : normalisedRoot
    }

    /// Resolve a raw path string from WASM. Treats leading `/` as relative to
    /// `root` (so WASM sees `/` as the sandbox root, not the device root).
    func resolve(_ raw: String) -> Resolution {
        guard !raw.isEmpty else {
            return .denied(reason: "empty path")
        }
        if raw.contains("\0") {
            return .denied(reason: "null byte in path")
        }

        let base: URL
        let trimmed: String
        if raw.hasPrefix("/") {
            base = root
            trimmed = String(raw.dropFirst())
        } else {
            base = cwd
            trimmed = raw
        }

        let combined = base.appendingPathComponent(trimmed)
        let standardised = Self.absoluteStandardised(combined)

        let rootPath = root.path
        let candidatePath = standardised.path

        guard candidatePath == rootPath || candidatePath.hasPrefix(rootPath + "/") else {
            return .denied(reason: "path escapes sandbox: \(candidatePath)")
        }

        return .allowed(standardised)
    }

    /// Returns the path as the WASM process should see it (with the sandbox
    /// root stripped, prefixed by `/`). Used when reporting resolved paths
    /// back via WASI calls like `fd_prestat_dir_name` or directory listings.
    func virtualPath(for resolved: URL) -> String? {
        let resolvedPath = Self.absoluteStandardised(resolved).path
        let rootPath = root.path
        guard resolvedPath == rootPath || resolvedPath.hasPrefix(rootPath + "/") else {
            return nil
        }
        if resolvedPath == rootPath { return "/" }
        return String(resolvedPath.dropFirst(rootPath.count))
    }

    /// Canonical form of a file URL. On iOS the app's Documents directory
    /// is at `/var/mobile/Containers/...`, which is a symlink to
    /// `/private/var/mobile/Containers/...`. `URL.resolvingSymlinksInPath`
    /// behaves inconsistently here (sometimes returns the un-prefixed
    /// form, sometimes the prefixed one depending on iOS version), and
    /// `NSString.standardizingPath` *does* resolve to the `/private/`
    /// form. Mismatched normalization gives a sandbox-escape false positive,
    /// so we force the `/private/` prefix explicitly here and use this
    /// helper from both the sandbox root setup AND the broker's per-call
    /// path resolution.
    static func canonical(_ url: URL) -> URL {
        let absolute = url.absoluteURL
        var path = (absolute.path as NSString).standardizingPath
        if !path.hasPrefix("/private/") {
            if path.hasPrefix("/var/") || path == "/var" ||
               path.hasPrefix("/tmp/") || path == "/tmp" ||
               path.hasPrefix("/etc/") || path == "/etc" {
                path = "/private" + path
            }
        }
        return URL(fileURLWithPath: path)
    }

    private static func absoluteStandardised(_ url: URL) -> URL {
        canonical(url)
    }
}
