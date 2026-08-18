//
//  AttentionStatusViews.swift
//  rootshell
//
//  Shared agent-attention presentation: the color vocabulary (t3code's
//  three-color rule — amber for act-now, sky for in-motion, red for
//  broken; done is emerald only while unread), the status dot used by the
//  top tab bar and sidebar rows, the status label with the live elapsed
//  timer, and the sidebar's rollup summary.
//

import SwiftUI

extension AgentAttentionStatus {
    /// Status palette. Rollups use `worst(of:)`, so a dot tinted with
    /// this color always reflects the attention ladder.
    var statusColor: Color {
        switch self {
        case .blocked: return .orange
        case .failed: return .red
        case .paused: return .orange
        case .working: return .cyan
        case .done: return .green
        case .idle: return Color.gray
        case .unknown: return Color.gray
        }
    }

    /// Short display label (the sidebar card's status word).
    var displayLabel: String {
        switch self {
        case .blocked: return String(localized: "Needs input")
        case .failed: return String(localized: "Failed")
        case .paused: return String(localized: "Paused")
        case .working: return String(localized: "Working")
        case .done: return String(localized: "Done")
        case .idle: return String(localized: "Idle")
        case .unknown: return ""
        }
    }

    /// Counted status phrase used by the vertical-sidebar rollup. This must
    /// be a complete localized phrase rather than `rawValue`: translators
    /// may need to reorder the count and status or inflect the status word.
    func rollupLabel(count: Int) -> String {
        switch self {
        case .blocked:
            return String(
                localized: "\(count) blocked",
                comment: "Agent status rollup: number of blocked agents")
        case .failed:
            return String(
                localized: "\(count) failed",
                comment: "Agent status rollup: number of failed agents")
        case .paused:
            return String(
                localized: "\(count) paused",
                comment: "Agent status rollup: number of paused agents")
        case .working:
            return String(
                localized: "\(count) working",
                comment: "Agent status rollup: number of working agents")
        case .done:
            return String(
                localized: "\(count) done",
                comment: "Agent status rollup: number of completed agents")
        case .idle:
            return String(
                localized: "\(count) idle",
                comment: "Agent status rollup: number of idle agents")
        case .unknown:
            return ""
        }
    }
}

// MARK: - Status Dot

/// One attention glyph: a filled circle in the status color, dimmed for
/// `idle`, smaller for `unknown`.
struct AttentionStatusDotView: View {
    private let status: AgentAttentionStatus
    var size: CGFloat = 8

    init(status: AgentAttentionStatus, size: CGFloat = 8) {
        self.status = status
        self.size = size
    }

    private var dotSize: CGFloat {
        status == .unknown ? size * 0.7 : size
    }

    private var dotOpacity: Double {
        switch status {
        case .idle: return 0.45
        case .unknown: return 0.7
        default: return 1
        }
    }

    var body: some View {
        Image(systemName: "circle.fill")
            .font(.system(size: dotSize))
            .foregroundStyle(status.statusColor.opacity(dotOpacity))
            .frame(width: size, height: size)
            .accessibilityLabel(Text(verbatim: status.displayLabel))
    }
}

// MARK: - Status Label (card line 1, right side)

/// The t3code-style status treatment: a colored word for act-now /
/// in-motion / broken states, a live self-ticking elapsed span while
/// working, and quiet relative time when idle. Only the timer text
/// re-renders each second (OS-driven), never the row.
struct AgentStatusLabel: View {
    let row: AgentRowState
    var fontSize: CGFloat = 12

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var dimmed = false

    /// Half a breathe: full opacity down to `breatheDim` and back is 3.4s.
    /// Easing settles the label at each end rather than pinging between
    /// them, so no explicit hold is needed.
    private static let breatheHalfCycle: TimeInterval = 1.7
    private static let breatheDim: Double = 0.75

    /// Only in-flight rows breathe. Decorative motion is the first thing to
    /// drop when the user has asked for less of it, or when the device is
    /// in Low Power Mode / thermally throttled (the `.saver` tier).
    private var breathes: Bool {
        row.status == .working
            && !reduceMotion
            && PowerManager.shared.tier != .saver
    }

    var body: some View {
        if breathes {
            label
                .opacity(dimmed ? Self.breatheDim : 1)
                .onAppear {
                    withAnimation(
                        .easeInOut(duration: Self.breatheHalfCycle)
                            .repeatForever(autoreverses: true)
                    ) {
                        dimmed = true
                    }
                }
                .onDisappear { dimmed = false }
        } else {
            label
        }
    }

    /// The status word, its glyph, and the live elapsed span. The breathe
    /// covers all three together so the label reads as one element.
    private var label: some View {
        HStack(spacing: 4) {
            switch row.status {
            case .working:
                Image(systemName: "circle.dashed")
                    .font(.system(size: fontSize - 1, weight: .semibold))
                Text(row.status.displayLabel)
                    .fontWeight(.medium)
                if row.backgroundAgentCount > 0 {
                    // Claude's fleet: "Working · 2 agents". The session
                    // itself is not counted.
                    Text("· ^[\(row.backgroundAgentCount) agent](inflect: true)")
                }
                if let progress = row.taskProgress {
                    // Task rows: "Working · 40%", quantized to 10% buckets
                    // so the row publishes on transitions only.
                    Text("· \(progress)")
                }
                if let since = row.workingSince {
                    // Same format as the agents' own TUIs ("2m 49s"), so
                    // the card visibly agrees with the terminal. Adapt to
                    // the same power tier as terminal rendering.
                    TimelineView(.periodic(from: .now, by: elapsedRefreshInterval)) { context in
                        Text(verbatim: Self.elapsedLabel(from: since, to: context.date))
                            .monospacedDigit()
                    }
                }
            case .paused:
                Image(systemName: "pause.circle")
                    .font(.system(size: fontSize - 1, weight: .semibold))
                Text(row.status.displayLabel)
                    .fontWeight(.medium)
                if let progress = row.taskProgress {
                    Text("· \(progress)")
                }
                if let since = row.workingSince {
                    TimelineView(.periodic(from: .now, by: elapsedRefreshInterval)) { context in
                        Text(verbatim: Self.elapsedLabel(from: since, to: context.date))
                            .monospacedDigit()
                    }
                }
            case .blocked:
                Text(row.status.displayLabel)
                    .fontWeight(.semibold)
            case .failed:
                if let code = row.exitCode, code != 0 {
                    Text("Failed · exit \(code)")
                        .fontWeight(.semibold)
                } else {
                    Text(row.status.displayLabel)
                        .fontWeight(.semibold)
                }
            case .done:
                Image(systemName: "checkmark.circle")
                    .font(.system(size: fontSize - 1, weight: .semibold))
                Text(row.status.displayLabel)
                    .fontWeight(.medium)
            case .idle, .unknown:
                if let finished = row.finishedAt {
                    // Static until some real state change redraws the row.
                    // SwiftUI's relative-date style owns an implicit timer,
                    // which would wake an otherwise-idle agent card.
                    Text(verbatim: Self.relativeLabel(from: finished, to: Date()))
                }
            }
        }
        .font(.system(size: fontSize))
        .foregroundStyle(labelColor)
        .lineLimit(1)
        .fixedSize()
    }

    private var labelColor: Color {
        switch row.status {
        case .idle, .unknown: return Color.secondary
        default: return row.status.statusColor
        }
    }

    private var elapsedRefreshInterval: TimeInterval {
        switch PowerManager.shared.tier {
        case .full: return 1
        case .reduced: return 5
        case .saver: return 15
        }
    }

    /// TUI-style elapsed: "17s", "2m 49s", "1h 5m". Shared with the
    /// notification body via `AgentElapsedFormat`.
    static func elapsedLabel(from start: Date, to now: Date) -> String {
        AgentElapsedFormat.elapsed(from: start, to: now)
    }

    static func relativeLabel(from start: Date, to now: Date) -> String {
        AgentElapsedFormat.relative(from: start, to: now)
    }
}

// MARK: - Rollup Summary

/// "2 blocked · 1 working" across every window's detected agents; only
/// the leading (most urgent) segment is colored and bold. Reads the
/// center's revision to register the Observation dependency.
struct AttentionRollupSummary: View {
    var fontSize: CGFloat = 12

    /// Segment display order: the attention ladder, most urgent first.
    private static let displayOrder: [AgentAttentionStatus] = [
        .blocked, .failed, .done, .paused, .working, .idle
    ]

    var body: some View {
        let _ = AgentAttentionCenter.shared.revision
        let counts = AgentAttentionCenter.shared.globalAgentCounts()
        let segments = Self.displayOrder.compactMap { status -> (status: AgentAttentionStatus, count: Int)? in
            guard let count = counts[status], count > 0 else { return nil }
            return (status, count)
        }
        if !segments.isEmpty {
            HStack(spacing: 5) {
                AttentionStatusDotView(status: segments[0].status, size: 7)
                if segments.allSatisfy({ $0.status == .idle }) {
                    Text("all idle")
                        .foregroundStyle(.secondary)
                } else {
                    segmentText(segments)
                }
            }
            .font(.system(size: fontSize))
            .lineLimit(1)
        }
    }

    private func segmentText(_ segments: [(status: AgentAttentionStatus, count: Int)]) -> Text {
        var result = Text(verbatim: "")
        for (index, segment) in segments.enumerated() {
            if index > 0 {
                result = result + Text(" · ").foregroundStyle(.secondary)
            }
            let piece = Text(verbatim: segment.status.rollupLabel(count: segment.count))
            if index == 0 {
                result = result + piece.bold().foregroundStyle(segment.status.statusColor)
            } else {
                result = result + piece.foregroundStyle(.secondary)
            }
        }
        return result
    }
}
