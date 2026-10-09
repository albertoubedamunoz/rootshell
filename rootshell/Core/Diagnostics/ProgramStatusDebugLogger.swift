//
//  ProgramStatusDebugLogger.swift
//  rootshell
//
//  File-based debug logger for OSC 7501 program status reports: each
//  callback from libghostty, the pane's records after applying it, and what
//  reaches the agent inbox. Writes to Documents/.ghostty/program_status_debug.log.
//
//  Toggle: UserDefaults["programStatusDebugLoggingEnabled"], checked on every write.
//

import Foundation

final class ProgramStatusDebugLogger: Sendable {
    nonisolated static let shared = ProgramStatusDebugLogger()

    /// UserDefaults key to enable/disable logging
    nonisolated static let enabledKey = "programStatusDebugLoggingEnabled"

    /// Max log file size before rotation (2 MB)
    private static let maxFileSize: UInt64 = 2 * 1024 * 1024

    /// Serial queue for thread-safe file I/O
    private let ioQueue = DispatchQueue(label: "com.rootshell.programStatusDebugLogger")

    /// Log file URL: Documents/.ghostty/program_status_debug.log
    private let logFileURL: URL

    /// Rotated log file URL
    private let rotatedLogFileURL: URL

    /// Date formatter for timestamps
    private let dateFormatter: DateFormatter

    private init() {
        let documentsURL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let ghosttyDir = documentsURL.appendingPathComponent(".ghostty", isDirectory: true)
        self.logFileURL = ghosttyDir.appendingPathComponent("program_status_debug.log")
        self.rotatedLogFileURL = ghosttyDir.appendingPathComponent("program_status_debug.1.log")

        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        self.dateFormatter = formatter

        try? FileManager.default.createDirectory(at: ghosttyDir, withIntermediateDirectories: true)
    }

    /// Whether logging is enabled (checked on each write)
    nonisolated var isEnabled: Bool {
        UserDefaults.standard.bool(forKey: Self.enabledKey)
    }

    // MARK: - Public API

    /// Categorized event line. Categories: CALLBACK, RECORDS, INBOX.
    nonisolated func event(_ category: String, _ message: String) {
        guard isEnabled else { return }
        write("[\(timestamp())] [\(category)] \(message)\n")
    }

    /// Session boundary marker (e.g. APP LAUNCH)
    nonisolated func logMarker(_ marker: String) {
        guard isEnabled else { return }
        let separator = String(repeating: "=", count: 60)
        write("\n\(separator)\n[\(timestamp())] >>> \(marker) <<<\n\(separator)\n\n")
    }

    // MARK: - Private

    private nonisolated func timestamp() -> String {
        dateFormatter.string(from: Date())
    }

    private nonisolated func write(_ text: String) {
        guard let data = text.data(using: .utf8) else { return }
        ioQueue.async { [self] in
            self.appendAndSync(data)
        }
    }

    private nonisolated func appendAndSync(_ data: Data) {
        rotateIfNeeded()

        if FileManager.default.fileExists(atPath: logFileURL.path) {
            if let handle = try? FileHandle(forWritingTo: logFileURL) {
                _ = try? handle.seekToEnd()
                try? handle.write(contentsOf: data)
                try? handle.synchronize()
                try? handle.close()
            }
        } else {
            try? data.write(to: logFileURL, options: .atomic)
        }
    }

    private nonisolated func rotateIfNeeded() {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: logFileURL.path),
              let size = attrs[.size] as? UInt64,
              size > Self.maxFileSize else {
            return
        }
        try? FileManager.default.removeItem(at: rotatedLogFileURL)
        try? FileManager.default.moveItem(at: logFileURL, to: rotatedLogFileURL)
    }
}
