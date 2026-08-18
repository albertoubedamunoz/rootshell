//
//  ShaderManager.swift
//  rootshell
//
//  Manages custom shader configuration for terminal cursor effects
//

import Foundation
import Observation
import os

@MainActor
@Observable
class ShaderManager {
    static let shared = ShaderManager()

    private static let logger = Logger(subsystem: "com.rootshell", category: "ShaderManager")

    // MARK: - Types

    struct CustomShader: Codable, Identifiable, Equatable {
        let id: UUID
        var name: String
        let filename: String
        let importDate: Date

        static func == (lhs: CustomShader, rhs: CustomShader) -> Bool {
            lhs.id == rhs.id
        }
    }

    enum AnimationMode: String, Codable, CaseIterable {
        case disabled = "false"
        case whenFocused = "true"
        case always = "always"

        var displayName: String {
            switch self {
            case .disabled:
                return String(localized: "Disabled", comment: "Shader animation: disabled")
            case .whenFocused:
                return String(localized: "When Focused", comment: "Shader animation: when focused")
            case .always:
                return String(localized: "Always", comment: "Shader animation: always")
            }
        }
    }

    /// Classification of shader animation behavior
    enum ShaderAnimationType {
        case cursorOnly      // Uses cursor uniforms - animation has finite duration
        case continuous      // Full-screen/time-based - needs continuous animation
    }

    /// Analysis result for a shader's animation characteristics
    struct ShaderAnalysis {
        let animationType: ShaderAnimationType
        let maxDuration: TimeInterval  // For cursor-only shaders, the animation duration
    }

    // MARK: - UserDefaults Keys

    private static let enabledCustomKey = "enabledCustomShaders"
    private static let animationModeKey = "shaderAnimationMode"
    private static let customShadersKey = "customShadersList"

    // MARK: - Observable Properties

    var enabledCustomShaderIDs: Set<UUID> = [] {
        didSet {
            saveEnabledCustomShaders()
            notifyConfigChanged()
        }
    }

    var customShaders: [CustomShader] = [] {
        didSet {
            saveCustomShaders()
        }
    }

    var animationMode: AnimationMode = .whenFocused {
        didSet {
            saveAnimationMode()
            notifyConfigChanged()
        }
    }

    // MARK: - Shader Animation Analysis

    /// Cached shader analysis result (invalidated when shaders change)
    private var cachedShaderAnalysis: ShaderAnalysis?

    /// Returns the animation analysis for the currently active shader(s)
    var activeShaderAnalysis: ShaderAnalysis {
        if let cached = cachedShaderAnalysis {
            return cached
        }

        let analysis = computeActiveShaderAnalysis()
        cachedShaderAnalysis = analysis
        return analysis
    }

    /// Whether the active shader(s) are cursor-only (can pause when idle)
    var isCursorOnlyShader: Bool {
        activeShaderAnalysis.animationType == .cursorOnly
    }

    /// Maximum cursor animation duration for pause timing
    var maxCursorAnimationDuration: TimeInterval {
        activeShaderAnalysis.maxDuration
    }

    // MARK: - Initialization

    private init() {
        loadEnabledCustomShaders()
        loadCustomShaders()
        loadAnimationMode()
        // Initialize wasActive after loading persisted state
        wasActive = hasActiveShaders
    }

    // MARK: - Path Resolution

    /// Returns the Documents path for a custom shader
    func documentsPathForCustomShader(_ filename: String) -> URL {
        let documentsURL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        return documentsURL
            .appendingPathComponent(".ghostty", isDirectory: true)
            .appendingPathComponent("shaders", isDirectory: true)
            .appendingPathComponent(filename)
    }

    /// Returns the custom shaders directory, creating it if needed
    private var customShadersDirectory: URL {
        let documentsURL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let shadersDir = documentsURL
            .appendingPathComponent(".ghostty", isDirectory: true)
            .appendingPathComponent("shaders", isDirectory: true)

        if !FileManager.default.fileExists(atPath: shadersDir.path) {
            try? FileManager.default.createDirectory(at: shadersDir, withIntermediateDirectories: true)
        }

        return shadersDir
    }

    // MARK: - Import/Export

    /// Imports a shader from a URL, copying it to the Documents directory
    func importShader(from url: URL, name: String) throws -> CustomShader {
        // Start security-scoped access
        guard url.startAccessingSecurityScopedResource() else {
            throw ShaderImportError.accessDenied
        }
        defer { url.stopAccessingSecurityScopedResource() }

        // Generate unique filename to avoid conflicts
        let originalFilename = url.lastPathComponent
        let uniqueFilename = "\(UUID().uuidString)_\(originalFilename)"
        let destinationURL = documentsPathForCustomShader(uniqueFilename)

        // Ensure directory exists
        _ = customShadersDirectory

        // Copy the file
        try FileManager.default.copyItem(at: url, to: destinationURL)

        Self.logger.info("Imported shader: \(name) -> \(uniqueFilename)")

        let shader = CustomShader(
            id: UUID(),
            name: name,
            filename: uniqueFilename,
            importDate: Date()
        )

        customShaders.append(shader)
        return shader
    }

    /// Deletes a custom shader
    func deleteCustomShader(id: UUID) {
        guard let index = customShaders.firstIndex(where: { $0.id == id }) else { return }

        let shader = customShaders[index]
        let fileURL = documentsPathForCustomShader(shader.filename)

        // Remove from enabled set
        enabledCustomShaderIDs.remove(id)

        // Delete the file
        try? FileManager.default.removeItem(at: fileURL)

        // Remove from list
        customShaders.remove(at: index)

        Self.logger.info("Deleted shader: \(shader.name)")
    }

    // MARK: - Config Generation

    /// Generates config lines for GhosttyConfig (includes cursor effects from CursorManager)
    func generateConfigLines() -> [String] {
        var lines: [String] = []

        let cursorEffect = CursorManager.shared.cursorEffect
        Self.logger.info("Generating shader config. Cursor effect: \(cursorEffect.rawValue), enabled custom: \(self.enabledCustomShaderIDs)")

        // Add cursor effect shader from CursorManager
        lines.append(contentsOf: CursorManager.shared.generateEffectConfigLines())

        // Add enabled custom shaders
        for shader in customShaders where enabledCustomShaderIDs.contains(shader.id) {
            let path = documentsPathForCustomShader(shader.filename)
            if FileManager.default.fileExists(atPath: path.path) {
                lines.append("custom-shader = \(path.path)")
                Self.logger.info("Added custom shader: \(shader.filename) at \(path.path)")
            } else {
                Self.logger.error("Custom shader file not found: \(path.path)")
            }
        }

        // Add animation mode
        // Always set to "false" to disable Ghostty's internal 8ms timer on all Apple platforms.
        // - iOS/visionOS: CADisplayLink in TerminalView drives animation at vsync rate
        // - Mac Catalyst: CVDisplayLink in Ghostty core drives animation via displayCallback
        // The user's animation mode preference is still respected by the CADisplayLink logic.
        // Disabling the 8ms timer prevents double-rendering and GPU pegging.
        lines.append("custom-shader-animation = false")
        Self.logger.info("Disabled Ghostty internal timer, using platform display link for shader animation")

        Self.logger.info("Generated \(lines.count) shader config lines")
        return lines
    }

    /// Returns the total number of enabled shaders (custom only, cursor effects tracked by CursorManager)
    var enabledShaderCount: Int {
        enabledCustomShaderIDs.count
    }

    /// Returns true if any custom shaders are currently enabled
    var hasActiveShaders: Bool {
        enabledShaderCount > 0
    }

    /// Returns true if any shaders (cursor effects or custom) are active
    var hasAnyShadersActive: Bool {
        CursorManager.shared.hasActiveEffect || hasActiveShaders
    }

    // MARK: - Shader Analysis

    /// Default max animation duration for cursor shaders (Cursor Blaze has the longest at 0.5s)
    private static let defaultCursorAnimationDuration: TimeInterval = 0.5

    /// Computes the shader analysis for currently active shaders
    private func computeActiveShaderAnalysis() -> ShaderAnalysis {
        // If no shaders are active, return a default
        guard hasAnyShadersActive else {
            return ShaderAnalysis(animationType: .cursorOnly, maxDuration: Self.defaultCursorAnimationDuration)
        }

        var maxDuration: TimeInterval = 0
        var allAreCursorOnly = true

        // Analyze cursor effect if enabled
        let cursorEffect = CursorManager.shared.cursorEffect
        if cursorEffect != .none,
           let path = CursorManager.shared.bundlePathForEffect(cursorEffect) {
            let analysis = analyzeShaderFile(at: path)
            if analysis.animationType == .continuous {
                allAreCursorOnly = false
            }
            maxDuration = max(maxDuration, analysis.maxDuration)
        }

        // Analyze custom shaders if enabled
        for shader in customShaders where enabledCustomShaderIDs.contains(shader.id) {
            let path = documentsPathForCustomShader(shader.filename)
            let analysis = analyzeShaderFile(at: path)
            if analysis.animationType == .continuous {
                allAreCursorOnly = false
            }
            maxDuration = max(maxDuration, analysis.maxDuration)
        }

        // If no duration was found, use default
        if maxDuration == 0 {
            maxDuration = Self.defaultCursorAnimationDuration
        }

        return ShaderAnalysis(
            animationType: allAreCursorOnly ? .cursorOnly : .continuous,
            maxDuration: maxDuration
        )
    }

    /// Analyzes a shader file to determine its animation type and duration
    private func analyzeShaderFile(at url: URL) -> ShaderAnalysis {
        guard let source = try? String(contentsOf: url, encoding: .utf8) else {
            Self.logger.warning("Could not read shader source at: \(url.path)")
            return ShaderAnalysis(animationType: .continuous, maxDuration: Self.defaultCursorAnimationDuration)
        }

        return analyzeShaderSource(source)
    }

    /// Analyzes shader source code to determine animation type and duration
    /// - Cursor-only shaders use iCurrentCursor/iPreviousCursor uniforms
    /// - Duration is parsed from "const float DURATION = X.X" pattern
    private func analyzeShaderSource(_ source: String) -> ShaderAnalysis {
        let usesCursorUniforms = source.contains("iCurrentCursor") || source.contains("iPreviousCursor")

        // Parse DURATION constant using regex
        // Pattern: const float DURATION = 0.5;
        var duration: TimeInterval = Self.defaultCursorAnimationDuration

        let durationPattern = #"const\s+float\s+DURATION\s*=\s*([0-9.]+)"#
        if let regex = try? NSRegularExpression(pattern: durationPattern, options: []),
           let match = regex.firstMatch(in: source, options: [], range: NSRange(source.startIndex..., in: source)),
           let range = Range(match.range(at: 1), in: source),
           let parsedDuration = TimeInterval(source[range]) {
            duration = parsedDuration
            Self.logger.debug("Parsed shader DURATION: \(parsedDuration)s")
        }

        // Classify as cursor-only if it uses cursor uniforms and has a reasonable duration
        // (< 10 seconds, to exclude potential full-screen time-based shaders)
        if usesCursorUniforms && duration > 0 && duration < 10 {
            Self.logger.debug("Shader classified as cursor-only (uses cursor uniforms, duration: \(duration)s)")
            return ShaderAnalysis(animationType: .cursorOnly, maxDuration: duration)
        }

        Self.logger.debug("Shader classified as continuous (no cursor uniforms or long duration)")
        return ShaderAnalysis(animationType: .continuous, maxDuration: 0)
    }

    // MARK: - Persistence

    private func saveEnabledCustomShaders() {
        let array = enabledCustomShaderIDs.map { $0.uuidString }
        UserDefaults.standard.set(array, forKey: Self.enabledCustomKey)
    }

    private func loadEnabledCustomShaders() {
        if let array = UserDefaults.standard.stringArray(forKey: Self.enabledCustomKey) {
            enabledCustomShaderIDs = Set(array.compactMap { UUID(uuidString: $0) })
        }
    }

    private func saveAnimationMode() {
        UserDefaults.standard.set(animationMode.rawValue, forKey: Self.animationModeKey)
    }

    private func loadAnimationMode() {
        if let rawValue = UserDefaults.standard.string(forKey: Self.animationModeKey),
           let mode = AnimationMode(rawValue: rawValue) {
            animationMode = mode
        }
    }

    private func saveCustomShaders() {
        if let data = try? JSONEncoder().encode(customShaders) {
            UserDefaults.standard.set(data, forKey: Self.customShadersKey)
        }
    }

    private func loadCustomShaders() {
        if let data = UserDefaults.standard.data(forKey: Self.customShadersKey),
           let shaders = try? JSONDecoder().decode([CustomShader].self, from: data) {
            customShaders = shaders
        }
    }

    // MARK: - Config Change Notification

    /// Tracks whether shaders were active before the last change
    private var wasActive: Bool = false

    private func notifyConfigChanged() {
        // Invalidate shader analysis cache when config changes
        cachedShaderAnalysis = nil

        // Check if shader activation state changed
        let isNowActive = hasActiveShaders
        if isNowActive != wasActive {
            wasActive = isNowActive
            NotificationCenter.default.post(
                name: .shaderActivationChanged,
                object: nil,
                userInfo: ["isActive": isNowActive]
            )
            Self.logger.info("Shader activation changed: \(isNowActive)")
        }

        // Post notification for config reload
        NotificationCenter.default.post(name: .shaderConfigChanged, object: nil)
    }
}

// MARK: - Errors

enum ShaderImportError: LocalizedError {
    case accessDenied
    case copyFailed(Error)

    var errorDescription: String? {
        switch self {
        case .accessDenied:
            return "Access denied to the selected file"
        case .copyFailed(let error):
            return "Failed to copy shader: \(error.localizedDescription)"
        }
    }
}

// MARK: - Notifications

extension Notification.Name {
    static let shaderConfigChanged = Notification.Name("shaderConfigChanged")
    /// Posted when shaders go from active→inactive or inactive→active
    /// userInfo contains "isActive": Bool
    static let shaderActivationChanged = Notification.Name("shaderActivationChanged")
}
