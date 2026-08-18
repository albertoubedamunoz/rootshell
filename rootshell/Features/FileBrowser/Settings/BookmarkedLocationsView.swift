#if !targetEnvironment(macCatalyst)

import SwiftUI
import UniformTypeIdentifiers

struct BookmarkedLocationsView: View {
    @Environment(\.sheetThemeColors) private var sheetThemeColors
    @ObservedObject var manager = BookmarkedLocationsManager.shared

    @State private var showFileImporter = false
    @State private var pendingFolderURL: URL?
    @State private var pendingName = ""
    @State private var showNamingSheet = false
    @State private var errorMessage: String?
    @State private var showError = false

    var body: some View {
        List {
            if manager.locations.isEmpty {
                Section {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Bookmark external folders to access them from the local shell.")
                            .foregroundColor(.secondary)
                        Text("Bookmarked folders appear as symlinks in your home directory and support tilde expansion (~name).")
                            .foregroundColor(.secondary)
                            .font(.caption)
                    }
                    .padding(.vertical, 4)
                    .themedRow()
                }
            }

            Section {
                ForEach(manager.locations) { location in
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            HStack(spacing: 6) {
                                Text(location.name)
                                    .font(.body)
                                if location.isStale {
                                    Image(systemName: "exclamationmark.triangle.fill")
                                        .font(.caption)
                                        .foregroundColor(.orange)
                                }
                            }
                            if let url = location.resolvedURL {
                                Text(url.lastPathComponent)
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                                    .lineLimit(1)
                            }
                        }
                        Spacer()
                        Text("~/\(location.name)")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    .themedRow()
                }
                .onDelete(perform: deleteLocations)
            } header: {
                if !manager.locations.isEmpty {
                    Text("Bookmarked Folders")
                }
            }
        }
        .themedList()
        .navigationTitle("Bookmarked Locations")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    showFileImporter = true
                } label: {
                    Image(systemName: "plus")
                }
            }
        }
        .fileImporter(
            isPresented: $showFileImporter,
            allowedContentTypes: [.folder]
        ) { result in
            switch result {
            case .success(let url):
                pendingFolderURL = url
                pendingName = suggestName(for: url)
                showNamingSheet = true
            case .failure(let error):
                errorMessage = error.localizedDescription
                showError = true
            }
        }
        .sheet(isPresented: $showNamingSheet) {
            NavigationStack {
                Form {
                    Section {
                        TextField("Bookmark name", text: $pendingName)
                            .autocorrectionDisabled()
                            .textInputAutocapitalization(.never)
                            .themedRow()
                    } header: {
                        Text("Name")
                    } footer: {
                        Text("This will appear as ~/\(pendingName.isEmpty ? "name" : pendingName) in your shell.")
                    }

                    if let url = pendingFolderURL {
                        Section("Selected Folder") {
                            Text(url.lastPathComponent)
                                .foregroundColor(.secondary)
                                .themedRow()
                        }
                    }
                }
                .themedList()
                .navigationTitle("Add Bookmark")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Cancel") {
                            pendingFolderURL = nil
                            pendingName = ""
                            showNamingSheet = false
                        }
                    }
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Save") {
                            saveBookmark()
                        }
                        .disabled(pendingName.trimmingCharacters(in: .whitespaces).isEmpty)
                    }
                }
            }
            .presentationDetents([.medium])
            .themedSubSheet(sheetThemeColors)
        }
        .alert("Error", isPresented: $showError) {
            Button("OK", role: .cancel) {}
        } message: {
            if let errorMessage {
                Text(errorMessage)
            }
        }
    }

    private func deleteLocations(at offsets: IndexSet) {
        for index in offsets {
            manager.removeLocation(manager.locations[index])
        }
    }

    private func saveBookmark() {
        guard let url = pendingFolderURL else { return }
        let name = pendingName.trimmingCharacters(in: .whitespaces)

        do {
            try manager.addLocation(name: name, folderURL: url)
            pendingFolderURL = nil
            pendingName = ""
            showNamingSheet = false
        } catch {
            errorMessage = error.localizedDescription
            showError = true
        }
    }

    private func suggestName(for url: URL) -> String {
        let name = url.lastPathComponent
            .lowercased()
            .replacingOccurrences(of: " ", with: "-")
            .filter { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" }

        if name.isEmpty || name == "." || name == ".." {
            return "folder"
        }

        // Truncate to 64 chars
        return String(name.prefix(64))
    }
}

#endif // !targetEnvironment(macCatalyst)
