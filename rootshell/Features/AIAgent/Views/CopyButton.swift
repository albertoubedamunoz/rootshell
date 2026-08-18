#if !CHINA_BUILD
//
//  CopyButton.swift
//  rootshell
//
//  Reusable copy button with visual feedback for AI Agent chat
//

import SwiftUI
import UIKit

/// Reusable copy button with visual feedback
struct CopyButton: View {
    let text: String
    let label: String?

    @State private var copied = false

    init(text: String, label: String? = nil) {
        self.text = text
        self.label = label
    }

    var body: some View {
        Button(action: copyToClipboard) {
            if let label = label {
                Label(copied ? "Copied" : label, systemImage: copied ? "checkmark" : "doc.on.doc")
                    .contentTransition(.symbolEffect(.replace))
                    .symbolEffect(.bounce, value: copied)
                    .font(.caption)
            } else {
                Image(systemName: copied ? "checkmark" : "doc.on.doc")
                    .contentTransition(.symbolEffect(.replace))
                    .symbolEffect(.bounce, value: copied)
                    .font(.caption)
            }
        }
        .buttonStyle(.borderless)
        .foregroundColor(copied ? .green : .secondary)
    }

    private func copyToClipboard() {
        UIPasteboard.general.string = text
        copied = true
        Task {
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            copied = false
        }
    }
}
#endif
