import Foundation

/// A resizable auxiliary exec channel. Transport.NewSession is reserved for
/// the gateway's one main PTY and must never be used for projected panes.
actor HerdrTSSHPTYChannel: HerdrPTYChannel {
    private let transportRef: TSSHTransportRef
    private let channelRef: Int64
    private let pipe: TrzszExecPipe
    private var closed = false
    /// The server's id for this channel's session, recorded for cleanup.
    let remoteSessionID: UInt64?
    /// Fires on close; see `TrzszExecPipe.onRemoteSessionEnded`.
    func setRemoteSessionEndedHandler(_ handler: @escaping @Sendable (UInt64) -> Void) {
        pipe.onRemoteSessionEnded = handler
    }

    private init(transport: TSSHTransportRef, channelRef: Int64, remoteSessionID: UInt64?) {
        self.transportRef = transport
        self.channelRef = channelRef
        self.remoteSessionID = remoteSessionID
        self.pipe = TrzszExecPipe(
            channelRef: channelRef,
            transportRef: transport,
            remoteSessionID: remoteSessionID
        )
    }

    static func open(transport: TSSHTransportRef, command: String, term: String, cols: Int, rows: Int) async throws -> HerdrTSSHPTYChannel {
        let ref = try await TSSHCallGate.shared.openExecPTY(
            on: transport, command: command, term: term, rows: rows, cols: cols
        )
        let sessionID = await TSSHCallGate.shared.execSessionID(on: transport, channelRef: ref)
        let pipe = HerdrTSSHPTYChannel(
            transport: transport,
            channelRef: ref,
            remoteSessionID: sessionID > 0 ? UInt64(sessionID) : nil
        )
        guard !Task.isCancelled else {
            await pipe.close()
            throw CancellationError()
        }
        return pipe
    }

    func read(maxBytes: Int) async throws -> Data? {
        try await pipe.read(maxBytes: maxBytes)
    }

    func write(_ data: Data) async throws {
        guard !closed else { throw HerdrPTYError.closed }
        try await pipe.write(data)
    }

    func resize(cols: Int, rows: Int) async throws {
        guard !closed else { throw HerdrPTYError.closed }
        try await TSSHCallGate.shared.execResizePTY(
            on: transportRef, channelRef: channelRef, rows: rows, cols: cols
        )
    }

    func close() async {
        guard !closed else { return }
        closed = true
        await pipe.close()
    }
}
