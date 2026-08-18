//
//  ShaderSettingsView.swift
//  rootshell
//
//  Settings view for importing and configuring custom shaders
//

import SwiftUI
import UniformTypeIdentifiers

struct ShaderSettingsView: View {
    @Bindable private var shaderManager = ShaderManager.shared
    @State private var showingFilePicker = false
    @State private var showingImportNameSheet = false
    @State private var pendingImportURL: URL?
    @State private var importName = ""
    @State private var showingError = false
    @State private var errorMessage = ""

    @Environment(\.sheetThemeColors) private var sheetThemeColors

    var body: some View {
        List {
            // Custom shaders section
            Section {
                ForEach(shaderManager.customShaders) { shader in
                    Toggle(isOn: customBinding(for: shader)) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(shader.name)
                            Text(shader.filename.components(separatedBy: "_").dropFirst().joined(separator: "_"))
                                .font(.caption)
                                .foregroundColor(.secondary)
                                .lineLimit(1)
                        }
                    }
                    .themedRow()
                }
                .onDelete(perform: deleteCustomShaders)

                Button {
                    showingFilePicker = true
                } label: {
                    Label("Import Shader...", systemImage: "square.and.arrow.down")
                }
                .themedRow()
            } header: {
                Text("Imported Shaders")
            } footer: {
                Text("Import your own Shadertoy-compatible GLSL shaders. Configure cursor effects in Cursor settings.")
            }

            // Animation mode section (only shown if shaders are active)
            if shaderManager.hasAnyShadersActive {
                Section {
                    Picker("Animation", selection: $shaderManager.animationMode) {
                        ForEach(ShaderManager.AnimationMode.allCases, id: \.self) { mode in
                            Text(mode.displayName).tag(mode)
                        }
                    }
                    .themedRow()
                } header: {
                    Text("Shader Animation")
                } footer: {
                    animationFooterText
                }
            }
        }
        .themedList()
        .navigationTitle("Custom Shaders")
        .navigationBarTitleDisplayMode(.inline)
        .fileImporter(
            isPresented: $showingFilePicker,
            allowedContentTypes: [
                UTType(filenameExtension: "glsl") ?? .item,
                .item
            ],
            allowsMultipleSelection: false
        ) { result in
            handleFileImport(result: result)
        }
        .sheet(isPresented: $showingImportNameSheet) {
            importNameSheet
                .themedSubSheet(sheetThemeColors)
        }
        .alert("Import Error", isPresented: $showingError) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(errorMessage)
        }
    }

    // MARK: - Animation Footer

    @ViewBuilder
    private var animationFooterText: some View {
        switch shaderManager.animationMode {
        case .disabled:
            Text("Shaders only render when terminal updates. Lowest CPU usage.")
        case .whenFocused:
            Text("Shaders animate when the terminal is focused. Recommended.")
        case .always:
            Text("Shaders always animate, even when unfocused. Highest CPU usage.")
        }
    }

    // MARK: - Import Name Sheet

    private var importNameSheet: some View {
        NavigationView {
            Form {
                Section {
                    TextField("Shader Name", text: $importName)
                        .textInputAutocapitalization(.words)
                        .themedRow()
                } header: {
                    Text("Name")
                } footer: {
                    Text("Give your shader a descriptive name.")
                }
            }
            .themedList()
            .navigationTitle("Import Shader")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        showingImportNameSheet = false
                        pendingImportURL = nil
                        importName = ""
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Import") {
                        performImport()
                    }
                    .disabled(importName.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
        }
    }

    // MARK: - Bindings

    private func customBinding(for shader: ShaderManager.CustomShader) -> Binding<Bool> {
        Binding(
            get: { shaderManager.enabledCustomShaderIDs.contains(shader.id) },
            set: { enabled in
                if enabled {
                    shaderManager.enabledCustomShaderIDs.insert(shader.id)
                } else {
                    shaderManager.enabledCustomShaderIDs.remove(shader.id)
                }
            }
        )
    }

    // MARK: - File Import

    private func handleFileImport(result: Result<[URL], Error>) {
        switch result {
        case .success(let urls):
            guard let url = urls.first else { return }

            // Set default name from filename (without extension)
            let filename = url.deletingPathExtension().lastPathComponent
            importName = filename.replacingOccurrences(of: "_", with: " ").capitalized

            pendingImportURL = url
            showingImportNameSheet = true

        case .failure(let error):
            errorMessage = error.localizedDescription
            showingError = true
        }
    }

    private func performImport() {
        guard let url = pendingImportURL else { return }

        let name = importName.trimmingCharacters(in: .whitespaces)

        do {
            let shader = try shaderManager.importShader(from: url, name: name)
            // Auto-enable the newly imported shader
            shaderManager.enabledCustomShaderIDs.insert(shader.id)
        } catch {
            errorMessage = error.localizedDescription
            showingError = true
        }

        showingImportNameSheet = false
        pendingImportURL = nil
        importName = ""
    }

    // MARK: - Delete

    private func deleteCustomShaders(at offsets: IndexSet) {
        for index in offsets {
            let shader = shaderManager.customShaders[index]
            shaderManager.deleteCustomShader(id: shader.id)
        }
    }
}

#Preview {
    NavigationView {
        ShaderSettingsView()
    }
}
