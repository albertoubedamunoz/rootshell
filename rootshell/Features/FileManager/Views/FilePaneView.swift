//
//  FilePaneView.swift
//  rootshell
//
//  One pane: location header, filter field (the keyboard anchor), listing,
//  and the touch selection bar. Pointer and keyboard use click/cursor
//  semantics; touch taps open and an explicit Select mode multi-selects.
//

import SwiftUI
import UniformTypeIdentifiers

struct FilePaneView: View {
    @Bindable var pane: FilePaneModel
    @Bindable var manager: FileManagerModel
    let isActive: Bool
    /// False while the file manager is hidden, so the field never steals the keyboard back.
    let canFocus: Bool
    let columns: FileRowView.Columns
    let otherPaneName: String
    let onClose: () -> Void

    @State private var arrowRepeat = ArrowKeyRepeatManager()
    @State private var isSelecting = false
    @State private var lastClick: (path: String, time: Date)?
    @State private var fieldFocused = false
    @State private var isDropTargeted = false

    private var hasHardwareKeyboard: Bool { KeyboardTracker.shared.isHardwareKeyboard }

    private var usesPointerSemantics: Bool {
        #if targetEnvironment(macCatalyst)
        return true
        #else
        return hasHardwareKeyboard
        #endif
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            filterRow
            Divider()
            content
            if isSelecting || (!usesPointerSemantics && !pane.selection.isEmpty) {
                Divider()
                selectionBar
            }
        }
        .background(isDropTargeted ? Color.accentColor.opacity(0.08) : .clear)
        .overlay(alignment: .top) {
            if isActive {
                Rectangle().fill(Color.accentColor).frame(height: 2)
            }
        }
        .onDrop(of: FileManagerDragDrop.acceptedTypes, isTargeted: $isDropTargeted) { providers in
            manager.handleDrop(providers, onto: pane.id, directory: nil)
        }
        .onDisappear { arrowRepeat.stop() }
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 6) {
            Button { manager.sheet = .connect(pane.id) } label: {
                HStack(spacing: 6) {
                    Image(systemName: endpointSymbol)
                    Text(pane.endpoint.displayName).fontWeight(.semibold).lineLimit(1)
                    if pane.status == .connecting {
                        ProgressView().controlSize(.mini)
                    }
                    Image(systemName: "chevron.down").font(.caption2).foregroundStyle(.secondary)
                }
            }
            .help(FileManagerShortcut.shortcut(for: .connect).helpText)
            .accessibilityLabel(String(localized: "Location: \(pane.endpoint.displayName)", comment: "File manager endpoint button"))

            Spacer(minLength: 4)

            navButton("chevron.left", command: .back, enabled: pane.canGoBack) { pane.goBack() }
            navButton("chevron.right", command: .forward, enabled: pane.canGoForward) { pane.goForward() }
            navButton("arrow.up", command: .parent, enabled: !pane.path.isEmpty && pane.path != "/") { pane.goUp() }
            navButton("arrow.clockwise", command: .refresh, enabled: !pane.isBusy) { pane.refresh() }
            if !usesPointerSemantics {
                Button(isSelecting ? String(localized: "Done", comment: "File manager: leave selection mode") : String(localized: "Select", comment: "File manager: enter selection mode")) {
                    isSelecting.toggle()
                    if !isSelecting { pane.selection.clear() }
                }
                .font(.callout)
            }
        }
        .buttonStyle(.borderless)
        .padding(.horizontal, 10)
        .padding(.top, 8)
        .padding(.bottom, 4)
    }

    private func navButton(_ symbol: String, command: FileManagerCommand, enabled: Bool, action: @escaping () -> Void) -> some View {
        let shortcut = FileManagerShortcut.shortcut(for: command)
        return Button(action: {
            manager.activeSide = pane.id
            action()
        }) {
            Image(systemName: symbol).frame(width: 22, height: 22)
        }
        .disabled(!enabled)
        .help(shortcut.helpText)
        .accessibilityLabel(shortcut.title)
    }

    private var endpointSymbol: String {
        guard pane.endpoint.isLocal else { return "server.rack" }
        #if targetEnvironment(macCatalyst)
        return "laptopcomputer"
        #else
        return UIDevice.current.userInterfaceIdiom == .pad ? "ipad" : "iphone"
        #endif
    }

    // MARK: - Filter field

    private var filterRow: some View {
        HStack(spacing: 6) {
            breadcrumb
            Image(systemName: "line.3.horizontal.decrease").foregroundStyle(.secondary).font(.caption)
            SidebarSearchField(
                text: $pane.filterText,
                placeholder: String(localized: "Filter", comment: "File manager filter placeholder"),
                fontSize: 14,
                canFocus: canFocus && isActive,
                focusRequestID: isActive ? manager.focusRequestID : 0,
                onMoveUpBegan: { beginMove(-1, .up) },
                onMoveUpEnded: { arrowRepeat.stop(direction: .up) },
                onMoveDownBegan: { beginMove(1, .down) },
                onMoveDownEnded: { arrowRepeat.stop(direction: .down) },
                onEscape: handleEscape,
                onSubmit: {
                    arrowRepeat.stop()
                    // On touch, Return just closes the keyboard and keeps the filter.
                    guard hasHardwareKeyboard else { return dismissSoftwareKeyboard() }
                    if !manager.queueFocused { manager.openCursor() }
                },
                onFocusChange: { focused in
                    Task { @MainActor in
                        fieldFocused = focused
                        if focused { manager.activeSide = pane.id } else { arrowRepeat.stop() }
                    }
                },
                onModifiedSubmit: { manager.perform(.openInTerminal) },
                onTab: { arrowRepeat.stop(); manager.perform(.switchPane) },
                onBackTab: { arrowRepeat.stop(); pane.goUp() },
                extraCommands: keyCommands,
                onSelectAll: { manager.perform(.selectAll) },
                claimsKeyboard: true
            )
            .frame(height: 22)
            .frame(minWidth: 60, maxWidth: 180)
            .accessibilityLabel(String(localized: "Filter files", comment: "File manager filter accessibility"))
            if pane.status == .loading {
                ProgressView().controlSize(.mini)
            }
        }
        .padding(.horizontal, 10)
        .padding(.bottom, 6)
    }

    /// Ancestors of the current folder, tappable.
    private var breadcrumb: some View {
        Menu {
            ForEach(ancestors, id: \.self) { path in
                Button(path) { pane.navigate(to: path) }
            }
            Divider()
            Button(FileManagerShortcut.shortcut(for: .goToPath).title) { manager.sheet = .goToPath }
        } label: {
            Text(pane.path.isEmpty ? "…" : pane.path)
                .font(.caption.monospaced())
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.head)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .menuStyle(.button)
        .buttonStyle(.borderless)
    }

    private var ancestors: [String] {
        var result: [String] = []
        var current = pane.path
        while !current.isEmpty, current != "/" {
            result.append(current)
            current = FileTransferLogic.parent(of: current)
        }
        if !pane.path.isEmpty { result.append("/") }
        return result
    }

    private var keyCommands: [SidebarSearchExtraCommand] {
        var commands = FileManagerShortcut.paneCommands { command, chord in
            arrowRepeat.stop()
            switch command {
            case .extendSelection:
                pane.selection.moveCursor(by: chord.input == UIKeyCommand.inputUpArrow ? -1 : 1, in: pane.visiblePaths, extending: true)
            default:
                manager.perform(command)
            }
        }
        if pane.filterText.isEmpty {
            commands.append(SidebarSearchExtraCommand(input: " ", modifiers: [], title: FileManagerShortcut.shortcut(for: .toggleSelection).title) {
                manager.perform(.toggleSelection)
            })
        }
        if manager.queueFocused {
            commands.append(SidebarSearchExtraCommand(input: UIKeyCommand.inputDelete, modifiers: [], title: FileManagerShortcut.shortcut(for: .cancelJob).title) {
                manager.perform(.cancelJob)
            })
        }
        return commands
    }

    private func beginMove(_ delta: Int, _ direction: ArrowKeyRepeatManager.Direction) {
        let step = {
            if manager.queueFocused {
                manager.moveQueueCursor(by: delta)
            } else {
                pane.selection.moveCursor(by: delta, in: pane.visiblePaths, extending: false)
            }
        }
        step()
        arrowRepeat.start(direction: direction, action: step)
    }

    /// Esc unwinds one layer at a time: filter, queue focus, selection, then the panel.
    private func handleEscape() {
        arrowRepeat.stop()
        if !pane.filterText.isEmpty {
            pane.filterText = ""
        } else if manager.queueFocused {
            manager.queueFocused = false
        } else if !pane.selection.isEmpty {
            pane.selection.clear()
            isSelecting = false
        } else {
            onClose()
        }
    }

    // MARK: - Listing

    @ViewBuilder
    private var content: some View {
        switch pane.status {
        case .connecting where pane.entries.isEmpty:
            statusView {
                ProgressView()
                Text("Connecting to \(pane.endpoint.displayName)…").foregroundStyle(.secondary)
            }
        case .failed(let message):
            statusView {
                Image(systemName: "exclamationmark.triangle").font(.title2).foregroundStyle(.orange)
                Text(message).multilineTextAlignment(.center).foregroundStyle(.secondary).textSelection(.enabled)
                HStack {
                    Button(String(localized: "Retry", comment: "File manager: retry listing")) {
                        pane.path.isEmpty ? pane.connect(to: pane.endpoint) : pane.refresh()
                    }
                    Button(String(localized: "Choose Location", comment: "File manager: pick another endpoint")) {
                        manager.sheet = .connect(pane.id)
                    }
                }
                .buttonStyle(.bordered)
            }
        default:
            if pane.visibleEntries.isEmpty && pane.status == .idle {
                statusView {
                    Text(pane.filterText.isEmpty
                         ? String(localized: "Empty folder", comment: "File manager: no files")
                         : String(localized: "No matches", comment: "File manager: filter matched nothing"))
                        .foregroundStyle(.secondary)
                }
            } else {
                list
            }
        }
    }

    private func statusView<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        VStack(spacing: 10, content: content)
            .padding()
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var list: some View {
        ScrollViewReader { proxy in
            ScrollView {
                if columns == .detailed { columnHeader }
                LazyVStack(spacing: 1) {
                    ForEach(pane.visibleEntries, id: \.path) { entry in
                        row(entry)
                    }
                }
                .padding(.horizontal, 6)
                .padding(.vertical, 4)
            }
            // With a hardware keyboard the field must keep focus while the list scrolls.
            .scrollDismissesKeyboard(hasHardwareKeyboard ? .never : .immediately)
            .onChange(of: pane.selection.cursor) { _, cursor in
                guard let cursor else { return }
                proxy.scrollTo(cursor)
            }
        }
    }

    private var columnHeader: some View {
        HStack(spacing: 8) {
            sortButton(String(localized: "Name", comment: "File manager column"), ascending: .nameAsc, descending: .nameDesc)
            Spacer()
            sortButton(String(localized: "Size", comment: "File manager column"), ascending: .sizeAsc, descending: .sizeDesc)
                .frame(width: 70, alignment: .trailing)
            sortButton(String(localized: "Modified", comment: "File manager column"), ascending: .modifiedAsc, descending: .modifiedDesc)
                .frame(width: 118, alignment: .trailing)
            Text("Mode").frame(width: 84, alignment: .trailing)
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 16)
        .padding(.top, 4)
    }

    private func sortButton(_ title: String, ascending: RFSortOrder, descending: RFSortOrder) -> some View {
        Button {
            pane.sortOrder = pane.sortOrder == ascending ? descending : ascending
        } label: {
            HStack(spacing: 2) {
                Text(title)
                if pane.sortOrder == ascending { Image(systemName: "chevron.up") }
                if pane.sortOrder == descending { Image(systemName: "chevron.down") }
            }
        }
        .buttonStyle(.plain)
    }

    private func row(_ entry: RFEntry) -> some View {
        FileRowView(
            entry: entry,
            isSelected: pane.selection.contains(entry.path),
            isCursor: pane.selection.cursor == entry.path,
            showsCursor: isActive && (fieldFocused || usesPointerSemantics),
            showsCheckbox: isSelecting,
            columns: columns
        )
        .id(entry.path)
        .onTapGesture { tap(entry) }
        .contextMenu { contextMenu(for: entry) }
        .onDrag { manager.beginDrag(of: dragEntries(for: entry), from: pane.id) }
        .onDrop(of: entry.isDirectory ? FileManagerDragDrop.acceptedTypes : [], isTargeted: nil) { providers in
            manager.handleDrop(providers, onto: pane.id, directory: entry.path)
        }
    }

    private func dragEntries(for entry: RFEntry) -> [RFEntry] {
        pane.selection.contains(entry.path) ? pane.actionEntries : [entry]
    }

    /// Touch has no Esc, so the filter gives up the on-screen keyboard on
    /// Return, on a row tap, and when the list scrolls.
    private func dismissSoftwareKeyboard() {
        guard !hasHardwareKeyboard else { return }
        UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
    }

    private func tap(_ entry: RFEntry) {
        manager.activeSide = pane.id
        manager.requestFocus()
        dismissSoftwareKeyboard()
        if isSelecting {
            pane.selection.toggle(entry.path)
            return
        }
        let flags = KeyboardTracker.shared.hardwareModifierFlags
        if flags.contains(.command) {
            pane.selection.click(entry.path, in: pane.visiblePaths, modifier: .toggle)
        } else if flags.contains(.shift) {
            pane.selection.click(entry.path, in: pane.visiblePaths, modifier: .range)
        } else if usesPointerSemantics {
            let now = Date()
            if let lastClick, lastClick.path == entry.path, now.timeIntervalSince(lastClick.time) < 0.4 {
                self.lastClick = nil
                open(entry)
            } else {
                pane.selection.click(entry.path, in: pane.visiblePaths, modifier: .none)
                lastClick = (entry.path, now)
            }
        } else {
            pane.selection.setCursor(entry.path)
            open(entry)
        }
    }

    private func open(_ entry: RFEntry) {
        if !pane.open(entry) { manager.preview(entry, in: pane) }
    }

    @ViewBuilder
    private func contextMenu(for entry: RFEntry) -> some View {
        let targets = dragEntries(for: entry)
        let plural = targets.count > 1
        Button { open(entry) } label: {
            Label(entry.isDirectory ? String(localized: "Open", comment: "File manager context menu") : FileManagerShortcut.shortcut(for: .quickLook).title,
                  systemImage: entry.isDirectory ? "folder" : "eye")
        }
        Divider()
        Button { manager.transferToOther(move: false, entries: targets, from: pane.id) } label: {
            Label(String(localized: "Copy to \(otherPaneName)", comment: "File manager context menu; argument is the other pane's location"), systemImage: "doc.on.doc")
        }
        Button { manager.transferToOther(move: true, entries: targets, from: pane.id) } label: {
            Label(String(localized: "Move to \(otherPaneName)", comment: "File manager context menu; argument is the other pane's location"), systemImage: "arrow.right.doc.on.clipboard")
        }
        Divider()
        if !plural {
            Button { manager.activeSide = pane.id; manager.sheet = .rename(entry) } label: {
                Label(FileManagerShortcut.shortcut(for: .rename).title, systemImage: "pencil")
            }
            Button { manager.activeSide = pane.id; manager.sheet = .info(entry) } label: {
                Label(FileManagerShortcut.shortcut(for: .info).title, systemImage: "info.circle")
            }
        }
        if entry.isDirectory, manager.openInTerminal != nil {
            Button { manager.activeSide = pane.id; pane.selection.setCursor(entry.path); manager.perform(.openInTerminal) } label: {
                Label(FileManagerShortcut.shortcut(for: .openInTerminal).title, systemImage: "terminal")
            }
        }
        Divider()
        Button(role: .destructive) { manager.activeSide = pane.id; manager.sheet = .confirmDelete(targets) } label: {
            Label(FileManagerShortcut.shortcut(for: .delete).title, systemImage: "trash")
        }
    }

    // MARK: - Touch selection bar

    private var selectionBar: some View {
        let count = pane.selection.count
        return HStack(spacing: 14) {
            Text("\(count) selected").font(.callout).foregroundStyle(.secondary)
            Spacer()
            Button { pane.selection.selectAll(pane.visiblePaths) } label: { Image(systemName: "checkmark.circle") }
                .accessibilityLabel(FileManagerShortcut.shortcut(for: .selectAll).title)
            Button { manager.activeSide = pane.id; manager.transferToOther(move: false); isSelecting = false } label: {
                Image(systemName: "doc.on.doc")
            }
            .accessibilityLabel(FileManagerShortcut.shortcut(for: .copyToOther).title)
            Button { manager.activeSide = pane.id; manager.transferToOther(move: true); isSelecting = false } label: {
                Image(systemName: "arrow.right.doc.on.clipboard")
            }
            .accessibilityLabel(FileManagerShortcut.shortcut(for: .moveToOther).title)
            Button(role: .destructive) {
                manager.activeSide = pane.id
                let entries = pane.actionEntries
                if !entries.isEmpty { manager.sheet = .confirmDelete(entries) }
            } label: {
                Image(systemName: "trash")
            }
            .accessibilityLabel(FileManagerShortcut.shortcut(for: .delete).title)
        }
        .disabled(count == 0)
        .buttonStyle(.borderless)
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
    }
}
