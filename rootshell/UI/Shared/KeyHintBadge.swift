//
//  KeyHintBadge.swift
//  rootshell
//
//  A keycap plus label for hardware-keyboard hint bars.
//

import SwiftUI

struct KeyHintBadge: View {
    let key: String
    let label: String
    var compact = false

    var body: some View {
        HStack(spacing: compact ? 4 : 6) {
            Text(key)
                .font(.system(size: compact ? 10 : 12, weight: .medium, design: .monospaced))
                .padding(.horizontal, compact ? 4 : 6)
                .padding(.vertical, compact ? 2 : 3)
                .background(.fill.quaternary, in: RoundedRectangle(cornerRadius: 3))
            Text(label)
                .font(.system(size: compact ? 10 : 12))
                .foregroundStyle(.tertiary)
        }
        .accessibilityElement(children: .combine)
    }
}
