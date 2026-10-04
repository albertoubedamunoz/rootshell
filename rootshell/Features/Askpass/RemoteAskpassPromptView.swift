import SwiftUI

/// Sheet for answering a credential request from a remote host. The
/// single `.password` field lets the OS password manager (e.g.
/// 1Password) fill it. Mirrors ``KeyboardInteractivePromptView``.
struct RemoteAskpassPromptView: View {
    let request: RemoteAskpassRequest
    let onSubmit: (String) -> Void
    let onCancel: () -> Void

    @State private var secret = ""
    @FocusState private var isFocused: Bool

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    HStack {
                        Image(systemName: "key.horizontal")
                            .foregroundColor(.secondary)
                        VStack(alignment: .leading) {
                            Text(request.sessionName)
                                .font(.headline)
                            Text(request.remoteHost)
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                    }
                    .themedRow()
                } header: {
                    Text("Connection")
                }

                if !request.command.isEmpty {
                    Section {
                        Text(request.command)
                            .font(.system(.footnote, design: .monospaced))
                            .textSelection(.enabled)
                            .themedRow()
                    } header: {
                        Text("Command")
                    } footer: {
                        Text("Reported by the server.")
                    }
                }

                Section {
                    SecureField("Password", text: $secret)
                        .textContentType(.password)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .focused($isFocused)
                        .submitLabel(.send)
                        .onSubmit(submit)
                        .background { usernameAnchor }
                        .themedRow()
                } header: {
                    Text(request.prompt.isEmpty ? "Password" : request.prompt)
                } footer: {
                    Text("The value is sent only to the program that asked for it.")
                }
            }
            .themedList()
            .navigationTitle("Credential Request")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { finish(nil) }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Send", action: submit)
                        .disabled(secret.isEmpty)
                        .fontWeight(.semibold)
                }
            }
            .onAppear {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                    isFocused = true
                }
            }
        }
        .presentationDragIndicator(.visible)
    }

    /// Invisible username field so AutoFill treats this as a login form.
    /// See ``KeyboardInteractivePromptView``.
    @ViewBuilder
    private var usernameAnchor: some View {
        if !request.remoteUser.isEmpty {
            TextField("", text: .constant(request.remoteUser))
                .textContentType(.username)
                .frame(width: 0, height: 0)
                .opacity(0)
                .accessibilityHidden(true)
                .allowsHitTesting(false)
        }
    }

    private func submit() {
        guard !secret.isEmpty else { return }
        finish(secret)
    }

    private func finish(_ value: String?) {
        secret = ""
        if let value {
            onSubmit(value)
        } else {
            onCancel()
        }
    }
}
