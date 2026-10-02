//
//  AttachmentUploadSheet.swift
//  rootshell
//
//  Confirmation sheet for uploading paste attachments to a remote server via SFTP.
//  Shows thumbnail preview, filename, size, destination path, and insert format.
//

import SwiftUI
import UniformTypeIdentifiers

/// Confirmation sheet for attachment upload
struct AttachmentUploadSheet: View {
    let attachments: [PasteAttachment]
    let host: String
    let onUpload: (String, PasteInsertFormat) -> Void
    let onCancel: () -> Void

    @Environment(\.sheetThemeColors) private var sheetThemeColors
    @State private var destination: String
    @State private var insertFormat: PasteInsertFormat
    @State private var dontAskAgain = false

    init(
        attachments: [PasteAttachment],
        host: String,
        defaultDestination: String,
        onUpload: @escaping (String, PasteInsertFormat) -> Void,
        onCancel: @escaping () -> Void
    ) {
        self.attachments = attachments
        self.host = host
        self.onUpload = onUpload
        self.onCancel = onCancel
        self._destination = State(initialValue: defaultDestination)
        self._insertFormat = State(initialValue: AttachmentUploadPreferences.defaultFormat)
    }

    private var trimmedDestination: String {
        destination.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var body: some View {
        NavigationStack {
            Form {
                // Preview section
                Section {
                    if attachments.count == 1, let attachment = attachments.first {
                        singlePreview(attachment)
                    } else {
                        multiPreview
                    }
                } header: {
                    Text("Attachment")
                }

                // Destination section
                Section {
                    TextField("Remote path", text: $destination)
                        .font(.system(.body, design: .monospaced))
                        .autocapitalization(.none)
                        .disableAutocorrection(true)
                        .themedRow()
                } header: {
                    Text("Upload to")
                } footer: {
                    Text("Directory on \(host) where the file will be uploaded")
                }

                // Insert format section
                Section {
                    Picker("Insert as", selection: $insertFormat) {
                        ForEach(PasteInsertFormat.allCases, id: \.rawValue) { format in
                            Text(format.displayName).tag(format)
                        }
                    }
                    .pickerStyle(.segmented)
                    .themedRow()
                } header: {
                    Text("Format")
                } footer: {
                    Text(insertFormat.detail)
                }

                Section {
                    Toggle("Don't ask again", isOn: $dontAskAgain)
                        .themedRow()
                } footer: {
                    Text("Future uploads go straight to this directory with this format. Change this in Settings → Connections → Uploads.")
                }
            }
            .themedList()
            .navigationTitle("Upload to Server")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        onCancel()
                    }
                }

                ToolbarItem(placement: .confirmationAction) {
                    Button("Upload") {
                        let destination = trimmedDestination
                        AttachmentUploadPreferences.remember(destination: destination, for: host)
                        if dontAskAgain {
                            AttachmentUploadPreferences.persistDefaults(destination: destination, format: insertFormat)
                        }
                        onUpload(destination, insertFormat)
                    }
                    .fontWeight(.semibold)
                    .disabled(trimmedDestination.isEmpty)
                }
            }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
    }

    // MARK: - Preview Views

    @ViewBuilder
    private func singlePreview(_ attachment: PasteAttachment) -> some View {
        HStack(spacing: 12) {
            if let thumbnail = attachment.thumbnail {
                Image(uiImage: thumbnail)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(maxWidth: 80, maxHeight: 80)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
            } else {
                Image(systemName: iconForUTType(attachment.uti))
                    .font(.system(size: 32))
                    .foregroundStyle(.secondary)
                    .frame(width: 80, height: 80)
            }

            VStack(alignment: .leading, spacing: 4) {
                Text(attachment.suggestedName)
                    .font(.system(.body, design: .monospaced))
                    .lineLimit(1)

                Text(attachment.formattedSize)
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Text(attachment.uti.localizedDescription ?? attachment.fileExtension.uppercased())
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
        .themedRow()
    }

    @ViewBuilder
    private var multiPreview: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(Array(attachments.enumerated()), id: \.offset) { _, attachment in
                    VStack(spacing: 4) {
                        if let thumbnail = attachment.thumbnail {
                            Image(uiImage: thumbnail)
                                .resizable()
                                .aspectRatio(contentMode: .fill)
                                .frame(width: 60, height: 60)
                                .clipShape(RoundedRectangle(cornerRadius: 6))
                        } else {
                            Image(systemName: iconForUTType(attachment.uti))
                                .font(.system(size: 24))
                                .foregroundStyle(.secondary)
                                .frame(width: 60, height: 60)
                        }
                        Text(attachment.formattedSize)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .padding(.vertical, 4)
        }
        .themedRow()

        HStack {
            Text("\(attachments.count) files")
                .font(.subheadline)
            Spacer()
            Text(totalSize)
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .themedRow()
    }

    // MARK: - Helpers

    private var totalSize: String {
        let total = attachments.reduce(0) { $0 + Int64($1.data.count) }
        return ByteCountFormatter.string(fromByteCount: total, countStyle: .file)
    }

    private func iconForUTType(_ uti: UTType) -> String {
        if uti.conforms(to: .pdf) { return "doc.fill" }
        if uti.conforms(to: .image) { return "photo.fill" }
        return "doc.fill"
    }
}
