import Foundation
import XCTest

final class ProgramIdentityTests: XCTestCase {
    // MARK: - Normalizer

    func testNormalizerStripsLoginDashAndPath() {
        XCTAssertEqual(ProgramNameNormalizer.normalize(name: "-zsh"), "zsh")
        XCTAssertEqual(ProgramNameNormalizer.normalize(name: "/usr/bin/htop"), "htop")
        XCTAssertEqual(ProgramNameNormalizer.normalize(name: "/opt/homebrew/bin/fish"), "fish")
    }

    func testNormalizerCollapsesInterpreterVersions() {
        XCTAssertEqual(ProgramNameNormalizer.normalize(name: "python3.12"), "python")
        XCTAssertEqual(ProgramNameNormalizer.normalize(name: "python3"), "python")
        XCTAssertEqual(ProgramNameNormalizer.normalize(
            name: "/opt/homebrew/Cellar/python@3.14/3.14.4/Frameworks/Python.framework/Versions/3.14/Resources/Python.app/Contents/MacOS/Python"),
            "python")
        XCTAssertEqual(ProgramNameNormalizer.normalize(name: "ruby3.3"), "ruby")
        XCTAssertEqual(ProgramNameNormalizer.normalize(name: "emacs-31.1"), "emacs")
        XCTAssertEqual(ProgramNameNormalizer.normalize(name: "/usr/bin/gcc-14"), "gcc")
        XCTAssertEqual(ProgramNameNormalizer.normalize(name: "mosh-client"), "mosh-client")
        XCTAssertEqual(ProgramNameNormalizer.normalize(name: "perldoc"), "perldoc")
        XCTAssertEqual(ProgramNameNormalizer.normalize(name: "nodemon"), "nodemon")
    }

    func testNormalizerUnwrapsLaunchers() {
        let normalize = { (line: String) in
            let words = ProgramNameNormalizer.words(of: line)
            return ProgramNameNormalizer.normalize(name: words[0], arguments: words)
        }
        XCTAssertEqual(normalize("sudo -u root htop"), "htop")
        XCTAssertEqual(normalize("sudo -E nvim /etc/hosts"), "nvim")
        XCTAssertEqual(normalize("env A=1 B=2 nvim"), "nvim")
        XCTAssertEqual(normalize("FOO=1 make -j8"), "make")
        XCTAssertEqual(normalize("nice -n 10 time make"), "make")
        XCTAssertEqual(normalize("exec -a name zsh"), "zsh")
        // Nothing left to run: the launcher is the program.
        XCTAssertEqual(normalize("sudo -i"), "sudo")
        XCTAssertEqual(normalize("command -v git"), "command")
    }

    func testNormalizerWithoutArgumentsKeepsLauncherName() {
        XCTAssertEqual(ProgramNameNormalizer.normalize(name: "sudo"), "sudo")
        XCTAssertNil(ProgramNameNormalizer.normalize(name: ""))
    }

    // MARK: - Catalog and identity

    func testCatalogAliases() {
        XCTAssertEqual(ProgramCatalog.entry(for: "nu")?.id, "nushell")
        XCTAssertEqual(ProgramCatalog.entry(for: "hx")?.mark, .asset("HelixLogo"))
        XCTAssertEqual(ProgramCatalog.entry(for: "vi")?.id, "vim")
        XCTAssertEqual(ProgramCatalog.entry(for: "nvim")?.id, "neovim")
        XCTAssertEqual(ProgramCatalog.entry(for: "mksh")?.mark, .symbol("terminal"))
        XCTAssertEqual(ProgramCatalog.entry(for: "pwsh")?.kind, .shell)
        XCTAssertEqual(ProgramCatalog.entry(for: "btm")?.id, "bottom")
        XCTAssertNil(ProgramCatalog.entry(for: "make"))
    }

    func testEveryProgramHasAMark() throws {
        XCTAssertEqual(try XCTUnwrap(ForegroundProgram(rawName: "make", source: .tmux)).mark, ProgramCatalog.runningProgramMark)
        XCTAssertEqual(try XCTUnwrap(ForegroundProgram(rawName: "rc", isShell: true, source: .herdr)).mark, .symbol("terminal"))
        XCTAssertEqual(try XCTUnwrap(ForegroundProgram(rawName: "top", source: .tmux)).mark, .symbol("gauge.with.dots.needle.67percent"))
        XCTAssertEqual(try XCTUnwrap(ForegroundProgram(rawName: "htop", source: .tmux)).mark, .asset("HtopLogo"))
        XCTAssertEqual(try XCTUnwrap(ForegroundProgram(rawName: "/Users/me/.cargo/bin/cargo", source: .localProcess)).mark, .asset("CargoLogo"))
        XCTAssertEqual(try XCTUnwrap(ForegroundProgram(rawName: "/opt/homebrew/bin/gtail", source: .localProcess)).mark, .asset("TailLogo"))
        XCTAssertEqual(try XCTUnwrap(ForegroundProgram(rawName: "nvim", source: .tmux)).mark, .asset("NeovimLogo"))
        XCTAssertEqual(try XCTUnwrap(ForegroundProgram(rawName: "python3.12", source: .tmux)).mark, .asset("PythonLogo"))
        XCTAssertTrue(try XCTUnwrap(ForegroundProgram(rawName: "htop", source: .tmux)).showsRunningCard)
        XCTAssertFalse(try XCTUnwrap(ForegroundProgram(rawName: "tmux", source: .localProcess)).showsRunningCard)
        XCTAssertFalse(try XCTUnwrap(ForegroundProgram(rawName: "-zsh", source: .localProcess)).showsRunningCard)
    }

    func testShellWithoutScriptIsAtPrompt() throws {
        let login = try XCTUnwrap(ForegroundProgram(rawName: "-zsh", arguments: ["-zsh"], source: .localProcess))
        XCTAssertTrue(login.isShell)
        let interactive = try XCTUnwrap(ForegroundProgram(rawName: "bash", arguments: ["bash", "-l"], source: .localProcess))
        XCTAssertTrue(interactive.isShell)
        let script = try XCTUnwrap(ForegroundProgram(rawName: "bash", arguments: ["bash", "build.sh"], source: .localProcess))
        XCTAssertFalse(script.isShell)
        let program = try XCTUnwrap(ForegroundProgram(rawName: "htop", source: .tmux))
        XCTAssertFalse(program.isShell)
        // An explicit answer from the source wins over the catalog.
        let reported = try XCTUnwrap(ForegroundProgram(rawName: "zsh", isShell: false, source: .herdr))
        XCTAssertFalse(reported.isShell)
    }

    func testSourcePriority() {
        XCTAssertGreaterThan(ForegroundProgram.Source.shellReport, .herdr)
        XCTAssertGreaterThan(ForegroundProgram.Source.herdr, .tmux)
        XCTAssertGreaterThan(ForegroundProgram.Source.tmux, .localProcess)
        XCTAssertGreaterThan(ForegroundProgram.Source.localProcess, .loginShell)
    }

    // MARK: - Shell reports

    func testShellReportsTrackShellAndCommand() {
        var reports = ShellProgramReports()
        reports.apply(id: ShellProgramReports.shellID, change: .idle, app: "zsh", title: "")
        XCTAssertEqual(reports.program?.name, "zsh")
        XCTAssertEqual(reports.program?.isShell, true)

        reports.apply(id: ShellProgramReports.commandID, change: .active, app: "sudo", title: "sudo htop -d 5")
        XCTAssertEqual(reports.program?.name, "htop")
        XCTAssertEqual(reports.program?.isShell, false)
        XCTAssertEqual(reports.program?.commandLine, "sudo htop -d 5")

        // 133;D drops the working command; the shell's idle record stays.
        reports.commandFinished()
        XCTAssertEqual(reports.program?.name, "zsh")

        reports.apply(id: ShellProgramReports.commandID, change: .active, app: "vim", title: "")
        reports.apply(id: ShellProgramReports.commandID, change: .finished, app: "vim", title: "")
        XCTAssertEqual(reports.program?.name, "zsh")

        // Clearing the shell record clears its children too.
        reports.apply(id: ShellProgramReports.commandID, change: .active, app: "vim", title: "")
        reports.apply(id: ShellProgramReports.shellID, change: .clear, app: "", title: "")
        XCTAssertNil(reports.program)
    }

    func testShellIdleReportClearsLeftoverCommand() {
        // A replacement session's first prompt must not inherit a dropped one's command.
        var reports = ShellProgramReports()
        reports.apply(id: ShellProgramReports.commandID, change: .active, app: "htop", title: "htop")
        XCTAssertEqual(reports.program?.name, "htop")
        reports.apply(id: ShellProgramReports.shellID, change: .idle, app: "bash", title: "")
        XCTAssertEqual(reports.program?.name, "bash")
        XCTAssertEqual(reports.program?.isShell, true)
    }

    func testShellReportOwnership() {
        XCTAssertTrue(ShellProgramReports.owns(id: "rootshell.shell"))
        XCTAssertTrue(ShellProgramReports.owns(id: "rootshell.shell/cmd"))
        XCTAssertFalse(ShellProgramReports.owns(id: "rootshell.shellfish"))
        XCTAssertFalse(ShellProgramReports.owns(id: ""))
        XCTAssertFalse(ShellProgramReports.owns(id: "build"))
    }

    // MARK: - Encoder

    func testEncoderBuildsCommandRecord() throws {
        let report = try XCTUnwrap(ShellProgramReportEncoder.commandStarted(commandLine: "sudo htop"))
        XCTAssertTrue(report.hasPrefix("\u{1B}]7501;state=working:id=rootshell.shell/cmd:app=htop:title="))
        XCTAssertTrue(report.hasSuffix("\u{1B}\\"))
        let title = try XCTUnwrap(Self.title(of: report))
        XCTAssertEqual(Data(base64Encoded: title).map { String(decoding: $0, as: UTF8.self) }, "sudo htop")
    }

    /// The base64 `title` value; padding can end in `=`, so no splitting on it.
    private static func title(of report: String) -> String? {
        guard let start = report.range(of: ":title="),
              let end = report.range(of: "\u{1B}\\", range: start.upperBound..<report.endIndex) else { return nil }
        return String(report[start.upperBound..<end.lowerBound])
    }

    func testEncoderKeepsTitleWithinLimitAndDropsControls() throws {
        let long = String(repeating: "é", count: 200)
        let report = try XCTUnwrap(ShellProgramReportEncoder.commandStarted(commandLine: "echo \(long)\u{7}"))
        let title = try XCTUnwrap(Self.title(of: report))
        let decoded = try XCTUnwrap(Data(base64Encoded: title))
        XCTAssertLessThanOrEqual(decoded.count, ShellProgramReportEncoder.maxCommandLineBytes)
        XCTAssertNotNil(String(data: decoded, encoding: .utf8))
        XCTAssertFalse(decoded.contains(0x07))
        XCTAssertNil(ShellProgramReportEncoder.commandStarted(commandLine: "   "))
    }

    // MARK: - herdr

    func testHerdrPaneInfoDecodesForegroundProcess() throws {
        let json = """
        {"pane_id":"p1","terminal_id":"t1","workspace_id":"w1","tab_id":"w1:t1","focused":true,
         "agent_status":"unknown","revision":3,
         "foreground_process":{"name":"htop","argv":["htop","-d","5"],"is_shell":false}}
        """
        let pane = try HerdrControl.decoder.decode(HerdrControl.PaneInfo.self, from: Data(json.utf8))
        XCTAssertEqual(pane.foregroundProgram?.name, "htop")
        XCTAssertEqual(pane.foregroundProgram?.isShell, false)
        XCTAssertEqual(pane.foregroundProgram?.source, .herdr)
    }

    func testHerdrPaneInfoWithoutForegroundProcess() throws {
        let json = """
        {"pane_id":"p1","terminal_id":"t1","workspace_id":"w1","tab_id":"w1:t1","focused":false,
         "agent_status":"unknown"}
        """
        let pane = try HerdrControl.decoder.decode(HerdrControl.PaneInfo.self, from: Data(json.utf8))
        XCTAssertNil(pane.foregroundProgram)
    }
}
