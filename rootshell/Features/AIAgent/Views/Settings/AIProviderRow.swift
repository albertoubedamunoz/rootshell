#if !CHINA_BUILD
//
//  AIProviderRow.swift
//  rootshell
//
//  Reusable row component for displaying AI providers in settings
//

import SwiftUI

/// Reusable row component showing provider name, status, and model count
struct AIProviderRow: View {
    let name: String
    let isConfigured: Bool
    let modelCount: Int
    var isEnabled: Bool = true
    var imageName: String? = nil
    var systemImage: String? = nil

    var body: some View {
        HStack(spacing: 12) {
            providerIcon
                .frame(width: 32, height: 32)

            VStack(alignment: .leading, spacing: 2) {
                HStack {
                    Text(name)
                    if !isEnabled {
                        Text("Disabled")
                            .font(.caption)
                            .foregroundColor(.secondary)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Color.secondary.opacity(0.2))
                            .cornerRadius(4)
                    }
                }

                if isConfigured {
                    Text("\(modelCount) model\(modelCount == 1 ? "" : "s")")
                        .font(.caption)
                        .foregroundColor(.secondary)
                } else {
                    Text("Not configured")
                        .font(.caption)
                        .foregroundColor(.orange)
                }
            }

            Spacer()

            if isConfigured {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundColor(.green)
            }
        }
        .opacity(isEnabled ? 1.0 : 0.6)
    }

    @ViewBuilder
    private var providerIcon: some View {
        if let imageName = imageName {
            Image(imageName)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .opacity(isConfigured && isEnabled ? 1.0 : 0.5)
        } else if let systemImage = systemImage {
            Image(systemName: systemImage)
                .font(.title2)
                .foregroundColor(isConfigured && isEnabled ? .accentColor : .secondary)
        } else {
            Image(systemName: "server.rack")
                .font(.title2)
                .foregroundColor(isConfigured && isEnabled ? .accentColor : .secondary)
        }
    }
}

/// Reusable row component for displaying a model
struct ModelRow: View {
    let model: AIProviderModel
    var showSource: Bool = false

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(model.displayName)
                Text(model.description)
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            Spacer()

            if showSource && model.source == .manual {
                Image(systemName: "hand.draw")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
    }
}

#Preview {
    List {
        AIProviderRow(
            name: "OpenAI",
            isConfigured: true,
            modelCount: 3,
            imageName: "OpenAILogo"
        )
        AIProviderRow(
            name: "Anthropic",
            isConfigured: false,
            modelCount: 4,
            imageName: "AnthropicLogo"
        )
        AIProviderRow(
            name: "Ollama Local",
            isConfigured: true,
            modelCount: 12,
            isEnabled: false,
            systemImage: "server.rack"
        )
    }
}
#endif
