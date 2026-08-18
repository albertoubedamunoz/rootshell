//
//  OptionKeyAsAltPicker.swift
//  rootshell
//
//  Option-key behavior picker.
//

import SwiftUI

struct OptionKeyAsAltPicker: View {
    @AppStorage("optionKeyAsAlt") private var optionKeyAsAlt: String = "off"

    var body: some View {
        Picker(selection: $optionKeyAsAlt) {
            ForEach(Ghostty.OptionKeyAsAlt.allCases, id: \.rawValue) { option in
                Text(option.displayName).tag(option.rawValue)
            }
        } label: {
            HStack(spacing: 12) {
                SettingsIcon(systemName: "option")
                Text("Option Key as Alt")
            }
        }
    }
}

