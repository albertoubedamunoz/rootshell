//
//  VPNRoutingRulesEditor.swift
//  rootshell
//
//  Domain and CIDR rules choosing SSH or direct egress in the Tailscale VPN.
//

#if !CHINA_BUILD

import SwiftUI

struct VPNRoutingRulesEditor: View {
    @Binding var rules: [VPNRoutingRule]
    @State private var newPattern = ""
    @State private var newAction: VPNRoutingAction = .ssh
    @State private var testHost = ""

    var body: some View {
        Form {
            Section {
                HStack {
                    TextField(String(localized: "corp.example.com or 10.0.0.0/8", comment: "Tailscale routing rule placeholder"), text: $newPattern)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                        .keyboardType(.URL)
                        .onSubmit(add)
                    Button(String(localized: "Add", comment: "Add button"), action: add)
                        .disabled(newPattern.trimmingCharacters(in: .whitespaces).isEmpty)
                }
                Picker(String(localized: "Send To", comment: "Tailscale routing rule action picker"), selection: $newAction) {
                    ForEach(VPNRoutingAction.allCases, id: \.self) { action in
                        Text(action.title).tag(action)
                    }
                }
                .pickerStyle(.segmented)
            } footer: {
                Text("A domain also covers its subdomains. Use `*` and `?` for wildcards, or an IP address or CIDR. The first matching rule wins. Tailnet names and addresses always use Tailscale.")
            }
            .themedRow()

            Section(String(localized: "Rules", comment: "Tailscale routing rules section")) {
                if rules.isEmpty {
                    Text(String(localized: "No rules: only the tailnet uses the VPN.", comment: "Tailscale routing rules empty"))
                        .foregroundStyle(.secondary)
                }
                ForEach($rules) { $rule in
                    HStack {
                        Image(systemName: rule.action.systemImage)
                            .foregroundStyle(rule.action == .ssh ? .green : .secondary)
                        Text(rule.pattern).font(.body.monospaced())
                        Spacer(minLength: 8)
                        Picker(String(localized: "Send To", comment: "Tailscale routing rule action picker"), selection: $rule.action) {
                            ForEach(VPNRoutingAction.allCases, id: \.self) { action in
                                Text(action.title).tag(action)
                            }
                        }
                        .labelsHidden()
                        .fixedSize()
                    }
                }
                .onDelete { rules.remove(atOffsets: $0) }
                .onMove { rules.move(fromOffsets: $0, toOffset: $1) }
            }
            .themedRow()

            Section {
                TextField(String(localized: "Test a hostname or IP", comment: "Tailscale routing rule tester"), text: $testHost)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                    .keyboardType(.URL)
                if !testHost.isEmpty {
                    if let rule = VPNRoutingRuleMatcher(rules: rules).match(testHost) {
                        Label(String(localized: "\(rule.action.title) (rule \(rule.pattern))", comment: "Tailscale routing rule test result"),
                              systemImage: rule.action.systemImage)
                            .foregroundStyle(rule.action == .ssh ? .green : .secondary)
                    } else {
                        Label(String(localized: "No rule: default route", comment: "Tailscale routing rule test result"),
                              systemImage: "arrow.triangle.branch")
                            .foregroundStyle(.secondary)
                    }
                }
            } header: {
                Text("Test")
            }
            .themedRow()
        }
        .formStyle(.grouped)
        .themedList()
        .navigationTitle(String(localized: "Routing Rules", comment: "Tailscale routing rules title"))
        .toolbar { EditButton() }
    }

    private func add() {
        let pattern = newPattern.trimmingCharacters(in: .whitespaces).lowercased()
        // Needs something to match: rejects ".", "/" and the like.
        guard pattern.unicodeScalars.contains(where: { CharacterSet.alphanumerics.contains($0) || $0 == "*" || $0 == "?" }),
              !pattern.contains(where: \.isWhitespace) else { return }
        rules.append(VPNRoutingRule(pattern: pattern, action: newAction))
        newPattern = ""
    }
}

extension VPNRoutingAction {
    var title: String {
        switch self {
        case .ssh: String(localized: "SSH", comment: "Tailscale routing action: through the SSH host")
        case .direct: String(localized: "Direct", comment: "Tailscale routing action: bypass the VPN")
        }
    }

    var systemImage: String {
        switch self {
        case .ssh: "lock.shield"
        case .direct: "arrow.up.right"
        }
    }
}

/// Swift mirror of vpntunnel/routing.go, used only for the editor's tester.
struct VPNRoutingRuleMatcher {
    let rules: [VPNRoutingRule]

    func match(_ input: String) -> VPNRoutingRule? {
        let host = input.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: ". "))
        let ip = Self.ipv4(host)
        for rule in rules {
            let pattern = rule.pattern.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: ". "))
            if let (network, length) = Self.cidr(pattern) {
                if let ip, length == 0 || (ip ^ network) >> (32 - length) == 0 { return rule }
            } else if ip == nil {
                if pattern.contains("*") || pattern.contains("?") {
                    if HostRuleMatcher.glob(pattern, host) { return rule }
                } else if host == pattern || host.hasSuffix("." + pattern) {
                    return rule
                }
            }
        }
        return nil
    }

    private static func ipv4(_ s: String) -> UInt32? {
        let parts = s.split(separator: ".", omittingEmptySubsequences: false).compactMap { UInt8($0) }
        guard parts.count == 4, s.split(separator: ".").count == 4 else { return nil }
        return parts.reduce(0) { $0 << 8 | UInt32($1) }
    }

    private static func cidr(_ s: String) -> (UInt32, Int)? {
        let parts = s.split(separator: "/")
        guard parts.count <= 2, let first = parts.first, let ip = ipv4(String(first)) else { return nil }
        let length = parts.count == 2 ? Int(parts[1]) ?? -1 : 32
        return (0...32).contains(length) ? (ip, length) : nil
    }
}

#endif
