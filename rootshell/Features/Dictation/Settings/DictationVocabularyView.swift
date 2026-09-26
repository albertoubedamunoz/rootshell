#if canImport(FluidAudio) && !CHINA_BUILD
//
//  DictationVocabularyView.swift
//  rootshell
//
//  Words dictation should favor, each with the ways it tends to be misheard.
//

import SwiftUI

struct DictationVocabularyView: View {
    @Setting(Settings.Dictation.vocabularyEnabled) private var enabled
    @Setting(Settings.Dictation.vocabulary) private var lines
    @State private var editing: Editing?
    private var store: DictationModelStore { .shared }

    private struct Editing: Identifiable {
        let id = UUID()
        var index: Int?
        var term = ""
        var aliases = ""
    }

    var body: some View {
        List {
            Section {
                SettingToggle(Settings.Dictation.vocabularyEnabled, title: "Vocabulary Boost", icon: "text.book.closed")
                    .themedRow()
                if enabled {
                    SettingDescribedToggle(Settings.Dictation.screenVocabulary, title: "Learn Words from Screen",
                                           description: "Adds identifiers visible in the terminal, like SettingsStore or main.swift, each time you start listening.")
                        .themedRow()
                    modelRow
                }
            } footer: {
                Text("A small keyword model rechecks each finished phrase and swaps in these terms when the audio supports them. It adds a moment of processing per phrase.")
            }

            if enabled {
                Section {
                    ForEach(Array(lines.enumerated()), id: \.offset) { index, line in
                        if let entry = DictationVocabulary.parse(line) {
                            Button {
                                editing = Editing(index: index, term: entry.term, aliases: entry.aliases.joined(separator: ", "))
                            } label: {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(verbatim: entry.term).foregroundStyle(.primary)
                                    if !entry.aliases.isEmpty {
                                        Text(verbatim: entry.aliases.joined(separator: ", "))
                                            .font(.caption).foregroundStyle(.secondary)
                                    }
                                }
                            }
                            .themedRow()
                        }
                    }
                    .onDelete { lines.remove(atOffsets: $0) }
                    Button {
                        editing = Editing()
                    } label: {
                        Label("Add Term", systemImage: "plus")
                    }
                    .themedRow()
                } header: {
                    SettingGroupHeader("Terms", group: .dictation)
                } footer: {
                    Text("Add how a term sounds when it's misheard, for example kubectl heard as “cube control”.")
                }

                Section {
                    Button("Restore Default Terms") {
                        lines = DictationVocabularyDefaults.terms
                    }
                    .themedRow()
                }
            }
        }
        .themedList()
        .navigationTitle("Vocabulary Boost")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(item: $editing) { item in
            NavigationStack { editor(item) }
        }
    }

    @ViewBuilder
    private var modelRow: some View {
        switch store.state(.vocabulary) {
        case .ready:
            LabeledContent("Keyword Model", value: String(localized: "Downloaded"))
                .themedRow()
        case .downloading(let value):
            LabeledContent("Keyword Model") { ProgressView(value: value).frame(width: 80) }
                .themedRow()
        case .failed(let message):
            Button("Retry Keyword Model Download") { store.download(.vocabulary) }
                .themedRow()
                .help(message)
        case .notDownloaded:
            Button("Download Keyword Model (97 MB)") { store.download(.vocabulary) }
                .themedRow()
        }
    }

    private func editor(_ item: Editing) -> some View {
        TermEditor(item: item) { term, aliases in
            let entry = DictationVocabulary.Entry(
                term: term.trimmingCharacters(in: .whitespaces),
                aliases: aliases.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty })
            guard !entry.term.isEmpty else { return }
            let line = DictationVocabulary.line(for: entry)
            if let index = item.index, lines.indices.contains(index) {
                lines[index] = line
            } else {
                lines.append(line)
            }
        }
    }

    private struct TermEditor: View {
        let item: Editing
        let onSave: (String, String) -> Void
        @State private var term = ""
        @State private var aliases = ""
        @Environment(\.dismiss) private var dismiss

        var body: some View {
            Form {
                Section {
                    TextField("Term", text: $term)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                } footer: {
                    Text("Written exactly as it should appear, for example kubectl.")
                }
                Section {
                    TextField("Sounds Like", text: $aliases)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                } footer: {
                    Text("Optional. Comma-separated phrases it's misheard as, for example cube control, cube cuddle.")
                }
            }
            .navigationTitle(item.index == nil ? Text("Add Term") : Text("Edit Term"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        onSave(term, aliases)
                        dismiss()
                    }
                    .disabled(term.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
            .onAppear {
                term = item.term
                aliases = item.aliases
            }
        }
    }
}
#endif
