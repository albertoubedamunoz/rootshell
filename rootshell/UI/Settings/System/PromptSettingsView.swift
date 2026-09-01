//
//  PromptSettingsView.swift
//  rootshell
//
//  Prompt settings and previews.
//

import SwiftUI

#if !targetEnvironment(macCatalyst)
// MARK: - Prompt & Username Settings (combined view)

struct PromptSettingsView: View {
    @Setting(Settings.Prompt.customUsername) private var customUsername
    @Setting(Settings.Prompt.useStarship) private var useStarshipPrompt
    @Setting(Settings.Prompt.showGit) private var showGitInPrompt
    @Setting(Settings.Prompt.starshipTheme) private var starshipTheme
    @Setting(Settings.Locale.clockFormat) private var clockFormat
    @Setting(Settings.Prompt.useTransientPrompt) private var useTransientPrompt
    @Setting(Settings.Prompt.useRightPrompt) private var useRightPrompt
    @Setting(Settings.Prompt.addNewline) private var promptAddNewline

    #if !targetEnvironment(macCatalyst)
    @State private var customConfigStatus: PromptConfigStatus = .none
    @State private var hasCustomConfig: Bool = false
    @State private var exampleCreated: Bool = false
    #endif

    var body: some View {
        List {
            Section {
                HStack {
                    Text("Username")
                    Spacer()
                    TextField("mobile", text: $customUsername)
                        .multilineTextAlignment(.trailing)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                }
                .themedRow()
            } header: {
                Text("Identity")
            } footer: {
                Text("Shown in the shell prompt and used as the default SSH username when none is specified.")
                    .font(.caption)
            }

            #if !targetEnvironment(macCatalyst)
            // Custom config section
            if hasCustomConfig {
                Section {
                    switch customConfigStatus {
                    case .active:
                        HStack {
                            Image(systemName: "checkmark.circle.fill")
                                .foregroundColor(.green)
                            Text("Custom prompt config active")
                                .foregroundColor(.primary)
                        }
                        .themedRow()

                    case .error(let message):
                        VStack(alignment: .leading, spacing: 4) {
                            HStack {
                                Image(systemName: "exclamationmark.triangle.fill")
                                    .foregroundColor(.orange)
                                Text("Config error — using built-in theme")
                                    .foregroundColor(.primary)
                            }
                            Text(message)
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                        .themedRow()

                    case .none:
                        EmptyView()
                    }

                    Button("Reload Config") {
                        PromptConfigManager.shared.forceReload()
                        refreshConfigStatus()
                    }
                    .themedRow()

                    Button("Remove Config", role: .destructive) {
                        PromptConfigManager.shared.removeConfigFile()
                        refreshConfigStatus()
                    }
                    .themedRow()
                } header: {
                    Text("Custom Config")
                } footer: {
                    Text("~/.promptrc.toml overrides the theme selected below. Remove it to use Settings themes.")
                        .font(.caption)
                }
            }
            #endif

            Section {
                Toggle("Starship-style Prompt", isOn: $useStarshipPrompt)
                    .themedRow()
                    #if !targetEnvironment(macCatalyst)
                    .disabled(hasCustomConfig && customConfigIsActive)
                    #endif

                if useStarshipPrompt {
                    NavigationLink {
                        PromptThemePickerView()
                    } label: {
                        HStack {
                            Text("Theme")
                            Spacer()
                            PromptThemePreview(theme: starshipTheme, compact: true)
                            Text(starshipTheme.displayName)
                                .foregroundColor(.secondary)
                                .font(.subheadline)
                        }
                    }
                    .themedRow()
                    #if !targetEnvironment(macCatalyst)
                    .opacity(hasCustomConfig && customConfigIsActive ? 0.5 : 1.0)
                    #endif

                    Picker("Clock Format", selection: $clockFormat) {
                        ForEach(UserPreferences.ClockFormat.allCases, id: \.rawValue) { format in
                            Text(format.displayName).tag(format)
                        }
                    }
                    .themedRow()
                    #if !targetEnvironment(macCatalyst)
                    .opacity(hasCustomConfig && customConfigIsActive ? 0.5 : 1.0)
                    #endif

                    Toggle("Show Git Status", isOn: $showGitInPrompt)
                        .themedRow()
                        #if !targetEnvironment(macCatalyst)
                        .opacity(hasCustomConfig && customConfigIsActive ? 0.5 : 1.0)
                        #endif
                }
            } header: {
                Text("Prompt")
            } footer: {
                #if !targetEnvironment(macCatalyst)
                if hasCustomConfig && customConfigIsActive {
                    Text("Custom config (~/.promptrc.toml) is overriding these settings.")
                        .font(.caption)
                } else if !useStarshipPrompt {
                    Text("Uses a plain \"$ \" prompt.")
                        .font(.caption)
                } else if showGitInPrompt {
                    Text("Shows branch name and file status when inside a git repository.")
                        .font(.caption)
                }
                #else
                if !useStarshipPrompt {
                    Text("Uses a plain \"$ \" prompt.")
                        .font(.caption)
                } else if showGitInPrompt {
                    Text("Shows branch name and file status when inside a git repository.")
                        .font(.caption)
                }
                #endif
            }

            if useStarshipPrompt {
                Section {
                    Toggle("Transient Prompt", isOn: $useTransientPrompt)
                        .themedRow()
                        #if !targetEnvironment(macCatalyst)
                        .disabled(hasCustomConfig && customConfigIsActive)
                        .opacity(hasCustomConfig && customConfigIsActive ? 0.5 : 1.0)
                        #endif

                    Toggle("Right Prompt", isOn: $useRightPrompt)
                        .themedRow()
                        #if !targetEnvironment(macCatalyst)
                        .disabled(hasCustomConfig && customConfigIsActive)
                        .opacity(hasCustomConfig && customConfigIsActive ? 0.5 : 1.0)
                        #endif

                    Toggle("Blank Line Before Prompt", isOn: $promptAddNewline)
                        .themedRow()
                        #if !targetEnvironment(macCatalyst)
                        .disabled(hasCustomConfig && customConfigIsActive)
                        .opacity(hasCustomConfig && customConfigIsActive ? 0.5 : 1.0)
                        #endif
                } header: {
                    Text("Advanced")
                } footer: {
                    VStack(alignment: .leading, spacing: 4) {
                        if useTransientPrompt && useRightPrompt {
                            Text("Transient prompt replaces the full prompt with ❯ after running a command. Right prompt moves the clock to the right side of the info bar.")
                        } else if useTransientPrompt {
                            Text("Replaces the full prompt with a minimal ❯ after running a command, reducing scrollback clutter.")
                        } else if useRightPrompt {
                            Text("Moves the clock from the info bar to the right side, making the left prompt shorter.")
                        }

                        if !promptAddNewline {
                            Text("Draws the prompt directly under the previous command's output instead of leaving a blank row.")
                        }
                    }
                    .font(.caption)
                }
            }

            #if !targetEnvironment(macCatalyst)
            if !hasCustomConfig {
                Section {
                    Button {
                        PromptConfigManager.shared.createExampleFile()
                        withAnimation { exampleCreated = true }
                    } label: {
                        HStack {
                            Text(exampleCreated ? "Example Created" : "Create Example Config")
                            if exampleCreated {
                                Spacer()
                                Image(systemName: "checkmark.circle.fill")
                                    .foregroundStyle(.green)
                            }
                        }
                    }
                    .disabled(exampleCreated)
                    .themedRow()
                } footer: {
                    Text("Creates ~/.promptrc.toml.example with all options documented. Rename to ~/.promptrc.toml to activate.")
                        .font(.caption)
                }
            }
            #endif
        }
        .themedList()
        .navigationTitle("Prompt & Username")
        .navigationBarTitleDisplayMode(.inline)
        #if !targetEnvironment(macCatalyst)
        .onAppear { refreshConfigStatus() }
        #endif
    }

    #if !targetEnvironment(macCatalyst)
    private var customConfigIsActive: Bool {
        if case .active = customConfigStatus { return true }
        return false
    }

    private func refreshConfigStatus() {
        let manager = PromptConfigManager.shared
        hasCustomConfig = manager.hasConfigFile()
        if hasCustomConfig {
            _ = manager.loadIfNeeded()
            customConfigStatus = manager.configStatus
        } else {
            customConfigStatus = .none
        }
    }
    #endif
}

// MARK: - Prompt Theme Picker

struct PromptThemePickerView: View {
    @Setting(Settings.Prompt.starshipTheme) private var starshipTheme

    var body: some View {
        List {
            ForEach(StarshipTheme.allCases, id: \.self) { theme in
                Button(action: {
                    starshipTheme = theme
                }) {
                    HStack(spacing: 12) {
                        VStack(alignment: .leading, spacing: 6) {
                            Text(theme.displayName)
                                .foregroundColor(.primary)

                            PromptThemePreview(theme: theme, compact: false)

                            // Content layout preview showing segment contents
                            PromptContentPreview(theme: theme)
                        }

                        Spacer()

                        if starshipTheme == theme {
                            Image(systemName: "checkmark")
                                .foregroundColor(.blue)
                        }
                    }
                    .padding(.vertical, 8)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .themedRow()
            }
        }
        .themedList()
        .navigationTitle("Prompt Theme")
        .navigationBarTitleDisplayMode(.inline)
    }
}

/// Short text description of what makes each prompt theme unique
struct PromptContentPreview: View {
    let theme: StarshipTheme

    private var description: String? {
        switch theme {
        case .catppuccin: return nil
        case .tokyoNight: return String(localized: "Gradient left cap, icon only")
        case .pastelPowerline: return String(localized: "Heart icon, icon only")
        case .gruvboxRainbow: return nil
        case .dracula: return nil
        case .nord: return nil
        case .oneDark: return nil
        case .solarizedDark: return nil
        case .monokaiPro: return String(localized: "Terminal icon instead of star")
        case .kanagawaWave: return String(localized: "Shows day of week instead of time")
        case .rosePine: return String(localized: "Star icon, no username — minimal")
        case .synthwave84: return String(localized: "Gradient left cap, rocket icon, \u{27E9} prompt")
        case .everforest: return String(localized: "Leaf icon — nature inspired")
        }
    }

    var body: some View {
        if let description {
            Text(description)
                .font(.caption2)
                .foregroundColor(.secondary)
        }
    }
}

/// Visual preview of a starship prompt theme
struct PromptThemePreview: View {
    let theme: StarshipTheme
    let compact: Bool

    // Catppuccin Mocha colors
    private let catppuccinRed = Color(red: 243/255, green: 139/255, blue: 168/255)
    private let catppuccinPeach = Color(red: 250/255, green: 179/255, blue: 135/255)
    private let catppuccinLavender = Color(red: 180/255, green: 190/255, blue: 254/255)

    // Tokyo Night colors
    private let tokyoLavender = Color(red: 163/255, green: 174/255, blue: 210/255)
    private let tokyoBlue = Color(red: 118/255, green: 159/255, blue: 240/255)
    private let tokyoDark = Color(red: 29/255, green: 34/255, blue: 48/255)

    // Pastel Powerline colors
    private let pastelPurple = Color(red: 154/255, green: 52/255, blue: 142/255)
    private let pastelPink = Color(red: 218/255, green: 98/255, blue: 125/255)
    private let pastelBlue = Color(red: 51/255, green: 101/255, blue: 138/255)

    // Gruvbox Rainbow colors
    private let gruvboxOrange = Color(red: 214/255, green: 93/255, blue: 14/255)
    private let gruvboxYellow = Color(red: 215/255, green: 153/255, blue: 33/255)
    private let gruvboxAqua = Color(red: 104/255, green: 157/255, blue: 106/255)

    // Dracula colors
    private let draculaPurple = Color(red: 189/255, green: 147/255, blue: 249/255)
    private let draculaPink = Color(red: 255/255, green: 121/255, blue: 198/255)
    private let draculaCyan = Color(red: 139/255, green: 233/255, blue: 253/255)

    // Nord colors
    private let nordDeep = Color(red: 94/255, green: 129/255, blue: 172/255)
    private let nordMedium = Color(red: 129/255, green: 161/255, blue: 193/255)
    private let nordTeal = Color(red: 143/255, green: 188/255, blue: 187/255)

    // One Dark colors
    private let oneDarkBlue = Color(red: 97/255, green: 175/255, blue: 239/255)
    private let oneDarkPurple = Color(red: 198/255, green: 120/255, blue: 221/255)
    private let oneDarkCyan = Color(red: 86/255, green: 182/255, blue: 194/255)

    // Solarized Dark colors
    private let solarizedYellow = Color(red: 181/255, green: 137/255, blue: 0/255)
    private let solarizedCyan = Color(red: 42/255, green: 161/255, blue: 152/255)
    private let solarizedBlue = Color(red: 38/255, green: 139/255, blue: 210/255)

    // Monokai Pro colors
    private let monokaiRed = Color(red: 255/255, green: 97/255, blue: 136/255)
    private let monokaiYellow = Color(red: 255/255, green: 216/255, blue: 102/255)
    private let monokaiCyan = Color(red: 120/255, green: 220/255, blue: 232/255)

    // Kanagawa Wave colors
    private let kanagawaOrange = Color(red: 255/255, green: 160/255, blue: 102/255)
    private let kanagawaGreen = Color(red: 152/255, green: 187/255, blue: 108/255)
    private let kanagawaBlue = Color(red: 126/255, green: 156/255, blue: 216/255)

    // Rosé Pine colors
    private let roseLove = Color(red: 235/255, green: 111/255, blue: 146/255)
    private let roseGold = Color(red: 246/255, green: 193/255, blue: 119/255)
    private let roseIris = Color(red: 196/255, green: 167/255, blue: 231/255)

    // Synthwave '84 colors
    private let synthPink = Color(red: 246/255, green: 24/255, blue: 143/255)
    private let synthYellow = Color(red: 253/255, green: 248/255, blue: 52/255)
    private let synthCyan = Color(red: 18/255, green: 195/255, blue: 226/255)

    // Everforest colors
    private let everforestRed = Color(red: 230/255, green: 126/255, blue: 128/255)
    private let everforestYellow = Color(red: 219/255, green: 188/255, blue: 127/255)
    private let everforestGreen = Color(red: 167/255, green: 192/255, blue: 128/255)

    var body: some View {
        HStack(spacing: 0) {
            switch theme {
            case .catppuccin:
                // Catppuccin: red → peach → lavender
                RoundedRectangle(cornerRadius: compact ? 2 : 3)
                    .fill(catppuccinRed)
                    .frame(width: compact ? 16 : 24, height: compact ? 8 : 12)
                RoundedRectangle(cornerRadius: 0)
                    .fill(catppuccinPeach)
                    .frame(width: compact ? 24 : 40, height: compact ? 8 : 12)
                RoundedRectangle(cornerRadius: compact ? 2 : 3)
                    .fill(catppuccinLavender)
                    .frame(width: compact ? 16 : 24, height: compact ? 8 : 12)

            case .tokyoNight:
                // Tokyo Night: lavender → blue → dark
                RoundedRectangle(cornerRadius: compact ? 2 : 3)
                    .fill(tokyoLavender)
                    .frame(width: compact ? 16 : 24, height: compact ? 8 : 12)
                RoundedRectangle(cornerRadius: 0)
                    .fill(tokyoBlue)
                    .frame(width: compact ? 24 : 40, height: compact ? 8 : 12)
                RoundedRectangle(cornerRadius: compact ? 2 : 3)
                    .fill(tokyoDark)
                    .frame(width: compact ? 16 : 24, height: compact ? 8 : 12)

            case .pastelPowerline:
                // Pastel Powerline: purple → pink → blue
                RoundedRectangle(cornerRadius: compact ? 2 : 3)
                    .fill(pastelPurple)
                    .frame(width: compact ? 16 : 24, height: compact ? 8 : 12)
                RoundedRectangle(cornerRadius: 0)
                    .fill(pastelPink)
                    .frame(width: compact ? 24 : 40, height: compact ? 8 : 12)
                RoundedRectangle(cornerRadius: compact ? 2 : 3)
                    .fill(pastelBlue)
                    .frame(width: compact ? 16 : 24, height: compact ? 8 : 12)

            case .gruvboxRainbow:
                // Gruvbox Rainbow: orange → yellow → aqua
                RoundedRectangle(cornerRadius: compact ? 2 : 3)
                    .fill(gruvboxOrange)
                    .frame(width: compact ? 16 : 24, height: compact ? 8 : 12)
                RoundedRectangle(cornerRadius: 0)
                    .fill(gruvboxYellow)
                    .frame(width: compact ? 24 : 40, height: compact ? 8 : 12)
                RoundedRectangle(cornerRadius: compact ? 2 : 3)
                    .fill(gruvboxAqua)
                    .frame(width: compact ? 16 : 24, height: compact ? 8 : 12)

            case .dracula:
                // Dracula: purple → pink → cyan
                RoundedRectangle(cornerRadius: compact ? 2 : 3)
                    .fill(draculaPurple)
                    .frame(width: compact ? 16 : 24, height: compact ? 8 : 12)
                RoundedRectangle(cornerRadius: 0)
                    .fill(draculaPink)
                    .frame(width: compact ? 24 : 40, height: compact ? 8 : 12)
                RoundedRectangle(cornerRadius: compact ? 2 : 3)
                    .fill(draculaCyan)
                    .frame(width: compact ? 16 : 24, height: compact ? 8 : 12)

            case .nord:
                // Nord: deep frost → medium frost → teal frost
                RoundedRectangle(cornerRadius: compact ? 2 : 3)
                    .fill(nordDeep)
                    .frame(width: compact ? 16 : 24, height: compact ? 8 : 12)
                RoundedRectangle(cornerRadius: 0)
                    .fill(nordMedium)
                    .frame(width: compact ? 24 : 40, height: compact ? 8 : 12)
                RoundedRectangle(cornerRadius: compact ? 2 : 3)
                    .fill(nordTeal)
                    .frame(width: compact ? 16 : 24, height: compact ? 8 : 12)

            case .oneDark:
                // One Dark: blue → purple → cyan
                RoundedRectangle(cornerRadius: compact ? 2 : 3)
                    .fill(oneDarkBlue)
                    .frame(width: compact ? 16 : 24, height: compact ? 8 : 12)
                RoundedRectangle(cornerRadius: 0)
                    .fill(oneDarkPurple)
                    .frame(width: compact ? 24 : 40, height: compact ? 8 : 12)
                RoundedRectangle(cornerRadius: compact ? 2 : 3)
                    .fill(oneDarkCyan)
                    .frame(width: compact ? 16 : 24, height: compact ? 8 : 12)

            case .solarizedDark:
                // Solarized Dark: yellow → cyan → blue
                RoundedRectangle(cornerRadius: compact ? 2 : 3)
                    .fill(solarizedYellow)
                    .frame(width: compact ? 16 : 24, height: compact ? 8 : 12)
                RoundedRectangle(cornerRadius: 0)
                    .fill(solarizedCyan)
                    .frame(width: compact ? 24 : 40, height: compact ? 8 : 12)
                RoundedRectangle(cornerRadius: compact ? 2 : 3)
                    .fill(solarizedBlue)
                    .frame(width: compact ? 16 : 24, height: compact ? 8 : 12)

            case .monokaiPro:
                // Monokai Pro: red → yellow → cyan
                RoundedRectangle(cornerRadius: compact ? 2 : 3)
                    .fill(monokaiRed)
                    .frame(width: compact ? 16 : 24, height: compact ? 8 : 12)
                RoundedRectangle(cornerRadius: 0)
                    .fill(monokaiYellow)
                    .frame(width: compact ? 24 : 40, height: compact ? 8 : 12)
                RoundedRectangle(cornerRadius: compact ? 2 : 3)
                    .fill(monokaiCyan)
                    .frame(width: compact ? 16 : 24, height: compact ? 8 : 12)

            case .kanagawaWave:
                // Kanagawa Wave: orange → green → blue
                RoundedRectangle(cornerRadius: compact ? 2 : 3)
                    .fill(kanagawaOrange)
                    .frame(width: compact ? 16 : 24, height: compact ? 8 : 12)
                RoundedRectangle(cornerRadius: 0)
                    .fill(kanagawaGreen)
                    .frame(width: compact ? 24 : 40, height: compact ? 8 : 12)
                RoundedRectangle(cornerRadius: compact ? 2 : 3)
                    .fill(kanagawaBlue)
                    .frame(width: compact ? 16 : 24, height: compact ? 8 : 12)

            case .rosePine:
                // Rosé Pine: love → gold → iris
                RoundedRectangle(cornerRadius: compact ? 2 : 3)
                    .fill(roseLove)
                    .frame(width: compact ? 16 : 24, height: compact ? 8 : 12)
                RoundedRectangle(cornerRadius: 0)
                    .fill(roseGold)
                    .frame(width: compact ? 24 : 40, height: compact ? 8 : 12)
                RoundedRectangle(cornerRadius: compact ? 2 : 3)
                    .fill(roseIris)
                    .frame(width: compact ? 16 : 24, height: compact ? 8 : 12)

            case .synthwave84:
                // Synthwave '84: pink → yellow → cyan
                RoundedRectangle(cornerRadius: compact ? 2 : 3)
                    .fill(synthPink)
                    .frame(width: compact ? 16 : 24, height: compact ? 8 : 12)
                RoundedRectangle(cornerRadius: 0)
                    .fill(synthYellow)
                    .frame(width: compact ? 24 : 40, height: compact ? 8 : 12)
                RoundedRectangle(cornerRadius: compact ? 2 : 3)
                    .fill(synthCyan)
                    .frame(width: compact ? 16 : 24, height: compact ? 8 : 12)

            case .everforest:
                // Everforest: red → yellow → green
                RoundedRectangle(cornerRadius: compact ? 2 : 3)
                    .fill(everforestRed)
                    .frame(width: compact ? 16 : 24, height: compact ? 8 : 12)
                RoundedRectangle(cornerRadius: 0)
                    .fill(everforestYellow)
                    .frame(width: compact ? 24 : 40, height: compact ? 8 : 12)
                RoundedRectangle(cornerRadius: compact ? 2 : 3)
                    .fill(everforestGreen)
                    .frame(width: compact ? 16 : 24, height: compact ? 8 : 12)
            }
        }
        .clipShape(Capsule())
    }
}
#endif

// MARK: - Option Key as Alt Picker
