#if !targetEnvironment(macCatalyst)
//
//  PromptConfig.swift
//  rootshell
//
//  Data model for custom prompt configuration parsed from .promptrc.toml.
//  All types are Sendable for safe use across concurrency boundaries.
//

import Foundation

// MARK: - Main Config

struct PromptConfig: Sendable {
    var format: String
    var rightFormat: String          // Right-aligned prompt format (empty = disabled)
    var transientPrompt: TransientPromptConfig
    var activePalette: String?
    var palettes: [String: [String: String]]

    // Core modules
    var character: CharacterConfig
    var directory: DirectoryConfig
    var gitBranch: GitBranchConfig
    var gitStatus: GitStatusConfig
    var username: UsernameConfig
    var time: TimeConfig
    var battery: BatteryConfig
    var lineBreak: LineBreakConfig

    // Network modules
    var wifi: WiFiConfig
    var network: NetworkModuleConfig
    var connectionType: ConnectionTypeConfig

    static func parse(from dict: [String: Any]) throws -> PromptConfig {
        let format = dict["format"] as? String ?? "$username$directory$git_branch$time\n$character"
        let rightFormat = dict["right_format"] as? String ?? ""
        let palette = dict["palette"] as? String

        // Parse palettes
        var palettes: [String: [String: String]] = [:]
        if let palettesDict = dict["palettes"] as? [String: Any] {
            for (name, value) in palettesDict {
                if let colorDict = value as? [String: Any] {
                    var colors: [String: String] = [:]
                    for (colorName, colorValue) in colorDict {
                        if let str = colorValue as? String {
                            colors[colorName] = str
                        }
                    }
                    palettes[name] = colors
                }
            }
        }

        return PromptConfig(
            format: format,
            rightFormat: rightFormat,
            transientPrompt: TransientPromptConfig.parse(from: dict["transient_prompt"] as? [String: Any] ?? [:]),
            activePalette: palette,
            palettes: palettes,
            character: CharacterConfig.parse(from: dict["character"] as? [String: Any] ?? [:]),
            directory: DirectoryConfig.parse(from: dict["directory"] as? [String: Any] ?? [:]),
            gitBranch: GitBranchConfig.parse(from: dict["git_branch"] as? [String: Any] ?? [:]),
            gitStatus: GitStatusConfig.parse(from: dict["git_status"] as? [String: Any] ?? [:]),
            username: UsernameConfig.parse(from: dict["username"] as? [String: Any] ?? [:]),
            time: TimeConfig.parse(from: dict["time"] as? [String: Any] ?? [:]),
            battery: BatteryConfig.parse(from: dict["battery"] as? [String: Any] ?? [:]),
            lineBreak: LineBreakConfig.parse(from: dict["line_break"] as? [String: Any] ?? [:]),
            wifi: WiFiConfig.parse(from: dict["wifi"] as? [String: Any] ?? [:]),
            network: NetworkModuleConfig.parse(from: dict["network"] as? [String: Any] ?? [:]),
            connectionType: ConnectionTypeConfig.parse(from: dict["connection_type"] as? [String: Any] ?? [:])
        )
    }
}

// MARK: - Transient Prompt Config

struct TransientPromptConfig: Sendable {
    var enabled: Bool
    var format: String?   // Custom transient format; nil = use $character only

    static let `default` = TransientPromptConfig(enabled: false, format: nil)

    static func parse(from dict: [String: Any]) -> TransientPromptConfig {
        TransientPromptConfig(
            enabled: dict["enabled"] as? Bool ?? false,
            format: dict["format"] as? String
        )
    }
}

// MARK: - Module Configs

struct CharacterConfig: Sendable {
    var successSymbol: String
    var errorSymbol: String
    var disabled: Bool

    static let `default` = CharacterConfig(
        successSymbol: "[❯](bold fg:#a6e3a1)",
        errorSymbol: "[❯](bold fg:#f38ba8)",
        disabled: false
    )

    static func parse(from dict: [String: Any]) -> CharacterConfig {
        CharacterConfig(
            successSymbol: dict["success_symbol"] as? String ?? Self.default.successSymbol,
            errorSymbol: dict["error_symbol"] as? String ?? Self.default.errorSymbol,
            disabled: dict["disabled"] as? Bool ?? false
        )
    }
}

struct DirectoryConfig: Sendable {
    var format: String
    var truncationLength: Int
    var truncationSymbol: String
    var disabled: Bool

    static let `default` = DirectoryConfig(
        format: "[ $path ](fg:#11111b bg:#fab387)",
        truncationLength: 3,
        truncationSymbol: "…/",
        disabled: false
    )

    static func parse(from dict: [String: Any]) -> DirectoryConfig {
        DirectoryConfig(
            format: dict["format"] as? String ?? Self.default.format,
            truncationLength: dict["truncation_length"] as? Int ?? Self.default.truncationLength,
            truncationSymbol: dict["truncation_symbol"] as? String ?? Self.default.truncationSymbol,
            disabled: dict["disabled"] as? Bool ?? false
        )
    }
}

struct GitBranchConfig: Sendable {
    var format: String
    var symbol: String
    var truncationLength: Int
    var disabled: Bool

    static let `default` = GitBranchConfig(
        format: "[ $symbol $branch$status ](fg:#11111b bg:#a6e3a1)",
        symbol: "\u{e0a0}",  // Branch icon
        truncationLength: 0,  // 0 = no truncation
        disabled: false
    )

    static func parse(from dict: [String: Any]) -> GitBranchConfig {
        GitBranchConfig(
            format: dict["format"] as? String ?? Self.default.format,
            symbol: dict["symbol"] as? String ?? Self.default.symbol,
            truncationLength: dict["truncation_length"] as? Int ?? Self.default.truncationLength,
            disabled: dict["disabled"] as? Bool ?? false
        )
    }
}

struct GitStatusConfig: Sendable {
    var format: String
    var staged: String
    var disabled: Bool

    static let `default` = GitStatusConfig(
        format: "$staged",
        staged: "+",
        disabled: false
    )

    static func parse(from dict: [String: Any]) -> GitStatusConfig {
        GitStatusConfig(
            format: dict["format"] as? String ?? Self.default.format,
            staged: dict["staged"] as? String ?? Self.default.staged,
            disabled: dict["disabled"] as? Bool ?? false
        )
    }
}

struct UsernameConfig: Sendable {
    var format: String
    var showAlways: Bool
    var disabled: Bool

    static let `default` = UsernameConfig(
        format: "[ $user ](fg:#11111b bg:#f38ba8)",
        showAlways: true,
        disabled: false
    )

    static func parse(from dict: [String: Any]) -> UsernameConfig {
        UsernameConfig(
            format: dict["format"] as? String ?? Self.default.format,
            showAlways: dict["show_always"] as? Bool ?? Self.default.showAlways,
            disabled: dict["disabled"] as? Bool ?? false
        )
    }
}

struct TimeConfig: Sendable {
    var format: String
    var timeFormat: String?  // strftime format, nil = use app preference
    var disabled: Bool

    static let `default` = TimeConfig(
        format: "[ \u{F017} $time ](fg:#11111b bg:#b4befe)",
        timeFormat: nil,
        disabled: false
    )

    static func parse(from dict: [String: Any]) -> TimeConfig {
        TimeConfig(
            format: dict["format"] as? String ?? Self.default.format,
            timeFormat: dict["time_format"] as? String,
            disabled: dict["disabled"] as? Bool ?? false
        )
    }
}

struct BatteryConfig: Sendable {
    var format: String
    var fullSymbol: String
    var chargingSymbol: String
    var dischargingSymbol: String
    var displayThreshold: Int  // Only show below this percentage
    var disabled: Bool

    static let `default` = BatteryConfig(
        format: "[ $symbol $percentage ](fg:#11111b bg:#f9e2af)",
        fullSymbol: "🔋",
        chargingSymbol: "⚡",
        dischargingSymbol: "🔋",
        displayThreshold: 100,
        disabled: false
    )

    static func parse(from dict: [String: Any]) -> BatteryConfig {
        BatteryConfig(
            format: dict["format"] as? String ?? Self.default.format,
            fullSymbol: dict["full_symbol"] as? String ?? Self.default.fullSymbol,
            chargingSymbol: dict["charging_symbol"] as? String ?? Self.default.chargingSymbol,
            dischargingSymbol: dict["discharging_symbol"] as? String ?? Self.default.dischargingSymbol,
            displayThreshold: dict["display_threshold"] as? Int ?? Self.default.displayThreshold,
            disabled: dict["disabled"] as? Bool ?? false
        )
    }
}

struct LineBreakConfig: Sendable {
    var disabled: Bool

    static let `default` = LineBreakConfig(disabled: false)

    static func parse(from dict: [String: Any]) -> LineBreakConfig {
        LineBreakConfig(disabled: dict["disabled"] as? Bool ?? false)
    }
}

// MARK: - Network Module Configs

struct WiFiConfig: Sendable {
    var format: String
    var bandIcon2_4: String
    var bandIcon5: String
    var bandIcon6: String
    var disabled: Bool

    static let `default` = WiFiConfig(
        format: "[ 󰤨 $ssid $band_icon ](fg:#11111b bg:#89b4fa)",
        bandIcon2_4: "2.4",
        bandIcon5: "5G",
        bandIcon6: "6E",
        disabled: false
    )

    static func parse(from dict: [String: Any]) -> WiFiConfig {
        WiFiConfig(
            format: dict["format"] as? String ?? Self.default.format,
            bandIcon2_4: dict["band_icon_2_4"] as? String ?? Self.default.bandIcon2_4,
            bandIcon5: dict["band_icon_5"] as? String ?? Self.default.bandIcon5,
            bandIcon6: dict["band_icon_6"] as? String ?? Self.default.bandIcon6,
            disabled: dict["disabled"] as? Bool ?? false
        )
    }
}

struct NetworkModuleConfig: Sendable {
    var format: String
    var showIP: Bool
    var disabled: Bool

    static let `default` = NetworkModuleConfig(
        format: "[ $country_flag $isp ](fg:#11111b bg:#a6e3a1)",
        showIP: false,
        disabled: false
    )

    static func parse(from dict: [String: Any]) -> NetworkModuleConfig {
        NetworkModuleConfig(
            format: dict["format"] as? String ?? Self.default.format,
            showIP: dict["show_ip"] as? Bool ?? Self.default.showIP,
            disabled: dict["disabled"] as? Bool ?? false
        )
    }
}

struct ConnectionTypeConfig: Sendable {
    var format: String
    var wifiSymbol: String
    var cellularSymbol: String
    var wiredSymbol: String
    var disabled: Bool

    static let `default` = ConnectionTypeConfig(
        format: "[$symbol](fg:#a6e3a1)",
        wifiSymbol: "󰤨",
        cellularSymbol: "󰣺",
        wiredSymbol: "󰈁",
        disabled: false
    )

    static func parse(from dict: [String: Any]) -> ConnectionTypeConfig {
        ConnectionTypeConfig(
            format: dict["format"] as? String ?? Self.default.format,
            wifiSymbol: dict["wifi_symbol"] as? String ?? Self.default.wifiSymbol,
            cellularSymbol: dict["cellular_symbol"] as? String ?? Self.default.cellularSymbol,
            wiredSymbol: dict["wired_symbol"] as? String ?? Self.default.wiredSymbol,
            disabled: dict["disabled"] as? Bool ?? false
        )
    }
}

#endif
