//
//  GuideComponents.swift
//  rootshell
//
//  Shared building blocks for the setup-guide screens under Settings.
//

import SwiftUI

/// Icon + title + description row used in "How It Works" style sections.
struct GuideRow: View {
    let icon: String
    let title: String
    let description: String

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 16))
                .foregroundColor(.accentColor)
                .frame(width: 24)

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.subheadline)
                    .fontWeight(.medium)
                Text(description)
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
    }
}

/// A labeled shell command or config snippet with a copy button.
struct GuideCodeBlock: View {
    let title: String
    let code: String

    var body: some View {
        CopyableValueBlock(title: title, value: code)
    }
}

/// A numbered setup step: title, command, optional note.
struct GuideInstructionStep: View {
    let number: Int
    let title: String
    let code: String
    var note: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            GuideCodeBlock(title: "\(number). \(title)", code: code)

            if let note {
                Text(note)
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
    }
}
