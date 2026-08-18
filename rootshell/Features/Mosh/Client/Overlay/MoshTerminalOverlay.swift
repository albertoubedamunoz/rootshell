//
//  MoshTerminalOverlay.swift
//  rootshell
//

import Foundation
import Darwin

enum MoshOverlayValidity {
    case pending
    case correct
    case correctNoCredit
    case incorrectOrExpired
    case inactive
}

/// Colors for Mosh overlay rendering, derived from terminal theme
struct MoshOverlayColors: Sendable {
    let foregroundColor: UInt32  // True color value
    let backgroundColor: UInt32  // True color value

    /// Default colors (white on blue) - matches traditional mosh
    static let `default` = MoshOverlayColors(
        foregroundColor: VTRenditions.makeTrueColor(220, 225, 240),
        backgroundColor: VTRenditions.makeTrueColor(50, 80, 140)
    )

    /// Creates overlay colors appropriate for theme (MainActor required)
    @MainActor
    static func fromTheme() -> MoshOverlayColors {
        let isLight = ThemeManager.shared.currentThemeInfo?.isLight ?? false

        if isLight {
            // Light theme: dark text on light blue background
            return MoshOverlayColors(
                foregroundColor: VTRenditions.makeTrueColor(30, 40, 70),
                backgroundColor: VTRenditions.makeTrueColor(200, 220, 255)
            )
        } else {
            // Dark theme: light text on darker blue background
            return MoshOverlayColors(
                foregroundColor: VTRenditions.makeTrueColor(220, 225, 240),
                backgroundColor: VTRenditions.makeTrueColor(50, 80, 140)
            )
        }
    }
}

class MoshConditionalOverlay {
    var expirationFrame: UInt64
    var col: Int
    var active: Bool
    var tentativeUntilEpoch: UInt64
    var predictionTime: UInt64

    init(expirationFrame: UInt64, col: Int, tentative: UInt64) {
        self.expirationFrame = expirationFrame
        self.col = col
        self.active = false
        self.tentativeUntilEpoch = tentative
        self.predictionTime = UInt64.max
    }

    func tentative(_ confirmedEpoch: UInt64) -> Bool {
        tentativeUntilEpoch > confirmedEpoch
    }

    func resetActivationState() {
        expirationFrame = UInt64.max
        tentativeUntilEpoch = UInt64.max
        active = false
    }

    func reset() {
        resetActivationState()
    }

    func expire(_ exp: UInt64, now: UInt64) {
        expirationFrame = exp
        predictionTime = now
    }
}

final class MoshConditionalCursorMove: MoshConditionalOverlay {
    var row: Int

    init(expirationFrame: UInt64, row: Int, col: Int, tentative: UInt64) {
        self.row = row
        super.init(expirationFrame: expirationFrame, col: col, tentative: tentative)
    }

    func apply(_ fb: VTFramebuffer, confirmedEpoch: UInt64) {
        if !active { return }
        if tentative(confirmedEpoch) { return }
        if row >= fb.cursorState.getHeight() || col >= fb.cursorState.getWidth() { return }
        if fb.cursorState.originMode { return }
        fb.cursorState.moveRow(row, relative: false)
        fb.cursorState.moveCol(col, relative: false)
    }

    func getValidity(_ fb: VTFramebuffer, earlyAck: UInt64, lateAck: UInt64) -> MoshOverlayValidity {
        if !active { return .inactive }
        if row >= fb.cursorState.getHeight() || col >= fb.cursorState.getWidth() { return .incorrectOrExpired }
        if lateAck >= expirationFrame {
            if fb.cursorState.getCursorCol() == col && fb.cursorState.getCursorRow() == row {
                return .correct
            }
            return .incorrectOrExpired
        }
        return .pending
    }
}

final class MoshConditionalOverlayCell: MoshConditionalOverlay {
    var replacement: VTCell
    var unknown: Bool
    var originalContents: [VTCell]

    override init(expirationFrame: UInt64, col: Int, tentative: UInt64) {
        self.replacement = VTCell(backgroundColor: 0)
        self.unknown = false
        self.originalContents = []
        super.init(expirationFrame: expirationFrame, col: col, tentative: tentative)
    }

    func apply(_ fb: VTFramebuffer, confirmedEpoch: UInt64, row: Int, flag: Bool) {
        if !active { return }
        if row >= fb.cursorState.getHeight() || col >= fb.cursorState.getWidth() { return }
        if tentative(confirmedEpoch) { return }

        var flag = flag
        if replacement.isBlank() && fb.getCell(row: row, col: col).isBlank() {
            flag = false
        }

        if unknown {
            if flag && col != fb.cursorState.getWidth() - 1 {
                var cell = fb.getMutableCell(row: row, col: col)
                var renditions = cell.getRenditions()
                renditions.setAttribute(.underlined, true)
                cell.setRenditions(renditions)
                fb.setMutableCell(cell, row: row, col: col)
            }
            return
        }

        if fb.getCell(row: row, col: col) != replacement {
            var cell = replacement
            if flag {
                var renditions = cell.getRenditions()
                renditions.setAttribute(.underlined, true)
                cell.setRenditions(renditions)
            }
            fb.setMutableCell(cell, row: row, col: col)
        }
    }

    func getValidity(_ fb: VTFramebuffer, row: Int, earlyAck: UInt64, lateAck: UInt64) -> MoshOverlayValidity {
        if !active { return .inactive }
        if row >= fb.cursorState.getHeight() || col >= fb.cursorState.getWidth() { return .incorrectOrExpired }
        let current = fb.getCell(row: row, col: col)
        if lateAck < expirationFrame { return .pending }
        if unknown { return .correctNoCredit }
        if replacement.isBlank() { return .correctNoCredit }
        if current.hasSameVisualContent(as: replacement) {
            for orig in originalContents {
                if orig.hasSameVisualContent(as: replacement) {
                    return .correctNoCredit
                }
            }
            return .correct
        }
        return .incorrectOrExpired
    }

    func resetWithOrig() {
        if !active || unknown {
            reset()
            return
        }
        originalContents.append(replacement)
        // Deactivate without clearing originalContents — calling self.reset()
        // would wipe the entry we just appended.
        resetActivationState()
    }

    override func reset() {
        unknown = false
        originalContents.removeAll(keepingCapacity: true)
        super.reset()
    }
}

final class MoshConditionalOverlayRow {
    let rowNum: Int
    var overlayCells: [MoshConditionalOverlayCell]

    init(rowNum: Int) {
        self.rowNum = rowNum
        self.overlayCells = []
    }

    func apply(_ fb: VTFramebuffer, confirmedEpoch: UInt64, flag: Bool) {
        for cell in overlayCells {
            cell.apply(fb, confirmedEpoch: confirmedEpoch, row: rowNum, flag: flag)
        }
    }
}

final class MoshNotificationEngine {
    private var lastWordFromServer: UInt64
    private var lastAckedState: UInt64
    private var escapeKeyString: String
    private var message: String
    private var messageIsNetworkError: Bool
    private var messageExpiration: UInt64
    private var showQuitKeystroke: Bool
    private var holePunchInProgress: Bool

    init() {
        let now = ProtocolTiming.monotonicNowMs()
        lastWordFromServer = now
        lastAckedState = now
        escapeKeyString = ""
        message = ""
        messageIsNetworkError = false
        messageExpiration = UInt64.max
        showQuitKeystroke = true
        holePunchInProgress = false
    }

    private func serverLate(_ ts: UInt64) -> Bool { (ts - lastWordFromServer) > 6500 }
    private func replyLate(_ ts: UInt64) -> Bool { (ts - lastAckedState) > 10000 }
    private func needCountup(_ ts: UInt64) -> Bool { serverLate(ts) || replyLate(ts) }

    func adjustMessage() {
        if ProtocolTiming.monotonicNowMs() >= messageExpiration {
            message.removeAll(keepingCapacity: true)
        }
    }

    func apply(_ fb: VTFramebuffer, colors: MoshOverlayColors = .default) {
        let now = ProtocolTiming.monotonicNowMs()
        let timeExpired = needCountup(now)
        if message.isEmpty && !timeExpired { return }
        if fb.cursorState.getWidth() == 0 || fb.cursorState.getHeight() == 0 { return }

        if fb.cursorState.getCursorRow() == 0 {
            fb.cursorState.cursorVisible = false
        }

        var notificationCell = VTCell(backgroundColor: 0)
        var renditions = notificationCell.getRenditions()
        renditions.setForegroundColor(Int(colors.foregroundColor))
        renditions.setBackgroundColor(Int(colors.backgroundColor))
        notificationCell.setRenditions(renditions)
        notificationCell.append(UInt32(UnicodeScalar(" ").value))

        for i in 0..<fb.cursorState.getWidth() {
            fb.setMutableCell(notificationCell, row: 0, col: i)
        }

        let sinceHeard = Double(now - lastWordFromServer) / 1000.0
        let sinceAck = Double(now - lastAckedState) / 1000.0
        let serverMessage = "contact"
        let replyMessage = "reply"

        var timeElapsed = sinceHeard
        var explanation = serverMessage
        if replyLate(now) && !serverLate(now) {
            timeElapsed = sinceAck
            explanation = replyMessage
        }

        let keystrokeStr = showQuitKeystroke ? escapeKeyString : ""
        let punchStr = holePunchInProgress ? " Punching..." : ""

        let stringToDraw: String
        if message.isEmpty && timeExpired {
            stringToDraw = "roam: Last \(explanation) \(humanReadableDuration(Int(timeElapsed), secondsAbbr: "seconds")) ago.\(punchStr)\(keystrokeStr)"
        } else if !message.isEmpty && !timeExpired {
            stringToDraw = "roam: \(message)\(punchStr)\(keystrokeStr)"
        } else {
            stringToDraw = "roam: \(message) (\(humanReadableDuration(Int(timeElapsed), secondsAbbr: "s")) without \(explanation).)\(punchStr)\(keystrokeStr)"
        }

        var overlayCol = 0
        var combiningCell: VTCell? = nil

        for scalar in stringToDraw.unicodeScalars {
            if overlayCol >= fb.cursorState.getWidth() { break }
            let ch = scalar.value
            let chwidth = VTCell.displayWidth(ch)

            switch chwidth {
            case 1, 2:
                var cell = fb.getMutableCell(row: 0, col: overlayCol)
                cell.reset(backgroundColor: fb.cursorState.getBackgroundRendition())
                var r = cell.getRenditions()
                r.setAttribute(.bold, true)
                r.setForegroundColor(Int(colors.foregroundColor))
                r.setBackgroundColor(Int(colors.backgroundColor))
                cell.setRenditions(r)
                cell.append(ch)
                cell.setWide(chwidth == 2)
                fb.setMutableCell(cell, row: 0, col: overlayCol)
                combiningCell = cell
                overlayCol += chwidth
            case 0:
                guard var comb = combiningCell else { break }
                if comb.isEmpty {
                    comb.setFallback(true)
                    overlayCol += 1
                }
                if !comb.isFull {
                    comb.append(ch)
                }
                fb.setMutableCell(comb, row: 0, col: overlayCol - 1)
            default:
                break
            }
        }
    }

    func serverHeard(_ ts: UInt64) { lastWordFromServer = ts }
    func serverAcked(_ ts: UInt64) { lastAckedState = ts }

    func waitTime() -> Int {
        var nextExpiry = UInt64(Int.max)
        let now = ProtocolTiming.monotonicNowMs()
        // Only schedule a wake if message is non-empty and hasn't expired yet.
        // Expired messages are cleared by adjustMessage() on next tick anyway,
        // so returning 0 here would cause busy-wait CPU spin.
        if !message.isEmpty && messageExpiration > now {
            nextExpiry = min(nextExpiry, messageExpiration - now)
        }

        if needCountup(now) {
            var countupInterval: UInt64 = 1000
            if now - lastWordFromServer > 60000 {
                countupInterval = ProtocolTiming.heartbeatIntervalMs
            }
            nextExpiry = min(nextExpiry, countupInterval)
        }

        return nextExpiry > UInt64(Int.max) ? Int.max : Int(nextExpiry)
    }

    func setNotificationString(_ message: String, permanent: Bool = false, showQuitKeystroke: Bool = true) {
        self.message = message
        if permanent {
            messageExpiration = UInt64.max
        } else {
            messageExpiration = ProtocolTiming.monotonicNowMs() + 1000
        }
        messageIsNetworkError = false
        self.showQuitKeystroke = showQuitKeystroke
    }

    func setEscapeKeyString(_ name: String) {
        escapeKeyString = " [To quit: \(name) .]"
    }

    func setHolePunchInProgress(_ inProgress: Bool) {
        holePunchInProgress = inProgress
    }

    func setNetworkError(_ s: String) {
        message = s
        messageIsNetworkError = true
        messageExpiration = ProtocolTiming.monotonicNowMs() + ProtocolTiming.heartbeatIntervalMs + 100
    }

    func clearNetworkError() {
        if messageIsNetworkError {
            messageExpiration = min(messageExpiration, ProtocolTiming.monotonicNowMs() + 1000)
        }
    }

    private func humanReadableDuration(_ seconds: Int, secondsAbbr: String) -> String {
        if seconds < 60 {
            return "\(seconds) \(secondsAbbr)"
        } else if seconds < 3600 {
            return String(format: "%d:%02d", seconds / 60, seconds % 60)
        } else {
            return String(format: "%d:%02d:%02d", seconds / 3600, (seconds / 60) % 60, seconds % 60)
        }
    }

    func getNotificationString() -> String { message }

    /// Returns true when the network banner should be visible
    /// (either due to an active message or count-up timeout state).
    func isBannerVisible(now: UInt64 = ProtocolTiming.monotonicNowMs()) -> Bool {
        let messageActive = !message.isEmpty && messageExpiration > now
        return messageActive || needCountup(now)
    }

    /// Returns the current banner state for SwiftUI overlay, or nil if banner should not be visible
    ///
    /// This method computes the display message using the same logic as apply(),
    /// but returns structured data for the SwiftUI banner instead of rendering to framebuffer.
    func getCurrentBannerState() -> MoshRoamBannerState? {
        let now = ProtocolTiming.monotonicNowMs()
        let timeExpired = needCountup(now)

        guard isBannerVisible(now: now) else { return nil }

        let sinceHeard = Double(now - lastWordFromServer) / 1000.0
        let sinceAck = Double(now - lastAckedState) / 1000.0

        var timeElapsed = sinceHeard
        var isReplyTimeout = false

        // Check if this is a reply timeout vs server contact timeout
        if replyLate(now) && !serverLate(now) {
            timeElapsed = sinceAck
            isReplyTimeout = true
        }

        let seconds = Int(timeElapsed)
        let messageActive = !message.isEmpty && messageExpiration > now

        // Build display message (without "roam: " prefix - SwiftUI badge handles that)
        let displayMessage: String
        let isTimeoutBanner: Bool

        if message.isEmpty && timeExpired {
            // Pure timeout banner
            let explanation = isReplyTimeout ? "reply" : "contact"
            displayMessage = "Last \(explanation) \(humanReadableDuration(seconds, secondsAbbr: "seconds")) ago."
            isTimeoutBanner = true
        } else if messageActive && !timeExpired {
            // Pure message banner (not timed out yet)
            displayMessage = message
            isTimeoutBanner = false
        } else {
            // Combined message + timeout
            let explanation = isReplyTimeout ? "reply" : "contact"
            displayMessage = "\(message) (\(humanReadableDuration(seconds, secondsAbbr: "s")) without \(explanation).)"
            isTimeoutBanner = true
        }

        return MoshRoamBannerState(
            message: displayMessage,
            secondsSinceContact: seconds,
            holePunchInProgress: holePunchInProgress,
            isTimeoutBanner: isTimeoutBanner,
            isReplyTimeout: isReplyTimeout
        )
    }
}

final class MoshTitleEngine {
    private var prefix: VTFramebuffer.TitleType = []

    func apply(_ fb: VTFramebuffer) {
        fb.prefixWindowTitle(prefix)
    }

    func setPrefix(_ s: String) {
        prefix = s.unicodeScalars.map { $0 }
    }
}

final class MoshPredictionEngine {
    enum DisplayPreference {
        case always
        case never
        case adaptive
        case experimental
    }

    private static let srttTriggerLow: UInt64 = 20
    private static let srttTriggerHigh: UInt64 = 30
    private static let flagTriggerLow: UInt64 = 50
    private static let flagTriggerHigh: UInt64 = 80
    private static let glitchThreshold: UInt64 = 250
    private static let glitchRepairCount: UInt64 = 10
    private static let glitchRepairMinInterval: UInt64 = 150
    private static let glitchFlagThreshold: UInt64 = 5000

    private var lastByte: UInt8 = 0
    private let parser = VTUTF8Parser()

    private var overlays: [MoshConditionalOverlayRow] = []
    private var overlaysByRow: [Int: MoshConditionalOverlayRow] = [:]  // O(1) lookup for getOrMakeRow
    private var cursors: [MoshConditionalCursorMove] = []

    private var localFrameSent: UInt64 = 0
    private var localFrameAcked: UInt64 = 0
    private var localFrameLateAcked: UInt64 = 0

    private var predictionEpoch: UInt64 = 1
    private var confirmedEpoch: UInt64 = 0

    private var flagging: Bool = false
    private var srttTrigger: Bool = false
    private var glitchTrigger: UInt64 = 0
    private var lastQuickConfirmation: UInt64 = 0

    private var sendIntervalMs: UInt64 = 250
    private var lastHeight: Int = 0
    private var lastWidth: Int = 0

    // Default to adaptive to avoid over-triggering predictions.
    private var displayPreference: DisplayPreference = .adaptive
    private var predictOverwrite: Bool = false

    func setDisplayPreference(_ pref: DisplayPreference) { displayPreference = pref }
    func setPredictOverwrite(_ overwrite: Bool) { predictOverwrite = overwrite }


    func setLocalFrameSent(_ x: UInt64) { localFrameSent = x }
    func setLocalFrameAcked(_ x: UInt64) { localFrameAcked = x }
    func setLocalFrameLateAcked(_ x: UInt64) { localFrameLateAcked = x }
    func setSendInterval(_ x: UInt64) { sendIntervalMs = x }

    /// Safe expiration frame that won't overflow (saturates at UInt64.max)
    private var nextExpirationFrame: UInt64 {
        localFrameSent == UInt64.max ? UInt64.max : localFrameSent + 1
    }

    func waitTime() -> Int {
        if timingTestsNecessary() && active() { return 50 }
        return Int.max
    }

    func apply(_ fb: VTFramebuffer) {
        if displayPreference == .never {
            return
        }
        if !(srttTrigger || glitchTrigger > 0 || displayPreference == .always || displayPreference == .experimental) {
            return
        }
        for cursor in cursors {
            cursor.apply(fb, confirmedEpoch: confirmedEpoch)
        }
        for row in overlays {
            row.apply(fb, confirmedEpoch: confirmedEpoch, flag: flagging)
        }
    }

    func reset() {
        cursors.removeAll()
        overlays.removeAll()
        overlaysByRow.removeAll()
        becomeTentative()
    }

    func cull(_ fb: VTFramebuffer) {
        if displayPreference == .never { return }

        if lastHeight != fb.cursorState.getHeight() || lastWidth != fb.cursorState.getWidth() {
            lastHeight = fb.cursorState.getHeight()
            lastWidth = fb.cursorState.getWidth()
            reset()
        }

        let now = ProtocolTiming.monotonicNowMs()

        // Note: srttTrigger hysteresis is checked AFTER cell processing (at end of function)
        // so that active() reflects the post-cull state. This prevents getting stuck in
        // prediction mode when RTT is low but predictions keep getting created/confirmed.

        if sendIntervalMs > MoshPredictionEngine.flagTriggerHigh {
            flagging = true
        } else if sendIntervalMs <= MoshPredictionEngine.flagTriggerLow {
            flagging = false
        }

        if glitchTrigger > MoshPredictionEngine.glitchRepairCount {
            flagging = true
        }

        // Skip overlay processing if no overlays or cursors exist
        if overlays.isEmpty && cursors.isEmpty {
            // Still need to check srttTrigger even with no overlays
            updateSrttTrigger()
            return
        }

        var rowIndex = 0
        while rowIndex < overlays.count {
            let row = overlays[rowIndex]
            if row.rowNum < 0 || row.rowNum >= fb.cursorState.getHeight() {
                overlaysByRow.removeValue(forKey: row.rowNum)
                overlays.remove(at: rowIndex)
                continue
            }
            for cell in row.overlayCells {
                switch cell.getValidity(fb, row: row.rowNum, earlyAck: localFrameAcked, lateAck: localFrameLateAcked) {
                case .incorrectOrExpired:
                    if cell.tentative(confirmedEpoch) {
                        if displayPreference == .experimental {
                            cell.reset()
                        } else {
                            killEpoch(cell.tentativeUntilEpoch, fb: fb)
                        }
                    } else {
                        if displayPreference == .experimental {
                            cell.reset()
                        } else {
                            reset()
                            return
                        }
                    }
                case .correct:
                    if cell.tentativeUntilEpoch > confirmedEpoch {
                        confirmedEpoch = cell.tentativeUntilEpoch
                    }
                    if now - cell.predictionTime < MoshPredictionEngine.glitchThreshold
                        && glitchTrigger > 0
                        && now - MoshPredictionEngine.glitchRepairMinInterval >= lastQuickConfirmation {
                        glitchTrigger -= 1
                        lastQuickConfirmation = now
                    }
                    let actualRenditions = fb.getCell(row: row.rowNum, col: cell.col).getRenditions()
                    // cell.col == array index (cells created with col: i for i in 0..<numCols)
                    for j in cell.col..<row.overlayCells.count {
                        row.overlayCells[j].replacement.setRenditions(actualRenditions)
                    }
                    fallthrough
                case .correctNoCredit:
                    cell.reset()
                case .pending:
                    if now - cell.predictionTime >= MoshPredictionEngine.glitchFlagThreshold {
                        glitchTrigger = MoshPredictionEngine.glitchRepairCount * 2
                    } else if now - cell.predictionTime >= MoshPredictionEngine.glitchThreshold
                                && glitchTrigger < MoshPredictionEngine.glitchRepairCount {
                        glitchTrigger = MoshPredictionEngine.glitchRepairCount
                    }
                case .inactive:
                    break
                }
            }
            rowIndex += 1
        }

        if !cursors.isEmpty {
            let cursor = cursors[cursors.count - 1]
            if cursor.getValidity(fb, earlyAck: localFrameAcked, lateAck: localFrameLateAcked) == .incorrectOrExpired {
                if displayPreference == .experimental {
                    cursors.removeAll()
                } else {
                    reset()
                    return
                }
            }
        }

        cursors.removeAll { $0.getValidity(fb, earlyAck: localFrameAcked, lateAck: localFrameLateAcked) != .pending }

        // Check srttTrigger AFTER processing so active() reflects post-cull state
        updateSrttTrigger()
    }

    /// Updates srttTrigger with hysteresis based on send interval and active predictions.
    /// Called at the end of cull() so active() reflects the post-cull state.
    private func updateSrttTrigger() {
        if sendIntervalMs > MoshPredictionEngine.srttTriggerHigh {
            srttTrigger = true
        } else if srttTrigger && sendIntervalMs <= MoshPredictionEngine.srttTriggerLow && !active() {
            srttTrigger = false
        }
    }

    func newUserByte(_ byte: UInt8, fb: VTFramebuffer) {
        if displayPreference == .never { return }
        if displayPreference == .experimental {
            predictionEpoch = confirmedEpoch
        }

        cull(fb)
        let now = ProtocolTiming.monotonicNowMs()

        var theByte = byte
        if lastByte == 0x1b && theByte == UInt8(ascii: "O") {
            theByte = UInt8(ascii: "[")
        }
        lastByte = theByte

        var events: [VTParserEvent] = []
        parser.input(theByte, events: &events)

        for event in events {
            if case .print = event.action, event.hasCodepoint {
                initCursor(fb)
                let ch = event.codepoint
                if ch == 0x7f {
                    let row = getOrMakeRow(cursor().row, numCols: fb.cursorState.getWidth())
                    if cursor().col > 0 {
                        cursor().col -= 1
                        cursor().expire(nextExpirationFrame, now: now)

                        if predictOverwrite {
                            let cell = row.overlayCells[cursor().col]
                            cell.resetWithOrig()
                            cell.active = true
                            cell.tentativeUntilEpoch = predictionEpoch
                            cell.expire(nextExpirationFrame, now: now)
                            let origCell = fb.getCell()
                            cell.originalContents.append(origCell)
                            cell.replacement = origCell
                            cell.replacement.clear()
                            cell.replacement.append(UInt32(UnicodeScalar(" ").value))
                        } else {
                            for i in cursor().col..<fb.cursorState.getWidth() {
                                let cell = row.overlayCells[i]
                                cell.resetWithOrig()
                                cell.active = true
                                cell.tentativeUntilEpoch = predictionEpoch
                                cell.expire(nextExpirationFrame, now: now)
                                cell.originalContents.append(fb.getCell(row: cursor().row, col: i))

                                if i + 2 < fb.cursorState.getWidth() {
                                    let nextCell = row.overlayCells[i + 1]
                                    let nextActual = fb.getCell(row: cursor().row, col: i + 1)
                                    if nextCell.active {
                                        if nextCell.unknown {
                                            cell.unknown = true
                                        } else {
                                            cell.unknown = false
                                            cell.replacement = nextCell.replacement
                                        }
                                    } else {
                                        cell.unknown = false
                                        cell.replacement = nextActual
                                    }
                                } else {
                                    cell.unknown = true
                                }
                            }
                        }
                    }
                } else if ch < 0x20 || VTCell.displayWidth(ch) != 1 {
                    becomeTentative()
                } else {
                    guard cursor().row >= 0, cursor().col >= 0 else { continue }
                    guard cursor().row < fb.cursorState.getHeight(), cursor().col < fb.cursorState.getWidth() else { continue }

                    let row = getOrMakeRow(cursor().row, numCols: fb.cursorState.getWidth())

                    if cursor().col + 1 >= fb.cursorState.getWidth() {
                        becomeTentative()
                    }

                    let rightmost = predictOverwrite ? cursor().col : fb.cursorState.getWidth() - 1
                    if rightmost >= cursor().col {
                        for i in stride(from: rightmost, to: cursor().col, by: -1) {
                            let cell = row.overlayCells[i]
                            cell.resetWithOrig()
                            cell.active = true
                            cell.tentativeUntilEpoch = predictionEpoch
                            cell.expire(nextExpirationFrame, now: now)
                            cell.originalContents.append(fb.getCell(row: cursor().row, col: i))

                            let prevCell = row.overlayCells[i - 1]
                            let prevActual = fb.getCell(row: cursor().row, col: i - 1)
                            if i == fb.cursorState.getWidth() - 1 {
                                cell.unknown = true
                            } else if prevCell.active {
                                if prevCell.unknown {
                                    cell.unknown = true
                                } else {
                                    cell.unknown = false
                                    cell.replacement = prevCell.replacement
                                }
                            } else {
                                cell.unknown = false
                                cell.replacement = prevActual
                            }
                        }
                    }

                    let cell = row.overlayCells[cursor().col]
                    cell.resetWithOrig()
                    cell.active = true
                    cell.tentativeUntilEpoch = predictionEpoch
                    cell.expire(nextExpirationFrame, now: now)
                    cell.replacement.setRenditions(fb.cursorState.getRenditions())

                    if cursor().col > 0 {
                        let prevCell = row.overlayCells[cursor().col - 1]
                        let prevActual = fb.getCell(row: cursor().row, col: cursor().col - 1)
                        if prevCell.active && !prevCell.unknown {
                            cell.replacement.setRenditions(prevCell.replacement.getRenditions())
                        } else {
                            cell.replacement.setRenditions(prevActual.getRenditions())
                        }
                    }

                    cell.replacement.clear()
                    cell.replacement.append(ch)
                    cell.originalContents.append(fb.getCell(row: cursor().row, col: cursor().col))

                    cursor().expire(nextExpirationFrame, now: now)

                    if cursor().col < fb.cursorState.getWidth() - 1 {
                        cursor().col += 1
                    } else {
                        becomeTentative()
                        newlineCarriageReturn(fb)
                    }
                }
            } else if case .execute = event.action, event.hasCodepoint {
                if event.codepoint == 0x0d {
                    becomeTentative()
                    newlineCarriageReturn(fb)
                } else {
                    becomeTentative()
                }
            } else if case .dispatchEsc = event.action {
                becomeTentative()
            } else if case .dispatchCSI = event.action, event.hasCodepoint {
                if event.codepoint == UInt32(UnicodeScalar("C").value) {
                    initCursor(fb)
                    if cursor().col < fb.cursorState.getWidth() - 1 {
                        cursor().col += 1
                        cursor().expire(nextExpirationFrame, now: now)
                    }
                } else if event.codepoint == UInt32(UnicodeScalar("D").value) {
                    initCursor(fb)
                    if cursor().col > 0 {
                        cursor().col -= 1
                        cursor().expire(nextExpirationFrame, now: now)
                    }
                } else {
                    becomeTentative()
                }
            }
        }
    }

    private func timingTestsNecessary() -> Bool {
        return !(glitchTrigger > 0 && flagging)
    }

    private func active() -> Bool {
        if !cursors.isEmpty { return true }
        for row in overlays {
            for cell in row.overlayCells {
                if cell.active { return true }
            }
        }
        return false
    }

    private func cursor() -> MoshConditionalCursorMove {
        return cursors.last!
    }

    private func initCursor(_ fb: VTFramebuffer) {
        if cursors.isEmpty {
            cursors.append(MoshConditionalCursorMove(expirationFrame: nextExpirationFrame, row: fb.cursorState.getCursorRow(), col: fb.cursorState.getCursorCol(), tentative: predictionEpoch))
            cursor().active = true
        } else if cursor().tentativeUntilEpoch != predictionEpoch {
            cursors.append(MoshConditionalCursorMove(expirationFrame: nextExpirationFrame, row: cursor().row, col: cursor().col, tentative: predictionEpoch))
            cursor().active = true
        }
    }

    private func killEpoch(_ epoch: UInt64, fb: VTFramebuffer) {
        cursors.removeAll { $0.tentative(epoch - 1) }
        cursors.append(MoshConditionalCursorMove(expirationFrame: nextExpirationFrame, row: fb.cursorState.getCursorRow(), col: fb.cursorState.getCursorCol(), tentative: predictionEpoch))
        cursor().active = true

        for row in overlays {
            for cell in row.overlayCells {
                if cell.tentative(epoch - 1) {
                    cell.reset()
                }
            }
        }
        becomeTentative()
    }

    private func newlineCarriageReturn(_ fb: VTFramebuffer) {
        let now = ProtocolTiming.monotonicNowMs()
        initCursor(fb)
        cursor().col = 0
        if cursor().row == fb.cursorState.getHeight() - 1 {
            let row = getOrMakeRow(cursor().row, numCols: fb.cursorState.getWidth())
            for cell in row.overlayCells {
                cell.active = true
                cell.tentativeUntilEpoch = predictionEpoch
                cell.expire(nextExpirationFrame, now: now)
                cell.replacement.clear()
            }
        } else {
            cursor().row += 1
        }
    }

    private func becomeTentative() {
        if displayPreference != .experimental {
            predictionEpoch += 1
        }
    }

    private func getOrMakeRow(_ rowNum: Int, numCols: Int) -> MoshConditionalOverlayRow {
        // O(1) lookup via dictionary instead of linear search
        if let existing = overlaysByRow[rowNum] {
            return existing
        }
        let row = MoshConditionalOverlayRow(rowNum: rowNum)
        row.overlayCells.reserveCapacity(numCols)
        for i in 0..<numCols {
            let cell = MoshConditionalOverlayCell(expirationFrame: 0, col: i, tentative: predictionEpoch)
            row.overlayCells.append(cell)
        }
        overlays.append(row)
        overlaysByRow[rowNum] = row
        return row
    }
}

final class MoshOverlayManager {
    private let notifications = MoshNotificationEngine()
    private let predictions = MoshPredictionEngine()
    private let title = MoshTitleEngine()

    func apply(_ fb: VTFramebuffer) {
        predictions.cull(fb)
        predictions.apply(fb)
        notifications.adjustMessage()
        // NOTE: Notification banner is rendered via SwiftUI overlay (MoshRoamBannerView)
        // instead of framebuffer rendering. This enables liquid glass effect, rounded
        // corners, and per-terminal scoping in splits. The notification engine's state
        // is still used (via getCurrentBannerState()) but not rendered to framebuffer.
        title.apply(fb)
    }

    func getNotificationEngine() -> MoshNotificationEngine { notifications }
    func getPredictionEngine() -> MoshPredictionEngine { predictions }

    func setTitlePrefix(_ s: String) { title.setPrefix(s) }

    func waitTime() -> Int { min(notifications.waitTime(), predictions.waitTime()) }
}
