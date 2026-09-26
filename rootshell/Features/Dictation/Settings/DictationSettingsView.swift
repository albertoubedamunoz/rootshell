#if canImport(FluidAudio) && !CHINA_BUILD
//
//  DictationSettingsView.swift
//  rootshell
//
//  On-device dictation: model, how text reaches the terminal, formatting,
//  agent prompt helpers, voice commands, and advanced recognition tuning.
//

import SwiftUI

struct DictationSettingsView: View {
    @Setting(Settings.Dictation.enabled) private var enabled
    @Setting(Settings.Dictation.model) private var model
    @Setting(Settings.Dictation.language) private var language
    @Setting(Settings.Dictation.commitMode) private var commitMode
    @Setting(Settings.Dictation.formatting) private var formatting
    @Setting(Settings.Dictation.vocabularyEnabled) private var vocabularyEnabled
    @Setting(Settings.Dictation.autoStopSilence) private var autoStopSilence
    @Setting(Settings.Dictation.pauseDuration) private var pauseDuration
    @Setting(Settings.Dictation.speechThreshold) private var speechThreshold
    @Setting(Settings.Dictation.keepLoadedMinutes) private var keepLoadedMinutes
    @Setting(Settings.Dictation.encoderPrecision) private var precision
    private var store: DictationModelStore { .shared }

    var body: some View {
        List {
            enableSection
            if enabled {
                modelSection
                commitSection
                formattingSection
                agentSection
                commandsSection
                vocabularySection
                advancedSection
            }
        }
        .themedList()
        .navigationTitle("Dictation")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { store.refresh() }
    }

    // MARK: - Sections

    private var enableSection: some View {
        Section {
            SettingToggle(Settings.Dictation.enabled, title: "Dictation", icon: "mic")
                .themedRow()
        } footer: {
            Text(enableFooter)
        }
    }

    private var enableFooter: String {
        let chord = KeybindManager.shared.sequence(for: .toggle_dictation)?.symbolDescription
        #if targetEnvironment(macCatalyst)
        if let chord {
            return String(localized: "Speech is recognized by Parakeet on this Mac; audio never leaves it. Press \(chord) or choose Shell › Dictation.")
        }
        return String(localized: "Speech is recognized by Parakeet on this Mac; audio never leaves it. Choose Shell › Dictation to start.")
        #else
        if let chord {
            return String(localized: "Speech is recognized by Parakeet on this device; audio never leaves it. Swipe left on the terminal keyboard, add the Dictation toolbar key, or press \(chord) on a hardware keyboard.")
        }
        return String(localized: "Speech is recognized by Parakeet on this device; audio never leaves it. Swipe left on the terminal keyboard or add the Dictation toolbar key.")
        #endif
    }

    private var modelSection: some View {
        Section {
            NavigationLink {
                DictationModelsView()
            } label: {
                LabeledContent {
                    Text(modelStatus)
                } label: {
                    Text("Speech Model").settingRow(Settings.Dictation.model)
                }
            }
            .themedRow()
            .settingContextMenu(Settings.Dictation.model)

            Picker(selection: $language) {
                Text("Automatic").tag("")
                ForEach(DictationLanguages.codes.sorted { DictationLanguages.name($0) < DictationLanguages.name($1) },
                        id: \.self) { code in
                    Text(DictationLanguages.name(code)).tag(code)
                }
            } label: {
                Text("Language").settingRow(Settings.Dictation.language)
            }
            .disabled(!model.supportsLanguageHint)
            .themedRow()
        } header: {
            SettingGroupHeader("Recognition", group: .dictation)
        } footer: {
            if model.supportsLanguageHint {
                Text("Automatic works for most speakers. Choosing a language keeps short phrases from drifting into another alphabet.")
            } else {
                Text("Parakeet v2 recognizes English only.")
            }
        }
    }

    private var modelStatus: String {
        switch store.state(.speech(model)) {
        case .ready: return String(localized: "\(model.displayName) · Ready")
        case .downloading(let value): return String(localized: "\(model.displayName) · \(value.formatted(.percent.precision(.fractionLength(0))))")
        case .failed: return String(localized: "\(model.displayName) · Failed")
        case .notDownloaded: return String(localized: "\(model.displayName) · Not Downloaded")
        }
    }

    private var commitSection: some View {
        Section {
            Picker(selection: $commitMode) {
                ForEach(DictationCommitMode.allCases, id: \.self) { mode in
                    VStack(alignment: .leading) {
                        Text(mode.displayName)
                        Text(mode.summary).font(.caption).foregroundStyle(.secondary)
                    }
                    .tag(mode)
                }
            } label: {
                Text("Insert Text").settingRow(Settings.Dictation.commitMode)
            }
            .pickerStyle(.inline)
            .themedRow()
        } header: {
            SettingGroupHeader("Insert Text", group: .dictation)
        } footer: {
            if commitMode == .handsFree {
                Text("Hands-Free runs every phrase as soon as you pause. A misheard shell command runs too, so prefer it for conversations with a coding agent.")
            }
        }
    }

    private var formattingSection: some View {
        Section {
            Picker(selection: $formatting) {
                ForEach(DictationFormatting.allCases, id: \.self) { value in
                    VStack(alignment: .leading) {
                        Text(value.displayName)
                        Text(value.summary).font(.caption).foregroundStyle(.secondary)
                    }
                    .tag(value)
                }
            } label: {
                Text("Formatting").settingRow(Settings.Dictation.formatting)
            }
            .pickerStyle(.inline)
            .themedRow()
        } header: {
            SettingGroupHeader("Formatting", group: .dictation)
        } footer: {
            Text("In Command formatting say “dash”, “dot”, “slash”, “pipe”, “tilde”, “quote”, “dollar home” or “and and” for shell symbols.")
        }
    }

    private var agentSection: some View {
        Section {
            SettingDescribedToggle(Settings.Dictation.removeFillers, title: "Remove Filler Words",
                                   description: "Drops “um” and “uh” from prose and prompts.")
                .themedRow()
            SettingDescribedToggle(Settings.Dictation.spokenCode, title: "Spoken Code Idioms",
                                   description: "“camel case user id” → userId, “snake case”, “backtick … backtick”, “at file main dot swift” → @main.swift, and “slash compact” → /compact.")
                .themedRow()
            SettingDescribedToggle(Settings.Dictation.quickReplies, title: "Agent Quick Replies",
                                   description: "Saying only “one” to “nine”, “yes” or “no” answers an agent's menu with that key.")
                .themedRow()
        } header: {
            SettingGroupHeader("Agent Prompts", group: .dictation)
        } footer: {
            Text("Prompts are sent with bracketed paste, so “new line” and “new paragraph” add line breaks without submitting. Return is pressed only when you choose Run or say “press enter”.")
        }
    }

    private var commandsSection: some View {
        Section {
            SettingToggle(Settings.Dictation.voiceCommands, title: "Voice Commands", icon: "command")
                .themedRow()
        } header: {
            SettingGroupHeader("Voice Commands", group: .dictation)
        } footer: {
            Text("When a phrase is only a command it acts instead of typing: “press enter”, “scratch that”, “escape”, “tab”, “control C”, “up arrow”, “clear line”. Ending a phrase with “…and press enter” types it, then runs it.")
        }
    }

    private var vocabularySection: some View {
        Section {
            NavigationLink {
                DictationVocabularyView()
            } label: {
                LabeledContent {
                    Text(vocabularyEnabled ? String(localized: "On") : String(localized: "Off"))
                } label: {
                    Text("Vocabulary Boost").settingRow(Settings.Dictation.vocabularyEnabled)
                }
            }
            .themedRow()
        } footer: {
            Text("Teach dictation words it would otherwise mishear, like kubectl, hostnames, and identifiers on screen.")
        }
    }

    private var advancedSection: some View {
        Section {
            Picker(selection: $autoStopSilence) {
                Text("Never").tag(0.0)
                ForEach([2.0, 4.0, 8.0, 15.0], id: \.self) { seconds in
                    Text(Duration.seconds(seconds).formatted(.units(allowed: [.seconds], width: .abbreviated))).tag(seconds)
                }
            } label: {
                Text("Stop After Silence").settingRow(Settings.Dictation.autoStopSilence)
            }
            .themedRow()

            VStack(alignment: .leading, spacing: 4) {
                LabeledContent {
                    Text(Duration.milliseconds(Int(pauseDuration * 1000))
                        .formatted(.units(allowed: [.seconds, .milliseconds], width: .abbreviated)))
                } label: {
                    Text("Phrase Pause").settingRow(Settings.Dictation.pauseDuration)
                }
                Slider(value: $pauseDuration, in: 0.4...2.0, step: 0.1)
            }
            .themedRow()

            VStack(alignment: .leading, spacing: 4) {
                LabeledContent {
                    Text(speechThreshold.formatted(.number.precision(.fractionLength(2))))
                } label: {
                    Text("Speech Detection Threshold").settingRow(Settings.Dictation.speechThreshold)
                }
                Slider(value: $speechThreshold, in: 0.3...0.9, step: 0.05)
            }
            .themedRow()

            SettingToggle(Settings.Dictation.numberNormalization, title: "Write Numbers as Digits")
                .themedRow()

            Picker(selection: $keepLoadedMinutes) {
                Text("Unload Right Away").tag(0)
                ForEach([1, 5, 15, 60], id: \.self) { minutes in
                    Text(Duration.seconds(minutes * 60).formatted(.units(allowed: [.minutes, .hours], width: .wide))).tag(minutes)
                }
            } label: {
                Text("Keep Model Loaded").settingRow(Settings.Dictation.keepLoadedMinutes)
            }
            .themedRow()

            if model == .parakeetV3 {
                Picker(selection: $precision) {
                    Text("Standard (int8)").tag(DictationEncoderPrecision.int8)
                    Text("Compact (int4)").tag(DictationEncoderPrecision.int4)
                } label: {
                    Text("Encoder Precision").settingRow(Settings.Dictation.encoderPrecision)
                }
                .themedRow()
                .onChange(of: precision) { _, _ in store.refresh() }
            }
        } header: {
            SettingGroupHeader("Advanced", group: .dictation)
        } footer: {
            Text("A longer phrase pause keeps sentences together. Raise the detection threshold in noisy places, lower it if quiet speech is missed. A loaded model answers instantly but holds memory; Compact precision downloads less at a small accuracy cost.")
        }
    }
}
#endif
