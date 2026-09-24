import XCTest

final class MuxSessionTargetTests: XCTestCase {
    func testLocalControlSessionCannotInterceptRemoteProfile() throws {
        for type in [MultiplexerType.tmux, .herdr] {
            let target = try XCTUnwrap(MuxSessionTarget(type: type, sessionName: "default", controlMode: true))
            XCTAssertFalse(target.matchesLiveAttachment(target, connectionKey: nil,
                requestedConnectionKey: "user@remote:22", isActive: true))
            XCTAssertFalse(target.matchesLiveAttachment(target, connectionKey: "user@other:22",
                requestedConnectionKey: "user@remote:22", isActive: true))
            XCTAssertTrue(target.matchesLiveAttachment(target, connectionKey: "user@remote:22",
                requestedConnectionKey: "user@remote:22", isActive: true))
        }
    }

    func testFailedConnectionsAndUnboundShellsDoNotBlockReconnect() throws {
        for type in [MultiplexerType.tmux, .herdr, .zmx, .zellij] {
            let target = try XCTUnwrap(MuxSessionTarget(type: type, sessionName: "work"))
            XCTAssertFalse(target.matchesLiveAttachment(target, connectionKey: "remote",
                requestedConnectionKey: "remote", isActive: false))
            XCTAssertFalse(target.matchesLiveAttachment(nil, connectionKey: "remote",
                requestedConnectionKey: "remote", isActive: true))
            XCTAssertTrue(target.matchesLiveAttachment(target, connectionKey: "remote",
                requestedConnectionKey: "remote", isActive: true))
        }
    }

    func testDifferentSessionsAndModesAreNotInterchangeable() throws {
        let target = try XCTUnwrap(MuxSessionTarget(type: .tmux, sessionName: "work", controlMode: true))
        for other in [
            MuxSessionTarget(type: .tmux, sessionName: "work"),
            MuxSessionTarget(type: .tmux, sessionName: "other", controlMode: true),
            MuxSessionTarget(type: .herdr, sessionName: "work", controlMode: true)
        ] {
            XCTAssertFalse(target.matchesLiveAttachment(other, connectionKey: "remote",
                requestedConnectionKey: "remote", isActive: true))
        }
    }

    func testUnknownSessionDoesNotOfferAnUnrelatedReconnect() {
        for type in [MultiplexerType.tmux, .herdr, .zellij, .zmx] {
            XCTAssertNil(MuxSessionTarget(type: type, sessionName: nil))
            XCTAssertNil(MuxSessionTarget(type: type, sessionName: ""))
        }
    }

    func testTmuxReconnectPreservesControlModeAndUsesExactSessionTarget() throws {
        for control in [false, true] {
            let target = try XCTUnwrap(MuxSessionTarget(type: .tmux, sessionName: "work", controlMode: control))
            XCTAssertEqual(target.execCommand, LoginShellCommand.runInPOSIXShell(
                LoginShellCommand.pathPrefix + "exec tmux \(control ? "-CC " : "")attach-session -t \"=work\""))
        }
    }

    func testHerdrControlReconnectLeavesGatewayOnShell() throws {
        let target = try XCTUnwrap(MuxSessionTarget(type: .herdr, sessionName: "default", controlMode: true))
        XCTAssertEqual(target.sessionName, "default")
        XCTAssertTrue(target.controlMode)
        XCTAssertNil(target.execCommand)
        let raw = try XCTUnwrap(MuxSessionTarget(type: .herdr, sessionName: "project"))
        XCTAssertEqual(raw.execCommand, LoginShellCommand.runInPOSIXShell(
            LoginShellCommand.pathPrefix + "exec herdr session attach \"project\""))
    }

    func testZellijAndZmxReconnectToDiscoveredName() throws {
        let zellij = try XCTUnwrap(MuxSessionTarget(type: .zellij, sessionName: "project", controlMode: true))
        XCTAssertFalse(zellij.controlMode)
        XCTAssertEqual(zellij.execCommand, LoginShellCommand.runInPOSIXShell(
            LoginShellCommand.pathPrefix + "exec zellij attach \"project\""))
        let zmx = try XCTUnwrap(MuxSessionTarget(type: .zmx, sessionName: "prefix-project"))
        XCTAssertEqual(zmx.execCommand, LoginShellCommand.runInPOSIXShell(
            LoginShellCommand.pathPrefix + "ZMX_SESSION_PREFIX= exec zmx attach \"prefix-project\""))
    }

    func testSessionNamesAreQuotedAcrossBothShellLayers() throws {
        let name = "work's \"tab\"; $HOME `id` \\ end"
        let target = try XCTUnwrap(MuxSessionTarget(type: .zellij, sessionName: name))
        let quoted = "\"work's \\\"tab\\\"; \\$HOME \\`id\\` \\\\ end\""
        XCTAssertEqual(target.execCommand, LoginShellCommand.runInPOSIXShell(
            LoginShellCommand.pathPrefix + "exec zellij attach " + quoted))
    }
}
