import SwiftUI
import UniformTypeIdentifiers

struct BackupRestoreView: View {
    @State private var selectedTab = 0

    var body: some View {
        List {
            Section {
                Picker("", selection: $selectedTab) {
                    Text("Create Backup").tag(0)
                    Text("Restore Backup").tag(1)
                }
                .pickerStyle(.segmented)
                .listRowBackground(Color.clear)
                .listRowInsets(EdgeInsets(top: 8, leading: 0, bottom: 8, trailing: 0))
            }

            if selectedTab == 0 {
                BackupCreateSection()
            } else {
                BackupRestoreSection()
            }
        }
        .themedList()
        .navigationTitle("Backup & Restore")
    }
}

// MARK: - Create Backup

private struct BackupCreateSection: View {
    @State private var selectedCategories: Set<BackupCategory> = Set(BackupCategory.allCases)
    @State private var password = ""
    @State private var confirmPassword = ""
    @State private var isExporting = false
    @State private var showShareSheet = false
    @State private var showFileSaver = false
    @State private var savedFileURL: URL?
    @State private var showCancelledWarning = false
    @State private var exportError: String?
    @State private var showError = false

    private var backupManager: BackupManager { BackupManager.shared }

    private var passwordsMatch: Bool {
        !password.isEmpty && password == confirmPassword
    }

    private var passwordLongEnough: Bool {
        password.count >= 8
    }

    private var canExport: Bool {
        !selectedCategories.isEmpty && passwordsMatch && passwordLongEnough
    }

    private var hasSensitiveCategories: Bool {
        selectedCategories.contains(where: \.isSensitive)
    }

    var body: some View {
        Section {
            ForEach(BackupCategory.allCases) { category in
                Toggle(isOn: binding(for: category)) {
                    HStack(spacing: 12) {
                        Image(systemName: category.systemImage)
                            .foregroundStyle(.tint)
                            .frame(width: 28)
                        VStack(alignment: .leading) {
                            Text(category.displayName)
                            if let count = itemCount(for: category), count > 0 {
                                Text("\(count) items")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                        }
                    }
                }
                .themedRow()
            }
        } header: {
            Text("Categories")
        } footer: {
            if hasSensitiveCategories {
                Text("Selected categories include sensitive data (SSH keys, passwords, API keys). This data will be encrypted with your password.")
                    .font(.caption)
            }
        }
        .alert("Backup Failed", isPresented: $showError) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(exportError ?? "An unknown error occurred.")
        }

        Section {
            SecureField("Password (min 8 characters)", text: $password)
                .textContentType(.newPassword)
                .themedRow()
            SecureField("Confirm Password", text: $confirmPassword)
                .textContentType(.newPassword)
                .themedRow()

            if !password.isEmpty && !passwordLongEnough {
                Text("Password must be at least 8 characters")
                    .font(.caption)
                    .foregroundColor(.red)
                    .themedRow()
            } else if !password.isEmpty && !confirmPassword.isEmpty && !passwordsMatch {
                Text("Passwords do not match")
                    .font(.caption)
                    .foregroundColor(.red)
                    .themedRow()
            }
        } header: {
            Text("Encryption")
        } footer: {
            Text("Encrypted with AES-256-GCM using a key derived via PBKDF2-HMAC-SHA256 (600,000 iterations). There is no way to recover data if you forget this password.")
                .font(.caption)
        }

        .fileMover(
            isPresented: $showFileSaver,
            file: backupManager.lastBackupURL
        ) { result in
            switch result {
            case .success(let url):
                guard url.startAccessingSecurityScopedResource() else { return }
                savedFileURL = url
                url.stopAccessingSecurityScopedResource()
            case .failure(let error):
                exportError = "Failed to save: \(error.localizedDescription)"
                showError = true
            }
        } onCancellation: {
            showCancelledWarning = true
        }

        Section {
            Button {
                Task { await createBackup() }
            } label: {
                HStack {
                    Spacer()
                    if case .exporting = backupManager.state {
                        ProgressView()
                            .padding(.trailing, 8)
                        Text("Creating Backup...")
                    } else {
                        Text("Create Backup")
                    }
                    Spacer()
                }
            }
            .disabled(!canExport || isExporting)
            .themedRow()

            if let summary = backupManager.exportSummary, !summary.skippedKeys.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Skipped keys (biometric cancelled):")
                        .font(.caption)
                        .foregroundColor(.orange)
                    ForEach(summary.skippedKeys, id: \.self) { name in
                        Text("  - \(name)")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }
                .themedRow()
            }
        }

        if let savedURL = savedFileURL {
            Section {
                HStack(spacing: 12) {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundColor(.green)
                        .font(.title2)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Backup Saved")
                            .font(.headline)
                        Text(savedURL.lastPathComponent)
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }
                .themedRow()

                ShareLink(item: savedURL) {
                    HStack {
                        Spacer()
                        Label("Share Backup File", systemImage: "square.and.arrow.up")
                        Spacer()
                    }
                }
                .themedRow()
            } footer: {
                if let summary = backupManager.exportSummary {
                    Text("Backup contains \(summary.totalItems) items across \(summary.categoryCounts.count) categories.")
                        .font(.caption)
                }
            }
        } else if showCancelledWarning, let url = backupManager.lastBackupURL {
            Section {
                HStack(spacing: 12) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundColor(.orange)
                        .font(.title2)
                    Text("Backup was created but not saved to a persistent location. It will be deleted when the app closes.")
                        .font(.caption)
                }
                .themedRow()

                Button {
                    showFileSaver = true
                } label: {
                    HStack {
                        Spacer()
                        Label("Save Backup File", systemImage: "folder")
                        Spacer()
                    }
                }
                .themedRow()

                ShareLink(item: url) {
                    HStack {
                        Spacer()
                        Label("Share Backup File", systemImage: "square.and.arrow.up")
                        Spacer()
                    }
                }
                .themedRow()
            } footer: {
                if let summary = backupManager.exportSummary {
                    Text("Backup contains \(summary.totalItems) items across \(summary.categoryCounts.count) categories.")
                        .font(.caption)
                }
            }
        }

    }

    private func binding(for category: BackupCategory) -> Binding<Bool> {
        Binding(
            get: { selectedCategories.contains(category) },
            set: { isOn in
                if isOn {
                    selectedCategories.insert(category)
                } else {
                    selectedCategories.remove(category)
                }
            }
        )
    }

    @MainActor
    private func itemCount(for category: BackupCategory) -> Int? {
        switch category {
        case .sshKeys: SSHKeyManager.shared.savedKeys.count
        case .sshPasswords: SSHPasswordManager.shared.savedPasswords.count
        case .connectionHistory: SSHConnectionHistoryManager.shared.entries.count
        case .knownHosts: KnownHostsManager.shared.allHosts.count
        case .connectionProfiles: ConnectionProfileManager.shared.profiles.count
        case .customThemes: CustomThemeManager.shared.customThemes.count
        case .customFonts: FontManager.shared.customFontFamilies.count
        case .cloudAccounts: CloudAccountManager.shared.accounts.count
        default: nil
        }
    }

    private func createBackup() async {
        isExporting = true
        savedFileURL = nil
        showCancelledWarning = false
        defer { isExporting = false }

        do {
            _ = try await backupManager.createBackup(
                categories: selectedCategories,
                password: password
            )
            showFileSaver = true
        } catch let error as BackupError where error.errorDescription != nil {
            exportError = error.errorDescription
            showError = true
        } catch {
            exportError = error.localizedDescription
            showError = true
        }
    }
}

// MARK: - Restore Backup

private struct BackupRestoreSection: View {
    @State private var showFilePicker = false
    @State private var selectedFileURL: URL?
    @State private var password = ""
    @State private var manifest: BackupManifest?
    @State private var selectedCategories: Set<BackupCategory> = []
    @State private var isValidating = false
    @State private var isRestoring = false
    @State private var errorMessage: String?
    @State private var showError = false

    private var backupManager: BackupManager { BackupManager.shared }

    var body: some View {
        Section {
            Button {
                showFilePicker = true
            } label: {
                HStack(spacing: 12) {
                    Image(systemName: "doc.badge.plus")
                        .foregroundStyle(.tint)
                        .frame(width: 28)
                    Text(selectedFileURL != nil ? selectedFileURL!.lastPathComponent : "Select Backup File")
                    Spacer()
                    if selectedFileURL != nil {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundColor(.green)
                    }
                }
            }
            .themedRow()
        } header: {
            Text("Backup File")
        }
        .fileImporter(
            isPresented: $showFilePicker,
            allowedContentTypes: [.rootshellBackup, .data],
            allowsMultipleSelection: false
        ) { result in
            switch result {
            case .success(let urls):
                selectedFileURL = urls.first
                manifest = nil
                selectedCategories = []
                errorMessage = nil
            case .failure(let error):
                errorMessage = error.localizedDescription
                showError = true
            }
        }
        .alert("Error", isPresented: $showError) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(errorMessage ?? "An unknown error occurred.")
        }

        if selectedFileURL != nil {
            Section {
                SecureField("Backup Password", text: $password)
                    .textContentType(.password)
                    .themedRow()

                Button {
                    Task { await validateBackup() }
                } label: {
                    HStack {
                        Spacer()
                        if isValidating {
                            ProgressView()
                                .padding(.trailing, 8)
                            Text("Validating...")
                        } else {
                            Text("Validate & Preview")
                        }
                        Spacer()
                    }
                }
                .disabled(password.isEmpty || isValidating)
                .themedRow()
            } header: {
                Text("Password")
            }
        }

        if let manifest {
            Section {
                HStack {
                    Text("Created")
                    Spacer()
                    Text(manifest.createdAt.formatted(date: .abbreviated, time: .shortened))
                        .foregroundColor(.secondary)
                }
                .themedRow()
                HStack {
                    Text("Device")
                    Spacer()
                    Text(manifest.deviceName)
                        .foregroundColor(.secondary)
                }
                .themedRow()
                HStack {
                    Text("App Version")
                    Spacer()
                    Text("\(manifest.appVersion) (\(manifest.appBuild))")
                        .foregroundColor(.secondary)
                }
                .themedRow()
            } header: {
                Text("Backup Info")
            }

            Section {
                ForEach(BackupCategory.allCases) { category in
                    if let count = manifest.categoryCounts[category] {
                        Toggle(isOn: restoreBinding(for: category)) {
                            HStack(spacing: 12) {
                                Image(systemName: category.systemImage)
                                    .foregroundStyle(.tint)
                                    .frame(width: 28)
                                Text(category.displayName)
                                Spacer()
                                Text("\(count)")
                                    .foregroundColor(.secondary)
                                    .font(.subheadline)
                            }
                        }
                        .themedRow()
                    }
                }
            } header: {
                Text("Select Categories to Restore")
            } footer: {
                Text("New items will be added. For connection history, known hosts, and profiles, newer records from the backup will update older local copies. Keys, passwords, and themes are skipped if they already exist.")
                    .font(.caption)
            }

            Section {
                Button {
                    Task { await restoreBackup() }
                } label: {
                    HStack {
                        Spacer()
                        if isRestoring {
                            ProgressView()
                                .padding(.trailing, 8)
                            Text("Restoring...")
                        } else {
                            Text("Restore Selected")
                        }
                        Spacer()
                    }
                }
                .disabled(selectedCategories.isEmpty || isRestoring)
                .themedRow()
            }
        }

        if let summary = backupManager.restoreSummary {
            Section {
                ForEach(BackupCategory.allCases) { category in
                    if let result = summary.results[category] {
                        VStack(alignment: .leading, spacing: 4) {
                            HStack {
                                Image(systemName: category.systemImage)
                                    .foregroundStyle(.tint)
                                    .frame(width: 20)
                                Text(category.displayName)
                                    .font(.subheadline.weight(.medium))
                                Spacer()
                            }
                            HStack(spacing: 16) {
                                if result.restored > 0 {
                                    Label("\(result.restored) restored", systemImage: "checkmark.circle")
                                        .font(.caption)
                                        .foregroundColor(.green)
                                }
                                if result.skipped > 0 {
                                    Label("\(result.skipped) skipped", systemImage: "minus.circle")
                                        .font(.caption)
                                        .foregroundColor(.secondary)
                                }
                                if !result.errors.isEmpty {
                                    Label("\(result.errors.count) errors", systemImage: "exclamationmark.circle")
                                        .font(.caption)
                                        .foregroundColor(.red)
                                }
                            }
                            ForEach(result.errors, id: \.self) { error in
                                Text(error)
                                    .font(.caption2)
                                    .foregroundColor(.red)
                            }
                        }
                        .themedRow()
                    }
                }

                HStack {
                    Spacer()
                    VStack(spacing: 4) {
                        Text("\(summary.totalRestored) restored, \(summary.totalSkipped) skipped")
                            .font(.headline)
                        if summary.totalErrors > 0 {
                            Text("\(summary.totalErrors) errors")
                                .font(.subheadline)
                                .foregroundColor(.red)
                        }
                    }
                    Spacer()
                }
                .themedRow()
            } header: {
                Text("Restore Summary")
            } footer: {
                Text("Most settings take effect immediately. New terminal tabs will use restored themes, fonts, and cursor settings. Custom fonts may require restarting the app.")
                    .font(.caption)
            }
        }

    }

    private func restoreBinding(for category: BackupCategory) -> Binding<Bool> {
        Binding(
            get: { selectedCategories.contains(category) },
            set: { isOn in
                if isOn {
                    selectedCategories.insert(category)
                } else {
                    selectedCategories.remove(category)
                }
            }
        )
    }

    private func validateBackup() async {
        guard let url = selectedFileURL else { return }
        isValidating = true
        defer { isValidating = false }

        do {
            manifest = try await backupManager.validateBackup(at: url, password: password)
            // Auto-select all available categories
            if let keys = manifest?.categoryCounts.keys {
                selectedCategories = Set(keys)
            }
        } catch let error as BackupError {
            errorMessage = error.errorDescription
            showError = true
            manifest = nil
        } catch {
            errorMessage = error.localizedDescription
            showError = true
            manifest = nil
        }
    }

    private func restoreBackup() async {
        guard let url = selectedFileURL else { return }
        isRestoring = true
        defer { isRestoring = false }

        do {
            _ = try await backupManager.restoreBackup(
                at: url,
                password: password,
                categories: selectedCategories
            )
        } catch let error as BackupError {
            errorMessage = error.errorDescription
            showError = true
        } catch {
            errorMessage = error.localizedDescription
            showError = true
        }
    }
}
