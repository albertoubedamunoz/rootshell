import Testing
@testable import RootshellPushKit

@Suite("Push agent logo mapping")
struct PushAgentLogoAttachmentTests {
    @Test("Known hook agents resolve to existing asset-catalog images", arguments: [
        (agent: "claude-code", assetName: "ClaudeLogo"),
        (agent: "codex", assetName: "CodexLogo"),
    ])
    func knownAgent(agent: String, assetName: String) {
        #expect(PushAgentLogoAttachment.assetName(for: agent) == assetName)
    }

    @Test("Unknown and absent agents do not resolve to an asset", arguments: [
        nil,
        "",
        "cursor",
        "claude",
    ] as [String?])
    func unknownAgent(agent: String?) {
        #expect(PushAgentLogoAttachment.assetName(for: agent) == nil)
    }
}
