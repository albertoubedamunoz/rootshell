//
//  CopyButton.swift
//  rootshell
//
//  Reusable clipboard button with transient visual feedback.
//

import SwiftUI
import UIKit

struct CopyButton: View {
    @Environment(\.sheetThemeColors) private var sheetThemeColors

    let text: String
    let label: String?
    let isBordered: Bool

    @State private var copied = false

    init(text: String, label: String? = nil, isBordered: Bool = false) {
        self.text = text
        self.label = label
        self.isBordered = isBordered
    }

    var body: some View {
        Group {
            if isBordered {
                button
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .tint(accentColor)
            } else {
                button
                    .buttonStyle(.borderless)
                    .foregroundColor(copied ? accentColor : .secondary)
            }
        }
    }

    private var accentColor: Color {
        sheetThemeColors?.accentColor ?? .accentColor
    }

    private var button: some View {
        Button(action: copyToClipboard) {
            Group {
                if let label {
                    ZStack {
                        Label(label, systemImage: "doc.on.doc")
                            .opacity(copied ? 0 : 1)
                        Label(
                            String(localized: "Copied", comment: "Copy button state: copied"),
                            systemImage: "checkmark"
                        )
                        .opacity(copied ? 1 : 0)
                    }
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)
                } else {
                    Image(systemName: copied ? "checkmark" : "doc.on.doc")
                        .frame(width: 16, height: 16)
                }
            }
            .contentTransition(.symbolEffect(.replace))
            .symbolEffect(.bounce, value: copied)
            .font(.caption)
        }
    }

    private func copyToClipboard() {
        UIPasteboard.general.string = text
        copied = true

        Task {
            try? await Task.sleep(for: .seconds(2))
            copied = false
        }
    }
}
