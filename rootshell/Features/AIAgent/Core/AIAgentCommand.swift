#if !CHINA_BUILD
//
//  AIAgentCommand.swift
//  rootshell
//
//  Command model with risk analysis for AI Agent
//

import Foundation

/// A command proposed by the AI agent
struct AIAgentCommand: Identifiable, Sendable {
    let id: UUID
    let toolCallId: String
    var command: String
    let explanation: String?
    let reason: String?                           // LLM-provided reason for running command
    let declaredOperationType: OperationType?     // LLM-declared operation type
    let detectedOperationType: OperationType      // Regex-detected operation type
    let riskLevel: RiskLevel
    let riskReasons: [String]
    let timestamp: Date
    let isFromXMLToolCall: Bool  // True if from MiniMax XML parsing

    /// Whether the LLM misclassified the operation (declared read but is clearly a write).
    /// Uses conservative detection - only flags commands that are UNAMBIGUOUSLY writes (rm, mv, chmod, etc.)
    /// to minimize false positives. Commands like `cat /etc/passwd` won't trigger this.
    var isMisclassified: Bool {
        guard let declared = declaredOperationType else { return false }
        guard declared == .read else { return false }

        // Only flag if command is UNAMBIGUOUSLY a write operation
        return CommandRiskAnalyzer.isUnambiguousWrite(command)
    }

    /// The effective operation type (uses detection if misclassified or undeclared)
    var effectiveOperationType: OperationType {
        if isMisclassified { return .write }
        return declaredOperationType ?? detectedOperationType
    }

    /// Command risk levels
    enum RiskLevel: Int, Sendable, Comparable {
        case low = 0       // Safe read-only commands: ls, cat, pwd, echo, df, ps
        case medium = 1    // Commands that modify state: rm, mv, chmod, cp, mkdir
        case high = 2      // Potentially dangerous: rm -r, dd, mkfs, chmod -R
        case critical = 3  // Extremely dangerous: rm -rf /, fork bombs, disk wipes

        static func < (lhs: RiskLevel, rhs: RiskLevel) -> Bool {
            lhs.rawValue < rhs.rawValue
        }

        var displayName: String {
            switch self {
            case .low: return String(localized: "Low Risk", comment: "Command risk level")
            case .medium: return String(localized: "Medium Risk", comment: "Command risk level")
            case .high: return String(localized: "High Risk", comment: "Command risk level")
            case .critical: return String(localized: "Critical Risk", comment: "Command risk level")
            }
        }

        var description: String {
            switch self {
            case .low:
                return String(localized: "Read-only command, safe to execute", comment: "Low risk description")
            case .medium:
                return String(localized: "May modify files or system state", comment: "Medium risk description")
            case .high:
                return String(localized: "Could cause significant changes or data loss", comment: "High risk description")
            case .critical:
                return String(localized: "Potentially catastrophic - review carefully!", comment: "Critical risk description")
            }
        }
    }

    /// Operation type declared or detected for a command
    enum OperationType: String, Codable, Sendable {
        case read = "read"
        case write = "write"

        var displayName: String {
            switch self {
            case .read: return String(localized: "Read", comment: "Operation type: read-only command")
            case .write: return String(localized: "Write", comment: "Operation type: modifying command")
            }
        }

        var icon: String {
            switch self {
            case .read: return "eye"
            case .write: return "pencil"
            }
        }
    }

    init(
        id: UUID = UUID(),
        toolCallId: String,
        command: String,
        explanation: String? = nil,
        reason: String? = nil,
        declaredOperationType: OperationType? = nil,
        timestamp: Date = Date(),
        isFromXMLToolCall: Bool = false
    ) {
        self.id = id
        self.toolCallId = toolCallId
        self.command = command
        self.explanation = explanation
        self.reason = reason
        self.declaredOperationType = declaredOperationType
        self.timestamp = timestamp
        self.isFromXMLToolCall = isFromXMLToolCall

        // Analyze risk and detect operation type
        let analysis = CommandRiskAnalyzer.analyze(command)
        self.riskLevel = analysis.level
        self.riskReasons = analysis.reasons
        self.detectedOperationType = analysis.operationType
    }
}

/// Analyzes commands for potential risks
struct CommandRiskAnalyzer {
    /// Analysis result
    struct Analysis {
        let level: AIAgentCommand.RiskLevel
        let reasons: [String]
        let operationType: AIAgentCommand.OperationType
    }

    // MARK: - Unambiguous Write Detection (for misclassification)

    /// Commands that are ALWAYS write operations - used for misclassification detection only.
    /// These must have near-zero false positive rate. Only commands with NO read variant.
    private static let unambiguousWriteCommands: Set<String> = [
        // Deletion (always destructive)
        "rm", "rmdir", "unlink", "shred",
        // Filesystem modification (always changes state)
        "mv", "mkdir", "touch", "truncate", "ln",
        // Permission changes (always modify)
        "chmod", "chown", "chgrp",
        // Disk operations (always destructive)
        "mkfs", "mkswap", "fdisk", "parted",
        // Copy (creates files)
        "cp",
    ]

    /// Patterns for write operations that need regex (not just command name).
    /// Used for misclassification detection - must have near-zero false positives.
    private static let unambiguousWritePatterns: [String] = [
        // dd with output file
        "\\bdd\\b.*\\bof=",

        // Output redirection to file (but not stderr redirect like 2>&1)
        "(?<!\\d)>(?!&|>)\\s*[^\\s]",   // > file (not >& or >>)
        ">>\\s*\\S",                     // >> file

        // Pipe to tee (writes to file)
        "\\|\\s*tee\\b",

        // Package management (always modifies system)
        "\\b(apt|apt-get)\\s+(install|remove|purge|update|upgrade)\\b",
        "\\byum\\s+(install|remove|update)\\b",
        "\\bdnf\\s+(install|remove|update)\\b",
        "\\bpacman\\s+-[SRU]",
        "\\bbrew\\s+(install|uninstall|upgrade)\\b",
        "\\bpip3?\\s+install\\b",
        "\\bnpm\\s+(install|uninstall|i|un)\\b",

        // Service management (state change)
        "\\bsystemctl\\s+(start|stop|restart|enable|disable)\\b",
        "\\bservice\\s+\\w+\\s+(start|stop|restart)\\b",
    ]

    /// Check if command is unambiguously a write operation (for misclassification detection).
    /// This is conservative - only returns true for commands that have NO read variant.
    static func isUnambiguousWrite(_ command: String) -> Bool {
        let trimmed = command.trimmingCharacters(in: .whitespaces)

        // Extract the base command (first word, ignoring sudo/doas prefix)
        var baseCommand = trimmed
        for prefix in ["sudo ", "doas "] {
            if baseCommand.lowercased().hasPrefix(prefix) {
                baseCommand = String(baseCommand.dropFirst(prefix.count)).trimmingCharacters(in: .whitespaces)
                break
            }
        }
        let firstWord = baseCommand.split(separator: " ").first.map { String($0) } ?? ""

        // Check if base command is an unambiguous write command
        if unambiguousWriteCommands.contains(firstWord.lowercased()) {
            return true
        }

        // Check regex patterns for compound write operations
        for pattern in unambiguousWritePatterns {
            if matches(command: trimmed, pattern: pattern) {
                return true
            }
        }

        return false
    }

    // MARK: - Read-Only Patterns

    /// Patterns that indicate read-only commands (safe for auto-approval in "approve writes only" mode)
    private static let readOnlyPatterns: [String] = [
        // File listing and inspection
        "^ls\\b",
        "^ll\\b",
        "^cat\\b",
        "^head\\b",
        "^tail\\b",
        "^less\\b",
        "^more\\b",
        "^file\\b",
        "^stat\\b",
        "^wc\\b",
        "^md5sum\\b",
        "^sha\\d*sum\\b",
        "^cksum\\b",

        // Text processing (read-only)
        "^grep\\b",
        "^egrep\\b",
        "^fgrep\\b",
        "^awk\\b",
        "^sed\\s+-n",  // sed -n is read-only (print only)
        "^sort\\b",
        "^uniq\\b",
        "^cut\\b",
        "^tr\\b",
        "^diff\\b",
        "^cmp\\b",
        "^comm\\b",

        // Search and find (read-only variants)
        "^find\\b.*-print",
        "^find\\b.*-ls",
        "^locate\\b",
        "^which\\b",
        "^whereis\\b",
        "^type\\b",

        // System info
        "^pwd\\b",
        "^whoami\\b",
        "^id\\b",
        "^hostname\\b",
        "^uname\\b",
        "^arch\\b",
        "^df\\b",
        "^du\\b",
        "^free\\b",
        "^uptime\\b",
        "^date\\b",
        "^cal\\b",
        "^timedatectl\\s+status",

        // Process info
        "^ps\\b",
        "^top\\s+-b",  // batch mode top
        "^htop\\b",
        "^pgrep\\b",
        "^pidof\\b",
        "^lsof\\b",

        // Network info
        "^netstat\\b",
        "^ss\\b",
        "^ip\\s+(addr|route|link|neigh)\\s*($|show)",
        "^ifconfig\\b",
        "^ping\\b",
        "^traceroute\\b",
        "^tracepath\\b",
        "^mtr\\b",
        "^dig\\b",
        "^nslookup\\b",
        "^host\\b",
        "^curl\\s+.*-I",  // HEAD request
        "^curl\\s+.*--head",
        "^wget\\s+.*--spider",

        // Environment
        "^env\\b",
        "^printenv\\b",
        "^echo\\b",
        "^printf\\b",
        "^set\\b",

        // Help and documentation
        "^man\\b",
        "^help\\b",
        "^info\\b",

        // User/group info
        "^w\\b",
        "^who\\b",
        "^users\\b",
        "^groups\\b",
        "^last\\b",
        "^lastlog\\b",
        "^getent\\b",
        "^finger\\b",

        // Service status (read-only)
        "^systemctl\\s+status",
        "^systemctl\\s+is-active",
        "^systemctl\\s+is-enabled",
        "^systemctl\\s+list-",
        "^service\\s+\\w+\\s+status",

        // Logs (read-only)
        "^journalctl\\b",
        "^dmesg\\b",

        // Hardware info
        "^lsblk\\b",
        "^lscpu\\b",
        "^lsmem\\b",
        "^lspci\\b",
        "^lsusb\\b",
        "^lshw\\b",
        "^dmidecode\\b",

        // Git read operations
        "^git\\s+(status|log|diff|show|branch|tag|remote|config\\s+--get)",

        // Docker read operations
        "^docker\\s+(ps|images|logs|inspect|stats)",

        // Kubernetes read operations
        "^kubectl\\s+(get|describe|logs|top)",
    ]

    // MARK: - Critical Risk Patterns

    private static let criticalPatterns: [(pattern: String, reason: String)] = [
        // Fork bombs and infinite loops
        (":\\(\\)\\{\\s*:|:&\\s*\\};:", "Fork bomb detected"),
        ("while\\s+true.*do.*done", "Infinite loop"),

        // Catastrophic deletions
        ("rm\\s+(-[rf]+\\s+)*/?\\s*$", "Delete root filesystem"),
        ("rm\\s+(-[rf]+\\s+)*/\\*", "Delete all files from root"),
        ("rm\\s+(-[rf]+\\s+)*/home/?\\*?", "Delete home directories"),
        ("rm\\s+(-[rf]+\\s+)*/etc/?\\*?", "Delete system configuration"),
        ("rm\\s+(-[rf]+\\s+)*/var/?\\*?", "Delete system data"),

        // Direct disk operations
        ("dd.*of=/dev/[hs]d[a-z]$", "Direct disk overwrite"),
        ("dd.*of=/dev/nvme", "Direct NVMe overwrite"),

        // System destruction
        ("mkfs\\s+/dev/[hs]d[a-z]\\d*", "Format disk partition"),
        (":>\\s*/dev/[hs]d[a-z]", "Overwrite disk device"),
    ]

    // MARK: - High Risk Patterns

    private static let highRiskPatterns: [(pattern: String, reason: String)] = [
        // Recursive force operations
        ("rm\\s+(-[^\\s]*r[^\\s]*|-[^\\s]*f[^\\s]*r|--recursive)", "Recursive file deletion"),
        ("chmod\\s+(-R|--recursive)", "Recursive permission change"),
        ("chown\\s+(-R|--recursive)", "Recursive ownership change"),

        // Disk and partition operations
        ("dd\\s+", "Direct disk operation"),
        ("fdisk", "Partition manipulation"),
        ("parted", "Partition manipulation"),
        ("mkswap", "Create swap space"),

        // Download and execute
        ("curl.*\\|.*sh", "Download and execute script"),
        ("wget.*\\|.*sh", "Download and execute script"),
        ("curl.*\\|.*bash", "Download and execute script"),
        ("wget.*\\|.*bash", "Download and execute script"),

        // System modifications
        ("chmod\\s+777", "World-writable permissions"),
        ("chmod\\s+666", "World-writable file"),
        ("/etc/passwd", "Modifying user database"),
        ("/etc/shadow", "Modifying password database"),
        ("/etc/sudoers", "Modifying sudo configuration"),

        // Service disruption
        ("shutdown", "System shutdown"),
        ("reboot", "System reboot"),
        ("init\\s+[06]", "System halt/reboot"),
        ("systemctl\\s+(stop|disable)\\s+", "Stop/disable service"),
        ("kill\\s+-9\\s+-1", "Kill all user processes"),
        ("killall\\s+-9", "Force kill processes"),
        ("pkill\\s+-9", "Force kill processes"),
    ]

    // MARK: - Medium Risk Patterns

    private static let mediumRiskPatterns: [(pattern: String, reason: String)] = [
        // File operations
        ("rm\\s+", "File deletion"),
        ("mv\\s+", "File move/rename"),
        ("cp\\s+", "File copy"),
        (">\\s*[^|]", "File overwrite"),
        (">>\\s*", "File append"),

        // Permission/ownership changes
        ("chmod\\s+", "Permission change"),
        ("chown\\s+", "Ownership change"),
        ("chgrp\\s+", "Group change"),

        // Process management
        ("kill\\s+", "Process termination"),
        ("pkill\\s+", "Process termination"),
        ("killall\\s+", "Process termination"),

        // Package management
        ("apt(-get)?\\s+(install|remove|purge)", "Package installation/removal"),
        ("yum\\s+(install|remove|erase)", "Package installation/removal"),
        ("dnf\\s+(install|remove)", "Package installation/removal"),
        ("pacman\\s+(-S|-R)", "Package installation/removal"),
        ("brew\\s+(install|uninstall)", "Package installation/removal"),
        ("pip\\s+install", "Python package installation"),
        ("npm\\s+(install|uninstall)", "Node.js package installation"),

        // Service management
        ("systemctl\\s+(start|restart|reload)", "Service management"),
        ("service\\s+\\w+\\s+(start|stop|restart)", "Service management"),

        // Elevated privileges
        ("sudo\\s+", "Elevated privileges"),
        ("su\\s+", "User switching"),
        ("doas\\s+", "Elevated privileges"),

        // Network changes
        ("iptables", "Firewall modification"),
        ("ufw", "Firewall modification"),
        ("firewall-cmd", "Firewall modification"),

        // Cron/scheduled tasks
        ("crontab", "Scheduled task modification"),
        ("at\\s+", "Scheduled task"),
    ]

    // MARK: - Analysis

    /// Analyze a command for risk level and operation type
    static func analyze(_ command: String) -> Analysis {
        var reasons: [String] = []
        var maxLevel: AIAgentCommand.RiskLevel = .low

        // Check critical patterns first
        for (pattern, reason) in criticalPatterns {
            if matches(command: command, pattern: pattern) {
                reasons.append(reason)
                maxLevel = .critical
            }
        }

        // If already critical, return early
        if maxLevel == .critical {
            let operationType = detectOperationType(command, riskLevel: maxLevel)
            return Analysis(level: maxLevel, reasons: reasons, operationType: operationType)
        }

        // Check high risk patterns
        for (pattern, reason) in highRiskPatterns {
            if matches(command: command, pattern: pattern) {
                reasons.append(reason)
                if maxLevel < .high {
                    maxLevel = .high
                }
            }
        }

        // Check medium risk patterns
        for (pattern, reason) in mediumRiskPatterns {
            if matches(command: command, pattern: pattern) {
                reasons.append(reason)
                if maxLevel < .medium {
                    maxLevel = .medium
                }
            }
        }

        // Remove duplicates while preserving order
        var seen = Set<String>()
        reasons = reasons.filter { seen.insert($0).inserted }

        // Detect operation type based on patterns
        let operationType = detectOperationType(command, riskLevel: maxLevel)

        return Analysis(level: maxLevel, reasons: reasons, operationType: operationType)
    }

    /// Detect whether command is a read or write operation.
    /// Used when LLM doesn't declare operation type. Prioritizes read-only pattern matching.
    private static func detectOperationType(_ command: String, riskLevel: AIAgentCommand.RiskLevel) -> AIAgentCommand.OperationType {
        let trimmedCommand = command.trimmingCharacters(in: .whitespaces)

        // First check if it's an unambiguous write (rm, mv, chmod, etc.)
        if isUnambiguousWrite(trimmedCommand) {
            return .write
        }

        // Check if command matches read-only patterns
        for pattern in readOnlyPatterns {
            if matches(command: trimmedCommand, pattern: pattern) {
                return .read
            }
        }

        // Default to write for safety (unknown commands should require approval)
        return .write
    }

    /// Check if command matches pattern (case-insensitive)
    private static func matches(command: String, pattern: String) -> Bool {
        guard let regex = try? NSRegularExpression(
            pattern: pattern,
            options: [.caseInsensitive]
        ) else {
            return false
        }

        let range = NSRange(command.startIndex..., in: command)
        return regex.firstMatch(in: command, options: [], range: range) != nil
    }
}

// MARK: - Command Highlighting

extension AIAgentCommand {
    /// Get ranges of dangerous keywords in the command for UI highlighting
    func dangerousKeywordRanges() -> [(range: Range<String.Index>, reason: String)] {
        var results: [(Range<String.Index>, String)] = []

        let dangerousKeywords: [(keyword: String, reason: String)] = [
            ("rm -rf", "Recursive force delete"),
            ("rm -fr", "Recursive force delete"),
            ("-rf", "Force recursive"),
            ("dd ", "Direct disk write"),
            ("mkfs", "Format filesystem"),
            ("chmod 777", "World-writable"),
            ("> /dev/", "Device write"),
            ("| sh", "Pipe to shell"),
            ("| bash", "Pipe to shell"),
            ("sudo", "Elevated privileges"),
            ("shutdown", "System shutdown"),
            ("reboot", "System reboot"),
            ("kill -9", "Force kill"),
        ]

        let lowercaseCommand = command.lowercased()

        for (keyword, reason) in dangerousKeywords {
            var searchRange = lowercaseCommand.startIndex..<lowercaseCommand.endIndex
            while let range = lowercaseCommand.range(of: keyword.lowercased(), range: searchRange) {
                // Convert to original string range
                let originalRange = Range(uncheckedBounds: (
                    command.index(command.startIndex, offsetBy: lowercaseCommand.distance(from: lowercaseCommand.startIndex, to: range.lowerBound)),
                    command.index(command.startIndex, offsetBy: lowercaseCommand.distance(from: lowercaseCommand.startIndex, to: range.upperBound))
                ))
                results.append((originalRange, reason))
                searchRange = range.upperBound..<lowercaseCommand.endIndex
            }
        }

        return results
    }
}
#endif
