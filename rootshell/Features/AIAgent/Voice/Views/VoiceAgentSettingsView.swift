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
    @State private var selectedVoice: GeminiVoice = .kore
    @State private var consultationMode: VoiceConsultationMode = .letFlashDecide
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
        .onAppear {
            loadSettings()
        }
    }

    // MARK: - Sections

    private var voiceSection: some View {
        Section {
            NavigationLink {
                VoiceSelectionList(selectedVoice: $selectedVoice)
            } label: {
                LabeledContent("Voice", value: selectedVoice.displayName)
            }
            .onChange(of: selectedVoice) { _, newValue in
                UserDefaults.standard.set(newValue.rawValue, forKey: "voice.agent.voice")
            }
            .themedRow()
        } header: {
            Text("Voice")
        } footer: {
            Text("Select the voice used by the AI assistant during voice sessions.")
        }
    }

    private var consultationSection: some View {
        Section {
            Picker("Expert Consultation", selection: $consultationMode) {
                ForEach(VoiceConsultationMode.allCases, id: \.self) { mode in
                    VStack(alignment: .leading) {
                        Text(mode.displayName)
                        Text(mode.description)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .tag(mode)
                }
            }
            .pickerStyle(.inline)
            .onChange(of: consultationMode) { _, newValue in
                UserDefaults.standard.set(newValue.rawValue, forKey: "voice.agent.consultationMode")
            }
            .themedRow()
        } header: {
            Text("Expert Model")
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

    // MARK: - Persistence

    private func loadSettings() {
        if let voiceRaw = UserDefaults.standard.string(forKey: "voice.agent.voice"),
           let voice = GeminiVoice(rawValue: voiceRaw) {
            selectedVoice = voice
        }
        if let modeRaw = UserDefaults.standard.string(forKey: "voice.agent.consultationMode"),
           let mode = VoiceConsultationMode(rawValue: modeRaw) {
            consultationMode = mode
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
    }
}
#endif
