//
//  InputSourcePickerView.swift
//  rootshell
//
//  Picker for assigning a system input source to a mod-tap action.
//

import SwiftUI
import UIKit

struct InputSourcePickerView: View {
    @Environment(\.dismiss) private var dismiss
    @Binding var selection: ModTapAction

    @State private var sources: [InputSourceDescriptor] = []

    private var currentSelectedLanguage: String? {
        if case .switchInputSource(let lang) = selection { return lang }
        return nil
    }

    var body: some View {
        List {
            if sources.isEmpty {
                Section {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("No input sources available")
                            .font(.headline)
                        #if targetEnvironment(macCatalyst)
                        Text("Add an input source in System Settings \u{2192} Keyboard \u{2192} Input Sources, then come back.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        #else
                        Text("Add an input source in Settings \u{2192} General \u{2192} Keyboard \u{2192} Keyboards, then come back.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        #endif
                    }
                    .padding(.vertical, 4)
                    .themedRow()
                }
            } else {
                Section {
                    ForEach(sources) { source in
                        Button {
                            selection = .switchInputSource(primaryLanguage: source.primaryLanguage)
                            dismiss()
                        } label: {
                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(source.displayName)
                                        .foregroundStyle(.primary)
                                    Text(source.primaryLanguage)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                Spacer()
                                if currentSelectedLanguage == source.primaryLanguage {
                                    Image(systemName: "checkmark")
                                        .foregroundStyle(.tint)
                                }
                            }
                        }
                        .themedRow()
                    }
                } footer: {
                    Text("Picker shows input sources you've enabled in system settings. Add more sources there to expand this list.")
                }
            }
        }
        .themedList()
        .navigationTitle("Input Source")
        .onAppear { reload() }
    }

    private func reload() {
        sources = InputSourceCatalog.available()
    }
}
