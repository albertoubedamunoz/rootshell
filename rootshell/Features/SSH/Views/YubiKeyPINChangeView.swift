//
//  YubiKeyPINChangeView.swift
//  rootshell
//
//  PIN change form for YubiKey PIV
//
//  Copyright (c) 2026 Kit Knox / Rootshell LLC
//

import SwiftUI

/// Modal view for changing YubiKey PIV PIN
struct YubiKeyPINChangeView: View {
    let onSubmit: (String, String) -> Void  // (oldPIN, newPIN)
    let onCancel: () -> Void

    @State private var oldPIN = ""
    @State private var newPIN = ""
    @State private var confirmPIN = ""
    @State private var showMismatchError = false
    @State private var showLengthError = false

    @FocusState private var focusedField: Field?

    private enum Field: Hashable {
        case oldPIN
        case newPIN
        case confirmPIN
    }

    private var isValid: Bool {
        oldPIN.count >= 6 &&
        newPIN.count >= 6 && newPIN.count <= 8 &&
        confirmPIN == newPIN &&
        oldPIN != newPIN
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 24) {
                    // Header
                    VStack(spacing: 12) {
                        Image(systemName: "lock.rotation")
                            .font(.system(size: 56))
                            .foregroundStyle(.orange)

                        Text("Change YubiKey PIN")
                            .font(.title2)
                            .fontWeight(.semibold)

                        Text("Enter your current PIN and choose a new one")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                    }
                    .padding(.top, 20)

                    // PIN fields
                    VStack(spacing: 16) {
                        // Old PIN
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Current PIN")
                                .font(.caption)
                                .foregroundStyle(.secondary)

                            SecureField("Enter current PIN", text: $oldPIN)
                                .textContentType(.password)
                                .keyboardType(.numberPad)
                                .focused($focusedField, equals: .oldPIN)
                                .font(.title3)
                                .padding()
                                .background(Color(uiColor: .secondarySystemBackground))
                                .cornerRadius(12)
                                .onSubmit {
                                    focusedField = .newPIN
                                }
                        }

                        // New PIN
                        VStack(alignment: .leading, spacing: 8) {
                            Text("New PIN")
                                .font(.caption)
                                .foregroundStyle(.secondary)

                            SecureField("Enter new PIN", text: $newPIN)
                                .textContentType(.newPassword)
                                .keyboardType(.numberPad)
                                .focused($focusedField, equals: .newPIN)
                                .font(.title3)
                                .padding()
                                .background(Color(uiColor: .secondarySystemBackground))
                                .cornerRadius(12)
                                .onChange(of: newPIN) { _, _ in
                                    showMismatchError = false
                                    showLengthError = false
                                }
                                .onSubmit {
                                    focusedField = .confirmPIN
                                }
                        }

                        // Confirm New PIN
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Confirm New PIN")
                                .font(.caption)
                                .foregroundStyle(.secondary)

                            SecureField("Re-enter new PIN", text: $confirmPIN)
                                .textContentType(.newPassword)
                                .keyboardType(.numberPad)
                                .focused($focusedField, equals: .confirmPIN)
                                .font(.title3)
                                .padding()
                                .background(Color(uiColor: .secondarySystemBackground))
                                .cornerRadius(12)
                                .onChange(of: confirmPIN) { _, _ in
                                    showMismatchError = false
                                }
                                .onSubmit {
                                    validateAndSubmit()
                                }
                        }

                        // Error messages
                        if showMismatchError {
                            HStack(spacing: 6) {
                                Image(systemName: "exclamationmark.triangle.fill")
                                    .foregroundStyle(.red)
                                Text("New PINs do not match")
                                    .font(.caption)
                                    .foregroundStyle(.red)
                            }
                        }

                        if showLengthError {
                            HStack(spacing: 6) {
                                Image(systemName: "exclamationmark.triangle.fill")
                                    .foregroundStyle(.red)
                                Text("PIN must be 6-8 digits")
                                    .font(.caption)
                                    .foregroundStyle(.red)
                            }
                        }

                        if oldPIN == newPIN && !newPIN.isEmpty {
                            HStack(spacing: 6) {
                                Image(systemName: "exclamationmark.triangle.fill")
                                    .foregroundStyle(.orange)
                                Text("New PIN must be different from current PIN")
                                    .font(.caption)
                                    .foregroundStyle(.orange)
                            }
                        }
                    }
                    .padding(.horizontal)

                    // Requirements
                    VStack(alignment: .leading, spacing: 8) {
                        Text("PIN Requirements")
                            .font(.caption)
                            .fontWeight(.medium)
                            .foregroundStyle(.secondary)

                        VStack(alignment: .leading, spacing: 4) {
                            requirementRow("6-8 digits", met: newPIN.count >= 6 && newPIN.count <= 8)
                            requirementRow("Numbers only", met: newPIN.allSatisfy { $0.isNumber })
                            requirementRow("Different from current", met: !newPIN.isEmpty && oldPIN != newPIN)
                        }
                    }
                    .padding(.horizontal)
                    .padding(.vertical, 8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color(uiColor: .tertiarySystemBackground))
                    .cornerRadius(12)
                    .padding(.horizontal)

                    // Buttons
                    VStack(spacing: 12) {
                        Button {
                            validateAndSubmit()
                        } label: {
                            Text("Change PIN")
                                .font(.headline)
                                .frame(maxWidth: .infinity)
                                .padding()
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(!isValid)

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
                focusedField = .oldPIN
            }
        }
        .frame(minWidth: 340)
        .presentationDetents([.large])
        .interactiveDismissDisabled()
    }

    private func requirementRow(_ text: String, met: Bool) -> some View {
        HStack(spacing: 8) {
            Image(systemName: met ? "checkmark.circle.fill" : "circle")
                .foregroundStyle(met ? .green : .secondary)
                .font(.caption)
            Text(text)
                .font(.caption)
                .foregroundStyle(met ? .primary : .secondary)
        }
    }

    private func validateAndSubmit() {
        // Validate PIN length
        guard newPIN.count >= 6 && newPIN.count <= 8 else {
            showLengthError = true
            return
        }

        // Validate PINs match
        guard newPIN == confirmPIN else {
            showMismatchError = true
            return
        }

        // Validate different from old
        guard oldPIN != newPIN else {
            return
        }

        onSubmit(oldPIN, newPIN)
    }
}

#Preview {
    YubiKeyPINChangeView(
        onSubmit: { old, new in
            print("Change PIN from \(old) to \(new)")
        },
        onCancel: {
            print("Cancelled")
        }
    )
}
