//
//  SessionPickerOverlay.swift
//  rootshell
//
//  Overlay for selecting an active multiplexer session (tmux/zellij/herdr/zmx) after SSH connection.
//

import SwiftUI

/// Why the picker is showing no rows. Only a user-invoked run presents a card
/// without results, so each case names something the user can act on.
enum SessionDiscoveryPlaceholder: Equatable {
    /// Scan in flight.
    case searching
    /// Scan finished and the host reported no sessions.
    case empty
    /// Scan could not complete: timeout, auth failure, helper unavailable.
    case failed
    /// Every multiplexer's discovery setting is off, so nothing was scanned.
    case disabled
    /// This surface cannot be scanned at all (not SSH-backed, no local shell).
    case unsupported
}

struct SessionPickerOverlay: View {
    let sessions: [MultiplexerSession]
    let sessionTypes: Set<MultiplexerType>
    let selectedIndex: Int
    let hasUserTyped: Bool
    /// Set when the card is up with no rows, saying why. Nil once rows exist.
    let placeholder: SessionDiscoveryPlaceholder?
    /// Keyboard/accessory coverage in this overlay's coordinate space. The
    /// terminal host owns keyboard avoidance, including toolbar-only layouts.
    let bottomClearance: CGFloat
    @Binding var tmuxAttachMode: TmuxAutoMode
    let allowsTmuxControlAttach: Bool
    @Binding var herdrAttachMode: HerdrAutoMode
    let allowsHerdrControlAttach: Bool
    let onSelect: (MultiplexerSession) -> Void
    let onChangeSelection: (Int) -> Void
    let onDismiss: () -> Void

    @State private var showAttachConfirmation = false
    @State private var pendingSession: MultiplexerSession?
    // List height excluding the selected preview, so growing that preview
    // cannot feed back into its own available-space calculation.
    @State private var listDetailsHeight: CGFloat?
    @State private var fixedHeaderHeight: CGFloat = 0
    @State private var fixedFooterHeight: CGFloat = 0
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    private var title: String {
        if sessionTypes.count == 1, let type = sessionTypes.first {
            return "\(type.rawValue) Sessions"
        }
        return "Terminal Sessions"
    }

    /// No rows to show.
    private var isPlaceholder: Bool { sessions.isEmpty }

    private var isSearching: Bool { placeholder == .searching }

    private var headerIcon: String {
        // Single-type pickers show that multiplexer's own icon; mixed pickers
        // fall back to tmux's, which reads as a generic "panes" glyph.
        if sessionTypes.count == 1, let type = sessionTypes.first {
            return type.iconName
        }
        return MultiplexerType.tmux.iconName
    }

    private var isMixed: Bool { sessionTypes.count > 1 }

    private var selectedSession: MultiplexerSession? {
        guard sessions.indices.contains(selectedIndex) else { return nil }
        return sessions[selectedIndex]
    }

    private var hasSelectedPreview: Bool {
        selectedSession?.capturedContent?.isEmpty == false
    }

    private var tmuxControlModeBinding: Binding<Bool> {
        Binding(
            get: { tmuxAttachMode == .control },
            set: { tmuxAttachMode = $0 ? .control : .regular }
        )
    }

    private var herdrControlModeBinding: Binding<Bool> {
        Binding(
            get: { herdrAttachMode == .control },
            set: { herdrAttachMode = $0 ? .control : .regular }
        )
    }

    var body: some View {
        GeometryReader { geometry in
            let availableHeight = max(0, geometry.size.height - bottomClearance)
            let isNarrow = geometry.size.width < 500
            let isCompact = isNarrow || availableHeight < 300
            let cardHeight = min(isNarrow ? .infinity : 700, max(0, availableHeight - 16))
            let isShort = cardHeight < 300 || dynamicTypeSize.isAccessibilitySize
            // Results use the full viewport. Only placeholder messages hug
            // their contents; extra room belongs to browsing and the preview.
            let placeholderHeight = listDetailsHeight.map {
                $0 + (isShort ? 0 : fixedHeaderHeight) + fixedFooterHeight
            }
            let fittedCardHeight = isPlaceholder
                ? min(cardHeight, placeholderHeight ?? cardHeight)
                : cardHeight

            ZStack(alignment: .top) {
                // Keep the dismissal backdrop full size; only the card avoids
                // the keyboard, which this terminal container ignores globally.
                Color.black.opacity(0.3)
                    .ignoresSafeArea()
                    .onTapGesture { onDismiss() }

                VStack(alignment: .leading, spacing: 0) {
                    if !isShort {
                        VStack(spacing: 0) {
                            header(compact: isCompact)
                            Divider().padding(.horizontal, 12)
                        }
                        .fixedSize(horizontal: false, vertical: true)
                        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: {
                            fixedHeaderHeight = $0
                        }
                    }

                    sessionList(compact: isCompact, includesHeader: isShort)

                    VStack(alignment: .leading, spacing: 0) {
                        if let session = selectedSession {
                            Divider().padding(.horizontal, 12)
                            attachBar(for: session, compact: isCompact)
                        }

                        if !isShort, !isCompact || isPlaceholder || KeyboardTracker.shared.isHardwareKeyboard {
                            footerHints(compact: isCompact)
                        }
                    }
                    .fixedSize(horizontal: false, vertical: true)
                    .layoutPriority(1)
                    .onGeometryChange(for: CGFloat.self) { $0.size.height } action: {
                        fixedFooterHeight = $0
                    }
                }
                .frame(maxWidth: isNarrow ? .infinity : 540)
                .frame(height: fittedCardHeight)
                .overlayCardBackground()
                .padding(.horizontal, isNarrow ? 12 : 32)
                .padding(.vertical, 8)
                .frame(maxWidth: .infinity)
                .frame(height: availableHeight, alignment: isCompact ? .top : .center)
                .clipped()
            }
        }
        .alert("Attach to Session?", isPresented: $showAttachConfirmation) {
            Button("Attach") {
                if let session = pendingSession {
                    onSelect(session)
                }
            }
            .keyboardShortcut(.defaultAction)
            Button("Cancel", role: .cancel) {
                pendingSession = nil
            }
        } message: {
            if let session = pendingSession {
                Text("You've already started typing. Attach to \"\(session.name)\" anyway? This will send a \(attachDescription(for: session)) command to the terminal.")
            }
        }
    }

    private func header(compact: Bool) -> some View {
        HStack(spacing: 10) {
            Image(systemName: headerIcon)
                .foregroundStyle(.secondary)
            Text(title)
                .font(.headline)
            Spacer(minLength: 8)
            if isSearching {
                ProgressView().controlSize(.small)
            } else {
                Text("\(sessions.count)")
                    .font(.system(.caption, design: .monospaced).weight(.medium))
                    .foregroundStyle(.tertiary)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(.fill.tertiary, in: Capsule())
            }
        }
        .padding(.horizontal, compact ? 16 : 20)
        .padding(.top, compact ? 14 : 18)
        .padding(.bottom, compact ? 10 : 14)
    }

    private func sessionList(compact: Bool, includesHeader: Bool) -> some View {
        GeometryReader { viewport in
            let minimumPreviewHeight: CGFloat = sessions.count == 1
                ? (compact ? 140 : 280)
                : (compact ? 100 : 150)
            // First reserve all session metadata and list padding. The selected
            // preview takes the remaining room; longer lists still scroll with
            // a usable minimum preview instead of squeezing the other rows.
            let previewHeight = hasSelectedPreview
                ? max(minimumPreviewHeight, viewport.size.height - (listDetailsHeight ?? viewport.size.height))
                : 0
            ScrollViewReader { proxy in
                ScrollView(.vertical) {
                    VStack(spacing: 0) {
                        if includesHeader {
                            header(compact: compact)
                            Divider().padding(.horizontal, 12)
                        }
                        if isPlaceholder {
                            placeholderBody(compact: compact)
                        } else {
                            VStack(spacing: 2) {
                                ForEach(Array(sessions.enumerated()), id: \.element.id) { index, session in
                                    sessionRow(session: session, isSelected: index == selectedIndex, compact: compact, previewHeight: previewHeight)
                                        .id(index)
                                        .onTapGesture { handleRowTap(session: session, index: index) }
                                        .accessibilityAddTraits(index == selectedIndex ? [.isSelected] : [])
                                }
                            }
                            .padding(.horizontal, 8)
                            .padding(.vertical, 6)
                        }
                    }
                    .onGeometryChange(for: CGFloat.self) {
                        max(0, $0.size.height - previewHeight)
                    } action: {
                        listDetailsHeight = $0
                    }
                }
                .scrollBounceBehavior(.basedOnSize)
                #if !os(visionOS)
                .scrollDismissesKeyboard(.never)
                #endif
                .onChange(of: selectedIndex) { _, index in
                    withAnimation(.easeOut(duration: 0.15)) {
                        proxy.scrollTo(index, anchor: .top)
                    }
                }
                .onGeometryChange(for: CGSize.self) { $0.size } action: { _ in
                    // Rotation, keyboard/toolbar changes and text sizing can all
                    // shrink the viewport. Keep metadata above a tall preview.
                    proxy.scrollTo(selectedIndex, anchor: .top)
                }
            }
        }
        .frame(minHeight: 0, maxHeight: .infinity)
    }

    @ViewBuilder
    private func footerHints(compact: Bool) -> some View {
        if KeyboardTracker.shared.isHardwareKeyboard {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: compact ? 8 : 16) {
                    hintBadge("Esc", label: "dismiss", compact: compact)
                    if !isPlaceholder {
                        hintBadge("\u{2191}\u{2193}", label: "navigate", compact: compact)
                        hintBadge("\u{21A9}", label: "attach", compact: compact)
                        if let jumpKeys = digitJumpKeys {
                            hintBadge(jumpKeys, label: "jump", compact: compact)
                        }
                    }
                }
                HStack(spacing: 8) {
                    hintBadge("Esc", label: "dismiss", compact: compact)
                    if !isPlaceholder {
                        hintBadge("\u{21A9}", label: "attach", compact: compact)
                    }
                }
            }
            .padding(.horizontal, compact ? 16 : 20)
            .padding(.vertical, compact ? 8 : 10)
        } else {
            Text(isPlaceholder
                 ? "Tap outside to dismiss"
                 : "Tap a session to select, tap Attach to connect")
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .padding(.horizontal, compact ? 16 : 20)
                .padding(.bottom, 8)
                .padding(.top, isPlaceholder ? 8 : 0)
        }
    }

    /// Stands in for the session list on a user-invoked run with no rows.
    @ViewBuilder
    private func placeholderBody(compact: Bool) -> some View {
        VStack(spacing: compact ? 6 : 8) {
            if isSearching {
                ProgressView()
                    .controlSize(.regular)
                Text("Searching for sessions…")
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.secondary)
            } else {
                Image(systemName: placeholderIcon)
                    .font(.system(size: compact ? 18 : 24, weight: .light))
                    .foregroundStyle(.tertiary)
                Text(placeholderTitle)
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.secondary)
                Text(placeholderDetail)
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .multilineTextAlignment(.center)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, compact ? 16 : 20)
        .padding(.vertical, compact ? 24 : 32)
    }

    private var placeholderIcon: String {
        switch placeholder {
        case .failed: return "exclamationmark.triangle"
        case .disabled: return "slider.horizontal.3"
        case .unsupported: return "minus.circle"
        default: return "magnifyingglass"
        }
    }

    private var placeholderTitle: String {
        switch placeholder {
        case .failed: return String(localized: "Could not check for sessions")
        case .disabled: return String(localized: "Session discovery is off")
        case .unsupported: return String(localized: "This tab cannot be checked")
        default: return String(localized: "No sessions found")
        }
    }

    private var placeholderDetail: String {
        switch placeholder {
        case .failed:
            return String(localized: "The host did not answer in time, or the connection could not be reused.")
        case .disabled:
            return String(localized: "Turn on discovery for tmux, zellij, herdr or zmx in Settings.")
        case .unsupported:
            // The local shell is only a discovery surface on unsandboxed Catalyst,
            // where the helper can run the scan.
            #if STANDALONE && targetEnvironment(macCatalyst)
            return String(localized: "Discovery needs an SSH connection or the local shell.")
            #else
            return String(localized: "Discovery needs an SSH connection.")
            #endif
        default:
            // Deliberately names no multiplexer: only the types still enabled in
            // Settings were scanned, so a fixed list would over-claim.
            return String(localized: "This host has no multiplexer sessions to attach to.")
        }
    }

    private func controlModeBinding(for session: MultiplexerSession) -> Binding<Bool>? {
        switch session.type {
        case .tmux where allowsTmuxControlAttach: return tmuxControlModeBinding
        case .herdr where allowsHerdrControlAttach: return herdrControlModeBinding
        default: return nil
        }
    }

    private func attachBar(for session: MultiplexerSession, compact: Bool) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            if !compact {
                selectedSessionLabel(session)
            }

            if let binding = controlModeBinding(for: session) {
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 12) {
                        controlModeToggle(binding, session: session)
                            .fixedSize(horizontal: true, vertical: false)
                        Spacer(minLength: 0)
                        attachButton(for: session)
                    }
                    VStack(alignment: .leading, spacing: 4) {
                        controlModeToggle(binding, session: session)
                        attachButton(for: session)
                            .frame(maxWidth: .infinity, alignment: .trailing)
                    }
                }
            } else {
                HStack(spacing: 12) {
                    if compact {
                        selectedSessionLabel(session)
                    }
                    Spacer(minLength: 0)
                    attachButton(for: session)
                }
            }
        }
        .padding(.horizontal, compact ? 16 : 20)
        .padding(.vertical, compact ? 4 : 8)
    }

    private func selectedSessionLabel(_ session: MultiplexerSession) -> some View {
        Label {
            Text(session.name)
                .font(.system(.caption, design: .monospaced).weight(.semibold))
                .lineLimit(1)
        } icon: {
            Image(systemName: session.type.iconName)
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .accessibilityLabel("Selected session: \(session.type.rawValue) \(session.name)")
    }

    private func controlModeToggle(_ binding: Binding<Bool>, session: MultiplexerSession) -> some View {
        Toggle("Control mode", isOn: binding)
            .font(.subheadline.weight(.medium))
            .toggleStyle(.switch)
            .fixedSize(horizontal: false, vertical: true)
            .frame(minHeight: 44)
            .accessibilityLabel("\(session.type.rawValue) control mode")
    }

    private func attachButton(for session: MultiplexerSession) -> some View {
        Button { handleAttach(session) } label: {
            Text("Attach")
                .font(.subheadline.weight(.semibold))
                .padding(.horizontal, 12)
                .frame(minWidth: 44, minHeight: 32)
                .background(.green, in: Capsule())
                .foregroundStyle(.white)
                .frame(minHeight: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .fixedSize()
        .accessibilityLabel("Attach to \(session.name)")
    }

    @ViewBuilder
    private func sessionRow(session: MultiplexerSession, isSelected: Bool, compact: Bool, previewHeight: CGFloat) -> some View {
        VStack(spacing: 0) {
            // Metadata row
            sessionRowMetadata(session: session, isSelected: isSelected, compact: compact)

            if isSelected, session.type == .herdr, allowsHerdrControlAttach,
               session.supportsControlStream == false {
                Text("No control stream; rootshell will use fallback mode. Install the rootshell herdr fork for full control mode.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.leading, compact ? 20 : 28)
                    .padding(.top, 4)
            }

            // Preview (only for selected row with captured content)
            if isSelected, let content = session.capturedContent, !content.isEmpty {
                let previewScale: CGFloat = 0.45
                let virtualHeight = previewHeight / previewScale

                GeometryReader { geo in
                    let virtualWidth = geo.size.width / previewScale

                    TmuxPreviewContainer(
                        content: content,
                        previewSize: CGSize(width: virtualWidth, height: virtualHeight)
                    )
                    .id(session.id)
                    .frame(width: virtualWidth, height: virtualHeight)
                    .scaleEffect(previewScale, anchor: .topLeading)
                }
                .frame(height: previewHeight)
                .clipped()
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                .padding(.horizontal, compact ? 8 : 14)
                .padding(.top, 6)
                .padding(.bottom, 4)
            }
        }
        .padding(.horizontal, compact ? 8 : 14)
        .padding(.vertical, compact ? 6 : 10)
        .frame(minHeight: 44)
        .background(
            isSelected
                ? AnyShapeStyle(.tint.opacity(0.12))
                : AnyShapeStyle(.clear),
            in: RoundedRectangle(cornerRadius: 8, style: .continuous)
        )
        .contentShape(Rectangle())
    }

    @ViewBuilder
    private func sessionRowMetadata(session: MultiplexerSession, isSelected: Bool, compact: Bool) -> some View {
        HStack(spacing: compact ? 8 : 12) {
            // Selection indicator
            Image(systemName: isSelected ? "chevron.right" : "")
                .font(.system(size: compact ? 10 : 13, weight: .bold))
                .foregroundStyle(.tint)
                .frame(width: compact ? 12 : 16)

            // Keep short metadata on one line. Long names and larger text
            // put status/detail below the identity instead of crushing it.
            VStack(alignment: .leading, spacing: 2) {
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 6) {
                        sessionIdentity(session, compact: compact)
                        sessionStatus(session)
                    }
                    .fixedSize(horizontal: true, vertical: false)

                    VStack(alignment: .leading, spacing: 2) {
                        sessionIdentity(session, compact: compact)
                        sessionStatus(session)
                    }
                }

                if let subtitle = session.subtitle {
                    Text(subtitle)
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }

            Spacer(minLength: 0)
        }
    }

    private func sessionIdentity(_ session: MultiplexerSession, compact: Bool) -> some View {
        HStack(spacing: 6) {
            Text(session.name)
                .font(.system(compact ? .subheadline : .body, design: .monospaced).weight(.semibold))
                .lineLimit(1)
                .layoutPriority(1)

            if isMixed {
                Text(session.type.rawValue)
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 4)
                    .padding(.vertical, 1)
                    .background(.fill.tertiary, in: Capsule())
                    .fixedSize()
            }
        }
    }

    private func sessionStatus(_ session: MultiplexerSession) -> some View {
        HStack(spacing: 6) {
            Text(statusText(for: session))
                .font(.caption.weight(.medium))
                .foregroundStyle(statusColor(for: session))
                .padding(.horizontal, 5)
                .padding(.vertical, 1)
                .background(statusColor(for: session).opacity(0.15), in: Capsule())
                .fixedSize()
            Text(session.detail)
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(.tertiary)
                .lineLimit(1)
        }
    }

    private func statusText(for session: MultiplexerSession) -> String {
        // herdr sessions have no attached-client notion; stopped ones are
        // resurrected by attach, so "exited"/"detached" would mislead.
        if session.type == .herdr { return session.isExited ? "stopped" : "running" }
        if session.isExited { return "exited" }
        return session.isAttached ? "attached" : "detached"
    }

    private func statusColor(for session: MultiplexerSession) -> Color {
        if session.type == .herdr { return session.isExited ? .secondary : .green }
        if session.isExited { return .red }
        return session.isAttached ? .orange : .green
    }

    @ViewBuilder
    private func hintBadge(_ key: String, label: String, compact: Bool = false) -> some View {
        HStack(spacing: compact ? 4 : 6) {
            Text(key)
                .font(.system(size: compact ? 10 : 12, weight: .medium, design: .monospaced))
                .padding(.horizontal, compact ? 4 : 6)
                .padding(.vertical, compact ? 2 : 3)
                .background(.fill.quaternary, in: RoundedRectangle(cornerRadius: 3))
            Text(label)
                .font(.system(size: compact ? 10 : 12))
                .foregroundStyle(.tertiary)
        }
    }

    /// Returns the digit key hint string if all session names are single digits (e.g. "0,2,5"),
    /// or nil if any session has a non-numeric name or there are too many to display.
    private var digitJumpKeys: String? {
        guard sessions.count <= 6 else { return nil }
        let digitNames = sessions.compactMap { s -> String? in
            let n = s.name
            guard n.count == 1, n.first?.isWholeNumber == true else { return nil }
            return n
        }
        guard digitNames.count == sessions.count else { return nil }
        return digitNames.joined(separator: ",")
    }

    private func handleRowTap(session: MultiplexerSession, index: Int) {
        if KeyboardTracker.shared.isHardwareKeyboard {
            // Hardware keyboard: tap attaches directly (same as Enter)
            handleAttach(session)
        } else {
            // Touch: tap selects the row; use Attach button to connect
            onChangeSelection(index)
        }
    }

    private func handleAttach(_ session: MultiplexerSession) {
        if hasUserTyped {
            pendingSession = session
            showAttachConfirmation = true
        } else {
            onSelect(session)
        }
    }

    private func attachDescription(for session: MultiplexerSession) -> String {
        if session.type == .tmux, tmuxAttachMode == .control, allowsTmuxControlAttach {
            return "tmux -CC attach"
        }
        if session.type == .herdr, herdrAttachMode == .control, allowsHerdrControlAttach {
            return "herdr control"
        }
        return "\(session.type.rawValue) attach"
    }
}
