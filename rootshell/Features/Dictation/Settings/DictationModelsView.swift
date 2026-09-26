#if canImport(FluidAudio) && !CHINA_BUILD
//
//  DictationModelsView.swift
//  rootshell
//
//  Choose, download and delete the Parakeet models dictation runs on.
//

import SwiftUI

struct DictationModelsView: View {
    @Setting(Settings.Dictation.model) private var selected
    @Setting(Settings.Dictation.encoderPrecision) private var precision
    private var store: DictationModelStore { .shared }

    var body: some View {
        List {
            Section {
                ForEach(DictationModel.allCases, id: \.self) { model in
                    modelRow(model)
                }
            } header: {
                SettingGroupHeader("Speech Model", group: .dictation)
            } footer: {
                Text("Models run on the Neural Engine and are downloaded once from Hugging Face. Tap a model to use it.")
            }

            Section {
                assetRow(.voiceActivity, title: String(localized: "Speech Detection"),
                         detail: String(localized: "Silero voice activity detection. Required, about 1 MB."))
                assetRow(.vocabulary, title: String(localized: "Vocabulary Boost"),
                         detail: String(localized: "Keyword spotter for custom vocabulary, about 97 MB."))
            } header: {
                Text("Supporting Models")
            } footer: {
                Text("Stored on this device only and excluded from backups. Models use \(ByteCountFormatter.string(fromByteCount: store.totalBytes, countStyle: .file)).")
            }
        }
        .themedList()
        .navigationTitle("Speech Model")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { store.refresh() }
    }

    private func modelRow(_ model: DictationModel) -> some View {
        let state = store.state(.speech(model))
        return HStack(spacing: 12) {
            Image(systemName: selected == model ? "checkmark.circle.fill" : "circle")
                .foregroundStyle(selected == model ? Color.accentColor : Color.secondary)
                .font(.title3)
            VStack(alignment: .leading, spacing: 2) {
                Text(model.displayName)
                Text(model.summary).font(.caption).foregroundStyle(.secondary)
                Text(sizeText(.speech(model), megabytes: model.downloadMegabytes(precision)))
                    .font(.caption2).foregroundStyle(.secondary)
            }
            Spacer()
            control(for: .speech(model), state: state)
        }
        .contentShape(Rectangle())
        .onTapGesture { selected = model }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(selected == model ? [.isButton, .isSelected] : .isButton)
        .themedRow()
        .swipeActions { deleteAction(.speech(model), state: state) }
        .contextMenu { deleteAction(.speech(model), state: state) }
    }

    private func assetRow(_ asset: DictationAsset, title: String, detail: String) -> some View {
        let state = store.state(asset)
        return HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                Text(detail).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            control(for: asset, state: state)
        }
        .themedRow()
        .swipeActions { deleteAction(asset, state: state) }
        .contextMenu { deleteAction(asset, state: state) }
    }

    @ViewBuilder
    private func control(for asset: DictationAsset, state: DictationModelStore.State) -> some View {
        switch state {
        case .ready:
            Image(systemName: "checkmark").foregroundStyle(.secondary)
                .accessibilityLabel(Text("Downloaded"))
        case .downloading(let value):
            HStack(spacing: 8) {
                ProgressView(value: value).frame(width: 60)
                Button { store.cancel(asset) } label: { Image(systemName: "xmark.circle.fill") }
                    .buttonStyle(.borderless)
                    .accessibilityLabel(Text("Cancel Download"))
            }
        case .failed(let message):
            Button { store.download(asset) } label: { Image(systemName: "arrow.clockwise.circle.fill").font(.title2) }
                .buttonStyle(.borderless)
                .foregroundStyle(.red)
                .help(message)
                .accessibilityLabel(Text("Retry Download"))
        case .notDownloaded:
            Button { store.download(asset) } label: { Image(systemName: "arrow.down.circle.fill").font(.title2) }
                .buttonStyle(.borderless)
                .accessibilityLabel(Text("Download"))
        }
    }

    @ViewBuilder
    private func deleteAction(_ asset: DictationAsset, state: DictationModelStore.State) -> some View {
        if state == .ready {
            Button(role: .destructive) {
                Task { await store.delete(asset) }
            } label: {
                Label("Delete", systemImage: "trash")
            }
        }
    }

    private func sizeText(_ asset: DictationAsset, megabytes: Int) -> String {
        if let bytes = store.sizes[asset], bytes > 0 {
            return String(localized: "\(ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)) on device")
        }
        return String(localized: "About \(megabytes) MB download")
    }
}
#endif
