//
//  OptionKeyAsAltPicker.swift
//  rootshell
//
//  Option-key behavior picker.
//

import SwiftUI

struct OptionKeyAsAltPicker: View {
    @Setting(Settings.Keyboard.optionKeyAsAlt) private var optionKeyAsAlt

    var body: some View {
        Picker(selection: $optionKeyAsAlt) {
            ForEach(Ghostty.OptionKeyAsAlt.allCases, id: \.rawValue) { option in
                Text(option.displayName).tag(option)
            }
        } label: {
            HStack(spacing: 12) {
                SettingsIcon(systemName: "option")
                Text("Option Key as Alt")
            }
            .settingRow(Settings.Keyboard.optionKeyAsAlt)
        }
    }
}

