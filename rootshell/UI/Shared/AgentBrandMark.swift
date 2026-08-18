//
//  AgentBrandMark.swift
//  rootshell
//
//  The detected agent's product logo, drawn at the trailing edge of the
//  sidebar card's context line. Card line 1 already names the agent in
//  text, so the mark is decorative and stays out of accessibility.
//

import SwiftUI

struct AgentBrandMark: View {
    /// Manifest agent id from `AgentRowState.agentID`; nil on plain
    /// command rows (a failed shell command with no agent).
    let agentID: String?
    var size: CGFloat = 14

    /// Manifest agent id → asset-catalog name.
    ///
    /// Presentation only, deliberately not a manifest field: the manifest
    /// can be replaced at runtime from Documents, so unknown ids must
    /// degrade to no mark rather than to a missing-asset box.
    ///
    /// Codex has no product mark of its own and borrows OpenAI's, but it
    /// gets its own `CodexLogo` rather than reusing `OpenAILogo`: that
    /// asset is an export with ~16% padding baked into its viewBox, which
    /// renders visibly smaller than the other marks at the same frame.
    /// `CodexLogo` is the same artwork cropped to its ink bounds.
    ///
    /// `omp` and `pi` are separate products (oh-my-pi is a fork of pi) and
    /// keep separate marks. `OhMyPiLogo` is oh-my-pi's own icon, letterboxed
    /// into a square viewBox and cropped to its ink bounds for the same
    /// reason `CodexLogo` is.
    private static let assetNames: [String: String] = [
        "agy": "AntigravityLogo",
        "claude": "ClaudeLogo",
        "codex": "CodexLogo",
        "copilot": "CopilotLogo",
        "cursor": "CursorAgentLogo",
        "omp": "OhMyPiLogo",
        "opencode": "OpenCodeLogo",
        "pi": "PiLogo",
    ]

    /// Bypasses the agent-id lookup for callers that already know which
    /// asset they want. The usage footer needs this: its rows are keyed by
    /// provider brand rather than by a detected agent, and oh-my-pi reports
    /// brands that have no manifest agent id at all.
    private var explicitAsset: String?

    init(agentID: String?, size: CGFloat = 14) {
        self.agentID = agentID
        self.size = size
        self.explicitAsset = nil
    }

    init(assetName: String, size: CGFloat = 14) {
        self.agentID = nil
        self.size = size
        self.explicitAsset = assetName
    }

    var body: some View {
        if let asset = explicitAsset ?? agentID.flatMap({ Self.assetNames[$0] }) {
            Image(asset)
                // Brand fills, not a tint: Claude's salmon is fixed in
                // both appearances, the rest ship light/dark variants.
                .renderingMode(.original)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(width: size, height: size)
                // Quiet enough to sit behind the row's text, but no
                // further: `SidebarTabRow` also fades receding agent
                // metadata to 0.72, and the two multiply.
                .opacity(0.85)
                .accessibilityHidden(true)
        }
    }
}
