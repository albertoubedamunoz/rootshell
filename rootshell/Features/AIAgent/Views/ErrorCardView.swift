#if !CHINA_BUILD
//
//  ErrorCardView.swift
//  rootshell
//
//  Error display card for AI Agent
//

import SwiftUI

/// Card displaying an error with retry and dismiss options
struct ErrorCardView: View {
    let error: AIAgentErrorCategory
    let onRetry: () -> Void
    let onDismiss: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Header with icon and title
            HStack(spacing: 8) {
                Image(systemName: error.icon)
                    .symbolEffect(.pulse)
                    .font(.callout.weight(.semibold))
                    .foregroundColor(error.color)

                Text(error.title)
                    .font(.headline)
                    .foregroundColor(error.color)

                Spacer()
            }

            // Error message
            Text(error.message)
                .font(.callout)
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            // Rate limit countdown hint
            if case .rateLimit(let retryAfter) = error, let seconds = retryAfter {
                HStack(spacing: 6) {
                    Image(systemName: "clock")
                        .font(.caption)

                    Text("Retry available in ~\(Int(seconds)) seconds")
                        .font(.caption)
                }
                .foregroundColor(.orange)
                .padding(.vertical, 2)
            }

            // Configuration hint for auth/config errors
            if case .authentication = error {
                HStack(spacing: 6) {
                    Image(systemName: "arrow.right.circle")
                        .font(.caption)

                    Text("Go to Settings to update your API key")
                        .font(.caption)
                }
                .foregroundColor(.secondary)
            }

            // Action buttons
            actionButtons
        }
        .padding(16)
        .background(cardBackground)
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(error.color.opacity(0.3), lineWidth: 1)
        )
    }

    // MARK: - Components

    private var actionButtons: some View {
        HStack(spacing: 12) {
            // Dismiss button
            Button(action: onDismiss) {
                Label("Dismiss", systemImage: "xmark.circle")
                    .font(AIAgentFonts.buttonSecondary)
            }
            .buttonStyle(.bordered)
            .tint(.secondary)

            Spacer()

            // Retry button
            Button(action: onRetry) {
                Label("Retry", systemImage: "arrow.clockwise.circle.fill")
                    .font(AIAgentFonts.button)
            }
            .buttonStyle(.borderedProminent)
            .tint(error.color)
        }
        .padding(.top, 4)
    }

    // MARK: - Styling

    private var cardBackground: Color {
        error.color.opacity(0.08)
    }
}

// MARK: - Preview

#if DEBUG
struct ErrorCardView_Previews: PreviewProvider {
    static var previews: some View {
        ScrollView {
            VStack(spacing: 20) {
                ErrorCardView(
                    error: .rateLimit(retryAfter: 30),
                    onRetry: {},
                    onDismiss: {}
                )

                ErrorCardView(
                    error: .network("Unable to connect to the server. Please check your internet connection."),
                    onRetry: {},
                    onDismiss: {}
                )

                ErrorCardView(
                    error: .authentication,
                    onRetry: {},
                    onDismiss: {}
                )

                ErrorCardView(
                    error: .quota,
                    onRetry: {},
                    onDismiss: {}
                )

                ErrorCardView(
                    error: .modelUnavailable("gpt-5-turbo"),
                    onRetry: {},
                    onDismiss: {}
                )

                ErrorCardView(
                    error: .configuration("API key not configured"),
                    onRetry: {},
                    onDismiss: {}
                )

                ErrorCardView(
                    error: .unknown("Something went wrong. Please try again."),
                    onRetry: {},
                    onDismiss: {}
                )
            }
            .padding()
        }
        .background(Color(uiColor: .secondarySystemBackground))
    }
}
#endif
#endif
