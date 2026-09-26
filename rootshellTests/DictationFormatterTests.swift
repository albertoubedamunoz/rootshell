import XCTest

final class DictationFormatterTests: XCTestCase {
    private func actions(_ style: DictationFormatter.Style, _ phrase: String,
                         commands: Bool = true, replies: Bool = true) -> [DictationAction] {
        DictationFormatter(.init(style: style, voiceCommands: commands, quickReplies: replies)).actions(for: phrase)
    }

    private func command(_ phrase: String) -> String {
        DictationFormatter(.init(style: .command)).format(phrase)
    }

    private func agent(_ phrase: String) -> String {
        DictationFormatter(.init(style: .agent)).format(phrase)
    }

    // MARK: - Command formatting

    func testCommandFormattingSpeaksShellSymbols() {
        XCTAssertEqual(command("Git commit dash m fix typo."), "git commit -m fix typo")
        XCTAssertEqual(command("LS dash dash help."), "ls --help")
        XCTAssertEqual(command("cat file dot txt pipe grep error"), "cat file.txt | grep error")
        XCTAssertEqual(command("ls star dot swift"), "ls *.swift")
        XCTAssertEqual(command("ssh user at sign host dot com"), "ssh user@host.com")
        XCTAssertEqual(command("make and and make install"), "make && make install")
    }

    func testCommandFormattingSeparatesPathsFromCommands() {
        XCTAssertEqual(command("CD slash etc slash hosts."), "cd /etc/hosts")
        XCTAssertEqual(command("cd dot dot slash projects"), "cd ../projects")
        XCTAssertEqual(command("cd tilde slash code"), "cd ~/code")
        XCTAssertEqual(command("git add dot"), "git add .")
    }

    func testSentencePunctuationDoesNotHideSpokenSymbols() {
        XCTAssertEqual(command("Git add dot."), "git add .")
        XCTAssertEqual(command("echo quote hello quote."), "echo \"hello\"")
        XCTAssertEqual(command("ls dash la, pipe grep swift."), "ls -la | grep swift")
        XCTAssertEqual(command("cat notes.txt."), "cat notes.txt")
    }

    func testCommandFormattingCaseAndQuotes() {
        XCTAssertEqual(command("Docker PS."), "docker ps")
        XCTAssertEqual(command("echo dollar home"), "echo $HOME")
        XCTAssertEqual(command("echo quote hello world quote"), "echo \"hello world\"")
        XCTAssertEqual(command("export camel case my value equals one"), "export myValue=one")
        XCTAssertEqual(command("open macOS"), "open macOS")
    }

    // MARK: - Agent formatting

    func testAgentFormattingKeepsProseAndCleansFillers() {
        XCTAssertEqual(agent("Um, so refactor the login form."), "So refactor the login form.")
        XCTAssertEqual(agent("Fix the bug. New line. Then run the tests."), "Fix the bug.\nThen run the tests.")
    }

    func testAgentFormattingSpokenCodeIdioms() {
        XCTAssertEqual(agent("Rename camel case user id for the form."), "Rename userId for the form.")
        XCTAssertEqual(agent("Use snake case user name."), "Use user_name.")
        XCTAssertEqual(agent("Rename backtick foo bar backtick please"), "Rename `foo bar` please")
        XCTAssertEqual(agent("Look at file main dot swift and fix it."), "Look at @main.swift and fix it.")
        XCTAssertEqual(agent("Check at file readme dot md"), "Check @readme.md")
        XCTAssertEqual(agent("Slash compact."), "/compact")
    }

    func testProseLeavesDashesAsWords() {
        let prose = DictationFormatter(.init(style: .prose))
        XCTAssertEqual(prose.format("Add a dash of salt."), "Add a dash of salt.")
        XCTAssertEqual(prose.format("Uh, hello there, new paragraph, next thing."), "Hello there\n\nnext thing.")
    }

    // MARK: - Commands

    func testWholeUtteranceVoiceCommands() {
        XCTAssertEqual(actions(.command, "Press enter."), [.submit])
        XCTAssertEqual(actions(.command, "Scratch that."), [.scratchThat])
        XCTAssertEqual(actions(.command, "Control C."), [.key(.control("c"))])
        XCTAssertEqual(actions(.command, "control see"), [.key(.control("c"))])
        XCTAssertEqual(actions(.command, "Escape."), [.key(.escape)])
        XCTAssertEqual(actions(.command, "git status and press enter"), [.text("git status"), .submit])
    }

    func testCommandsNeverFireInsideDictation() {
        XCTAssertEqual(actions(.agent, "Press enter to continue the tour."), [.text("Press enter to continue the tour.")])
        XCTAssertEqual(actions(.command, "Press enter.", commands: false), [.text("press enter")])
    }

    func testQuickRepliesOnlyInAgentStyle() {
        XCTAssertEqual(actions(.agent, "Two."), [.text("2")])
        XCTAssertEqual(actions(.agent, "Yes."), [.text("y")])
        XCTAssertEqual(actions(.command, "Two."), [.text("two")])
        XCTAssertEqual(actions(.agent, "Two.", replies: false), [.text("Two.")])
    }

    func testJoiningPhrases() {
        XCTAssertEqual(DictationFormatter.joining("", "b"), "b")
        XCTAssertEqual(DictationFormatter.joining("a", "b"), "a b")
        XCTAssertEqual(DictationFormatter.joining("a\n", "b"), "a\nb")
    }

    // MARK: - Vocabulary

    func testVocabularyParsing() {
        XCTAssertEqual(DictationVocabulary.parse("kubectl: cube control, cube cuddle"),
                       .init(term: "kubectl", aliases: ["cube control", "cube cuddle"]))
        XCTAssertEqual(DictationVocabulary.parse("  ssh "), .init(term: "ssh", aliases: []))
        XCTAssertNil(DictationVocabulary.parse(": alias"))
        XCTAssertEqual(DictationVocabulary.line(for: .init(term: "tmux", aliases: ["tee mux"])), "tmux: tee mux")
    }

    func testScreenTermsFindIdentifiersNotWords() {
        let screen = "error: SettingsStore.swift failed\nuser_name is undefined in main.swift near the parser"
        let terms = DictationVocabulary.screenTerms(from: screen)
        XCTAssertTrue(terms.contains(.init(term: "SettingsStore.swift", aliases: ["settings store dot swift"])))
        XCTAssertTrue(terms.contains(.init(term: "user_name", aliases: ["user name"])))
        XCTAssertTrue(terms.contains(.init(term: "main.swift", aliases: ["main dot swift"])))
        XCTAssertFalse(terms.contains { $0.term == "parser" || $0.term == "error" })
    }
}
