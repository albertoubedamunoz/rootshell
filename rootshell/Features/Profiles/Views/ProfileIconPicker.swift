import SwiftUI

/// Icon picker for connection profiles: curated SF Symbols, Nerd Font
/// dev icons, and a website-favicon option, with search across both
/// catalogs. Pushed inside the presenting NavigationStack (profile
/// editor panel) rather than shown as a separate sheet.
struct ProfileIconPicker: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.sheetThemeColors) private var sheetThemeColors
    @Binding var selectedIcon: String
    let host: String?

    private enum Tab: Hashable {
        case symbols, devIcons, website
    }

    @State private var tab: Tab
    @State private var searchText = ""
    @State private var customHost: String
    @State private var debouncedCustomHost: String

    init(selectedIcon: Binding<String>, host: String?) {
        self._selectedIcon = selectedIcon
        self.host = host
        var initialCustomHost = ""
        switch ProfileIcon(storageString: selectedIcon.wrappedValue) {
        case .nerd:
            self._tab = State(initialValue: .devIcons)
        case .favicon(let customHost):
            self._tab = State(initialValue: .website)
            initialCustomHost = customHost ?? ""
        case .symbol:
            self._tab = State(initialValue: .symbols)
        }
        self._customHost = State(initialValue: initialCustomHost)
        self._debouncedCustomHost = State(initialValue: initialCustomHost)
    }

    private var trimmedSearch: String {
        searchText.trimmingCharacters(in: .whitespaces)
    }

    private var trimmedHost: String {
        (host ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var body: some View {
        VStack(spacing: 0) {
            Picker("Icon Type", selection: $tab) {
                Text("Symbols").tag(Tab.symbols)
                Text("Dev Icons").tag(Tab.devIcons)
                Text("Website").tag(Tab.website)
            }
            .pickerStyle(.segmented)
            .padding(.horizontal)
            .padding(.vertical, 8)

            selectionRow

            if !trimmedSearch.isEmpty {
                searchResults
            } else {
                switch tab {
                case .symbols:
                    categoryGrid(ProfileIconCatalog.symbolCategories)
                case .devIcons:
                    categoryGrid(ProfileIconCatalog.nerdCategories)
                case .website:
                    websiteTab
                }
            }
        }
        .background {
            if let sheetThemeColors {
                sheetThemeColors.background.ignoresSafeArea()
            }
        }
        .searchable(text: $searchText, placement: .navigationBarDrawer(displayMode: .always), prompt: "Search icons")
        .navigationTitle("Choose Icon")
        .navigationBarTitleDisplayMode(.inline)
    }

    // MARK: - Current selection

    private var selectionRow: some View {
        let icon = ProfileIcon(storageString: selectedIcon)
        return HStack(spacing: 8) {
            Text("Selected:")
                .font(.callout)
                .foregroundStyle(.secondary)
            ProfileIconView(icon: icon, host: trimmedHost)
            Text(ProfileIconCatalog.displayName(for: icon))
                .font(.callout.weight(.medium))
            Spacer()
        }
        .padding(.horizontal)
        .padding(.bottom, 8)
    }

    // MARK: - Grids

    private func categoryGrid(_ categories: [ProfileIconCategory]) -> some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 8) {
                ForEach(categories) { category in
                    categoryHeader(category.title)
                    iconGrid(category.entries)
                }
            }
            .padding()
        }
    }

    private var searchResults: some View {
        let results = ProfileIconCatalog.search(trimmedSearch)
        return ScrollView {
            LazyVStack(alignment: .leading, spacing: 8) {
                if results.symbols.isEmpty && results.nerd.isEmpty {
                    ContentUnavailableView.search(text: trimmedSearch)
                        .padding(.top, 40)
                } else {
                    if !results.symbols.isEmpty {
                        categoryHeader("Symbols")
                        iconGrid(results.symbols)
                    }
                    if !results.nerd.isEmpty {
                        categoryHeader("Dev Icons")
                        iconGrid(results.nerd)
                    }
                }
            }
            .padding()
        }
    }

    private func categoryHeader(_ title: LocalizedStringResource) -> some View {
        Text(title)
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(.secondary)
            .padding(.top, 8)
    }

    private func iconGrid(_ entries: [ProfileIconEntry]) -> some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 50))], spacing: 12) {
            ForEach(entries) { entry in
                iconCell(entry)
            }
        }
    }

    private func iconCell(_ entry: ProfileIconEntry) -> some View {
        Button {
            selectedIcon = entry.icon.storageString
            dismiss()
        } label: {
            ProfileIconView(icon: entry.icon, tint: .primary, size: 22)
                .frame(width: 44, height: 44)
                .background(selectedIcon == entry.icon.storageString ? Color.accentColor.opacity(0.2) : Color.clear)
                .cornerRadius(8)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(entry.displayName)
    }

    // MARK: - Website tab

    private var trimmedCustomHost: String {
        customHost.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Domain the Use button would store: custom entry wins, else profile host
    private var commitDomain: String {
        trimmedCustomHost.isEmpty ? trimmedHost : trimmedCustomHost
    }

    private var websiteTab: some View {
        let previewCustom = debouncedCustomHost.trimmingCharacters(in: .whitespacesAndNewlines)
        return ScrollView {
            VStack(spacing: 16) {
                ProfileIconView(
                    icon: .favicon(customHost: previewCustom.isEmpty ? nil : previewCustom),
                    size: 48,
                    host: trimmedHost
                )
                .padding(.top, 24)

                if commitDomain.isEmpty {
                    Text("Enter a hostname below, or set the profile's host first.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                } else {
                    Text(commitDomain)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }

                TextField("Custom hostname (optional)", text: $customHost)
                    .textFieldStyle(.roundedBorder)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .keyboardType(.URL)
                    .frame(maxWidth: 320)
                    .task(id: customHost) {
                        // Debounce so the preview doesn't fetch per keystroke
                        try? await Task.sleep(for: .milliseconds(400))
                        if !Task.isCancelled { debouncedCustomHost = customHost }
                    }

                Button {
                    let custom = trimmedCustomHost
                    selectedIcon = ProfileIcon.favicon(customHost: custom.isEmpty ? nil : custom).storageString
                    dismiss()
                } label: {
                    Text("Use Website Icon")
                }
                .buttonStyle(.borderedProminent)
                .disabled(commitDomain.isEmpty)

                Text("The icon is fetched from the hostname and updates automatically. Leave the field blank to follow the profile's host.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            .frame(maxWidth: .infinity)
            .padding()
        }
    }
}
