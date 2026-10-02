//
//  CaptureSessionsView.swift
//  rootshell
//
//  Saved capture sessions: open, rename, export, delete.
//

#if !CHINA_BUILD

import SwiftUI

struct CaptureSessionsView: View {
    let model: HTTPCaptureModel
    @Environment(\.dismiss) private var dismiss
    @State private var renaming: CaptureSessionMeta?
    @State private var newName = ""
    @State private var confirmDeleteAll = false

    private var store: CaptureSessionStore { .shared }

    var body: some View {
        List {
            if store.sessions.isEmpty {
                Text(String(localized: "No capture sessions yet.", comment: "HTTP capture sessions empty")).foregroundStyle(.secondary)
                    .themedRow()
            }
            ForEach(store.sessions) { meta in
                Button {
                    model.open(sessionID: meta.id)
                    dismiss()
                } label: {
                    row(meta)
                }
                .buttonStyle(.plain)
                .contextMenu { actions(meta) }
                .swipeActions {
                    if !meta.isRecording {
                        Button(role: .destructive) {
                            Task { await store.delete(meta.id) }
                        } label: { Label(String(localized: "Delete", comment: "Delete button"), systemImage: "trash") }
                    }
                }
                .themedRow()
            }
        }
        .themedList()
        .navigationTitle(String(localized: "Capture Sessions", comment: "HTTP capture sessions title"))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button(String(localized: "Done", comment: "Done button")) { dismiss() }
            }
            ToolbarItem(placement: .primaryAction) {
                Menu {
                    Button(role: .destructive) { confirmDeleteAll = true } label: {
                        Label(String(localized: "Delete All Sessions", comment: "HTTP capture action"), systemImage: "trash")
                    }
                } label: { Image(systemName: "ellipsis.circle") }
            }
        }
        .alert(String(localized: "Rename Session", comment: "HTTP capture rename alert"), isPresented: renameBinding) {
            TextField(String(localized: "Name", comment: "HTTP capture session name field"), text: $newName)
            Button(String(localized: "Save", comment: "Save button")) {
                if let meta = renaming, !newName.trimmingCharacters(in: .whitespaces).isEmpty {
                    store.rename(meta.id, to: newName)
                }
                renaming = nil
            }
            Button(String(localized: "Cancel", comment: "Cancel button"), role: .cancel) { renaming = nil }
        }
        .confirmationDialog(String(localized: "Delete all finished sessions?", comment: "HTTP capture delete-all confirmation"),
                            isPresented: $confirmDeleteAll, titleVisibility: .visible) {
            Button(String(localized: "Delete All", comment: "HTTP capture delete-all button"), role: .destructive) {
                Task { await store.deleteAll() }
            }
        }
        .onAppear { store.reload() }
    }

    private func row(_ meta: CaptureSessionMeta) -> some View {
        HStack(spacing: 10) {
            Image(systemName: meta.isRecording ? "record.circle.fill" : "doc.text.magnifyingglass")
                .foregroundStyle(meta.isRecording ? .red : .secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text(meta.name).font(.body.weight(model.sessionID == meta.id ? .semibold : .regular))
                Text(details(meta)).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
        }
        .contentShape(Rectangle())
    }

    private func details(_ meta: CaptureSessionMeta) -> String {
        var parts = [meta.createdAt.formatted(date: .abbreviated, time: .shortened)]
        if let profile = meta.profileName { parts.append(profile) }
        if let size = meta.byteSize { parts.append(CaptureFormat.bytes(size)) }
        if meta.isRecording { parts.append(String(localized: "Recording", comment: "HTTP capture session state")) }
        return parts.joined(separator: " · ")
    }

    @ViewBuilder
    private func actions(_ meta: CaptureSessionMeta) -> some View {
        Button {
            newName = meta.name
            renaming = meta
        } label: { Label(String(localized: "Rename", comment: "Rename button"), systemImage: "pencil") }
        CaptureSessionExportMenu(meta: meta, model: model)
        if !meta.isRecording {
            Button(role: .destructive) {
                Task { await store.delete(meta.id) }
            } label: { Label(String(localized: "Delete", comment: "Delete button"), systemImage: "trash") }
        }
    }

    private var renameBinding: Binding<Bool> {
        Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })
    }
}

#endif
