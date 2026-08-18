//
//  TSSHTransferReceiver.swift
//  rootshell
//
//  Coordinates the receiving side of a "Transfer to Nearby Device" flow.
//  Owns the NSUserActivity continuation streams, performs the X25519
//  exchange, deposits the decoded payload into TrzszTransferInbox, and
//  ack's success/failure back to the originating device once the new
//  TerminalView has called attachFromTransferPayload().
//

import Combine
import CryptoKit
import Foundation
import os.log
import UIKit

@MainActor
final class TrzszTransferReceiver {
    nonisolated private static let logger = Logger(
        subsystem: "com.kk2.rootshell",
        category: "TrzszTransferReceiver"
    )

    /// Lightweight description of an incoming offer, surfaced to the
    /// SwiftUI accept sheet so the user can decide whether to take it.
    struct Offer: Identifiable {
        let id = UUID()
        let activity: NSUserActivity
        let originDeviceName: String
        let displayName: String
        let host: String
        let originPubKey: Data

        init?(activity: NSUserActivity) {
            guard activity.activityType == TrzszTransferActivity.activityType else {
                return nil
            }
            guard activity.supportsContinuationStreams else {
                return nil
            }
            guard let info = activity.userInfo else { return nil }
            guard let version = info[TrzszTransferActivity.UserInfoKey.version] as? Int,
                  version == TrzszTransferActivity.payloadVersion else {
                return nil
            }
            guard let pub = info[TrzszTransferActivity.UserInfoKey.originPubKey] as? Data,
                  pub.count == 32 else {
                return nil
            }
            guard let originDeviceName = info[TrzszTransferActivity.UserInfoKey.originDeviceName] as? String,
                  let displayName = info[TrzszTransferActivity.UserInfoKey.displayName] as? String else {
                return nil
            }
            let host = info[TrzszTransferActivity.UserInfoKey.host] as? String ?? displayName
            self.activity = activity
            self.originDeviceName = originDeviceName
            self.displayName = displayName
            self.host = host
            self.originPubKey = pub
        }
    }

    enum Status: Equatable, Sendable {
        case idle
        case openingStreams
        case negotiating
        case awaitingAttach    // Payload decoded; waiting on TerminalView to finish attach
        case completed
        case failed(message: String)
        case cancelled
    }

    @Published private(set) var status: Status = .idle

    private let offer: Offer
    private let privateKey: Curve25519.KeyAgreement.PrivateKey
    private var channel: TrzszTransferChannel?
    private var pumpTask: Task<Void, Never>?
    private var pendingTicketID: UUID?

    /// Called once the receiver has decoded the payload and successfully
    /// deposited it into the inbox. The host (MainView) creates a new tab
    /// with `.trzszTransfer(ticketID, displayName, host)`. The TerminalView
    /// inside that tab consumes the inbox slot.
    private let onPayloadReady: @MainActor (UUID, TrzszTransferPayload) -> Void

    init(
        offer: Offer,
        onPayloadReady: @escaping @MainActor (UUID, TrzszTransferPayload) -> Void
    ) {
        self.offer = offer
        self.privateKey = TrzszTransferCrypto.generateEphemeralKeyPair()
        self.onPayloadReady = onPayloadReady
    }

    /// Begin the accept flow: open continuation streams against the
    /// activity Apple handed us, run the protocol, and on success deposit
    /// the payload into the inbox so the next tab pulls it.
    func accept(requestedCols: UInt16, requestedRows: UInt16) {
        guard status == .idle else { return }
        status = .openingStreams
        Self.logger.info("Accepting trzsz transfer offer from \(self.offer.originDeviceName, privacy: .public)")

        offer.activity.getContinuationStreams { [weak self] input, output, error in
            struct ContinuationResult: @unchecked Sendable {
                let input: InputStream?
                let output: OutputStream?
                let errorMessage: String?
            }
            let continuationResult = ContinuationResult(
                input: input,
                output: output,
                errorMessage: error?.trzszTransferDisplayDescription
            )
            Task { @MainActor [weak self] in
                guard let self else { return }
                if self.isTerminalStatus {
                    continuationResult.input?.close()
                    continuationResult.output?.close()
                    return
                }
                if let msg = continuationResult.errorMessage {
                    Self.logger.error("getContinuationStreams failed: \(msg, privacy: .public)")
                    self.status = .failed(message: msg)
                    return
                }
                guard let input = continuationResult.input,
                      let output = continuationResult.output else {
                    self.status = .failed(message: "No continuation streams")
                    return
                }
                self.driveProtocol(
                    input: input,
                    output: output,
                    cols: requestedCols,
                    rows: requestedRows
                )
            }
        }
    }

    /// User dismissed the offer sheet without accepting (or before attach
    /// completed). Closes any open streams.
    func cancel() {
        guard !isTerminalStatus else { return }
        Self.logger.info("Receiver cancelled trzsz transfer")
        if let ticketID = pendingTicketID {
            pendingTicketID = nil
            TrzszTransferInbox.shared.cancel(ticketID)
            return
        }
        pumpTask?.cancel()
        pumpTask = nil
        let channelToClose = self.channel
        self.channel = nil
        status = .cancelled
        if let channelToClose {
            Task.detached(priority: .userInitiated) {
                channelToClose.close()
            }
        }
    }

    var isTerminalStatus: Bool {
        switch status {
        case .completed, .failed, .cancelled:
            return true
        default:
            return false
        }
    }

    // MARK: - Protocol

    private func driveProtocol(
        input: InputStream,
        output: OutputStream,
        cols: UInt16,
        rows: UInt16
    ) {
        guard !isTerminalStatus else {
            input.close()
            output.close()
            return
        }
        let channel = TrzszTransferChannel(input: input, output: output)
        self.channel = channel
        status = .negotiating

        let privateKey = self.privateKey
        let originPubKey = offer.originPubKey
        let deviceName = TrzszTransferActivity.currentDeviceName()

        // The pump body MUST run off the main thread. With this project's
        // `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`, Task.detached closures
        // inherit MainActor isolation by default, so we route through a
        // `nonisolated` static helper to force the executor hop. The channel
        // is intentionally NOT closed here — deliverAck needs it alive to
        // ship the final ack frame back to the originator.
        let handleResult: @MainActor @Sendable (Result<TrzszTransferPayload, Error>) -> Void = { [weak self] result in
            guard let self else { return }
            switch result {
            case .success(let payload):
                self.handlePayloadReady(payload, channel: channel)
            case .failure(let error):
                self.failProtocol(error)
            }
        }

        pumpTask = Task.detached(priority: .userInitiated) {
            let result = await Self.runProtocolDetached(
                channel: channel,
                privateKey: privateKey,
                originPubKey: originPubKey,
                deviceName: deviceName,
                requestedCols: cols,
                requestedRows: rows
            )
            await handleResult(result)
        }
    }

    /// Off-main entry point for the wire protocol. Opens the channel and
    /// runs the handshake; leaves the channel open so deliverAck can ship
    /// the ack back to the originator.
    nonisolated private static func runProtocolDetached(
        channel: TrzszTransferChannel,
        privateKey: Curve25519.KeyAgreement.PrivateKey,
        originPubKey: Data,
        deviceName: String,
        requestedCols: UInt16,
        requestedRows: UInt16
    ) async -> Result<TrzszTransferPayload, Error> {
        channel.open()
        do {
            let payload = try await runProtocol(
                channel: channel,
                privateKey: privateKey,
                originPubKey: originPubKey,
                deviceName: deviceName,
                requestedCols: requestedCols,
                requestedRows: requestedRows
            )
            return .success(payload)
        } catch {
            channel.close()
            return .failure(error)
        }
    }

    nonisolated private static func runProtocol(
        channel: TrzszTransferChannel,
        privateKey: Curve25519.KeyAgreement.PrivateKey,
        originPubKey: Data,
        deviceName: String,
        requestedCols: UInt16,
        requestedRows: UInt16
    ) async throws -> TrzszTransferPayload {
        let hello = TrzszTransferHello(
            version: TrzszTransferActivity.payloadVersion,
            receiverPubKey: privateKey.publicKey.rawRepresentation,
            receiverDeviceName: deviceName,
            requestedCols: requestedCols,
            requestedRows: requestedRows
        )
        let helloFrame = try JSONEncoder().encode(hello)
        // Hello is tiny; the wait is for the stream pair to be usable.
        let helloDeadline = Date().addingTimeInterval(30)
        try channel.sendFrame(helloFrame, deadline: helloDeadline)

        // Bootstrap carries scrollback; allow 30s to receive even on
        // a slow Continuity link.
        let bootstrapDeadline = Date().addingTimeInterval(30)
        let bootstrapFrame = try channel.receiveFrame(deadline: bootstrapDeadline)
        let bootstrap = try JSONDecoder().decode(TrzszTransferBootstrap.self, from: bootstrapFrame)

        let key = try TrzszTransferCrypto.deriveSharedKey(
            privateKey: privateKey,
            peerPublicKeyRaw: originPubKey
        )
        let plaintext = try TrzszTransferCrypto.open(bootstrap.ciphertext, using: key)
        let payload = try JSONDecoder().decode(TrzszTransferPayload.self, from: plaintext)
        guard payload.version == TrzszTransferActivity.payloadVersion else {
            throw TrzszTransferError.versionMismatch(
                received: payload.version,
                expected: TrzszTransferActivity.payloadVersion
            )
        }
        return payload
    }

    private func handlePayloadReady(_ payload: TrzszTransferPayload, channel: TrzszTransferChannel) {
        guard !isTerminalStatus else {
            Task.detached(priority: .userInitiated) {
                channel.close()
            }
            return
        }
        status = .awaitingAttach
        Self.logger.info("Trzsz transfer payload decoded; depositing into inbox")

        let attemptedClientId = TrzszSession.transferAttachClientId(after: payload.credentials.clientId)
        let ticketID = TrzszTransferInbox.shared.deposit(payload: payload) { result in
            self.deliverAck(result, channel: channel, attemptedClientId: attemptedClientId)
        }
        pendingTicketID = ticketID

        onPayloadReady(ticketID, payload)
    }

    private func deliverAck(
        _ result: Result<Void, Error>,
        channel: TrzszTransferChannel,
        attemptedClientId: UInt64
    ) {
        let ack: TrzszTransferAck
        switch result {
        case .success:
            ack = TrzszTransferAck(success: true, errorMessage: nil, attemptedClientId: attemptedClientId)
            status = .completed
        case .failure(let error):
            let msg = error.trzszTransferDisplayDescription
            ack = TrzszTransferAck(success: false, errorMessage: msg, attemptedClientId: attemptedClientId)
            if let transferError = error as? TrzszTransferError,
               case .cancelled = transferError {
                status = .cancelled
            } else {
                status = .failed(message: msg)
            }
        }
        // Route through a nonisolated helper so the ack send + drain + close
        // run off the main thread regardless of the project's default
        // MainActor isolation.
        Task.detached(priority: .userInitiated) {
            await Self.sendAckAndDrain(channel: channel, ack: ack)
        }
        pendingTicketID = nil
        self.channel = nil
    }

    /// Encodes and sends the ack, then waits for the originator to close
    /// its side before tearing the channel down. Without the drain, closing
    /// the Continuity NSOutputStream right after writing the small ack frame
    /// can drop the buffered bytes and leave the originator's `receiveFrame`
    /// hanging until Apple's stream layer times out ~60 s later.
    nonisolated private static func sendAckAndDrain(
        channel: TrzszTransferChannel,
        ack: TrzszTransferAck
    ) async {
        do {
            let frame = try JSONEncoder().encode(ack)
            // Ack is tiny; 5s is plenty even on a slow link.
            let ackDeadline = Date().addingTimeInterval(5)
            try channel.sendFrame(frame, deadline: ackDeadline)
        } catch {
            Self.logger.error("Failed to send ack: \(error.localizedDescription, privacy: .public)")
        }
        channel.drainUntilRemoteClose()
        channel.close()
    }

    private func failProtocol(_ error: Error) {
        let msg = error.trzszTransferDisplayDescription
        Self.logger.error("Receiver protocol failed: \(msg, privacy: .public)")
        status = .failed(message: msg)
        pumpTask = nil
        let channelToClose = self.channel
        self.channel = nil
        if let channelToClose {
            Task.detached(priority: .userInitiated) {
                channelToClose.close()
            }
        }
    }
}
