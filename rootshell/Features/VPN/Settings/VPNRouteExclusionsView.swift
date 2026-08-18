//
//  VPNRouteExclusionsView.swift
//  rootshell
//
//  Route exclusion editor for VPN tunnel (CIDRs excluded from tunnel).
//

import SwiftUI

struct VPNRouteExclusionsView: View {
    @Environment(\.sheetThemeColors) private var sheetThemeColors
    @Binding var excludedRoutes: [String]
    @State private var newRoute: String = ""

    var body: some View {
        List {
            Section {
                ForEach(excludedRoutes, id: \.self) { route in
                    Text(route)
                        .font(.body.monospaced())
                        .themedRow()
                }
                .onDelete(perform: deleteRoute)
            } header: {
                Text("Excluded Routes")
            } footer: {
                Text("Traffic to these CIDR ranges will bypass the VPN and use the direct network path. Use this for local network access or to exclude specific services.")
            }

            Section("Add Route") {
                HStack {
                    TextField("CIDR (e.g., 192.168.1.0/24)", text: $newRoute)
                        .textContentType(.URL)
                        .textInputAutocapitalization(.never)
                        .submitLabel(.done)
                        .onSubmit { addRoute() }

                    Button("Add") {
                        addRoute()
                    }
                    .disabled(newRoute.trimmingCharacters(in: .whitespaces).isEmpty)
                }
                .themedRow()
            }

            Section("Common Exclusions") {
                exclusionButton(name: "Local Network", route: "192.168.0.0/16")
                    .themedRow()
                exclusionButton(name: "Local Network", route: "10.0.0.0/8")
                    .themedRow()
                exclusionButton(name: "Link-Local", route: "169.254.0.0/16")
                    .themedRow()
            }
        }
        .themedList()
        #if !os(visionOS)
        .scrollDismissesKeyboard(.interactively)
        #endif
        .navigationTitle("Route Exclusions")
    }

    private func addRoute() {
        let trimmed = newRoute.trimmingCharacters(in: .whitespaces)
        addIfMissing(trimmed)
        newRoute = ""
    }

    private func addIfMissing(_ route: String) {
        guard !route.isEmpty, !excludedRoutes.contains(route) else { return }
        excludedRoutes.append(route)
    }

    private func deleteRoute(at offsets: IndexSet) {
        excludedRoutes.remove(atOffsets: offsets)
    }

    @ViewBuilder
    private func exclusionButton(name: String, route: String) -> some View {
        let isActive = excludedRoutes.contains(route)
        Button {
            addIfMissing(route)
        } label: {
            LabeledContent {
                if isActive {
                    Image(systemName: "checkmark")
                        .foregroundStyle(.tint)
                }
            } label: {
                VStack(alignment: .leading) {
                    Text(name)
                    Text(route)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .tint(.primary)
    }
}
