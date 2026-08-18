#if !targetEnvironment(macCatalyst)

import Foundation
import Yams
import OSLog

/// Persistent configuration for the rf file browser.
/// Loaded from ~/Documents/.config/rf/rf.yaml on startup.
@MainActor
struct RFConfig: Sendable {
    nonisolated static let logger = Logger(subsystem: "com.kk2.rootshell", category: "rf-config")

    var showHidden: Bool = false
    var sortBy: RFSortOrder = .nameAsc

    /// Navigation root — user cannot navigate above this path.
    /// Defaults to ~/Documents. Set to nil to allow unrestricted navigation.
    var rootPath: String? = documentsPath()

    /// Load config from the standard location. Returns defaults if file doesn't exist.
    static func load() -> RFConfig {
        let path = configFilePath()
        guard FileManager.default.fileExists(atPath: path) else {
            return RFConfig()
        }

        do {
            let content = try String(contentsOfFile: path, encoding: .utf8)
            return parse(yaml: content)
        } catch {
            logger.error("Failed to load rf config: \(error.localizedDescription)")
            return RFConfig()
        }
    }

    /// Parse YAML content into RFConfig.
    static func parse(yaml: String) -> RFConfig {
        guard let parsed = try? Yams.load(yaml: yaml) as? [String: Any] else {
            return RFConfig()
        }

        var config = RFConfig()

        if let general = parsed["general"] as? [String: Any] {
            if let showHidden = general["show_hidden"] as? Bool {
                config.showHidden = showHidden
            }
            if let sortBy = general["sort_by"] as? String {
                config.sortBy = RFSortOrder.from(configString: sortBy)
            }
            if let restrictToHome = general["restrict_to_home"] as? Bool, !restrictToHome {
                config.rootPath = nil
            }
        }

        return config
    }

    /// Standard config file path: ~/Documents/.config/rf/rf.yaml
    static func configFilePath() -> String {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        return docs.appendingPathComponent(".config/rf/rf.yaml").path
    }

    /// ~/Documents path (iOS home directory).
    static func documentsPath() -> String {
        (FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].path as NSString).standardizingPath
    }
}

extension RFSortOrder {
    static func from(configString: String) -> RFSortOrder {
        switch configString.lowercased() {
        case "name":                      return .nameAsc
        case "name_desc":                 return .nameDesc
        case "size":                      return .sizeDesc
        case "size_asc":                  return .sizeAsc
        case "modified", "date":          return .modifiedDesc
        case "modified_asc", "date_asc":  return .modifiedAsc
        case "type", "extension":         return .typeAsc
        default:                          return .nameAsc
        }
    }
}

#endif
