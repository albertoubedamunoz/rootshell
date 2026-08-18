#if targetEnvironment(macCatalyst) && STANDALONE

import SwiftUI

struct LocalAgentAuditLogView: View {
    @State private var auditLog = LocalAgentAuditLog.shared
    @State private var clientFilter = ""

    private var filteredEvents: [LocalAgentAuditEvent] {
        let filter = clientFilter.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !filter.isEmpty else { return auditLog.events }
        return auditLog.events.filter {
            $0.clientName.localizedCaseInsensitiveContains(filter) ||
            $0.clientIdentity.localizedCaseInsensitiveContains(filter)
        }
    }

    var body: some View {
        List {
            Section {
                TextField(
                    String(localized: "Filter by client", comment: "Local SSH agent audit log filter placeholder"),
                    text: $clientFilter
                )
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .themedRow()

                Button(role: .destructive) {
                    auditLog.clear()
                } label: {
                    Text(String(localized: "Clear Audit Log", comment: "Local SSH agent audit log clear button"))
                }
                .themedRow()
            }

            Section {
                if filteredEvents.isEmpty {
                    Text(String(localized: "No audit events.", comment: "Local SSH agent audit log empty text"))
                        .foregroundColor(.secondary)
                        .themedRow()
                } else {
                    ForEach(filteredEvents) { event in
                        VStack(alignment: .leading, spacing: 6) {
                            HStack(alignment: .firstTextBaseline) {
                                Text(event.clientName)
                                    .font(.headline)
                                Spacer()
                                Text(event.outcome.displayName)
                                    .font(.caption)
                                    .padding(.horizontal, 8)
                                    .padding(.vertical, 3)
                                    .background(outcomeColor(event.outcome).opacity(0.16))
                                    .foregroundColor(outcomeColor(event.outcome))
                                    .clipShape(Capsule())
                            }

                            Text("\(event.action.displayName) · \(event.timestamp.formatted(date: .abbreviated, time: .standard))")
                                .font(.caption)
                                .foregroundColor(.secondary)

                            if let keyName = event.keyName {
                                Text(String(localized: "Key: \(keyName)", comment: "Local SSH agent audit log key line"))
                                    .font(.caption)
                            }
                            if let destination = event.destination {
                                Text(String(localized: "Destination: \(destination)", comment: "Local SSH agent audit log destination line"))
                                    .font(.caption)
                            }
                            if let detail = event.detail {
                                Text(detail)
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                        }
                        .themedRow()
                    }
                }
            }
        }
        .themedList()
        .navigationTitle(String(localized: "Local Agent Audit", comment: "Local SSH agent audit log title"))
        .navigationBarTitleDisplayMode(.inline)
    }

    private func outcomeColor(_ outcome: LocalAgentAuditEvent.Outcome) -> Color {
        switch outcome {
        case .allowed, .promptedAllowed:
            return .green
        case .denied, .promptedDenied, .timeout:
            return .red
        case .failed:
            return .orange
        }
    }
}

#endif
