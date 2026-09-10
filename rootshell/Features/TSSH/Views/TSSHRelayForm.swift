import SwiftUI

/// Shared by quick connect and the saved-profile editor.
struct TSSHRelayForm: View {
    @Binding var settings: TSSHRelaySettings?

    var body: some View {
        Picker("Jump Connection", selection: Binding(
            get: { settings != nil },
            set: { settings = $0 ? TSSHRelaySettings() : nil }
        )) {
            Text("SSH bootstrap only").tag(false)
            Text("Relay full session").tag(true)
        }
        .themedRow()

        if settings != nil {
            Text("Install tsshd on both hosts. Allow UDP from this device to the jump host, and from the jump host to the target. The target does not need to be reachable directly from this device.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .themedRow()
        } else {
            Text("The jump host starts tsshd over SSH. This device must then reach the target directly over UDP.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .themedRow()
        }
    }
}

/// Place after the jump host's connection and authentication fields.
struct TSSHRelayAdvancedForm: View {
    @Binding var settings: TSSHRelaySettings?
    @State private var isExpanded = false
    @State private var minimum = ""
    @State private var maximum = ""

    var body: some View {
        if settings != nil {
            DisclosureGroup("Advanced", isExpanded: $isExpanded) {
                HStack {
                    Text("Port Min")
                    Spacer()
                    TextField("Default (\(TrzszConfig.preferredUDPPortMin))", text: $minimum)
                        .keyboardType(.numberPad)
                        .multilineTextAlignment(.trailing)
                        .frame(width: 140)
                }

                HStack {
                    Text("Port Max")
                    Spacer()
                    TextField("Default (\(TrzszConfig.preferredUDPPortMax))", text: $maximum)
                        .keyboardType(.numberPad)
                        .multilineTextAlignment(.trailing)
                        .frame(width: 140)
                }

                TextField("tsshd Binary (e.g. /usr/local/bin/tsshd)", text: Binding(
                    get: { settings?.serverPath ?? "" },
                    set: { settings?.serverPath = $0.isEmpty ? nil : $0 }
                ))
                .autocapitalization(.none)
                .autocorrectionDisabled()

                Text("Empty port fields inherit from Settings → Roam. Both hops use the session’s transport mode.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .themedRow()
            .onAppear { loadPorts() }
            .onChange(of: settings?.boundJump) { _, _ in loadPorts() }
            .onChange(of: minimum) { _, value in settings?.udpPortMin = value.isEmpty ? nil : (Int(value) ?? -1) }
            .onChange(of: maximum) { _, value in settings?.udpPortMax = value.isEmpty ? nil : (Int(value) ?? -1) }
        }
    }

    private func loadPorts() {
        minimum = settings?.udpPortMin.map(String.init) ?? ""
        maximum = settings?.udpPortMax.map(String.init) ?? ""
    }
}
