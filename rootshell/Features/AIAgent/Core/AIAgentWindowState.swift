#if !CHINA_BUILD
//
//  AIAgentWindowState.swift
//  rootshell
//
//  Singleton state manager for the dedicated AI Agent window
//

import Foundation
import os.log

/// Singleton state manager for the AI Agent window
/// Tracks which sessions are active and which is currently displayed
@Observable
@MainActor
final class AIAgentWindowState {
    private nonisolated static let logger = Logger(subsystem: "com.rootshell", category: "AIAgentWindowState")

    static let shared = AIAgentWindowState()

    // MARK: - State

    /// Sessions currently displayed in the window (tab ID -> session)
    private(set) var windowSessions: [UUID: AIAgentSession] = [:]

    /// Currently selected session tab ID in the window
    var selectedSessionTabID: UUID?

    /// Whether the window should be shown
    var isWindowOpen: Bool = false

    // MARK: - Computed Properties

    /// Ordered list of tab IDs for display in picker (sorted by display name)
    var orderedTabIDs: [UUID] {
        Array(windowSessions.keys).sorted {
            windowSessions[$0]?.displayName ?? "" <
            windowSessions[$1]?.displayName ?? ""
        }
    }

    /// Get current session based on selection
    var currentSession: AIAgentSession? {
        guard let id = selectedSessionTabID else { return nil }
        return windowSessions[id]
    }

    /// Number of active sessions
    var sessionCount: Int {
        windowSessions.count
    }

    /// Whether there are any sessions
    var hasSessions: Bool {
        !windowSessions.isEmpty
    }

    // MARK: - Session Management

    /// Add a session to the window
    func addSession(tabID: UUID, session: AIAgentSession) {
        Self.logger.debug("Adding session for tab \(tabID.uuidString.prefix(8)) - \(session.displayName)")
        windowSessions[tabID] = session
        if selectedSessionTabID == nil {
            selectedSessionTabID = tabID
        }
    }

    /// Remove a session from the window
    func removeSession(tabID: UUID) {
        guard windowSessions[tabID] != nil else { return }
        Self.logger.debug("Removing session for tab \(tabID.uuidString.prefix(8))")
        windowSessions.removeValue(forKey: tabID)
        if selectedSessionTabID == tabID {
            selectedSessionTabID = orderedTabIDs.first
        }
    }

    /// Check if a session is in the window
    func containsSession(tabID: UUID) -> Bool {
        windowSessions[tabID] != nil
    }

    /// Get display name for a tab
    func displayName(for tabID: UUID) -> String {
        windowSessions[tabID]?.displayName ?? "Unknown"
    }

    /// Select a specific session
    func selectSession(tabID: UUID) {
        guard windowSessions[tabID] != nil else { return }
        selectedSessionTabID = tabID
    }

    /// Select the previous session (with wrap-around)
    func previousSession() {
        let ordered = orderedTabIDs
        guard ordered.count > 1,
              let currentID = selectedSessionTabID,
              let currentIndex = ordered.firstIndex(of: currentID) else { return }

        let newIndex = currentIndex > 0 ? currentIndex - 1 : ordered.count - 1
        selectedSessionTabID = ordered[newIndex]
    }

    /// Select the next session (with wrap-around)
    func nextSession() {
        let ordered = orderedTabIDs
        guard ordered.count > 1,
              let currentID = selectedSessionTabID,
              let currentIndex = ordered.firstIndex(of: currentID) else { return }

        let newIndex = currentIndex < ordered.count - 1 ? currentIndex + 1 : 0
        selectedSessionTabID = ordered[newIndex]
    }

    /// Select a session by 1-based index (for CMD-1 through CMD-9)
    func selectSession(at index: Int) {
        let ordered = orderedTabIDs
        let arrayIndex = index - 1  // Convert 1-based to 0-based
        guard arrayIndex >= 0 && arrayIndex < ordered.count else { return }
        selectedSessionTabID = ordered[arrayIndex]
    }

    /// Close the current session
    /// - Returns: true if this was the last session (window should close)
    func closeCurrentSession() -> Bool {
        guard let currentID = selectedSessionTabID else { return windowSessions.isEmpty }
        removeSession(tabID: currentID)
        return windowSessions.isEmpty
    }

    /// Clear all sessions (used when closing window)
    func clearAllSessions() {
        Self.logger.debug("Clearing all sessions")
        for (_, session) in windowSessions {
            session.cancel()
        }
        windowSessions.removeAll()
        selectedSessionTabID = nil
    }

    // MARK: - Private

    private init() {}
}
#endif
