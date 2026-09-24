import XCTest

final class MuxSessionTargetTests: XCTestCase {
    func testCustomTmuxServersSurviveReconnect() throws {
        for (command, socket) in [
            ("tmux -L work -CC new-session -A -s main", TmuxSocketIdentity.name("work")),
            ("exec /usr/bin/tmux -S '/tmp/work socket' attach -t main", .path("/tmp/work socket")),
            ("sh -c 'exec tmux -Lwork -CC attach -t main'", .name("work")),
            ("tmux -S/tmp/socket -Lignored attach -t main", .path("/tmp/socket")),
            ("tmux -CC new-session -A -s main", .defaultServer)
        ] {
            XCTAssertEqual(TmuxSocketIdentity.fromStartupCommand(command), socket)
            let target = try XCTUnwrap(MuxSessionTarget(type: .tmux, sessionName: "main", controlMode: true,
                                                      tmuxSocket: socket))
            XCTAssertEqual(target.execCommand, LoginShellCommand.runInPOSIXShell(
                LoginShellCommand.pathPrefix + "exec tmux \(socket.arguments)-CC attach-session -t \"=main\""))
        }
        XCTAssertNil(TmuxSocketIdentity.fromStartupCommand("tmux -S \"$SOCKET\" attach"))
        XCTAssertNil(TmuxSocketIdentity.fromStartupCommand("tmux -S ~/socket attach"))
        XCTAssertNil(TmuxSocketIdentity.fromStartupCommand("tmux -S /tmp/socket-* attach"))
        XCTAssertNil(MuxSessionTarget(type: .tmux, sessionName: "main", tmuxSocket: nil))
    }

    func testControlServerIdentityCapturesResolvedNamedSocketAndQuotesIt() throws {
        let path = "/tmp/tmux-501/work,team:one ' $HOME `id`"
        let socket = try XCTUnwrap(TmuxSocketIdentity.fromServerIdentity("host:\(path),123,456"))
        XCTAssertEqual(socket, .path(path))
        let target = try XCTUnwrap(MuxSessionTarget(type: .tmux, sessionName: "main", controlMode: true, tmuxSocket: socket))
        XCTAssertEqual(target.execCommand, LoginShellCommand.runInPOSIXShell(LoginShellCommand.pathPrefix
            + "exec tmux -S \"/tmp/tmux-501/work,team:one ' \\$HOME \\`id\\`\" -CC attach-session -t \"=main\""))
        XCTAssertNil(TmuxSocketIdentity.fromServerIdentity("incomplete"))
    }

    func testSameNamedSessionsOnDifferentTmuxServersDoNotMatch() throws {
        let work = try XCTUnwrap(MuxSessionTarget(type: .tmux, sessionName: "main", tmuxSocket: .name("work")))
        let other = try XCTUnwrap(MuxSessionTarget(type: .tmux, sessionName: "main", tmuxSocket: .name("other")))
        XCTAssertFalse(work.matchesLiveAttachment(other, connectionKey: "remote", requestedConnectionKey: "remote", isActive: true))
        let resolved = try XCTUnwrap(MuxSessionTarget(type: .tmux, sessionName: "main", tmuxSocket: .path("/tmp/tmux-501/work"),
                                                    tmuxSocketSelector: .name("work")))
        XCTAssertTrue(work.matchesLiveAttachment(resolved, connectionKey: "remote", requestedConnectionKey: "remote",
                                                 isActive: true))
        XCTAssertFalse(other.matchesLiveAttachment(resolved, connectionKey: "remote", requestedConnectionKey: "remote",
                                                  isActive: true))
    }

    func testOriginalProfileMatchesAfterRepeatedReconnectAndRestoration() throws {
        for selector in [TmuxSocketIdentity.defaultServer, .name("work")] {
            for controlMode in [false, true] {
                let profile = try XCTUnwrap(MuxSessionTarget(type: .tmux, sessionName: "main",
                                                            controlMode: controlMode, tmuxSocket: selector))
                let path = TmuxSocketIdentity.path("/tmp/tmux-501/resolved")
                var attachment = profile
                for _ in 0..<2 {
                    let detached = try XCTUnwrap(MuxSessionTarget(type: .tmux, sessionName: attachment.sessionName,
                        controlMode: attachment.controlMode, tmuxSocket: path,
                        tmuxSocketSelector: attachment.configuredTmuxSocket))
                    attachment = try JSONDecoder().decode(MuxSessionTarget.self, from: JSONEncoder().encode(detached))
                    XCTAssertEqual(attachment.configuredTmuxSocket, selector)
                    XCTAssertEqual(attachment.tmuxSocket, path)
                    XCTAssertEqual(attachment.execCommand, LoginShellCommand.runInPOSIXShell(
                        LoginShellCommand.pathPrefix + "exec tmux -S \"/tmp/tmux-501/resolved\" "
                        + "\(controlMode ? "-CC " : "")attach-session -t \"=main\""))
                    XCTAssertTrue(profile.matchesLiveAttachment(attachment, connectionKey: "remote",
                        requestedConnectionKey: "remote", isActive: true))
                    let other = try XCTUnwrap(MuxSessionTarget(type: .tmux, sessionName: "main",
                        controlMode: controlMode, tmuxSocket: .name("other")))
                    XCTAssertFalse(other.matchesLiveAttachment(attachment, connectionKey: "remote",
                        requestedConnectionKey: "remote", isActive: true))
                }
            }
        }
    }

    func testTildeExpansionIsUnknownWhileQuotedTildesRemainLiteral() {
        for command in ["tmux -S ~/work.sock attach", "tmux -S ~user/work.sock attach",
                        "sh -c 'exec tmux -S ~/work.sock attach'"] {
            let socket = TmuxSocketIdentity.fromStartupCommand(command)
            XCTAssertNil(socket)
            XCTAssertNil(MuxSessionTarget(type: .tmux, sessionName: "main", tmuxSocket: socket))
        }
        for command in ["tmux -S '~/work.sock' attach", "tmux -S \"~/work.sock\" attach",
                        "tmux -S \\~/work.sock attach"] {
            XCTAssertEqual(TmuxSocketIdentity.fromStartupCommand(command), .path("~/work.sock"))
        }
    }

    func testZellijAndCustomTmuxTargetsRoundTripForTabRestoration() throws {
        for target in [
            MuxSessionTarget(type: .zellij, sessionName: "restored project"),
            MuxSessionTarget(type: .tmux, sessionName: "main", controlMode: true, tmuxSocket: .path("/tmp/custom socket")),
            MuxSessionTarget(type: .tmux, sessionName: "main", tmuxSocket: .name("work"))
        ] {
            let original = try XCTUnwrap(target)
            let data = try JSONEncoder().encode(original)
            let restored = try JSONDecoder().decode(MuxSessionTarget.self, from: data)
            XCTAssertEqual(restored, original)
            XCTAssertEqual(restored.execCommand, original.execCommand)
            XCTAssertNotNil(restored.execCommand)
        }
    }

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
