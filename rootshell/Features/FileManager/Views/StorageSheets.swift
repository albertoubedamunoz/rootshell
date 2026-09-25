//
//  StorageSheets.swift
//  rootshell
//
//  Sheets only S3 storage panes offer: object info with editable headers and
//  metadata, presigned share links, and a bucket's incomplete uploads.
//

import SwiftUI
import UIKit

private extension FilePaneModel {
    func storageFileSystem() async throws -> S3FileSystem {
        guard let s3 = try await fileSystem().s3 else {
            throw StorageError.unsupported(String(localized: "This location isn't cloud storage.", comment: "Storage error"))
        }
        return s3
    }
}

// MARK: - Object info

struct StorageObjectInfoSheet: View {
    let entry: RFEntry
    let pane: FilePaneModel
    let onDismiss: () -> Void

    @State private var details: S3ObjectDetails?
    @State private var headers = S3ObjectHeaders()
    @State private var fields: [MetadataField] = []
    @State private var loadError: String?
    @State private var saveError: String?
    @State private var isSaving = false

    private struct MetadataField: Identifiable {
        let id = UUID()
        var key = ""
        var value = ""
    }

    private var edited: S3ObjectHeaders {
        var result = headers
        for keyPath in [\S3ObjectHeaders.contentType, \.cacheControl, \.contentDisposition, \.contentEncoding, \.contentLanguage] {
            result[keyPath: keyPath] = result[keyPath: keyPath].trimmingCharacters(in: .whitespaces)
        }
        let pairs = fields
            .map { ($0.key.trimmingCharacters(in: .whitespaces).lowercased(), $0.value.trimmingCharacters(in: .whitespaces)) }
            .filter { !$0.0.isEmpty }
        result.metadata = Dictionary(pairs, uniquingKeysWith: { _, last in last })
        return result
    }

    private var isValid: Bool {
        let edited = edited
        let headerValues = [edited.contentType, edited.cacheControl, edited.contentDisposition, edited.contentEncoding, edited.contentLanguage]
        return headerValues.allSatisfy(S3KeyLogic.isValidHeaderValue)
            && fields.allSatisfy { field in
                let key = field.key.trimmingCharacters(in: .whitespaces)
                return (key.isEmpty && field.value.isEmpty) || S3KeyLogic.isValidMetadata(key: key, value: field.value.trimmingCharacters(in: .whitespaces))
            }
    }

    private var hasChanges: Bool {
        details.map { edited != $0.headers } ?? false
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    row(String(localized: "Location", comment: "File info label"), "\(pane.endpoint.displayName):\(entry.path)")
                    let size = details?.size ?? entry.size
                    row(String(localized: "Size", comment: "File info label"), "\(FileRowView.sizeText(size)) (\(size.formatted()) bytes)")
                    if let date = details?.modified ?? entry.modifiedDate {
                        row(String(localized: "Modified", comment: "File info label"), FileRowView.dateText(date))
                    }
                    if let details {
                        objectRows(details)
                    }
                }
                if details != nil {
                    headerSection
                    metadataSection
                } else if let loadError {
                    Section { Text(loadError).foregroundStyle(.red).themedRow() }
                } else {
                    Section { ProgressView().frame(maxWidth: .infinity).themedRow() }
                }
                if let saveError {
                    Section { Text(saveError).foregroundStyle(.red).themedRow() }
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
                ToolbarItem(placement: .confirmationAction) {
                    if isSaving {
                        ProgressView()
                    } else {
                        Button(String(localized: "Save", comment: "Storage object info: save headers and metadata"), action: save)
                            .keyboardShortcut(.defaultAction)
                            .disabled(!hasChanges || !isValid)
                    }
                }
            }
        }
        .task { await load() }
    }

    @ViewBuilder
    private func objectRows(_ details: S3ObjectDetails) -> some View {
        if let eTag = details.eTag {
            row(String(localized: "ETag", comment: "Storage object info label"), eTag)
        }
        row(String(localized: "Storage Class", comment: "Storage object info label"), details.storageClass)
        if let encryption = details.encryption {
            row(String(localized: "Encryption", comment: "Storage object info label"), Self.encryptionName(encryption))
        }
        if let key = details.kmsKeyID {
            row(String(localized: "KMS Key", comment: "Storage object info label"), key)
        }
        if let version = details.versionID {
            row(String(localized: "Version", comment: "Storage object info label"), version)
        }
        if details.tagCount > 0 {
            row(String(localized: "Tags", comment: "Storage object info label"), details.tagCount.formatted())
        }
        switch S3KeyLogic.restoreState(details.restore) {
        case .inProgress:
            row(String(localized: "Archive", comment: "Storage object info label"),
                String(localized: "Restore in progress", comment: "Storage object archive state"))
        case .restored(let until):
            row(String(localized: "Archive", comment: "Storage object info label"), until.map {
                String(localized: "Restored until \(FileRowView.dateText($0))", comment: "Storage object archive state; argument is a date")
            } ?? String(localized: "Restored", comment: "Storage object archive state"))
        case .none:
            if details.isArchived {
                row(String(localized: "Archive", comment: "Storage object info label"),
                    String(localized: "Archived; restore it before downloading", comment: "Storage object archive state"))
            }
        }
    }

    private var headerSection: some View {
        Section {
            headerField("Content-Type", text: $headers.contentType, placeholder: "application/octet-stream")
            headerField("Cache-Control", text: $headers.cacheControl, placeholder: "max-age=3600")
            headerField("Content-Disposition", text: $headers.contentDisposition, placeholder: "attachment")
            headerField("Content-Encoding", text: $headers.contentEncoding, placeholder: "gzip")
            headerField("Content-Language", text: $headers.contentLanguage, placeholder: "en")
        } header: {
            Text("Headers", comment: "Storage object info section")
        } footer: {
            Text("Saving rewrites the object in place, as a new version if the bucket keeps versions. Storage class, encryption, tags and permissions are kept.",
                 comment: "Storage object info: what saving headers does")
        }
    }

    private var metadataSection: some View {
        Section {
            ForEach($fields) { $field in
                HStack {
                    TextField(String(localized: "Name", comment: "Storage metadata field name placeholder"), text: $field.key)
                        .font(.body.monospaced())
                    TextField(String(localized: "Value", comment: "Storage metadata field value placeholder"), text: $field.value)
                    Button(role: .destructive) { fields.removeAll { $0.id == field.id } } label: {
                        Image(systemName: "minus.circle.fill")
                    }
                    .buttonStyle(.borderless)
                    .accessibilityLabel(String(localized: "Remove", comment: "Storage metadata: remove field"))
                }
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .themedRow()
            }
            Button { fields.append(MetadataField()) } label: {
                Label(String(localized: "Add Field", comment: "Storage metadata: add a custom field"), systemImage: "plus")
            }
            .themedRow()
        } header: {
            Text("Custom Metadata", comment: "Storage object info section")
        } footer: {
            if !isValid {
                Text("Names use letters, numbers, “-”, “_” and “.”; values and headers use plain ASCII.",
                     comment: "Storage object info: invalid metadata")
                    .foregroundStyle(.red)
            } else {
                Text("Stored as x-amz-meta- headers. Names are lowercased.", comment: "Storage object info: metadata explanation")
            }
        }
    }

    private func headerField(_ name: String, text: Binding<String>, placeholder: String) -> some View {
        LabeledContent(name) {
            TextField(placeholder, text: text)
                .multilineTextAlignment(.trailing)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
        }
        .themedRow()
    }

    private func row(_ label: String, _ value: String) -> some View {
        LabeledContent(label) {
            Text(value).textSelection(.enabled).multilineTextAlignment(.trailing)
        }
        .themedRow()
    }

    private static func encryptionName(_ value: String) -> String {
        switch value {
        case "AES256": "SSE-S3 (AES-256)"
        case "aws:kms": "SSE-KMS"
        case "aws:kms:dsse": "DSSE-KMS"
        default: value
        }
    }

    private func load() async {
        do {
            let loaded = try await pane.storageFileSystem().details(entry.path)
            details = loaded
            headers = loaded.headers
            fields = loaded.headers.metadata.sorted { $0.key < $1.key }.map { MetadataField(key: $0.key, value: $0.value) }
        } catch {
            loadError = error.localizedDescription
        }
    }

    private func save() {
        guard let details else { return }
        let edited = edited
        isSaving = true
        saveError = nil
        Task {
            do {
                try await pane.storageFileSystem().updateHeaders(entry.path, to: edited, base: details)
                pane.refresh()
                onDismiss()
            } catch {
                saveError = error.localizedDescription
            }
            isSaving = false
        }
    }
}

// MARK: - Share link

struct StorageShareLinkSheet: View {
    let entry: RFEntry
    let pane: FilePaneModel
    let onDismiss: () -> Void

    @State private var expiry: Expiry = .day
    @State private var url: URL?
    @State private var error: String?
    @State private var copied = false

    enum Expiry: Int64, CaseIterable, Identifiable {
        case hour = 3600
        case day = 86_400
        case week = 604_800

        var id: Int64 { rawValue }

        var title: String {
            switch self {
            case .hour: String(localized: "1 Hour", comment: "Share link expiry option")
            case .day: String(localized: "1 Day", comment: "Share link expiry option")
            case .week: String(localized: "7 Days", comment: "Share link expiry option")
            }
        }
    }

    private var provider: StorageProvider? { pane.endpoint.storageProvider }
    private var signs: Bool { provider?.isAnonymous == false }

    var body: some View {
        NavigationStack {
            Form {
                if signs {
                    Picker(String(localized: "Expires After", comment: "Share link expiry picker"), selection: $expiry) {
                        ForEach(Expiry.allCases) { Text($0.title).tag($0) }
                    }
                    .themedRow()
                }
                Section {
                    if let url {
                        Text(url.absoluteString)
                            .font(.caption.monospaced())
                            .textSelection(.enabled)
                            .lineLimit(6)
                            .themedRow()
                    } else if let error {
                        Text(error).foregroundStyle(.red).themedRow()
                    } else {
                        ProgressView().frame(maxWidth: .infinity).themedRow()
                    }
                } footer: {
                    Text(footer)
                }
                if let url {
                    Section {
                        Button {
                            UIPasteboard.general.url = url
                            copied = true
                        } label: {
                            Label(copied
                                  ? String(localized: "Copied", comment: "Share link: copied to clipboard")
                                  : String(localized: "Copy Link", comment: "Share link: copy to clipboard"),
                                  systemImage: copied ? "checkmark" : "doc.on.doc")
                        }
                        .themedRow()
                        ShareLink(item: url) {
                            Label(String(localized: "Share…", comment: "Share link: system share sheet"), systemImage: "square.and.arrow.up")
                        }
                        .themedRow()
                    }
                }
            }
            .themedList()
            .navigationTitle(entry.name)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button(String(localized: "Done", comment: "Done button"), action: onDismiss)
                        .keyboardShortcut(.cancelAction)
                }
            }
        }
        .task(id: expiry) { await generate() }
    }

    private var footer: String {
        guard signs else {
            return String(localized: "This is the object's plain address. It only opens if the object is public.",
                          comment: "Share link footer for a provider without keys")
        }
        let base = String(localized: "Anyone with this link can download the file until it expires.", comment: "Share link footer")
        guard provider?.sessionToken.isEmpty == false else { return base }
        return base + " " + String(localized: "Links signed with temporary credentials stop working when those credentials expire.",
                                   comment: "Share link footer: session token caveat")
    }

    private func generate() async {
        url = nil
        error = nil
        copied = false
        do {
            url = try await pane.storageFileSystem().shareURL(entry.path, expiresIn: expiry.rawValue)
        } catch {
            self.error = error.localizedDescription
        }
    }
}

// MARK: - Incomplete uploads

struct StorageIncompleteUploadsSheet: View {
    let bucket: String
    let pane: FilePaneModel
    let onDismiss: () -> Void

    @State private var uploads: [S3PendingUpload]?
    @State private var error: String?
    @State private var aborting: Set<String> = []
    @State private var confirmsAbortAll = false
    @Environment(\.sheetThemeColors) private var sheetThemeColors

    var body: some View {
        NavigationStack {
            Group {
                if let uploads, uploads.isEmpty {
                    ContentUnavailableView(
                        String(localized: "No Incomplete Uploads", comment: "Storage incomplete uploads: empty state"),
                        systemImage: "checkmark.icloud"
                    )
                } else {
                    list
                }
            }
            .background(sheetThemeColors?.background.ignoresSafeArea())
            .navigationTitle(String(localized: "Incomplete Uploads", comment: "Storage incomplete uploads sheet title"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(String(localized: "Close", comment: "Close button"), action: onDismiss)
                        .keyboardShortcut(.cancelAction)
                }
                ToolbarItem(placement: .destructiveAction) {
                    Button(String(localized: "Abort All", comment: "Storage incomplete uploads: abort every upload"), role: .destructive) {
                        confirmsAbortAll = true
                    }
                    .disabled(uploads?.isEmpty != false || !aborting.isEmpty)
                }
            }
            .confirmationDialog(
                String(localized: "Abort \(uploads?.count ?? 0) uploads?", comment: "Storage incomplete uploads: confirm; argument is a count"),
                isPresented: $confirmsAbortAll, titleVisibility: .visible
            ) {
                Button(String(localized: "Abort All", comment: "Storage incomplete uploads: abort every upload"), role: .destructive) {
                    Task { await abortAll() }
                }
            } message: {
                Text("Their uploaded parts are deleted. An upload still running on any device will fail.",
                     comment: "Storage incomplete uploads: abort confirmation detail")
            }
        }
        .task { await load() }
    }

    private var list: some View {
        List {
            if let error {
                Text(error).foregroundStyle(.red).themedRow()
            }
            if let uploads {
                Section {
                    ForEach(uploads) { upload in
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(upload.key).lineLimit(1).truncationMode(.middle)
                                if let initiated = upload.initiated {
                                    Text(String(localized: "Started \(initiated.formatted(.relative(presentation: .named)))",
                                                comment: "Storage incomplete upload start; argument is a relative date"))
                                        .font(.caption).foregroundStyle(.secondary)
                                }
                            }
                            Spacer()
                            if aborting.contains(upload.id) {
                                ProgressView()
                            } else {
                                Button(String(localized: "Abort", comment: "Storage incomplete uploads: abort one upload"), role: .destructive) {
                                    Task { await abort(upload) }
                                }
                                .buttonStyle(.borderless)
                            }
                        }
                        .themedRow()
                    }
                } header: {
                    Text(bucket)
                } footer: {
                    Text("Parts of unfinished uploads are stored, and billed, until the upload is aborted. Uploads running right now are listed too.",
                         comment: "Storage incomplete uploads explanation")
                }
            } else if error == nil {
                ProgressView().frame(maxWidth: .infinity).themedRow()
            }
        }
        .themedList()
    }

    private func load() async {
        do {
            uploads = try await pane.storageFileSystem().incompleteUploads(in: bucket)
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func abort(_ upload: S3PendingUpload) async {
        aborting.insert(upload.id)
        defer { aborting.remove(upload.id) }
        do {
            try await pane.storageFileSystem().abort(upload, in: bucket)
            uploads?.removeAll { $0.id == upload.id }
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func abortAll() async {
        for upload in uploads ?? [] {
            await abort(upload)
            if error != nil { break }
        }
    }
}
