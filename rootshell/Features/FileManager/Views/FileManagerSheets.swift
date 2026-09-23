//
//  FileManagerSheets.swift
//  rootshell
//
//  Sheets presented by the file manager: location picker, name and path
//  entry, info and permissions, conflict resolution, shortcuts, and the
//  interactive auth prompts. All work fully from the keyboard.
//

import SwiftUI

// MARK: - Locations

/// A place the file manager can open: this device, the origin pane's session, or an SSH profile.
struct FileManagerLocation: Identifiable {
    let id: String
    let endpoint: SFTPEndpoint
    let title: String
    let detail: String?
    let symbol: String

    static func all(origin: SFTPEndpoint.PaneSource?) -> [FileManagerLocation] {
        var result: [FileManagerLocation] = [
            FileManagerLocation(id: "local", endpoint: .local, title: SFTPEndpoint.local.displayName, detail: nil, symbol: "internaldrive"),
        ]
        if let origin, origin.terminal != nil, !SFTPEndpoint.pane(origin).isLocal {
            result.append(FileManagerLocation(
                id: "pane", endpoint: .pane(origin), title: origin.displayName,
                detail: String(localized: "Current terminal connection", comment: "File manager location picker: reuse the pane's session"),
                symbol: "rectangle.connected.to.line.below"
            ))
        }
        let profiles = ConnectionProfileManager.shared.profiles
            .filter { !$0.isDeleted && $0.isSSHBased && $0.isAvailableOnCurrentPlatform }
            .sorted { ($0.lastUsedAt ?? .distantPast) > ($1.lastUsedAt ?? .distantPast) }
        for profile in profiles {
            let host = "\(profile.sshConfig.username)@\(profile.sshConfig.host)"
            let via = profile.sshConfig.jumpHost.map { String(localized: " via \($0.host)", comment: "File manager location picker: jump host suffix") } ?? ""
            let transport = profile.connectionProtocol == .trzsz ? " · tssh" : ""
            result.append(FileManagerLocation(
                id: profile.id.uuidString, endpoint: .profile(profile.id), title: profile.name,
                detail: host + via + transport, symbol: profile.iconName ?? profile.connectionProtocol.iconName
            ))
        }
        return result
    }

    func matches(_ query: String) -> Bool {
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return true }
        return title.localizedCaseInsensitiveContains(trimmed) || (detail?.localizedCaseInsensitiveContains(trimmed) ?? false)
    }
}

// MARK: - Location picker

struct EndpointPickerSheet: View {
    let manager: FileManagerModel
    let side: FilePaneModel.Side
    let onDismiss: () -> Void

    @State private var query = ""
    @State private var cursor = 0
    @State private var focusRequest = 1
    @State private var arrowRepeat = ArrowKeyRepeatManager()
    @Environment(\.sheetThemeColors) private var sheetThemeColors

    private var choices: [FileManagerLocation] {
        FileManagerLocation.all(origin: manager.originPane).filter { $0.matches(query) }
    }

    var body: some View {
        let choices = choices
        NavigationStack {
            VStack(spacing: 0) {
                HStack {
                    Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                    SidebarSearchField(
                        text: $query,
                        placeholder: String(localized: "Search profiles", comment: "File manager location picker placeholder"),
                        fontSize: 16,
                        canFocus: true,
                        focusRequestID: KeyboardTracker.shared.isHardwareKeyboard ? focusRequest : 0,
                        onMoveUpBegan: { move(-1, .up, count: choices.count) },
                        onMoveUpEnded: { arrowRepeat.stop(direction: .up) },
                        onMoveDownBegan: { move(1, .down, count: choices.count) },
                        onMoveDownEnded: { arrowRepeat.stop(direction: .down) },
                        onEscape: onDismiss,
                        onSubmit: { if choices.indices.contains(cursor) { choose(choices[cursor]) } },
                        onFocusChange: { _ in }
                    )
                    .frame(height: 24)
                }
                .padding(10)
                .background(.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 8))
                .padding()

                ScrollViewReader { proxy in
                    List {
                        ForEach(Array(choices.enumerated()), id: \.element.id) { index, choice in
                            Button { choose(choice) } label: {
                                HStack(spacing: 12) {
                                    Image(systemName: choice.symbol).frame(width: 24).foregroundStyle(Color.accentColor)
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(choice.title).foregroundStyle(.primary)
                                        if let detail = choice.detail {
                                            Text(detail).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                                        }
                                    }
                                    Spacer()
                                    if manager.pane(side).endpoint == choice.endpoint {
                                        Image(systemName: "checkmark").foregroundStyle(Color.accentColor)
                                    }
                                }
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .listRowBackground(index == cursor ? Color.accentColor.opacity(0.15) : sheetThemeColors?.rowBackground)
                            .id(choice.id)
                        }
                    }
                    .listStyle(.plain)
                    .themedList()
                    .onChange(of: cursor) { _, index in
                        if choices.indices.contains(index) { proxy.scrollTo(choices[index].id) }
                    }
                }
            }
            .background(sheetThemeColors?.background.ignoresSafeArea())
            .navigationTitle(String(localized: "Choose Location", comment: "File manager location picker title"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(String(localized: "Cancel", comment: "Cancel button"), action: onDismiss)
                }
            }
            .onChange(of: query) { _, _ in cursor = 0 }
            .onDisappear { arrowRepeat.stop() }
        }
    }

    private func move(_ delta: Int, _ direction: ArrowKeyRepeatManager.Direction, count: Int) {
        let step = { cursor = min(max(cursor + delta, 0), max(0, count - 1)) }
        step()
        arrowRepeat.start(direction: direction, action: step)
    }

    private func choose(_ choice: FileManagerLocation) {
        arrowRepeat.stop()
        manager.pane(side).connect(to: choice.endpoint)
        manager.activeSide = side
        if case .profile(let id) = choice.endpoint { ConnectionProfileManager.shared.recordUsage(id: id) }
        onDismiss()
    }
}

// MARK: - Name / path entry

struct FileNameEntrySheet: View {
    let title: String
    let actionTitle: String
    let initialText: String
    let placeholder: String
    let onSubmit: (String) -> Void
    let onCancel: () -> Void

    @State private var text = ""
    @FocusState private var focused: Bool

    var body: some View {
        NavigationStack {
            Form {
                TextField(placeholder, text: $text)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .focused($focused)
                    .onSubmit(submit)
                    .themedRow()
            }
            .themedList()
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(String(localized: "Cancel", comment: "Cancel button"), action: onCancel)
                        .keyboardShortcut(.cancelAction)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(actionTitle, action: submit)
                        .keyboardShortcut(.defaultAction)
                        .disabled(text.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
        }
        .presentationDetents([.height(200)])
        .onAppear {
            text = initialText
            focused = true
        }
    }

    private func submit() {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        onSubmit(trimmed)
    }
}

// MARK: - Info and permissions

struct FileInfoSheet: View {
    let entry: RFEntry
    let endpointName: String
    let onApplyPermissions: (UInt32) -> Void
    let onDismiss: () -> Void

    @State private var mode: UInt32 = 0

    private struct PermissionRow {
        let label: String
        let masks: [UInt32]
    }

    private static let bits = [
        PermissionRow(label: String(localized: "Owner", comment: "File permissions row"), masks: [0o400, 0o200, 0o100]),
        PermissionRow(label: String(localized: "Group", comment: "File permissions row"), masks: [0o040, 0o020, 0o010]),
        PermissionRow(label: String(localized: "Everyone", comment: "File permissions row"), masks: [0o004, 0o002, 0o001]),
    ]

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    row(String(localized: "Location", comment: "File info label"), "\(endpointName):\(entry.path)")
                    if !entry.isDirectory {
                        row(String(localized: "Size", comment: "File info label"),
                            "\(FileRowView.sizeText(entry.size)) (\(entry.size.formatted()) bytes)")
                    }
                    if let date = entry.modifiedDate {
                        row(String(localized: "Modified", comment: "File info label"), FileRowView.dateText(date))
                    }
                    if let owner = entry.owner {
                        row(String(localized: "Owner", comment: "File info label"), owner)
                    }
                    if let target = entry.symlinkTarget {
                        row(String(localized: "Link Target", comment: "File info label"), target)
                    }
                }
                if entry.permissions != nil {
                    Section(String(localized: "Permissions", comment: "File info section")) {
                        Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 8) {
                            GridRow {
                                Text("")
                                Text("Read").font(.caption)
                                Text("Write").font(.caption)
                                Text("Execute").font(.caption)
                            }
                            ForEach(Self.bits, id: \.label) { row in
                                GridRow {
                                    Text(row.label)
                                    ForEach(row.masks, id: \.self) { mask in
                                        Toggle("", isOn: binding(for: mask)).labelsHidden()
                                    }
                                }
                            }
                        }
                        .themedRow()
                        HStack {
                            Text(String(format: "%04o", mode & 0o7777)).font(.body.monospaced())
                            Text(FileRowView.permissionsText(mode)).font(.body.monospaced()).foregroundStyle(.secondary)
                        }
                        .themedRow()
                    }
                }
            }
            .themedList()
            .navigationTitle(entry.name)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(String(localized: "Close", comment: "Close button"), action: onDismiss)
                        .keyboardShortcut(.cancelAction)
                }
                if entry.permissions != nil {
                    ToolbarItem(placement: .confirmationAction) {
                        Button(String(localized: "Apply", comment: "File info: apply permissions")) {
                            onApplyPermissions(mode & 0o7777)
                            onDismiss()
                        }
                        .keyboardShortcut(.defaultAction)
                        .disabled(mode & 0o7777 == (entry.permissions ?? 0) & 0o7777)
                    }
                }
            }
        }
        .onAppear { mode = entry.permissions ?? 0 }
    }

    private func row(_ label: String, _ value: String) -> some View {
        LabeledContent(label) {
            Text(value).textSelection(.enabled).multilineTextAlignment(.trailing)
        }
        .themedRow()
    }

    private func binding(for mask: UInt32) -> Binding<Bool> {
        Binding(
            get: { mode & mask != 0 },
            set: { isOn in mode = isOn ? mode | mask : mode & ~mask }
        )
    }
}

// MARK: - Conflicts

struct TransferConflictSheet: View {
    let question: FileTransferCenter.ConflictQuestion
    @State private var applyToAll = false
    @Environment(\.sheetThemeColors) private var sheetThemeColors
    private var center: FileTransferCenter { .shared }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label {
                Text("“\(question.name)” already exists in \(question.destinationDirectory).")
                    .font(.headline)
                    .fixedSize(horizontal: false, vertical: true)
            } icon: {
                Image(systemName: "doc.on.doc").foregroundStyle(.orange)
            }
            Text(question.job.title).font(.caption).foregroundStyle(.secondary)
            Toggle(String(localized: "Apply to all conflicts in this transfer", comment: "File transfer conflict option"), isOn: $applyToAll)
            HStack {
                Button(String(localized: "Stop", comment: "File transfer conflict: cancel the job"), role: .cancel) {
                    center.cancelConflict()
                }
                .keyboardShortcut(.cancelAction)
                Spacer()
                Button(String(localized: "Skip", comment: "File transfer conflict: skip item")) { answer(.skip) }
                    .keyboardShortcut("s", modifiers: [])
                Button(String(localized: "Keep Both", comment: "File transfer conflict: keep both")) { answer(.keepBoth) }
                    .keyboardShortcut("k", modifiers: [])
                if question.isDirectory {
                    Button(String(localized: "Merge", comment: "File transfer conflict: merge folders")) { answer(.merge) }
                        .keyboardShortcut("m", modifiers: [])
                }
                Button(String(localized: "Replace", comment: "File transfer conflict: overwrite")) { answer(.replace) }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
            }
            .buttonStyle(.bordered)
        }
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(sheetThemeColors?.background.ignoresSafeArea())
        .presentationDetents([.height(210)])
        .interactiveDismissDisabled()
    }

    private func answer(_ resolution: TransferConflictResolution) {
        center.resolveConflict(resolution, applyToAll: applyToAll)
    }
}

// MARK: - Shortcuts

struct FileManagerShortcutsSheet: View {
    let onDismiss: () -> Void

    var body: some View {
        NavigationStack {
            List {
                ForEach(FileManagerShortcut.Group.allCases, id: \.self) { group in
                    Section(group.title) {
                        ForEach(FileManagerShortcut.all.filter { $0.group == group }, id: \.command) { shortcut in
                            HStack {
                                Text(shortcut.title)
                                Spacer()
                                Text(shortcut.glyph)
                                    .font(.callout.monospaced())
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 2)
                                    .background(.fill.quaternary, in: RoundedRectangle(cornerRadius: 4))
                            }
                            .themedRow()
                        }
                    }
                }
                Section {
                    shortcutRow(
                        String(localized: "Open or close the file manager", comment: "File manager shortcut list"),
                        glyph: KeybindManager.shared.sequence(for: .toggle_file_manager)?.symbolDescription ?? "—"
                    )
                    .themedRow()
                }
            }
            .themedList()
            .navigationTitle(String(localized: "Keyboard Shortcuts", comment: "File manager shortcuts sheet title"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button(String(localized: "Done", comment: "Done button"), action: onDismiss)
                        .keyboardShortcut(.defaultAction)
                }
            }
        }
    }

    private func shortcutRow(_ title: String, glyph: String) -> some View {
        HStack {
            Text(title)
            Spacer()
            Text(glyph).font(.callout.monospaced()).foregroundStyle(.secondary)
        }
    }
}

// MARK: - Auth prompts

struct FileManagerPromptSheet: View {
    let request: FileManagerPrompts.Request
    let prompts: FileManagerPrompts

    @State private var password = ""
    @FocusState private var passwordFocused: Bool

    var body: some View {
        switch request {
        case .keyboardInteractive(let challenge, let label):
            KeyboardInteractivePromptView(
                challenge: challenge,
                sessionLabel: label,
                onSubmit: { prompts.respond(.responses($0)) },
                onCancel: { prompts.respond(.cancelled) }
            )
        case .keyResolution(let config, let keys, let profileID):
            KeyResolutionSheet(
                unresolvedKeys: keys,
                config: config,
                profileID: profileID,
                connectionIdentity: nil,
                onResolved: { prompts.respond(.config($0)) },
                onCancel: { prompts.respond(.cancelled) }
            )
        case .password(let label):
            NavigationStack {
                Form {
                    SecureField(String(localized: "Password", comment: "Password field"), text: $password)
                        .textContentType(.password)
                        .focused($passwordFocused)
                        .onSubmit { prompts.respond(.password(password)) }
                        .themedRow()
                }
                .themedList()
                .navigationTitle(label)
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button(String(localized: "Cancel", comment: "Cancel button")) { prompts.respond(.cancelled) }
                            .keyboardShortcut(.cancelAction)
                    }
                    ToolbarItem(placement: .confirmationAction) {
                        Button(String(localized: "Connect", comment: "Password prompt: connect")) { prompts.respond(.password(password)) }
                            .keyboardShortcut(.defaultAction)
                            .disabled(password.isEmpty)
                    }
                }
            }
            .presentationDetents([.height(200)])
            .onAppear { passwordFocused = true }
        }
    }
}
