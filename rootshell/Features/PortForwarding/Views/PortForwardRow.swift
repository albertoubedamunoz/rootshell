//
//  PortForwardRow.swift
//  rootshell
//
//  Row view for displaying a single port forward configuration
//
//  Copyright (c) 2025 Kit Knox / Rootshell LLC
//

import SwiftUI

/// Row displaying a single port forward with delete action
struct PortForwardRow: View {
    let forward: PortForwardConfig.PortForward
    let onDelete: () -> Void

    private var directionIcon: String {
        switch forward.direction {
        case .local: return "arrow.right.circle.fill"
        case .remote: return "arrow.left.circle.fill"
        case .dynamic: return "globe"
        }
    }

    private var directionColor: Color {
        switch forward.direction {
        case .local: return .blue
        case .remote: return .green
        case .dynamic: return .orange
        }
    }

    var body: some View {
        HStack(spacing: 12) {
            // Direction indicator
            Image(systemName: directionIcon)
                .foregroundColor(directionColor)
                .font(.title3)

            // Forward details
            VStack(alignment: .leading, spacing: 2) {
                Text(forward.displayString)
                    .font(.body.monospaced())

                Text(forward.direction.description)
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            Spacer()

            // Delete button
            Button(action: onDelete) {
                Image(systemName: "trash")
                    .foregroundColor(.red)
            }
            .buttonStyle(.plain)
        }
        .padding(.vertical, 4)
    }
}

/// Compact row for displaying port forwards in lists/summaries
struct PortForwardCompactRow: View {
    let forward: PortForwardConfig.PortForward

    private var directionColor: Color {
        switch forward.direction {
        case .local: return .blue
        case .remote: return .green
        case .dynamic: return .orange
        }
    }

    var body: some View {
        HStack(spacing: 8) {
            Text(forward.direction.shortName)
                .font(.caption.bold())
                .foregroundColor(directionColor)
                .frame(width: 16)

            Text(forward.specString)
                .font(.caption.monospaced())
                .foregroundColor(.secondary)
        }
    }
}

#Preview {
    List {
        Section("Port Forwards") {
            PortForwardRow(
                forward: PortForwardConfig.PortForward(
                    direction: .local,
                    bindPort: 8080,
                    targetHost: "localhost",
                    targetPort: 80
                ),
                onDelete: {}
            )

            PortForwardRow(
                forward: PortForwardConfig.PortForward(
                    direction: .remote,
                    bindAddress: "0.0.0.0",
                    bindPort: 3000,
                    targetHost: "127.0.0.1",
                    targetPort: 3000
                ),
                onDelete: {}
            )

            PortForwardRow(
                forward: PortForwardConfig.PortForward(
                    direction: .dynamic,
                    bindPort: 1080,
                    targetHost: "",
                    targetPort: 0
                ),
                onDelete: {}
            )
        }

        Section("Compact") {
            PortForwardCompactRow(
                forward: PortForwardConfig.PortForward(
                    direction: .local,
                    bindPort: 8080,
                    targetHost: "localhost",
                    targetPort: 80
                )
            )
            PortForwardCompactRow(
                forward: PortForwardConfig.PortForward(
                    direction: .remote,
                    bindPort: 3000,
                    targetHost: "127.0.0.1",
                    targetPort: 3000
                )
            )
            PortForwardCompactRow(
                forward: PortForwardConfig.PortForward(
                    direction: .dynamic,
                    bindPort: 1080,
                    targetHost: "",
                    targetPort: 0
                )
            )
        }
    }
}
