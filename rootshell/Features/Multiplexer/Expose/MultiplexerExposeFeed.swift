//
//  MultiplexerExposeFeed.swift
//  rootshell
//
//  Keeps a raw multiplexer session's tabs and pane frames fresh while the
//  exposé is up, over one-shot exec commands on the pane's own connection
//  (RemoteExecProbe). Ticks are strictly serialized and adaptively paced:
//  fast while frames change, backing off when the session is quiet, with
//  visible panes fetched first and the rest on a slower cadence.
//

import Foundation
import GhosttyKit
import QuartzCore
import os

@MainActor
final class MultiplexerExposeFeed {
    enum State: Equatable {
        case idle
        /// No binding yet: working out which multiplexer a local pane is
        /// attached to (hand-started `tmux` / `herdr` / `zellij`).
        case detecting
        case loading
        case live
        /// The multiplexer is unusable here (too old, no session): show app tabs.
        case unsupported
        /// Ticks keep failing; the last frames stay up with a hint.
        case failed
    }

    private static let logger = Logger(subsystem: "com.rootshell", category: "MuxExpose")

    private(set) var state: State = .idle
    private(set) var snapshot: MuxExposeSnapshot?
    private(set) var type: MultiplexerType?
    private(set) var sessionName: String?
    /// Fired on state or topology changes (frames are polled by the views).
    var onChange: (() -> Void)?

    private(set) weak var terminal: Ghostty.TerminalView?
    var ghosttyApp: Ghostty.App? { terminal?.ghosttyApp }

    private var adapter: (any MultiplexerExposeAdapter)?
    private var frames: [String: MuxPaneFrame] = [:]
    private var loop: Task<Void, Never>?
    private var sleeper: Task<Void, Never>?
    private var stopTask: Task<Void, Never>?
    private var visiblePanes: Set<String> = []
    private var lastFetchAt: [String: CFTimeInterval] = [:]
    private var hints: [String: String] = [:]
    /// Bumped by every teardown; identifies the run that owns the feed.
    private var generation: UInt64 = 0
    private var tickCount = 0
    private var interval: TimeInterval = baseInterval
    private var failures = 0
    private var fetchCap = Int.max
    private var cleanTicks = 0
    /// Last presentation, reusable for an instant repaint on quick re-entry.
    private var cache: (owner: ObjectIdentifier, session: String, snapshot: MuxExposeSnapshot,
                        frames: [String: MuxPaneFrame], at: CFTimeInterval)?

    private static let baseInterval: TimeInterval = 0.4
    private static let maxInterval: TimeInterval = 2.5
    private static let hiddenPaneEveryNthTick = 3
    private static let staleAfter: CFTimeInterval = 2
    private static let cacheLifetime: CFTimeInterval = 60
    private static let maxPreviewPanesPerTab = 6
    private static let responseCap = 512 * 1024
    private static let tickTimeout: TimeInterval = 5
    /// Retries while another probe holds the transport's single slot.
    private static let focusAttempts = 12
    /// Consecutive failures before the tray says the session is unavailable.
    private static let failuresBeforeUnavailable = 3

    // MARK: - Identity

    var sessionKey: String { "\(type?.rawValue ?? "-"):\(sessionName ?? "")" }

    var tabs: [MuxTab] { snapshot?.tabs ?? [] }

    var tabUUIDs: [UUID] { tabs.map { $0.uuid(sessionKey: sessionKey) } }

    var activeTabUUID: UUID? {
        snapshot?.activeTabID.flatMap { id in snapshot?.tab(withID: id) }?.uuid(sessionKey: sessionKey)
    }

    func tab(uuid: UUID) -> MuxTab? {
        tabs.first { $0.uuid(sessionKey: sessionKey) == uuid }
    }

    func frame(for paneID: String) -> MuxPaneFrame? { frames[paneID] }

    var isServing: Bool { state == .loading || state == .live || state == .failed }

    /// Short name for the tray header.
    var title: String {
        let mux: String
        switch type {
        case .tmux: mux = "tmux"
        case .zellij: mux = "zellij"
        case .herdr: mux = "herdr"
        case nil: mux = ""
        }
        if let sessionName, !sessionName.isEmpty { return "\(mux) · \(sessionName)" }
        return mux
    }

    // MARK: - Eligibility

    /// The multiplexer this terminal is attached to, once it owns the screen.
    /// `hasOwnedAltScreen` is maintained by agent attention's scans, which
    /// may not have run yet; the surface's own alt-screen state stands in.
    static func binding(for terminal: Ghostty.TerminalView?) -> Ghostty.TerminalView.RawMultiplexerBinding? {
        guard let terminal, let binding = terminal.rawMultiplexer, RemoteExecProbe.canProbe(terminal),
              binding.hasOwnedAltScreen || isAlternateScreenActive(terminal) else { return nil }
        return binding
    }

    /// A pane with no binding whose screen is taken by something: ask the
    /// host what is running there. The alternate screen is the gate — every
    /// multiplexer holds it for its whole attach — so an ordinary shell is
    /// never probed just because the exposé opened.
    static func canDetect(_ terminal: Ghostty.TerminalView) -> Bool {
        RemoteExecProbe.canProbe(terminal) && isAlternateScreenActive(terminal)
    }

    private static func isAlternateScreenActive(_ terminal: Ghostty.TerminalView) -> Bool {
        guard let surface = terminal.surface else { return false }
        var altActive = false
        guard ghostty_surface_try_is_alternate_active(surface, &altActive) else { return false }
        return altActive
    }

    /// `ttys004` for a local macOS pane; nil for anything remote.
    private static func localTTY(_ terminal: Ghostty.TerminalView) -> String? {
        #if targetEnvironment(macCatalyst)
        guard terminal.connectionConfig.underlyingSSHConfig == nil,
              let path = terminal.session?.pty.slavePath, path.hasPrefix("/dev/") else { return nil }
        return String(path.dropFirst("/dev/".count))
        #else
        return nil
        #endif
    }

    // MARK: - Lifecycle

    /// Begin (or resume) serving `terminal`'s session. Returns false when the
    /// terminal has no usable multiplexer binding and nothing to detect.
    @discardableResult
    func start(terminal: Ghostty.TerminalView) -> Bool {
        let binding = Self.binding(for: terminal)
        guard binding != nil || Self.canDetect(terminal) else {
            Self.logger.debug("not a multiplexer pane: bound=\(terminal.rawMultiplexer != nil) probe=\(RemoteExecProbe.canProbe(terminal)) alt=\(Self.isAlternateScreenActive(terminal))")
            return false
        }
        Self.logger.debug("start: \(binding?.type.rawValue ?? "detect", privacy: .public)")
        stopTask?.cancel()
        stopTask = nil
        if loop != nil, self.terminal === terminal,
           binding == nil || (type == binding?.type && sessionName == binding?.sessionName) {
            // Re-opened inside the stop grace: the running feed still serves
            // this session, so its tabs and frames are already current.
            Self.logger.debug("reusing live feed: \(self.tabs.count) tabs, \(self.frames.count) frames")
            return true
        }
        teardownLoop()

        self.terminal = terminal
        resetSession()
        if let binding {
            configure(binding)
        } else {
            type = nil
            sessionName = nil
            adapter = nil
            state = .detecting
        }
        onChange?()
        let generation = self.generation
        loop = Task { [weak self] in await self?.run(generation: generation) }
        return true
    }

    private func resetSession() {
        frames = [:]
        snapshot = nil
        hints = [:]
        lastHints = [:]
        lastFetchAt = [:]
        // Pane ids are the previous session's; the tray reports afresh.
        visiblePanes = []
        tickCount = 0
        failures = 0
        fetchCap = Int.max
        cleanTicks = 0
        interval = Self.baseInterval
    }

    private func configure(_ binding: Ghostty.TerminalView.RawMultiplexerBinding) {
        type = binding.type
        sessionName = binding.sessionName
        switch binding.type {
        case .herdr: adapter = HerdrExposeAdapter()
        case .tmux: adapter = TmuxExposeAdapter()
        case .zellij: adapter = ZellijExposeAdapter()
        }
        // Quick re-entry: repaint the last picture while the first tick runs.
        if let terminal, let cache, cache.owner == ObjectIdentifier(terminal),
           cache.session == "\(binding.type.rawValue):\(binding.sessionName ?? "")",
           CACurrentMediaTime() - cache.at < Self.cacheLifetime {
            snapshot = cache.snapshot
            frames = cache.frames
            state = .live
        } else {
            state = .loading
        }
    }

    /// Stop after `grace` seconds unless restarted; the picture is cached.
    func stop(grace: TimeInterval) {
        guard loop != nil else { return }
        stopTask?.cancel()
        stopTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(grace))
            guard !Task.isCancelled else { return }
            self?.stopNow()
        }
    }

    func stopNow() {
        stopTask?.cancel()
        stopTask = nil
        if let terminal, let snapshot, let type {
            cache = (ObjectIdentifier(terminal), "\(type.rawValue):\(sessionName ?? "")", snapshot, frames, CACurrentMediaTime())
        }
        teardownLoop()
        state = .idle
        snapshot = nil
        frames = [:]
        onChange?()
    }

    private func teardownLoop() {
        // Invalidates any work already in flight for the previous run.
        generation &+= 1
        loop?.cancel()
        loop = nil
        sleeper?.cancel()
        sleeper = nil
    }

    /// Panes on screen right now; they are fetched first and every tick.
    func setVisiblePanes(_ ids: Set<String>) {
        guard ids != visiblePanes else { return }
        let newcomers = ids.subtracting(visiblePanes)
        visiblePanes = ids
        // A cell that scrolled in with no picture yet should not wait a whole interval.
        if newcomers.contains(where: { frames[$0] == nil }) { wake() }
    }

    /// Switch the multiplexer to `tabID`. Independent of the tick loop so it
    /// still runs while the exposé is already dismissing.
    func focus(tabID: String) {
        guard let terminal, let adapter else { return }
        let script = adapter.focusScript(session: sessionName, tabID: tabID)
        Task { [weak self] in
            for attempt in 0..<Self.focusAttempts {
                do {
                    _ = try await RemoteExecProbe.run(script, on: terminal, timeout: 4, maxResponseBytes: 4096)
                    self?.wake()
                    return
                } catch RemoteExecProbe.ProbeError.busy {
                    // tssh: one probe at a time; the tick in flight is short.
                    try? await Task.sleep(for: .milliseconds(250))
                    if attempt == Self.focusAttempts - 1 { Self.logger.warning("focus abandoned: transport busy") }
                } catch {
                    Self.logger.warning("focus failed: \(error.localizedDescription)")
                    return
                }
            }
        }
    }

    private func wake() {
        sleeper?.cancel()
    }

    // MARK: - Loop

    /// Work started by a superseded run must never touch the feed again: its
    /// answers describe a session this feed no longer serves, and its
    /// teardown would stop the run that replaced it. Every await in the loop
    /// is followed by this check before anything shared is read or written.
    private func isCurrent(_ generation: UInt64) -> Bool {
        generation == self.generation && !Task.isCancelled
    }

    private func giveUp(_ reason: String) {
        Self.logger.debug("\(reason, privacy: .public)")
        state = .unsupported
        loop = nil
        onChange?()
    }

    private func run(generation: UInt64) async {
        if adapter == nil {
            let detected = await detect()
            guard isCurrent(generation) else {
                Self.logger.debug("detect superseded by a newer run")
                return
            }
            guard let detected else {
                giveUp("detect: nothing attached on this tty")
                return
            }
            Self.logger.debug("detected \(detected.type.rawValue, privacy: .public), session named=\(detected.sessionName != nil)")
            configure(detected)
            onChange?()
        }
        if sessionName == nil {
            let resolved = await resolveSession()
            guard isCurrent(generation) else { return }
            guard let resolved else {
                giveUp("resolveSession: no single session")
                return
            }
            sessionName = resolved
            onChange?()
        }
        while true {
            let outcome = await tick(generation: generation)
            guard isCurrent(generation) else { return }
            switch outcome {
            case .cancelled:
                return
            case .unsupported:
                giveUp("tick: session no longer usable")
                return
            case .immediate:
                continue
            case .wait(let seconds):
                let sleeper = Task<Void, Never> { try? await Task.sleep(for: .seconds(seconds)) }
                self.sleeper = sleeper
                await sleeper.value
                guard isCurrent(generation) else { return }
            }
        }
    }

    /// Which multiplexer is attached in this pane, and to which session.
    ///
    /// A pane the app did not start has no binding to read, so the host is
    /// asked. Locally the pane's own tty names the process directly. Over a
    /// connection there is no tty to name, so candidates are found by
    /// command and narrowed by ancestry: this exec channel and the pane's
    /// shell descend from the same sshd/tsshd, exactly as the project probe
    /// identifies a pane's process. (id=mux-expose-detect)
    private func detect() async -> Ghostty.TerminalView.RawMultiplexerBinding? {
        guard let terminal else { return nil }
        let tty = Self.localTTY(terminal)
        let nonce = Self.nonce()
        // Candidate multiplexer clients: on this tty locally, ours anywhere
        // otherwise. `grep` only narrows; the command name is checked here.
        let candidates = tty.map { "ps -t \(MuxScript.dq($0)) -o pid=,ppid=,tty=,args= 2>/dev/null" }
            ?? "ps -xo pid=,ppid=,tty=,args= 2>/dev/null | grep -E \"tmux|herdr|zellij\" | grep -v grep"
        let candidatePIDs = "$(\(candidates) | awk \"{print \\$1}\")"
        // Ancestor walks, so a candidate can be tied to THIS connection.
        let walk = "_q=$1; while [ -n \"$_q\" ] && [ \"$_q\" -gt 1 ] 2>/dev/null;"
            + " do echo \"$_q\"; _q=$(ps -o ppid= -p \"$_q\" 2>/dev/null | tr -d \" \"); done"

        var body = "_walk() { \(walk); }"
        body += "; echo \(MuxScript.dq(MuxScript.topology(nonce)))"
        body += "; \(candidates)"
        body += "; echo \"::MX_SELF::\"; _walk $$"
        body += "; echo \"::MX_CHAINS::\"; for _p in \(candidatePIDs); do echo \"::MX_PID:$_p::\"; _walk \"$_p\"; done"
        body += "; echo \"::MX_CLIENTS::\""
        body += "; tmux list-clients -F \"#{client_tty}\(TmuxExposeAdapter.separator)#{session_name}\" 2>/dev/null"
        // A name is often absent from argv: `zellij` alone joins a
        // server-named session and herdr's default is implicit. The client
        // holds its session's socket open, which names it. Two ways to read
        // that: `lsof` (macOS), and /proc — where a connected client socket
        // has no path of its own, so its inode is matched in /proc/net/unix.
        // Linux servers routinely lack lsof, and a client socket there
        // usually has no name in it even when installed.
        body += "; echo \"::MX_SOCKETS::\"; for _p in \(candidatePIDs); do"
        body += " echo \"::MX_PID:$_p::\"; lsof -a -p \"$_p\" -U -F n 2>/dev/null;"
        body += " if [ -d \"/proc/$_p/fd\" ]; then"
        body += " for _i in $(ls -l \"/proc/$_p/fd\" 2>/dev/null"
        body += " | sed -n \"s/.*socket:\\[\\([0-9][0-9]*\\)\\].*/\\1/p\"); do"
        body += " awk -v i=\"$_i\" \"\\$7==i && \\$8 ~ /^\\// {print \\$8}\" /proc/net/unix 2>/dev/null;"
        body += " done; fi; done"
        // Exported by the user's own shell where it was used (`HERDR_SESSION=x herdr`).
        body += "; echo \"::MX_ENV::\"; for _p in \(candidatePIDs); do echo \"::MX_PID:$_p::\";"
        body += " [ -r \"/proc/$_p/environ\" ] && tr \"\\0\" \"\\n\" < \"/proc/$_p/environ\" 2>/dev/null"
        body += " | grep -E \"^(HERDR_SESSION|HERDR_SOCKET_PATH|ZELLIJ_SESSION_NAME)=\"; done"
        // zellij's server runs as `zellij --server <sock dir>/<session>`.
        body += "; echo \"::MX_SERVERS::\"; ps -xo pid=,ppid=,args= 2>/dev/null | grep -- \"--server\" | grep -v grep"

        guard let output = try? await RemoteExecProbe.run(
            MuxScript.wrap(body, nonce: nonce), on: terminal,
            timeout: Self.tickTimeout, maxResponseBytes: 64 * 1024
        ) else {
            Self.logger.debug("detect: probe failed")
            return nil
        }
        let parts = ["::MX_SELF::", "::MX_CHAINS::", "::MX_CLIENTS::", "::MX_SOCKETS::", "::MX_ENV::", "::MX_SERVERS::"]
            .reduce([MuxScript.sections(of: output, nonce: nonce).topology]) { sections, marker in
                sections.flatMap { $0.components(separatedBy: marker) }
            }
        guard parts.count >= 7 else {
            Self.logger.debug("detect: unexpected reply, \(output.count) bytes")
            return nil
        }
        let ownChain = Set(parts[1].split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) })
        let chains = Self.pidSections(parts[2]).mapValues { Set($0) }
        let clients = parts[3]
        let sockets = Self.pidSections(parts[4])
        let environments = Self.pidSections(parts[5]).mapValues { Self.environment($0) }
        let servers = parts[6]

        var found: [(binding: Ghostty.TerminalView.RawMultiplexerBinding, pid: String, tty: String)] = []
        for line in parts[0].split(separator: "\n") {
            var words = line.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
            guard words.count >= 4 else { continue }
            let pid = words.removeFirst()
            words.removeFirst()                       // ppid
            let processTTY = words.removeFirst()
            guard let command = words.first?.split(separator: "/").last.map(String.init) else { continue }
            func value(after flags: [String]) -> String? {
                for (index, word) in words.enumerated() where flags.contains(word) && index + 1 < words.count {
                    return words[index + 1]
                }
                return nil
            }
            let binding: Ghostty.TerminalView.RawMultiplexerBinding
            // A multiplexer's own server process carries the same binary
            // name as its client and is a descendant of the client that
            // spawned it, so it would otherwise pass every test below and
            // double the candidates for a single session.
            if words.contains("--server") || words.dropFirst().first == "server" { continue }

            switch command {
            case "tmux":
                // Control mode is the app's own projection, not a raw attach.
                if words.contains("-CC") { continue }
                let wanted = "/dev/\(tty ?? processTTY)"
                let session = clients.split(separator: "\n").lazy
                    .map { $0.components(separatedBy: TmuxExposeAdapter.separator) }
                    .first { $0.count == 2 && ($0[0] == wanted || $0[0].hasSuffix("/\(processTTY)")) }?[1]
                binding = .init(type: .tmux, sessionName: session, hasOwnedAltScreen: true)
            case "herdr":
                let environment = environments[pid] ?? [:]
                var session = value(after: ["--session", "-s"])
                if session == nil, let index = words.firstIndex(of: "attach"), index > 0, index + 1 < words.count,
                   words[index - 1] == "session" {
                    session = words[index + 1]
                }
                session = session ?? environment["HERDR_SESSION"]
                    ?? Self.herdrSession(in: sockets[pid] ?? [])
                    ?? environment["HERDR_SOCKET_PATH"].flatMap { Self.herdrSession(in: [$0]) }
                binding = .init(type: .herdr, sessionName: session ?? "default", hasOwnedAltScreen: true)
            case "zellij":
                var session = value(after: ["--session", "-s"])
                if session == nil, let index = words.firstIndex(where: { $0 == "attach" || $0 == "a" }),
                   index + 1 < words.count, !words[index + 1].hasPrefix("-") {
                    session = words[index + 1]
                }
                session = session ?? (environments[pid] ?? [:])["ZELLIJ_SESSION_NAME"]
                    ?? Self.zellijSession(in: sockets[pid] ?? [])
                    ?? Self.zellijSession(servers: servers, clientPID: pid)
                binding = .init(type: .zellij, sessionName: session, hasOwnedAltScreen: true)
            default:
                continue
            }
            found.append((binding, pid, processTTY))
        }
        guard !found.isEmpty else { return nil }
        // On the pane's own tty there is nothing to disambiguate, and a lone
        // client on the host is the one this pane is attached to.
        if tty != nil || found.count == 1 { return found[0].binding }
        // Otherwise keep only what shares this connection's sshd, and give up
        // unless exactly one does: showing another session's tabs, or focusing
        // one, is worse than falling back to the app tabs.
        let related = found.filter { !(chains[$0.pid] ?? []).intersection(ownChain).isEmpty }
        guard related.count == 1 else {
            Self.logger.debug("detect: \(found.count) candidates, \(related.count) on this connection; not guessing")
            return nil
        }
        return related[0].binding
    }

    /// Lines grouped by the `::MX_PID:<pid>::` markers the script emits.
    /// `lsof -F` prefixes paths with `n`, which is stripped here.
    private static func pidSections(_ text: String) -> [String: [String]] {
        var result: [String: [String]] = [:]
        var pid: String?
        for line in text.split(separator: "\n") {
            if line.hasPrefix("::MX_PID:"), line.hasSuffix("::") {
                pid = String(line.dropFirst("::MX_PID:".count).dropLast(2))
            } else if let pid {
                let value = line.hasPrefix("n") ? String(line.dropFirst()) : String(line)
                let trimmed = value.trimmingCharacters(in: .whitespaces)
                if !trimmed.isEmpty { result[pid, default: []].append(trimmed) }
            }
        }
        return result
    }

    /// `NAME=value` lines into a dictionary; a value may contain `=`.
    private static func environment(_ lines: [String]) -> [String: String] {
        var result: [String: String] = [:]
        for line in lines {
            guard let split = line.firstIndex(of: "="), split > line.startIndex else { continue }
            let value = String(line[line.index(after: split)...])
            guard !value.isEmpty else { continue }
            result[String(line[..<split])] = value
        }
        return result
    }

    /// zellij's client socket is `<sock dir>/<session name>`.
    private static func zellijSession(in paths: [String]) -> String? {
        for path in paths where path.contains("zellij") {
            let name = (path as NSString).lastPathComponent
            guard !name.isEmpty, name != "web_server_bus", !name.hasPrefix("zellij") else { continue }
            return name
        }
        return nil
    }

    /// zellij's server is `zellij --server <sock dir>/<session name>`, and
    /// the client that created a session is its parent. With one server there
    /// is no ambiguity; with several, only the client's own child answers
    /// (attaching by name already carries the name in argv).
    private static func zellijSession(servers: String, clientPID: String) -> String? {
        var names: [(ppid: String, name: String)] = []
        for line in servers.split(separator: "\n") {
            let words = line.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
            guard words.count >= 4, words.contains("--server"),
                  let index = words.firstIndex(of: "--server"), index + 1 < words.count,
                  words[2].split(separator: "/").last.map(String.init)?.hasPrefix("zellij") == true else { continue }
            let path = words[index + 1]
            let name = (path as NSString).lastPathComponent
            guard !name.isEmpty else { continue }
            names.append((words[1], name))
        }
        if let own = names.first(where: { $0.ppid == clientPID }) { return own.name }
        return names.count == 1 ? names[0].name : nil
    }

    /// herdr's client socket is `<config>/herdr-client.sock` for the default
    /// session and `<config>/sessions/<name>/herdr-client.sock` for a named one.
    private static func herdrSession(in paths: [String]) -> String? {
        for path in paths where (path as NSString).lastPathComponent.hasPrefix("herdr") {
            let directory = (path as NSString).deletingLastPathComponent
            let parent = ((directory as NSString).deletingLastPathComponent as NSString).lastPathComponent
            if parent == "sessions" {
                return (directory as NSString).lastPathComponent
            }
            return "default"
        }
        return nil
    }

    /// The session name when the host runs exactly one; nil leaves the feed
    /// unusable rather than guessing (the caller applies the result).
    private func resolveSession() async -> String? {
        guard let terminal, let adapter else { return nil }
        let nonce = Self.nonce()
        guard let output = try? await RemoteExecProbe.run(
            adapter.resolveSessionScript(nonce: nonce), on: terminal, timeout: Self.tickTimeout, maxResponseBytes: 16 * 1024
        ) else { return nil }
        let names = MuxScript.sections(of: output, nonce: nonce).topology
            .split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        guard names.count == 1 else { return nil }
        return names[0]
    }

    private enum Outcome {
        /// This run was superseded while awaiting: touch nothing, just stop.
        case cancelled
        case unsupported
        case immediate
        case wait(TimeInterval)
    }

    private func tick(generation: UInt64) async -> Outcome {
        guard let terminal, let adapter else { return .unsupported }
        let now = CACurrentMediaTime()
        let request = MuxTickRequest(fetch: fetchList(now: now), knownRevisions: frames.mapValues(\.revision))
        let nonce = Self.nonce()
        let script = adapter.tickScript(session: sessionName, request: request, nonce: nonce)
        let output: String
        do {
            output = try await RemoteExecProbe.run(script, on: terminal, timeout: Self.tickTimeout, maxResponseBytes: Self.responseCap)
        } catch RemoteExecProbe.ProbeError.busy {
            return isCurrent(generation) ? .wait(0.3) : .cancelled
        } catch {
            guard isCurrent(generation) else { return .cancelled }
            return failed("tick: \(error.localizedDescription)")
        }
        // The reply describes the session this run was started for; a newer
        // run may already own the feed's frames and snapshot.
        guard isCurrent(generation) else { return .cancelled }
        guard let result = adapter.parseTick(output: output, nonce: nonce) else {
            // Only the prelude's own verdict is final. Anything else (a
            // half-written reply, a momentarily unavailable server) is a
            // transient failure worth retrying, and never throws away a
            // session that has already been serving.
            if MuxScript.sections(of: output, nonce: nonce).unsupported {
                Self.logger.debug("multiplexer reports unsupported")
                return .unsupported
            }
            Self.logger.debug("tick: unparseable reply, \(output.count) bytes")
            if snapshot == nil, failures >= 2 { return .unsupported }
            return failed("tick: unparseable")
        }
        tickCount += 1
        if tickCount == 1 {
            Self.logger.debug("first tick: \(result.snapshot.tabs.count) tabs, \(result.snapshot.allPanes.count) panes")
        }
        failures = 0
        hints.merge(result.changeHints) { _, new in new }
        let fetched = Set(request.fetch)

        var changed = false
        for (id, frame) in result.frames {
            // A capture of nothing at all is a failed read, not a blank
            // screen (a cleared pane still returns its rows). Keeping the
            // last picture beats painting an empty one that then sticks,
            // since an unchanged revision would never be redrawn.
            guard !frame.ansi.isEmpty else {
                Self.logger.debug("empty capture for pane \(id); keeping last frame")
                continue
            }
            if frames[id]?.revision != frame.revision { changed = true }
            frames[id] = frame
        }
        for id in fetched { lastFetchAt[id] = now }
        // Panes that vanished take their frames with them.
        let live = Set(result.snapshot.allPanes.map(\.id))
        frames = frames.filter { live.contains($0.key) }

        let topologyChanged = result.snapshot != snapshot
        snapshot = result.snapshot
        let wasLoading = state != .live
        state = .live
        if topologyChanged || wasLoading { onChange?() }

        if result.truncated {
            fetchCap = max(1, min(fetchCap, max(request.fetch.count, 2)) / 2)
            cleanTicks = 0
            Self.logger.debug("reply truncated at \(Self.responseCap) bytes; fetching \(self.fetchCap) panes per tick")
        } else {
            cleanTicks += 1
            if cleanTicks >= 5, fetchCap != Int.max {
                fetchCap = fetchCap >= (Int.max / 2) ? Int.max : fetchCap * 2
                cleanTicks = 0
            }
        }

        // First topology lands with no frames: fetch the visible set right away.
        if tickCount == 1 { return .immediate }
        if changed {
            interval = Self.baseInterval
        } else {
            interval = min(interval * 1.5, Self.maxInterval)
        }
        return .wait(interval)
    }

    private func failed(_ message: String) -> Outcome {
        failures += 1
        Self.logger.debug("\(message, privacy: .public) (failure \(self.failures))")
        if failures >= Self.failuresBeforeUnavailable, state != .failed {
            state = .failed
            // The tray now says the session is unavailable: worth one line.
            Self.logger.warning("multiplexer session stopped answering after \(self.failures) attempts")
            onChange?()
        }
        return .wait(min(pow(2, Double(failures - 1)), 10))
    }

    /// Panes to capture this tick, active tab first, then visible, then the rest.
    private func fetchList(now: CFTimeInterval) -> [String] {
        guard let snapshot else { return [] }
        var ordered: [(String, Int)] = []
        for tab in snapshot.tabs {
            // Over the cap only the active pane gets a picture.
            var budget = Self.maxPreviewPanesPerTab
            for pane in tab.panes where pane.isPreviewable {
                if budget <= 0, !pane.isActive { continue }
                budget -= 1
                let visible = visiblePanes.contains(pane.id)
                let rank = tab.id == snapshot.activeTabID ? 0 : (visible ? 1 : 2)
                ordered.append((pane.id, rank))
            }
        }
        var fetch: [String] = []
        for (id, rank) in ordered.sorted(by: { $0.1 < $1.1 }) {
            guard let last = lastFetchAt[id], frames[id] != nil else {
                fetch.append(id)
                continue
            }
            let hintChanged = hints[id] != nil && hints[id] != lastHints[id]
            let stale = now - last >= Self.staleAfter
            if rank < 2 {
                if hintChanged || stale || hints[id] == nil { fetch.append(id) }
            } else if hintChanged || (stale && tickCount % Self.hiddenPaneEveryNthTick == 0) {
                fetch.append(id)
            }
        }
        for id in fetch { lastHints[id] = hints[id] }
        if fetch.count > fetchCap { fetch.removeLast(fetch.count - fetchCap) }
        return fetch
    }

    /// Hint value each pane was last fetched under.
    private var lastHints: [String: String] = [:]

    private static func nonce() -> String {
        String(UInt64.random(in: 0...UInt64.max), radix: 36)
    }
}
