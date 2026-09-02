//
//  ConfigFileEditorSheet.swift
//  rootshell
//
//  In-app monospaced editor for the config file.
//

import SwiftUI

struct ConfigFileEditorSheet: View {
    let url: URL
    let onSave: () -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var text = ""
    @State private var original = ""
    @State private var loadError: String?

    var body: some View {
        NavigationStack {
            Group {
                if let loadError {
                    Text(loadError)
                        .foregroundColor(.red)
                        .padding()
                } else {
                    TextEditor(text: $text)
                        .font(.system(.body, design: .monospaced))
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                        .padding(.horizontal, 8)
                }
            }
            .navigationTitle(url.lastPathComponent)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { save() }
                        .disabled(text == original || loadError != nil)
                }
            }
        }
        .onAppear(perform: load)
    }

    private func load() {
        do {
            text = try String(contentsOf: url, encoding: .utf8)
            original = text
        } catch {
            loadError = error.localizedDescription
        }
    }

    private func save() {
        do {
            try text.write(to: url, atomically: false, encoding: .utf8)
            onSave()
            dismiss()
        } catch {
            loadError = error.localizedDescription
        }
    }
}
