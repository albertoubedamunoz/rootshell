#if !targetEnvironment(macCatalyst)

import Foundation

/// Transfer phase for progress reporting and UI state.
enum CrocTransferPhase: Sendable, Equatable {
    case idle
    case connecting(host: String)
    case authenticating
    case waitingForPeer
    case pakeExchange
    case securingChannel
    case transferringFileInfo
    case waitingForAcceptance
    case transferringData(fileIndex: Int, totalFiles: Int, progress: Double)
    case verifying
    case completed(totalBytes: Int64, duration: TimeInterval)
    case failed(String)
    case cancelled

    var isTerminal: Bool {
        switch self {
        case .completed, .failed, .cancelled:
            return true
        default:
            return false
        }
    }

    var statusDescription: String {
        switch self {
        case .idle:
            return "Idle"
        case .connecting(let host):
            return "Connecting to \(host)..."
        case .authenticating:
            return "Authenticating with relay..."
        case .waitingForPeer:
            return "Waiting for peer..."
        case .pakeExchange:
            return "Securing connection..."
        case .securingChannel:
            return "Establishing encrypted channel..."
        case .transferringFileInfo:
            return "Exchanging file information..."
        case .waitingForAcceptance:
            return "Waiting for acceptance..."
        case .transferringData(let index, let total, let progress):
            let pct = Int(progress * 100)
            return "Transferring file \(index + 1)/\(total) (\(pct)%)..."
        case .verifying:
            return "Verifying..."
        case .completed(let bytes, let duration):
            let speed = duration > 0 ? CrocUtils.byteCountDecimal(Int64(Double(bytes) / duration)) + "/s" : ""
            return "Transfer complete (\(CrocUtils.byteCountDecimal(bytes)) in \(String(format: "%.1f", duration))s \(speed))"
        case .failed(let reason):
            return "Failed: \(reason)"
        case .cancelled:
            return "Cancelled"
        }
    }
}

#endif
