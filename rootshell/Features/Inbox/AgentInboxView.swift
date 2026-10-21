//
//  AgentInboxView.swift
//  rootshell
//
//  The inbox screen. This is the only place besides the terminal where the
//  message text is allowed: the person has unlocked the device and opened the
//  app. Rows are grouped by what has to happen, not by which agent spoke.
//
//  Layout follows the app's other lists (inset-grouped `List`, system section
//  headers, `.subheadline` / `.caption2` type ramp) and every string goes
//  through `String(localized:)` so the screen tracks the system language.
//

import RootshellPushKit
import Combine
import SwiftUI

/// Presentation state shared by the island's deep links and this screen.
@MainActor
@Observable
final class AgentInboxRouter {
    static let shared = AgentInboxRouter()

    var isPresented = false
    /// Highlighted briefly after arriving from the island so the row the person
    /// tapped is findable in a list that may have moved on.
    var highlightedID: String?

    func present(highlighting id: String? = nil) {
        highlightedID = id
        isPresented = true
    }
}

struct AgentInboxView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var colorScheme
    /// The sheet's own card colour, so the inbox cards are the same fill as
    /// every other panel in the app rather than a white system row on a dark
    /// sheet.
    @Environment(\.sheetThemeColors) private var sheetThemeColors
    /// Set when the inbox is hosted in the app's own drawer instead of a sheet.
    var onClose: (() -> Void)?
    /// False when the caller already provides a `NavigationStack` (the inbox is
    /// then a pushed page and the system owns the interactive back gesture).
    var embedsNavigation: Bool = true
    @State private var store = AgentInboxStore.shared
    @State private var filter: Filter = .all
    @State private var highlight: String?
    @State private var flashTask: Task<Void, Never>?
    /// Drives the relative timestamps: row bodies read this, so "2 分钟前"
    /// becomes "3 分钟前" on its own instead of freezing at first render.
    @State private var now = Date()

    enum Filter: String, CaseIterable, Identifiable {
        case all, needsYou, failed
        var id: String { rawValue }

        var title: String {
            switch self {
            case .all: String(localized: "All Messages", comment: "Inbox filter")
            case .needsYou: String(localized: "Needs You", comment: "Inbox filter")
            case .failed: String(localized: "Failed Runs", comment: "Inbox filter")
            }
        }
    }

    private var sections: [AgentInboxSection] {
        switch filter {
        case .all: [.needsYou, .working, .done]
        case .needsYou: [.needsYou]
        case .failed: [.done]
        }
    }

    /// Matches the app's own card surfaces: a soft translucent fill with an
    /// 18pt radius, rather than the system's grouped grey list rows.
    /// The page's own luminance decides how semantic colours resolve. The app can
    /// run a dark terminal theme while the system is in light mode; without this
    /// `.secondary` is black-on-black and the timestamps disappear.
    private var surfaceScheme: ColorScheme {
        guard let theme = sheetThemeColors else { return colorScheme }
        return theme.isDarkSurface ? .dark : .light
    }

    private var accentTint: Color {
        sheetThemeColors?.inboxAccent ?? .accentColor
    }

    private var cardFill: Color {
        sheetThemeColors?.cardFill ?? Color(uiColor: .secondarySystemGroupedBackground)
    }

    private var cardStroke: Color {
        sheetThemeColors?.cardStroke ?? Color(uiColor: .separator).opacity(0.5)
    }

    var body: some View {
        if embedsNavigation {
            NavigationStack { pageContent }
        } else {
            pageContent
        }
    }

    @ViewBuilder
    private var pageContent: some View {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    AgentInboxFilterBar(filter: $filter)
                        .padding(.horizontal, 16)
                        .padding(.top, 8)

                    if store.isEmpty {
                        ContentUnavailableView(
                            String(localized: "No Agent Messages", comment: "Inbox empty state title"),
                            systemImage: "tray",
                            description: Text(String(localized: "Hook messages from your agents land here.", comment: "Inbox empty state detail"))
                        )
                        .padding(.top, 40)
                    } else {
                        ForEach(sections, id: \.self) { section in
                            let rows = visibleRows(in: section)
                            if !rows.isEmpty {
                                VStack(alignment: .leading, spacing: 8) {
                                    AgentInboxSectionHeader(section: section, count: rows.count)
                                        .padding(.horizontal, 4)

                                    VStack(spacing: 0) {
                                        ForEach(Array(rows.enumerated()), id: \.element.id) { index, row in
                                            AgentInboxRowView(
                                                row: row,
                                                now: now,
                                                highlighted: highlight == row.id,
                                                onOpen: { open(row) },
                                                onArchive: { store.archive(row.id) }
                                            )
                                            if index < rows.count - 1 {
                                                Rectangle()
                                                    .fill(cardStroke)
                                                    .frame(height: 0.5)
                                                    .padding(.leading, 50)
                                            }
                                        }
                                    }
                                    .background(
                                        RoundedRectangle(cornerRadius: 18, style: .continuous)
                                            .fill(cardFill)
                                    )
                                    .overlay(
                                        RoundedRectangle(cornerRadius: 18, style: .continuous)
                                            .strokeBorder(cardStroke, lineWidth: 0.5)
                                    )
                                }
                                .padding(.horizontal, 16)
                            }
                        }
                    }
                }
                .padding(.bottom, 24)
                // On iPad the cards otherwise stretch the full 13-inch width and
                // every row turns into a banner; cap the column and centre it.
                .frame(maxWidth: 680, alignment: .leading)
                .frame(maxWidth: .infinity)
            }
            .themedList()
            .agentInboxPage(sheetThemeColors)
            .environment(\.colorScheme, surfaceScheme)
            .toolbarColorScheme(surfaceScheme, for: .navigationBar)
            .agentInboxSwipeBack { close() }
            .simultaneousGesture(
                DragGesture(minimumDistance: 40).onEnded { value in
                    guard value.translation.width < -70,
                          abs(value.translation.width) > abs(value.translation.height) * 1.5 else { return }
                    close()
                }
            )
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(sheetThemeColors?.pageFill ?? Color(uiColor: .systemGroupedBackground), for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
            .toolbar {
                // The bar's own title ignored `toolbarColorScheme` in this stack and
                // stayed black on a dark bar; a principal item resolves `.primary`
                // against the scheme we force below instead.
                ToolbarItem(placement: .principal) {
                    Text(String(localized: "Agent Inbox", comment: "Inbox title"))
                        .font(.headline)
                        .foregroundStyle(.primary)
                }
                // A pushed page uses the system back button; the sheet needs its
                // own, because a sheet has no navigation bar of its own.
                if embedsNavigation {
                    ToolbarItem(placement: .topBarLeading) {
                        Button(String(localized: "Done", comment: "Done button")) {
                            if let onClose { onClose() } else { dismiss() }
                        }
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    // A text button in a glass capsule reads as a primary action;
                    // the icon alone sits at the weight of the rest of the bar.
                    Button {
                        store.markAllRead()
                    } label: {
                        Image(systemName: "checkmark.circle")
                    }
                    .tint(accentTint)
                    .disabled(store.unreadCount == 0)
                    .accessibilityLabel(String(localized: "Mark All Read", comment: "Inbox action"))
                }
            }
        .onReceive(Timer.publish(every: 20, on: .main, in: .common).autoconnect()) { tick in
            now = tick
        }
        .onAppear {
            now = Date()
            flash(AgentInboxRouter.shared.highlightedID)
            AgentInboxRouter.shared.highlightedID = nil
        }
    }

    private func visibleRows(in section: AgentInboxSection) -> [AgentInboxRow] {
        let rows = store.rows(in: section)
        guard filter == .failed else { return rows }
        return rows.filter { $0.status == .failed }
    }

    /// Tapping a row opens its pane; the shell handles the navigation and then
    /// the pane counts as read, which is what clears the island.
    private func close() {
        if let onClose { onClose() } else { dismiss() }
    }

    private func open(_ row: AgentInboxRow) {
        // Opening a row is a read; the island's count has to drop with it.
        store.markRead(deepLink: row.deepLink)
        close()
        Task { @MainActor in
            // Let the panel finish dismissing first, otherwise the tab switch
            // happens behind it and looks like nothing moved.
            try? await Task.sleep(for: .milliseconds(320))
            PushNotificationRouter.openInboxRow(deepLink: row.deepLink, tabTitle: row.tab)
        }
    }

    private func flash(_ id: String?) {
        guard let id else { return }
        highlight = id
        flashTask?.cancel()
        flashTask = Task {
            try? await Task.sleep(for: .seconds(1.2))
            guard !Task.isCancelled else { return }
            highlight = nil
        }
    }
}

private struct AgentInboxSectionHeader: View {
    let section: AgentInboxSection
    let count: Int

    var body: some View {
        HStack {
            Text(section.title)
            Spacer()
            Text("\(count)").monospacedDigit()
        }
        .font(.footnote.weight(.semibold))
        .foregroundStyle(.secondary)
        // Keep the sentence casing in every language: `textCase(nil)` stops the
        // grouped list from forcing uppercase, which does nothing for Chinese
        // and shouts for no reason in English.
        .textCase(nil)
    }
}

private struct AgentInboxRowView: View {
    @Environment(\.colorScheme) private var colorScheme
    /// The sheet's own card colour, so the inbox cards are the same fill as
    /// every other panel in the app rather than a white system row on a dark
    /// sheet.
    @Environment(\.sheetThemeColors) private var sheetThemeColors
    let row: AgentInboxRow
    let now: Date
    let highlighted: Bool
    let onOpen: () -> Void
    let onArchive: () -> Void

    var body: some View {
        Button(action: onOpen) {
            HStack(alignment: .top, spacing: 10) {
                AgentInboxGlyph(agent: row.agent)
                VStack(alignment: .leading, spacing: 3) {
                    Text(row.summary ?? row.agent)
                        .font(.subheadline)
                        .foregroundStyle(.primary)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)

                    // Which machine this came from: hooks fire on several hosts
                    // at once, and two rows can otherwise look identical.
                    if let host = row.host {
                        HStack(spacing: 5) {
                            AgentInboxHostChip(host: host)
                            if let tab = row.tab {
                                Text(tab)
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }
                        }
                        .padding(.top, 1)
                    } else if let location {
                        Text(location)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer(minLength: 6)
                VStack(alignment: .trailing, spacing: 6) {
                    Text(AgentInboxTime.short(row.receivedAt, now: now))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    AgentInboxStatusDot(status: row.status)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 11)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background(
            highlighted ? Color.accentColor.opacity(0.10) : Color.clear
        )
        .contextMenu {
            Button(role: .destructive, action: onArchive) {
                Label(String(localized: "Archive Message", comment: "Inbox row action"), systemImage: "archivebox")
            }
        }
    }

    /// The app's list surfaces are soft translucent cards rather than the
    /// system's grouped grey, so the inbox reads as part of the app.
    /// The page's own luminance decides how semantic colours resolve. The app can
    /// run a dark terminal theme while the system is in light mode; without this
    /// `.secondary` is black-on-black and the timestamps disappear.
    private var surfaceScheme: ColorScheme {
        guard let theme = sheetThemeColors else { return colorScheme }
        return theme.isDarkSurface ? .dark : .light
    }

    private var accentTint: Color {
        sheetThemeColors?.inboxAccent ?? .accentColor
    }

    private var cardFill: Color {
        sheetThemeColors?.cardFill ?? Color(uiColor: .secondarySystemGroupedBackground)
    }

    private var cardStroke: Color {
        sheetThemeColors?.cardStroke ?? Color(uiColor: .separator).opacity(0.5)
    }

    private var location: String? {
        let parts = [row.host, row.tab].compactMap { $0 }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }
}

struct AgentInboxGlyph: View {
    let agent: String

    /// The shipped artwork is drawn for notification thumbnails: Codex is a
    /// white knot on transparency, oh-my-pi is near-black strokes with orange
    /// accents. One fixed plate colour makes half of them vanish, so the plate
    /// follows the mark's own luminance — light mark on a dark plate, dark mark
    /// on a light one. Brand colours are never recoloured, only the backdrop.
    private static let darkPlate = Color(white: 0.11)
    private static let lightPlate = Color(white: 0.94)

    var body: some View {
        RoundedRectangle(cornerRadius: 6, style: .continuous)
            .fill(Self.plate(for: Self.logo(for: agent)))
            .frame(width: 22, height: 22)
            .overlay {
                if let logo = Self.logo(for: agent) {
                    Image(uiImage: logo)
                        .resizable()
                        .scaledToFit()
                        .padding(3)
                } else {
                    Image(systemName: "terminal")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(.white.opacity(0.8))
                }
            }
            .overlay(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .strokeBorder(Color.white.opacity(0.10), lineWidth: 0.5)
            )
    }

    private static func plate(for image: UIImage?) -> Color {
        guard let image, let cg = image.cgImage else { return darkPlate }
        return averageLuminance(cg) > 0.55 ? darkPlate : lightPlate
    }

    /// Average luminance of the opaque pixels, sampled on a 16pt grid.
    private static func averageLuminance(_ cg: CGImage) -> Double {
        let side = 16
        var pixels = [UInt8](repeating: 0, count: side * side * 4)
        guard let context = CGContext(
            data: &pixels,
            width: side,
            height: side,
            bitsPerComponent: 8,
            bytesPerRow: side * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return 0.5 }
        context.draw(cg, in: CGRect(x: 0, y: 0, width: side, height: side))
        var total = 0.0
        var count = 0.0
        for index in stride(from: 0, to: pixels.count, by: 4) where pixels[index + 3] > 102 {
            total += 0.2126 * Double(pixels[index])
                + 0.7152 * Double(pixels[index + 1])
                + 0.0722 * Double(pixels[index + 2])
            count += 255
        }
        return count > 0 ? total / count : 0.5
    }

    /// The same artwork the push notification uses as its attachment, so the
    /// inbox and the notification agree on what each agent looks like.
    private static func logo(for agent: String) -> UIImage? {
        if let cached = logoCache[agent] { return cached }
        guard let url = PushAgentLogoAttachment.resourceURL(for: agent),
              let data = try? Data(contentsOf: url),
              let image = UIImage(data: data) else { return nil }
        logoCache[agent] = image
        return image
    }

    private static var logoCache: [String: UIImage] = [:]
}

struct AgentInboxStatusDot: View {
    let status: AgentInboxStatus

    var body: some View {
        Group {
            if status == .done {
                Image(systemName: "checkmark")
                    .font(.system(size: 10, weight: .black))
                    .foregroundStyle(.green)
            } else {
                Circle()
                    .strokeBorder(color, lineWidth: status == .other ? 1.5 : 0)
                    .background(Circle().fill(status == .other ? .clear : color))
                    .frame(width: 11, height: 11)
            }
        }
        .frame(width: 15, height: 15)
    }

    private var color: Color {
        switch status {
        case .blocked: .orange
        case .done: .green
        case .failed: .red
        case .other: .green
        }
    }
}

/// Compact elapsed time. `Text(_, style: .relative)` prints "3 分钟 13 秒",
/// which is too wide for a trailing edge and reads like a stopwatch.
enum AgentInboxTime {
    static func short(_ date: Date, now: Date = Date()) -> String {
        let seconds = max(0, now.timeIntervalSince(date))
        switch seconds {
        case ..<60:
            return String(localized: "Just Now", comment: "Inbox relative time")
        case ..<3600:
            return String(format: String(localized: "%lld min ago", comment: "Inbox relative time"), Int(seconds / 60))
        case ..<86_400:
            return String(format: String(localized: "%lld hr ago", comment: "Inbox relative time"), Int(seconds / 3600))
        default:
            return String(format: String(localized: "%lld d ago", comment: "Inbox relative time"), Int(seconds / 86_400))
        }
    }
}


/// The inbox filter, sized like the app's own controls.
///
/// The system segmented control collapses to ~32pt here, which reads as a
/// stray control rather than part of the screen; this keeps the app's card
/// surface, radius and type scale instead.
private struct AgentInboxFilterBar: View {
    @Binding var filter: AgentInboxView.Filter
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.sheetThemeColors) private var sheetThemeColors

    var body: some View {
        HStack(spacing: 2) {
            ForEach(AgentInboxView.Filter.allCases) { item in
                let selected = item == filter
                Button {
                    withAnimation(.snappy(duration: 0.18)) { filter = item }
                } label: {
                    Text(item.title)
                        .font(.subheadline.weight(selected ? .semibold : .regular))
                        .foregroundStyle(selected ? Color.primary : Color.secondary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.85)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 10)
                        .background(
                            RoundedRectangle(cornerRadius: 10, style: .continuous)
                                .fill(selected ? selectedFill : Color.clear)
                        )
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(3)
        .background(
            RoundedRectangle(cornerRadius: 13, style: .continuous)
                .fill(sheetThemeColors?.controlFill ?? (colorScheme == .dark ? Color.white.opacity(0.06) : Color(uiColor: .secondarySystemGroupedBackground)))
        )
    }

    private var selectedFill: Color {
        sheetThemeColors?.selectedControlFill ?? (colorScheme == .dark ? Color.white.opacity(0.14) : Color(uiColor: .systemBackground))
    }
}


/// The machine a message came from. Rendered as a small chip rather than plain
/// grey text so a glance at the list separates hosts when several are pushing
/// at the same time.
struct AgentInboxHostChip: View {
    let host: String
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        HStack(spacing: 3) {
            Image(systemName: "server.rack")
                .font(.system(size: 8, weight: .semibold))
            Text(host)
                .font(.caption2.weight(.medium))
                .monospaced()
                .lineLimit(1)
        }
        .foregroundStyle(.secondary)
        .padding(.horizontal, 5)
        .padding(.vertical, 2)
        .background(
            Capsule().fill(colorScheme == .dark ? Color.white.opacity(0.09) : Color.black.opacity(0.05))
        )
        .accessibilityLabel(Text(String(localized: "Host", comment: "Inbox row host label") + " " + host))
    }
}
