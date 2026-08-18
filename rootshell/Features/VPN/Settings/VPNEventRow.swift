//
//  VPNEventRow.swift
//  rootshell
//
//  Event history row for VPN events.
//

import SwiftUI

struct VPNEventRow: View {
    let event: VPNEvent

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: event.type.iconName)
                .foregroundStyle(event.type.iconColor)
                .font(.body)

            VStack(alignment: .leading, spacing: 2) {
                Text(event.type.displayName)
                    .font(.subheadline)
                if let message = event.message {
                    Text(message)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            }

            Spacer()

            Text(event.timestamp, style: .relative)
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
    }
}
