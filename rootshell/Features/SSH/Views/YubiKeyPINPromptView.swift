//
//  YubiKeyPINPromptView.swift
//  rootshell
//
//  PIN entry prompt for YubiKey operations
//
//  Copyright (c) 2026 Kit Knox / Rootshell LLC
//

import SwiftUI

/// Modal view for entering YubiKey PIN
struct YubiKeyPINPromptView: View {
    let request: YubiKeyPINRequest
    let onSubmit: (String) -> Void
    let onCancel: () -> Void

    @State private var pin = ""
    @FocusState private var isPINFieldFocused: Bool

    // PIV PINs are 6-8 bytes; submitting a longer value fails on the key
    private var isValidPIN: Bool {
        pin.count >= 6 && pin.count <= 8 && pin.utf8.count <= 8
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 24) {
                    // Header
                    VStack(spacing: 12) {
                        Image(systemName: "key.viewfinder")
                            .font(.system(size: 56))
                            .foregroundStyle(.orange)

                        Text("YubiKey PIN Required")
                            .font(.title2)
                            .fontWeight(.semibold)

                        Text("Enter your PIN to use '\(request.keyName)'")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                    }
                    .padding(.top, 20)

                    // PIN field
                    VStack(spacing: 8) {
                        SecureField("PIN", text: $pin)
                            .textContentType(.password)
                            .keyboardType(.numberPad)
                            .focused($isPINFieldFocused)
                            .font(.title3)
                            .padding()
                            .background(Color(uiColor: .secondarySystemBackground))
                            .onSubmit {
                                guard isValidPIN else { return }
                                onSubmit(pin)
                            }
                            .cornerRadius(12)

                        if !pin.isEmpty && !isValidPIN {
                            HStack(spacing: 6) {
                                Image(systemName: "exclamationmark.circle")
                                    .foregroundStyle(.orange)
                                Text("PIN must be 6-8 digits")
                                    .font(.caption)
                                    .foregroundStyle(.orange)
                            }
                            .padding(.top, 4)
                        }

                        // Attempts remaining warning
                        if let attempts = request.attemptsRemaining {
                            HStack(spacing: 6) {
                                Image(systemName: attemptsWarningIcon(attempts))
                                    .foregroundStyle(attemptsWarningColor(attempts))
                                Text(attemptsWarningText(attempts))
                                    .font(.caption)
                                    .foregroundStyle(attemptsWarningColor(attempts))
                            }
                            .padding(.top, 4)
                        }
                    }
                    .padding(.horizontal)

                    // Buttons
                    VStack(spacing: 12) {
                        Button {
                            onSubmit(pin)
                        } label: {
                            Text("Unlock")
                                .font(.headline)
                                .frame(maxWidth: .infinity)
                                .padding()
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(!isValidPIN)

                        Button {
                            onCancel()
                        } label: {
                            Text("Cancel")
                                .frame(maxWidth: .infinity)
                                .padding()
                        }
                        .buttonStyle(.bordered)
                        .tint(.secondary)
                    }
                    .padding(.horizontal)
                    .padding(.bottom, 20)
                }
                .frame(maxWidth: .infinity)
            }
            #if !os(visionOS)
            .scrollDismissesKeyboard(.interactively)
            #endif
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button {
                        onCancel()
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .onAppear {
                isPINFieldFocused = true
            }
        }
        .frame(minWidth: 340, minHeight: 500)
        .presentationDetents([.height(520), .large])
        .interactiveDismissDisabled()
    }

    private func attemptsWarningIcon(_ attempts: Int) -> String {
        if attempts <= 1 {
            return "exclamationmark.triangle.fill"
        } else if attempts <= 3 {
            return "exclamationmark.circle.fill"
        } else {
            return "info.circle.fill"
        }
    }

    private func attemptsWarningColor(_ attempts: Int) -> Color {
        if attempts <= 1 {
            return .red
        } else if attempts <= 3 {
            return .orange
        } else {
            return .secondary
        }
    }

    private func attemptsWarningText(_ attempts: Int) -> String {
        if attempts == 0 {
            return "PIN is blocked. Use PUK to reset."
        } else if attempts == 1 {
            return "Last attempt! PIN will be blocked if incorrect."
        } else {
            return "\(attempts) attempts remaining"
        }
    }
}

#Preview {
    YubiKeyPINPromptView(
        request: YubiKeyPINRequest(
            keyName: "Authentication (9a)",
            attemptsRemaining: 3
        ) { _ in },
        onSubmit: { _ in },
        onCancel: {}
    )
}
