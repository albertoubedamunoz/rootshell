#if !targetEnvironment(macCatalyst)
//
//  PromptConfigManager.swift
//  rootshell
//
//  Manages loading, caching, and file-watching of .promptrc.toml custom prompt configs.
//  Falls back to Settings theme when no config is present or when config has errors.
//

import Foundation
import os.log
import UIKit

// MARK: - Config Status

enum PromptConfigStatus: Sendable {
    case none               // No config file present
    case active             // Config loaded and valid
    case error(String)      // Config has errors, using fallback
}

// MARK: - Manager

@MainActor
final class PromptConfigManager {
    static let shared = PromptConfigManager()

    private nonisolated static let logger = Logger(subsystem: "com.rootshell", category: "PromptConfig")

    private(set) var activeConfig: PromptConfig?
    private(set) var configStatus: PromptConfigStatus = .none
    private var lastModificationDate: Date?
    private var parsedFormatNodes: [FormatNode]?
    private var parsedRightFormatNodes: [FormatNode]?
    private var parsedTransientFormatNodes: [FormatNode]?

    static let configFileName = ".promptrc.toml"

    var configFilePath: String {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].path
        return (docs as NSString).appendingPathComponent(Self.configFileName)
    }

    private init() {}

    private var configStatusIsNone: Bool {
        if case .none = configStatus { return true }
        return false
    }

    // MARK: - Loading

    /// Check file mod date and reload if changed. Returns config if valid, nil for fallback.
    func loadIfNeeded() -> PromptConfig? {
        let path = configFilePath

        guard FileManager.default.fileExists(atPath: path) else {
            if !configStatusIsNone {
                configStatus = .none
                activeConfig = nil
                parsedFormatNodes = nil
                parsedRightFormatNodes = nil
                parsedTransientFormatNodes = nil
                lastModificationDate = nil
            }
            return nil
        }

        // Check modification date for cache hit
        let attrs = try? FileManager.default.attributesOfItem(atPath: path)
        let modDate = attrs?[.modificationDate] as? Date

        if let cached = activeConfig,
           let lastMod = lastModificationDate,
           let currentMod = modDate,
           lastMod == currentMod {
            return cached
        }

        // Reload
        return forceReload()
    }

    /// Force reload the config file
    @discardableResult
    func forceReload() -> PromptConfig? {
        let path = configFilePath

        guard FileManager.default.fileExists(atPath: path) else {
            configStatus = .none
            activeConfig = nil
            parsedFormatNodes = nil
            parsedRightFormatNodes = nil
            parsedTransientFormatNodes = nil
            lastModificationDate = nil
            return nil
        }

        do {
            let contents = try String(contentsOfFile: path, encoding: .utf8)
            let tomlDict = try TOMLParser.parse(contents)
            let config = try PromptConfig.parse(from: tomlDict)

            // Validate format string parses cleanly
            let nodes = try PromptFormatParser.parse(config.format)

            // Parse right format if present
            var rightNodes: [FormatNode]?
            if !config.rightFormat.isEmpty {
                rightNodes = try PromptFormatParser.parse(config.rightFormat)
            }

            // Parse transient format if present
            var transientNodes: [FormatNode]?
            if let transientFormat = config.transientPrompt.format, config.transientPrompt.enabled {
                transientNodes = try PromptFormatParser.parse(transientFormat)
            }

            activeConfig = config
            parsedFormatNodes = nodes
            parsedRightFormatNodes = rightNodes
            parsedTransientFormatNodes = transientNodes
            configStatus = .active

            let attrs = try? FileManager.default.attributesOfItem(atPath: path)
            lastModificationDate = attrs?[.modificationDate] as? Date

            Self.logger.info("Loaded custom prompt config")
            return config
        } catch {
            let msg = error.localizedDescription
            Self.logger.warning("Invalid .promptrc.toml: \(msg)")
            configStatus = .error(msg)
            activeConfig = nil
            parsedFormatNodes = nil
            parsedRightFormatNodes = nil
            parsedTransientFormatNodes = nil
            return nil
        }
    }

    // MARK: - Prompt Generation

    /// Generate a prompt from the active config. Returns nil on evaluation failure.
    func safeGeneratePrompt(
        config: PromptConfig,
        directory: String,
        commandSucceeded: Bool,
        gitInfo: PromptGitInfo?
    ) -> PromptStyle.PromptResult? {
        // Build context from cached singletons
        let context = buildContext(
            directory: directory,
            commandSucceeded: commandSucceeded,
            gitInfo: gitInfo
        )

        // Use cached parsed nodes if available
        let nodes: [FormatNode]
        if let cached = parsedFormatNodes {
            nodes = cached
        } else {
            guard let parsed = try? PromptFormatParser.parse(config.format) else {
                Self.logger.warning("Failed to parse format string")
                configStatus = .error("Failed to parse format string")
                return nil
            }
            nodes = parsed
        }

        var result = PromptFormatEvaluator.evaluate(
            nodes: nodes,
            config: config,
            context: context
        )
        result.addsLeadingSeparator = true

        // Validate we have a usable prompt
        let visible = PromptStyle.stripANSI(result.text)
        guard !visible.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            Self.logger.warning("Custom config produced empty prompt, falling back")
            return nil
        }

        guard result.secondLinePrefix > 0 else {
            Self.logger.warning("Custom config has no input line, falling back")
            return nil
        }

        // Evaluate right prompt if configured
        if let rightNodes = parsedRightFormatNodes {
            let rightResult = PromptFormatEvaluator.evaluate(
                nodes: rightNodes,
                config: config,
                context: context,
                skipAutoCharacter: true
            )
            let rightVisible = PromptStyle.stripANSI(rightResult.text)
            if !rightVisible.trimmingCharacters(in: .whitespaces).isEmpty {
                result.rightPromptText = rightResult.text
                result.rightPromptWidth = rightVisible.count
            }
        }

        return result
    }

    /// Generate a transient (simplified) prompt to replace the full prompt after command execution.
    /// Returns nil if transient prompt is not enabled or evaluation fails.
    func generateTransientPrompt(
        config: PromptConfig,
        directory: String,
        commandSucceeded: Bool,
        gitInfo: PromptGitInfo?
    ) -> PromptStyle.PromptResult? {
        guard config.transientPrompt.enabled else { return nil }

        let context = buildContext(
            directory: directory,
            commandSucceeded: commandSucceeded,
            gitInfo: gitInfo
        )

        // Use custom transient format or default to just $character
        let nodes: [FormatNode]
        if let cached = parsedTransientFormatNodes {
            nodes = cached
        } else {
            // Default transient prompt: just the character module
            guard let parsed = try? PromptFormatParser.parse("$character") else {
                return nil
            }
            nodes = parsed
        }

        let result = PromptFormatEvaluator.evaluate(
            nodes: nodes,
            config: config,
            context: context,
            skipAutoCharacter: true  // Skip auto-appending \r\n❯ — transient is a single-line replacement
        )

        let visible = PromptStyle.stripANSI(result.text)
        guard !visible.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return nil
        }

        return result
    }

    // MARK: - Context Building

    private func buildContext(
        directory: String,
        commandSucceeded: Bool,
        gitInfo: PromptGitInfo?
    ) -> PromptEvalContext {
        // Battery
        let device = UIDevice.current
        device.isBatteryMonitoringEnabled = true
        let batteryLevel = device.batteryLevel
        let batteryState = device.batteryState

        // Network data from cached singletons
        var wifiSSID: String?
        var wifiBand: String?
        var wifiAPName: String?
        var networkIP: String?
        var networkISP: String?
        var networkCountryFlag: String?
        var networkType: String?
        var connectionType: String?

        #if canImport(ActivityKit)
        let lam = LiveActivityManager.shared
        wifiSSID = lam.cachedWiFiSSID
        wifiBand = lam.cachedWiFiBand
        wifiAPName = lam.cachedWiFiAPName
        networkIP = lam.cachedPublicIP
        networkISP = lam.cachedASName
        networkCountryFlag = lam.cachedCountryFlag
        networkType = lam.cachedNetworkType
        #endif

        let monitor = NetworkReachabilityMonitor.shared
        switch monitor.connectionType {
        case .wifi: connectionType = "wifi"
        case .cellular: connectionType = "cellular"
        case .wired: connectionType = "wired"
        case .loopback: connectionType = "loopback"
        case .unknown: connectionType = nil
        }

        return PromptEvalContext(
            directory: directory,
            commandSucceeded: commandSucceeded,
            gitInfo: gitInfo,
            batteryLevel: batteryLevel,
            batteryState: batteryState,
            wifiSSID: wifiSSID,
            wifiBand: wifiBand,
            wifiAPName: wifiAPName,
            networkIP: networkIP,
            networkISP: networkISP,
            networkCountryFlag: networkCountryFlag,
            networkType: networkType,
            connectionType: connectionType
        )
    }

    // MARK: - File Management

    func hasConfigFile() -> Bool {
        FileManager.default.fileExists(atPath: configFilePath)
    }

    /// Copy bundled example to ~/.promptrc.toml.example
    func createExampleFile() {
        let exampleDest = (configFilePath as NSString).appendingPathExtension("example") ?? configFilePath + ".example"

        guard let bundledURL = Bundle.main.url(forResource: "promptrc_example", withExtension: "toml") else {
            Self.logger.warning("Bundled example config not found")
            return
        }

        do {
            let content = try String(contentsOf: bundledURL, encoding: .utf8)
            try content.write(toFile: exampleDest, atomically: true, encoding: .utf8)
            Self.logger.info("Created example config at \(exampleDest)")
        } catch {
            Self.logger.warning("Failed to create example config: \(error)")
        }
    }

    /// Remove the config file
    func removeConfigFile() {
        try? FileManager.default.removeItem(atPath: configFilePath)
        configStatus = .none
        activeConfig = nil
        parsedFormatNodes = nil
        parsedRightFormatNodes = nil
        parsedTransientFormatNodes = nil
        lastModificationDate = nil
    }
}

#endif
