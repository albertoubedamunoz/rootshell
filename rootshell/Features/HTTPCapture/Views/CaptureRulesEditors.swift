//
//  CaptureRulesEditors.swift
//  rootshell
//
//  Editors for decrypted-host rules (Surge syntax) and header/body rewrite rules.
//

#if !CHINA_BUILD

import SwiftUI

struct HostRulesEditor: View {
    @State var rules: [String]
    @State private var newRule = ""
    @State private var testHost = ""

    var body: some View {
        Form {
            Section {
                HStack {
                    TextField(String(localized: "*.example.com", comment: "HTTP capture host rule placeholder"), text: $newRule)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                        .keyboardType(.URL)
                        .onSubmit(add)
                    Button(String(localized: "Add", comment: "Add button"), action: add)
                        .disabled(newRule.trimmingCharacters(in: .whitespaces).isEmpty)
                }
                Button(String(localized: "Decrypt All Hosts", comment: "HTTP capture host rule shortcut")) {
                    if !rules.contains("*") { rules.append("*") }
                    save()
                }
                .disabled(rules.contains("*"))
            } footer: {
                Text("`*.example.com` matches subdomains, `?` one character, `-host` excludes, `host:8443` adds a port (`:0` any port), `*` matches everything. The first matching rule wins.")
            }
            .themedRow()

            Section(String(localized: "Rules", comment: "HTTP capture host rules section")) {
                if rules.isEmpty {
                    Text(String(localized: "No rules: HTTPS is never decrypted.", comment: "HTTP capture host rules empty")).foregroundStyle(.secondary)
                }
                ForEach(Array(rules.enumerated()), id: \.offset) { _, rule in
                    HStack {
                        Image(systemName: rule.hasPrefix("-") ? "minus.circle" : "lock.open")
                            .foregroundStyle(rule.hasPrefix("-") ? .orange : .green)
                        Text(rule).font(.body.monospaced())
                    }
                }
                .onDelete { rules.remove(atOffsets: $0); save() }
                .onMove { rules.move(fromOffsets: $0, toOffset: $1); save() }
            }
            .themedRow()

            Section {
                TextField(String(localized: "Test a hostname", comment: "HTTP capture host rule tester"), text: $testHost)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                    .keyboardType(.URL)
                if !testHost.isEmpty {
                    let match = HostRuleMatcher(rules: rules).match(host: testHost)
                    Label(match.decrypt
                          ? String(localized: "Decrypted (rule \(match.rule ?? ""))", comment: "HTTP capture host rule test result")
                          : String(localized: "Not decrypted\(match.rule.map { " (rule \($0))" } ?? "")", comment: "HTTP capture host rule test result"),
                          systemImage: match.decrypt ? "lock.open" : "lock")
                        .foregroundStyle(match.decrypt ? .green : .secondary)
                }
            } header: {
                Text("Test")
            }
            .themedRow()
        }
        .formStyle(.grouped)
        .themedList()
        .navigationTitle(String(localized: "Decrypted Hosts", comment: "HTTP capture host rules title"))
        .toolbar { EditButton() }
    }

    private func add() {
        let rule = newRule.trimmingCharacters(in: .whitespaces).lowercased()
        guard !rule.isEmpty else { return }
        // Exclusions go first so they win over broader includes.
        if rule.hasPrefix("-") { rules.insert(rule, at: 0) } else { rules.append(rule) }
        newRule = ""
        save()
    }

    private func save() {
        CaptureController.shared.saveHostRules(rules)
    }
}

/// Swift mirror of vpntunnel/hostmatch.go, used only for the editor's tester.
struct HostRuleMatcher {
    let rules: [String]

    func match(host: String, port: Int = 443) -> (decrypt: Bool, rule: String?) {
        let host = host.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: ". "))
        for raw in rules {
            var s = raw.lowercased().trimmingCharacters(in: .whitespaces)
            guard !s.isEmpty, !s.hasPrefix("#") else { continue }
            let exclude = s.hasPrefix("-")
            if exclude { s.removeFirst() }
            var rulePort = -1
            if s.filter({ $0 == ":" }).count == 1, let i = s.lastIndex(of: ":"), let p = Int(s[s.index(after: i)...]) {
                rulePort = p
                s = String(s[..<i])
            }
            let portOK = rulePort == -1 ? port == 443 : (rulePort == 0 || rulePort == port)
            if portOK && Self.glob(s, host) { return (!exclude, raw) }
        }
        return (false, nil)
    }

    static func glob(_ pattern: String, _ s: String) -> Bool {
        let p = Array(pattern), t = Array(s)
        var pi = 0, ti = 0, star = -1, mark = 0
        while ti < t.count {
            if pi < p.count, p[pi] == "?" || p[pi] == t[ti] {
                pi += 1; ti += 1
            } else if pi < p.count, p[pi] == "*" {
                star = pi; mark = ti; pi += 1
            } else if star >= 0 {
                pi = star + 1; mark += 1; ti = mark
            } else {
                return false
            }
        }
        while pi < p.count, p[pi] == "*" { pi += 1 }
        return pi == p.count
    }
}

// MARK: - Rewrite rules

struct RewriteRulesList: View {
    @State private var rules = CaptureController.rewriteRules()
    @State private var editing: CaptureRewriteRule?
    @Environment(\.sheetThemeColors) private var sheetThemeColors

    var body: some View {
        List {
            Section {
                if rules.isEmpty {
                    Text(String(localized: "No rewrite rules. Add one here or from a request's menu.", comment: "HTTP capture rewrite rules empty"))
                        .foregroundStyle(.secondary)
                }
                ForEach($rules) { $rule in
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(rule.name.isEmpty ? rule.match : rule.name)
                            Text(RewriteRuleEditor.summary(rule)).font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Toggle("", isOn: $rule.enabled).labelsHidden()
                    }
                    .contentShape(Rectangle())
                    .onTapGesture { editing = rule }
                }
                .onDelete { rules.remove(atOffsets: $0) }
                .onMove { rules.move(fromOffsets: $0, toOffset: $1) }
            } footer: {
                Text("Rules run in order on decrypted and plain HTTP traffic. Body rewrites apply to bodies up to 1 MB.")
            }
            .themedRow()
        }
        .themedList()
        .navigationTitle(String(localized: "Rewrite Rules", comment: "HTTP capture rewrite rules title"))
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button { editing = CaptureRewriteRule() } label: { Image(systemName: "plus") }
                    .accessibilityLabel(String(localized: "Add Rule", comment: "HTTP capture add rewrite rule"))
            }
            ToolbarItem(placement: .secondaryAction) { EditButton() }
        }
        .onChange(of: rules) { _, newRules in CaptureController.shared.saveRewriteRules(newRules) }
        .sheet(item: $editing) { rule in
            NavigationStack {
                RewriteRuleEditor(rule: rule) { saved in
                    if let index = rules.firstIndex(where: { $0.id == saved.id }) {
                        rules[index] = saved
                    } else {
                        rules.append(saved)
                    }
                }
            }
            .themedSubSheet(sheetThemeColors)
        }
    }
}

struct RewriteRuleEditor: View {
    @State var rule: CaptureRewriteRule
    let onSave: (CaptureRewriteRule) -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        Form {
            Section {
                TextField(String(localized: "Name (optional)", comment: "HTTP capture rewrite rule field"), text: $rule.name)
                TextField(String(localized: "URL pattern", comment: "HTTP capture rewrite rule field"), text: $rule.match)
                    .font(.body.monospaced())
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                    .keyboardType(.URL)
                Toggle(String(localized: "Regular Expression", comment: "HTTP capture rewrite rule field"), isOn: $rule.isRegex)
            } header: {
                Text("Match")
            } footer: {
                Text(rule.isRegex
                     ? String(localized: "Matched against the full URL.", comment: "HTTP capture rewrite rule help")
                     : String(localized: "`*` matches anything: `api.example.com/v1/*`, `*://*.example.com/*`.", comment: "HTTP capture rewrite rule help"))
            }
            .themedRow()

            Section(String(localized: "Action", comment: "HTTP capture rewrite rule section")) {
                Picker(String(localized: "Applies To", comment: "HTTP capture rewrite rule field"), selection: $rule.phase) {
                    Text(String(localized: "Request", comment: "HTTP capture message side")).tag(CaptureRewriteRule.Phase.request)
                    Text(String(localized: "Response", comment: "HTTP capture message side")).tag(CaptureRewriteRule.Phase.response)
                }
                .pickerStyle(.segmented)
                Picker(String(localized: "Action", comment: "HTTP capture rewrite rule field"), selection: $rule.action) {
                    Text(String(localized: "Add Header", comment: "HTTP capture rewrite action")).tag(CaptureRewriteRule.Action.addHeader)
                    Text(String(localized: "Set Header", comment: "HTTP capture rewrite action")).tag(CaptureRewriteRule.Action.setHeader)
                    Text(String(localized: "Remove Header", comment: "HTTP capture rewrite action")).tag(CaptureRewriteRule.Action.removeHeader)
                    Text(String(localized: "Replace in Body", comment: "HTTP capture rewrite action")).tag(CaptureRewriteRule.Action.replaceBody)
                }
                switch rule.action {
                case .addHeader, .setHeader:
                    TextField(String(localized: "Header name", comment: "HTTP capture rewrite rule field"), text: $rule.header)
                        .autocorrectionDisabled().textInputAutocapitalization(.never)
                    TextField(String(localized: "Value", comment: "HTTP capture rewrite rule field"), text: $rule.value)
                        .autocorrectionDisabled().textInputAutocapitalization(.never)
                case .removeHeader:
                    TextField(String(localized: "Header name", comment: "HTTP capture rewrite rule field"), text: $rule.header)
                        .autocorrectionDisabled().textInputAutocapitalization(.never)
                case .replaceBody:
                    TextField(String(localized: "Find", comment: "HTTP capture rewrite rule field"), text: $rule.find, axis: .vertical)
                        .font(.body.monospaced()).autocorrectionDisabled().textInputAutocapitalization(.never)
                    TextField(String(localized: "Replace with", comment: "HTTP capture rewrite rule field"), text: $rule.replace, axis: .vertical)
                        .font(.body.monospaced()).autocorrectionDisabled().textInputAutocapitalization(.never)
                    Toggle(String(localized: "Regular Expression ($1 for groups)", comment: "HTTP capture rewrite rule field"), isOn: $rule.bodyRegex)
                }
            }
            .themedRow()

            if let problem = validation {
                Section { Label(problem, systemImage: "exclamationmark.triangle").foregroundStyle(.orange) }
                    .themedRow()
            }

            Section {
                Toggle(String(localized: "Enabled", comment: "HTTP capture rewrite rule field"), isOn: $rule.enabled)
            }
            .themedRow()
        }
        .formStyle(.grouped)
        .themedList()
        .navigationTitle(String(localized: "Rewrite Rule", comment: "HTTP capture rewrite rule editor title"))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button(String(localized: "Cancel", comment: "Cancel button")) { dismiss() }
            }
            ToolbarItem(placement: .confirmationAction) {
                Button(String(localized: "Save", comment: "Save button")) {
                    onSave(rule)
                    dismiss()
                }
                .disabled(validation != nil)
            }
        }
    }

    private var validation: String? {
        if rule.match.trimmingCharacters(in: .whitespaces).isEmpty {
            return String(localized: "Enter a URL pattern.", comment: "HTTP capture rewrite rule validation")
        }
        if rule.isRegex, (try? NSRegularExpression(pattern: rule.match)) == nil {
            return String(localized: "The URL pattern is not a valid regular expression.", comment: "HTTP capture rewrite rule validation")
        }
        switch rule.action {
        case .addHeader, .setHeader, .removeHeader:
            if rule.header.trimmingCharacters(in: .whitespaces).isEmpty {
                return String(localized: "Enter a header name.", comment: "HTTP capture rewrite rule validation")
            }
        case .replaceBody:
            if rule.find.isEmpty {
                return String(localized: "Enter the text to find.", comment: "HTTP capture rewrite rule validation")
            }
            if rule.bodyRegex, (try? NSRegularExpression(pattern: rule.find)) == nil {
                return String(localized: "The find pattern is not a valid regular expression.", comment: "HTTP capture rewrite rule validation")
            }
        }
        return nil
    }

    static func summary(_ rule: CaptureRewriteRule) -> String {
        let side = rule.phase == .request
            ? String(localized: "Request", comment: "HTTP capture message side")
            : String(localized: "Response", comment: "HTTP capture message side")
        switch rule.action {
        case .addHeader: return "\(side): + \(rule.header): \(rule.value)"
        case .setHeader: return "\(side): \(rule.header) = \(rule.value)"
        case .removeHeader: return "\(side): − \(rule.header)"
        case .replaceBody: return "\(side): \(rule.find) → \(rule.replace)"
        }
    }
}

#endif
