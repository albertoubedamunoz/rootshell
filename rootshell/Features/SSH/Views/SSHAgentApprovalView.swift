//
//  SSHAgentApprovalView.swift
//  rootshell
//
//  Alert view for SSH agent signing request approval
//

import SwiftUI

/// A compact approval view for SSH agent signing requests
struct SSHAgentApprovalView: View {
    let request: SSHAgentApprovalRequest
    let onApprove: () -> Void
    let onDeny: () -> Void

    var body: some View {
        VStack(spacing: 16) {
            // Header
            HStack {
                Image(systemName: "key.fill")
                    .font(.title2)
                    .foregroundStyle(.orange)
                Text("SSH Agent Request")
                    .font(.headline)
            }

            // Key info
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("Session:")
                        .foregroundStyle(.secondary)
                    Text(request.sessionName)
                        .fontWeight(.medium)
                }

                HStack {
                    Text("Key:")
                        .foregroundStyle(.secondary)
                    Text(request.keyName)
                        .fontWeight(.medium)
                }

                Text(request.fingerprint)
                    .font(.caption)
                    .fontDesign(.monospaced)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding()
            .background(Color(uiColor: .secondarySystemBackground))
            .clipShape(RoundedRectangle(cornerRadius: 8))

            // Buttons
            HStack(spacing: 12) {
                Button(action: onDeny) {
                    Text("Deny")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .tint(.red)

                Button(action: onApprove) {
                    Text("Approve")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .padding()
        .frame(maxWidth: 320)
    }
}
