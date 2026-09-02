#if !CHINA_BUILD
//
//  VoiceAgentSettingsView.swift
//  rootshell
//
//  Settings view for voice agent configuration:
//  voice selection, consultation mode, and general preferences.
//

import SwiftUI

struct VoiceAgentSettingsView: View {
    @Setting(Settings.AI.voice) private var selectedVoice
    @Setting(Settings.AI.voiceConsultationMode) private var consultationMode
    @Environment(\.sheetThemeColors) private var sheetThemeColors

    var body: some View {
        List {
            voiceSection
            consultationSection
            infoSection
        }
        .themedList()
        .navigationTitle("Voice Agent")
        .navigationBarTitleDisplayMode(.inline)
    }

    // MARK: - Sections

    private var voiceSection: some View {
        Section {
            NavigationLink {
                VoiceSelectionList(selectedVoice: $selectedVoice)
            } label: {
                LabeledContent {
                    Text(selectedVoice.displayName)
                } label: {
                    HStack(spacing: 6) {
                        Text("Voice")
                        SettingPinTag(Settings.AI.voice.erased)
                    }
                }
            }
            .themedRow()
            .settingContextMenu(Settings.AI.voice)
        } header: {
            SettingGroupHeader("Voice", group: .ai)
        } footer: {
            Text("Select the voice used by the AI assistant during voice sessions.")
        }
    }

    private var consultationSection: some View {
        Section {
            Picker(selection: $consultationMode) {
                ForEach(VoiceConsultationMode.allCases, id: \.self) { mode in
                    VStack(alignment: .leading) {
                        Text(mode.displayName)
                        Text(mode.description)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .tag(mode)
                }
            } label: {
                Text("Expert Consultation")
                    .settingRow(Settings.AI.voiceConsultationMode)
            }
            .pickerStyle(.inline)
            .themedRow()
        } header: {
            SettingGroupHeader("Expert Model", group: .ai)
        } footer: {
            Text("Controls whether the voice agent (Gemini Flash) delegates complex questions to Gemini 3.1 Pro for deeper analysis.")
        }
    }

    private var infoSection: some View {
        Section {
            LabeledContent("Model", value: "Gemini 3.1 Flash Live")
                .themedRow()
            LabeledContent("Expert Model", value: "Gemini 3.1 Pro")
                .themedRow()
            LabeledContent("Session Limit", value: "30 minutes")
                .themedRow()
            LabeledContent("Input Audio", value: "16kHz PCM16")
                .themedRow()
            LabeledContent("Output Audio", value: "24kHz PCM16")
                .themedRow()
        } header: {
            Text("Technical Details")
        }
    }
}

// MARK: - Voice Selection List

private struct VoiceSelectionList: View {
    @Binding var selectedVoice: GeminiVoice

    var body: some View {
        List {
            Section {
                ForEach(GeminiVoice.allCases, id: \.self) { voice in
                    Button {
                        selectedVoice = voice
                    } label: {
                        HStack {
                            VStack(alignment: .leading) {
                                Text(voice.displayName)
                                Text(voice.voiceDescription)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            if voice == selectedVoice {
                                Image(systemName: "checkmark")
                                    .foregroundStyle(.tint)
                            }
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .themedRow()
                }
            }
        }
        .themedList()
        .navigationTitle("Voice")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { SettingsScreenPinMenu(groups: [.ai]) }
    }
}
#endif
