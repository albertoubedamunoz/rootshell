//
//  ConfigFileExporter.swift
//  rootshell
//
//  Renders the current settings as a config file: non-default keys live,
//  defaults commented, grouped with banners.
//

import Foundation

@MainActor
enum ConfigFileExporter {
    static let preamble = """
    # rootshell config
    #
    # Every uncommented key in this file is kept on the device where the file
    # lives and stops following iCloud until you remove it. Lines starting
    # with # are ignored. Repeat a key to give it several values.
    #
    """

    static func render(includeDefaults: Bool = true, store: SettingsStore = .shared, registry: SettingsRegistry = .shared) -> String {
        var out: [String] = [preamble]
        var currentGroup: SettingGroup?
        for def in registry.configEditableDefinitions {
            guard let configKey = def.configKey else { continue }
            if def.group != currentGroup {
                currentGroup = def.group
                out.append("")
                out.append("# ---- \(def.group.title) ----")
            }
            let current = store.codableValue(def.name)
            let defaultText = def.defaultCodable.flatMap { ConfigOverlayCodec.encode($0, for: def) }?.joined(separator: ", ")
            if let current, current != def.defaultCodable, let lines = ConfigOverlayCodec.encode(current, for: def) {
                if let defaultText { out.append("# \(def.title) (default: \(defaultText))") } else { out.append("# \(def.title)") }
                out.append(contentsOf: lines.map { ConfigOverlayCodec.line(configKey: configKey, value: $0) })
            } else if includeDefaults {
                let shown = defaultText ?? ""
                out.append("# \(def.title)")
                out.append("# \(ConfigOverlayCodec.line(configKey: configKey, value: shown))")
            }
        }
        return out.joined(separator: "\n") + "\n"
    }
}
