import XCTest

@MainActor
final class ProxyJumpTests: XCTestCase {
    // MARK: - ProxyJumpSpec

    func testParseListSplitsHopsWithUsersAndPorts() throws {
        let hops = try XCTUnwrap(ProxyJumpSpec.parseList("ops@gateway, bastion:2222,dev@[fd00::1]:2200"))
        XCTAssertEqual(hops, [
            ProxyJumpSpec(host: "gateway", port: nil, username: "ops"),
            ProxyJumpSpec(host: "bastion", port: 2222, username: nil),
            ProxyJumpSpec(host: "fd00::1", port: 2200, username: "dev"),
        ])
        XCTAssertEqual(hops[0].portOrDefault, 22)
    }

    func testParseListAcceptsURIsAndBareIPv6() throws {
        XCTAssertEqual(ProxyJumpSpec.parseList("ssh://me@jump.example.com:2022/"),
                       [ProxyJumpSpec(host: "jump.example.com", port: 2022, username: "me")])
        XCTAssertEqual(ProxyJumpSpec.parseList("fd00::1"), [ProxyJumpSpec(host: "fd00::1", port: nil, username: nil)])
        XCTAssertEqual(ProxyJumpSpec.parseList("[fd00::1]"), [ProxyJumpSpec(host: "fd00::1", port: nil, username: nil)])
        XCTAssertEqual(ProxyJumpSpec.parseList("a@b@corp@host"), [ProxyJumpSpec(host: "host", port: nil, username: "a@b@corp")])
    }

    func testParseListRejectsNoneEmptyHopsAndBadPorts() {
        XCTAssertNil(ProxyJumpSpec.parseList("none"))
        XCTAssertNil(ProxyJumpSpec.parseList("  "))
        XCTAssertNil(ProxyJumpSpec.parseList("a,,b"))
        XCTAssertNil(ProxyJumpSpec.parseList("a,"))
        XCTAssertNil(ProxyJumpSpec.parseList("host:0"))
        XCTAssertNil(ProxyJumpSpec.parseList("host:70000"))
        XCTAssertNil(ProxyJumpSpec.parseList("host:ssh"))
        XCTAssertNil(ProxyJumpSpec.parseList("user@"))
        XCTAssertNil(ProxyJumpSpec.parseList("[fd00::1"))
    }

    // MARK: - OpenSSH import

    private let sshDirectory = URL(fileURLWithPath: "/tmp/proxyjump-tests/.ssh")

    private func resolveChain(_ text: String, target: String) throws -> OpenSSHHostResolution.JumpChainResolution {
        let entries = OpenSSHConfigParser.parse(text: text, sshDirectory: sshDirectory).entries
        let concretes = entries.filter { !$0.isWildcard }
        let entry = try XCTUnwrap(concretes.first { $0.aliases.contains(target) })
        let resolved = OpenSSHHostResolution.resolve(entry: entry, entries: entries)
        return OpenSSHHostResolution.resolveJumpChain(for: resolved, entries: entries,
                                                      defaultUsername: "root", resolvePath: { $0 })
    }

    func testIssueConfigKeepsEveryHopWithItsOwnSettings() throws {
        let config = """
        Host work
            HostName work.internal
            User dev
            ProxyJump gateway,bastion

        Host gateway
            HostName gw.example.com
            User ops
            Port 2200
            IdentityFile ~/.ssh/gateway_key

        Host bastion
            HostName 10.0.0.5
            User jump
            IdentityFile ~/.ssh/bastion_key
        """
        let resolution = try resolveChain(config, target: "work")
        XCTAssertNil(resolution.warning)
        XCTAssertEqual(resolution.hops.map(\.host), ["gw.example.com", "10.0.0.5"])
        XCTAssertEqual(resolution.hops.map(\.username), ["ops", "jump"])
        XCTAssertEqual(resolution.hops.map(\.port), [2200, 22])
        XCTAssertEqual(resolution.hops.map(\.identityPaths), [["~/.ssh/gateway_key"], ["~/.ssh/bastion_key"]])
        XCTAssertEqual(resolution.hops.map(\.display), ["ops@gw.example.com:2200", "jump@10.0.0.5"])
    }

    func testExplicitUserAndPortOverrideHopBlock() throws {
        let config = """
        Host work
            ProxyJump admin@gateway:2022,plain.example.com

        Host gateway
            HostName gw.example.com
            User ops
            Port 2200
        """
        let hops = try resolveChain(config, target: "work").hops
        XCTAssertEqual(hops.map(\.host), ["gw.example.com", "plain.example.com"])
        XCTAssertEqual(hops.map(\.username), ["admin", "root"])
        XCTAssertEqual(hops.map(\.port), [2022, 22])
        // Hops without their own IdentityFile inherit the target's keys.
        XCTAssertEqual(hops.map(\.identityPaths), [nil, nil])
    }

    func testFirstHopOwnProxyJumpIsPrepended() throws {
        let config = """
        Host work
            ProxyJump bastion,inner

        Host bastion
            ProxyJump edge
            IdentityFile none

        Host inner
            ProxyJump ignored

        Host edge
            HostName edge.example.com
        """
        let resolution = try resolveChain(config, target: "work")
        XCTAssertNil(resolution.warning)
        XCTAssertEqual(resolution.hops.map(\.host), ["edge.example.com", "bastion", "inner"])
        // `IdentityFile none` means no keys, not the target's.
        XCTAssertEqual(resolution.hops[1].identityPaths, [])
    }

    func testJumpCycleIsSkippedWithWarning() throws {
        let config = """
        Host work
            ProxyJump a

        Host a
            ProxyJump b

        Host b
            ProxyJump a
        """
        let resolution = try resolveChain(config, target: "work")
        XCTAssertTrue(resolution.hops.isEmpty)
        XCTAssertNotNil(resolution.warning)
    }

    func testWildcardFillsHopSettings() throws {
        let config = """
        Host work
            ProxyJump jump1.corp

        Host *.corp
            User corpuser
            Port 2222
        """
        let hop = try XCTUnwrap(try resolveChain(config, target: "work").hops.first)
        XCTAssertEqual(hop.host, "jump1.corp")
        XCTAssertEqual(hop.username, "corpuser")
        XCTAssertEqual(hop.port, 2222)
    }

    func testHopWildcardMatchesOnlyTheNamedAlias() throws {
        let config = """
        Host work
            ProxyJump gw-dev

        Host gw-prod gw-dev
            HostName gw.example.com

        Host gw-prod*
            User produser
            Port 2299
            IdentityFile ~/.ssh/prod_key
        """
        let hop = try XCTUnwrap(try resolveChain(config, target: "work").hops.first)
        XCTAssertEqual(hop.host, "gw.example.com")
        XCTAssertEqual(hop.username, "root")
        XCTAssertEqual(hop.port, 22)
        XCTAssertNil(hop.identityPaths)
    }

    func testRepeatedHostBlocksMergeForHop() throws {
        let config = """
        Host work
            ProxyJump bastion

        Host bastion
            User ops
            IdentityFile ~/.ssh/a_key

        Host other bastion
            User ignored
            Port 2222
            IdentityFile ~/.ssh/b_key
        """
        let hop = try XCTUnwrap(try resolveChain(config, target: "work").hops.first)
        XCTAssertEqual(hop.username, "ops")
        XCTAssertEqual(hop.port, 2222)
        XCTAssertEqual(hop.identityPaths, ["~/.ssh/a_key", "~/.ssh/b_key"])
    }

    func testProxyJumpNoneMeansNoChain() throws {
        let resolution = try resolveChain("Host work\n    ProxyJump none\n", target: "work")
        XCTAssertTrue(resolution.hops.isEmpty)
        XCTAssertNil(resolution.warning)
    }

    func testEarlierWildcardWinsHopOptionsAndKeepsIdentityOrder() throws {
        let config = """
        Host work
            ProxyJump gateway

        Host gateway*
            HostName shared.example.com
            User shared
            Port 2200
            IdentityFile ~/.ssh/shared_key

        Host gateway
            HostName specific.example.com
            User ops
            Port 22
            IdentityFile ~/.ssh/specific_key
        """
        let hop = try XCTUnwrap(try resolveChain(config, target: "work").hops.first)
        XCTAssertEqual(hop.host, "shared.example.com")
        XCTAssertEqual(hop.username, "shared")
        XCTAssertEqual(hop.port, 2200)
        XCTAssertEqual(hop.identityPaths, ["~/.ssh/shared_key", "~/.ssh/specific_key"])
    }

    func testLaterWildcardOnlyFillsUnsetHopOptions() throws {
        let config = """
        Host work
            ProxyJump gateway

        Host gateway
            HostName specific.example.com
            User ops
            IdentityFile ~/.ssh/specific_key

        Host gateway*
            HostName shared.example.com
            User shared
            Port 2200
            IdentityFile ~/.ssh/shared_key
        """
        let hop = try XCTUnwrap(try resolveChain(config, target: "work").hops.first)
        XCTAssertEqual(hop.host, "specific.example.com")
        XCTAssertEqual(hop.username, "ops")
        XCTAssertEqual(hop.port, 2200)
        XCTAssertEqual(hop.identityPaths, ["~/.ssh/specific_key", "~/.ssh/shared_key"])
    }

    func testInterleavedBlocksUseFirstValueForEachHopOption() throws {
        let config = """
        Host work
            ProxyJump gateway

        Host gateway*
            User shared

        Host gateway
            HostName specific.example.com
            Port 2200

        Host * !work
            User ignored
            Port 2299

        Host gateway
            User ops
            Port 22
        """
        let hop = try XCTUnwrap(try resolveChain(config, target: "work").hops.first)
        XCTAssertEqual(hop.host, "specific.example.com")
        XCTAssertEqual(hop.username, "shared")
        XCTAssertEqual(hop.port, 2200)
    }

    func testEarlierWildcardProxyJumpWinsForDestination() throws {
        let config = """
        Host work*
            ProxyJump gateway

        Host work
            ProxyJump ignored
        """
        let resolution = try resolveChain(config, target: "work")
        XCTAssertNil(resolution.warning)
        XCTAssertEqual(resolution.hops.map(\.host), ["gateway"])
    }

    func testIncludedWildcardKeepsItsPositionBeforeConcreteBlock() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try """
        Host gateway*
            User shared
            Port 2200
            IdentityFile ~/.ssh/shared_key
        """.write(to: directory.appendingPathComponent("defaults.conf"), atomically: true, encoding: .utf8)
        let configURL = directory.appendingPathComponent("config")
        try """
        Include defaults.conf
        Host work
            ProxyJump gateway
        Host gateway
            User ops
            Port 22
            IdentityFile ~/.ssh/specific_key
        """.write(to: configURL, atomically: true, encoding: .utf8)
        let parsed = try OpenSSHConfigParser.parse(fileURL: configURL, sshDirectory: directory)
        XCTAssertTrue(parsed.warnings.isEmpty)
        let entry = try XCTUnwrap(parsed.entries.first { $0.aliases == ["work"] })
        let resolved = OpenSSHHostResolution.resolve(entry: entry, entries: parsed.entries)
        let chain = OpenSSHHostResolution.resolveJumpChain(
            for: resolved, entries: parsed.entries, defaultUsername: "root", resolvePath: { $0 }
        )
        XCTAssertNil(chain.warning)
        let hop = try XCTUnwrap(chain.hops.first)
        XCTAssertEqual(hop.username, "shared")
        XCTAssertEqual(hop.port, 2200)
        XCTAssertEqual(hop.identityPaths, ["~/.ssh/shared_key", "~/.ssh/specific_key"])
    }

    private func resolveFirst(_ text: String, target: String) throws -> OpenSSHHostEntry {
        let entries = OpenSSHConfigParser.parse(text: text, sshDirectory: sshDirectory).entries
        let entry = try XCTUnwrap(entries.first { $0.aliases.contains(target) })
        return OpenSSHHostResolution.resolve(entry: entry, entries: entries)
    }

    func testEarlierProxyCommandBlocksLaterProxyJump() throws {
        let resolved = try resolveFirst("""
        Host work
            ProxyCommand ssh -W %h:%p ops@edge
        Host work
            ProxyJump other
        """, target: "work")
        XCTAssertEqual(resolved.proxyCommand, "ssh -W %h:%p ops@edge")
        XCTAssertNil(resolved.proxyJump)
    }

    func testFirstProxyDirectiveWinsWithinBlock() throws {
        let jumpFirst = try resolveFirst("""
        Host work
            ProxyJump gateway
            ProxyCommand ssh -W %h:%p ops@edge
        """, target: "work")
        XCTAssertEqual(jumpFirst.proxyJump, "gateway")
        XCTAssertNil(jumpFirst.proxyCommand)

        let commandFirst = try resolveFirst("""
        Host work
            ProxyCommand ssh -W %h:%p ops@edge
            ProxyJump gateway
        """, target: "work")
        XCTAssertNil(commandFirst.proxyJump)
        XCTAssertEqual(commandFirst.proxyCommand, "ssh -W %h:%p ops@edge")
    }

    func testProxyJumpNoneLeavesLaterProxyCommandInEffect() throws {
        let resolved = try resolveFirst("""
        Host work
            ProxyJump none
        Host *
            ProxyJump ignored
            ProxyCommand ssh -W %h:%p ops@edge
        """, target: "work")
        let chain = OpenSSHHostResolution.resolveJumpChain(
            for: resolved, entries: [], defaultUsername: "root",
            parseProxyCommand: { _ in .init(host: "edge", port: 22, username: "ops") },
            resolvePath: { $0 }
        )
        XCTAssertNil(chain.warning)
        XCTAssertEqual(chain.hops.map(\.host), ["edge"])
    }

    func testProxyCommandNoneMeansDirect() throws {
        let resolved = try resolveFirst("""
        Host work
            ProxyCommand none
        Host *
            ProxyJump gateway
        """, target: "work")
        let chain = OpenSSHHostResolution.resolveJumpChain(
            for: resolved, entries: [], defaultUsername: "root", resolvePath: { $0 }
        )
        XCTAssertNil(chain.warning)
        XCTAssertTrue(chain.hops.isEmpty)
    }

    func testIdentityFileNoneKeepsOtherIdentities() throws {
        let acrossBlocks = try resolveFirst("""
        Host work
            IdentityFile ~/.ssh/work_key
        Host work
            IdentityFile none
        """, target: "work")
        XCTAssertEqual(acrossBlocks.identityFiles, ["~/.ssh/work_key"])

        let sameBlock = try resolveFirst("""
        Host work
            IdentityFile ~/.ssh/work_key
            IdentityFile none
        Host *
            IdentityFile ~/.ssh/shared_key
        """, target: "work")
        XCTAssertEqual(sameBlock.identityFiles, ["~/.ssh/work_key", "~/.ssh/shared_key"])
        XCTAssertTrue(sameBlock.listsIdentityFileNone)
    }
}
