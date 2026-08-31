#if !targetEnvironment(macCatalyst)

import Foundation

/// On-device conformance suite for the shell interpreter, runnable via the
/// `shelltest` command. Mirrors the `wasm test` self-test pattern.
///
/// Two tiers:
/// - **Pure** cases run against a fresh `ShellEnvironment` + `ShellInterpreter`
///   with external execution stubbed out (exit 127), so they exercise only the
///   tokenizer/parser/interpreter/builtins and are fully deterministic.
/// - **External** cases (opt-in via `shelltest external`) run with the
///   session's real ios_system hooks wired in.
///
/// Cases marked `xfail` document known bugs: they report `[xfail]` while the
/// bug exists and `[XPASS]` once fixed (at which point the marker should be
/// removed). Only unexpected failures count against the suite's exit code.
nonisolated enum ShellConformanceTest {

    // MARK: - Case model

    enum Expectation {
        /// Output must match exactly (after CRLF→LF normalization).
        case exact(String)
        /// Output must contain the substring.
        case contains(String)
        /// Output must NOT contain the substring.
        case notContains(String)
    }

    enum Tier {
        case pure
        case external
    }

    struct Case {
        let id: String
        let script: String
        var stdin: [String] = []
        var expect: Expectation
        var expectedExit: Int32? = nil
        var xfail: Bool = false
        /// Non-nil = never run (e.g. would hang until a later phase lands).
        var skip: String? = nil
        var tier: Tier = .pure
    }

    /// Real ios_system hooks for the external tier.
    struct ExternalHooks {
        let executeExternal: @Sendable (String) -> Int32
        let captureExternal: @Sendable (String) -> (Int32, String)
    }

    struct Summary {
        var passed = 0
        var failed = 0
        var xfailed = 0
        var xpassed = 0
        var skipped = 0
        var aborted = false
    }

    // MARK: - Runner

    /// Per-case watchdog: a hung case is cancelled rather than wedging the suite.
    private static let caseTimeout: TimeInterval = 10

    /// Shared session identity for all pure-tier environments.
    private static let suiteSessionID = UUID()

    /// Run the suite. `emit` receives human-readable progress lines (LF endings;
    /// the caller converts for the terminal). `isCancelled` is polled between
    /// cases and inside each case so Ctrl-C aborts the suite.
    static func run(filter: String? = nil,
                    hooks: ExternalHooks? = nil,
                    isCancelled: (@Sendable () -> Bool)? = nil,
                    emit: (String) -> Void) -> Summary {
        var summary = Summary()
        let selected = cases.filter { c in
            guard filter == nil || c.id.hasPrefix(filter!) else { return false }
            return c.tier == .pure || hooks != nil
        }
        emit("shelltest: running \(selected.count) case(s)\n")

        for c in selected {
            if isCancelled?() == true {
                summary.aborted = true
                emit("shelltest: aborted\n")
                break
            }
            if let reason = c.skip {
                summary.skipped += 1
                emit("  [skip] \(c.id) — \(reason)\n")
                continue
            }

            let (passed, detail) = runCase(c, hooks: hooks, isCancelled: isCancelled)
            switch (passed, c.xfail) {
            case (true, false):
                summary.passed += 1
                emit("  [ok]   \(c.id)\n")
            case (false, true):
                summary.xfailed += 1
                emit("  [xfail] \(c.id) — known bug\n")
            case (true, true):
                summary.xpassed += 1
                emit("  [XPASS] \(c.id) — fixed! remove the xfail marker\n")
            case (false, false):
                summary.failed += 1
                emit("  [FAIL] \(c.id) — \(detail)\n")
            }
        }

        emit("\nshelltest: \(summary.passed) passed, \(summary.failed) failed, " +
             "\(summary.xfailed) xfail, \(summary.xpassed) xpass, \(summary.skipped) skipped\n")
        return summary
    }

    private static func runCase(_ c: Case,
                                hooks: ExternalHooks?,
                                isCancelled: (@Sendable () -> Bool)?) -> (Bool, String) {
        // Parse
        let tokenizer = ShellTokenizer(source: c.script)
        let parser = ShellParser(tokenizer: tokenizer)
        let ast: ShellCommand
        do {
            ast = try parser.parse()
        } catch {
            return check(c, output: "sh: \(error.localizedDescription)\n", exit: 2)
        }

        // Fresh, process-isolated environment per case. One shared session UUID
        // for the whole suite: env *reads* fall through to ios_getenv, which
        // creates an ios_system session on demand per unique key — a random
        // UUID per case would accumulate one throwaway session each.
        let environment = ShellEnvironment(sessionID: Self.suiteSessionID, allowProcessEnvWrites: false)
        environment.setPositionalParams([], scriptName: "shelltest")

        let token = CancellationToken()
        let outputLock = UnfairLock()
        // outputLock is what serializes access; the compiler can't see that.
        nonisolated(unsafe) var captured = Data()
        nonisolated(unsafe) var stdinLines = c.stdin

        let interpreter = ShellInterpreter(
            environment: environment,
            cancellationToken: token,
            executeExternal: hooks?.executeExternal ?? { @Sendable _ in 127 },
            captureExternal: hooks?.captureExternal ?? { @Sendable _ in (127, "") },
            isLocallyCancelled: { isCancelled?() ?? false },
            writeOutput: { data in
                outputLock.withLock { captured.append(data) }
            },
            readLine: { _, _ in
                outputLock.withLock {
                    stdinLines.isEmpty ? nil : stdinLines.removeFirst()
                }
            }
        )

        // Watchdog so a hung case can't wedge the suite
        DispatchQueue.global().asyncAfter(deadline: .now() + caseTimeout) { token.cancel() }

        var exitCode: Int32
        do {
            exitCode = try interpreter.execute(ast)
        } catch ShellError.exitSignal(let code) {
            exitCode = code
        } catch ShellError.cancelled {
            exitCode = 130
        } catch {
            outputLock.withLock { captured.append(Data("sh: \(error.localizedDescription)\n".utf8)) }
            exitCode = 1
        }

        let raw = outputLock.withLock { String(data: captured, encoding: .utf8) ?? "" }
        return check(c, output: raw.replacingOccurrences(of: "\r\n", with: "\n"), exit: exitCode)
    }

    private static func check(_ c: Case, output: String, exit: Int32) -> (Bool, String) {
        if let want = c.expectedExit, exit != want {
            return (false, "exit \(exit), expected \(want); output: \(preview(output))")
        }
        switch c.expect {
        case .exact(let want):
            guard output == want else {
                return (false, "output \(preview(output)), expected \(preview(want))")
            }
        case .contains(let want):
            guard output.contains(want) else {
                return (false, "output \(preview(output)) missing \(preview(want))")
            }
        case .notContains(let unwanted):
            guard !output.contains(unwanted) else {
                return (false, "output \(preview(output)) contains forbidden \(preview(unwanted))")
            }
        }
        return (true, "")
    }

    private static func preview(_ s: String) -> String {
        let visible = s
            .replacingOccurrences(of: "\n", with: "\\n")
            .replacingOccurrences(of: "\r", with: "\\r")
        return "\"\(visible.count > 80 ? visible.prefix(77) + "..." : visible)\""
    }

    // MARK: - Case table

    /// IDs are grouped: `base.*` should always pass; `p0.*`/`p1.*`/`p2.*`
    /// carry an xfail marker per known finding and flip as fixes land.
    static let cases: [Case] = [
        // --- Baseline: quoting, expansion, control flow, builtins ---
        Case(id: "base.echo",
             script: "echo hello",
             expect: .exact("hello\n"), expectedExit: 0),
        Case(id: "base.var-expansion",
             script: "x=world; echo \"hi $x\"",
             expect: .exact("hi world\n"), expectedExit: 0),
        Case(id: "base.single-quote-literal",
             script: "echo '$x literal'",
             expect: .exact("$x literal\n"), expectedExit: 0),
        Case(id: "base.double-quote-embedded-single",
             script: "echo \"a'b\"",
             expect: .exact("a'b\n"), expectedExit: 0),
        Case(id: "base.if-else",
             script: "if true; then echo yes; else echo no; fi",
             expect: .exact("yes\n"), expectedExit: 0),
        Case(id: "base.for-loop",
             script: "for i in 1 2 3; do echo $i; done",
             expect: .exact("1\n2\n3\n"), expectedExit: 0),
        Case(id: "base.while-arith",
             script: "i=0; while [ $i -lt 3 ]; do echo $i; i=$((i+1)); done",
             expect: .exact("0\n1\n2\n"), expectedExit: 0),
        Case(id: "base.until-loop",
             script: "i=0; until [ $i -ge 2 ]; do echo $i; i=$((i+1)); done",
             expect: .exact("0\n1\n"), expectedExit: 0),
        Case(id: "base.case-glob",
             script: "case abc in a*) echo match;; *) echo no;; esac",
             expect: .exact("match\n"), expectedExit: 0),
        Case(id: "base.function-args",
             script: "f() { echo \"arg:$1\"; }; f hello",
             expect: .exact("arg:hello\n"), expectedExit: 0),
        Case(id: "base.exit-status-var",
             script: "false; echo $?",
             expect: .exact("1\n"), expectedExit: 0),
        Case(id: "base.and-or",
             script: "true && echo a || echo b",
             expect: .exact("a\n"), expectedExit: 0),
        Case(id: "base.test-numeric",
             script: "[ 2 -lt 10 ] && echo ok",
             expect: .exact("ok\n"), expectedExit: 0),
        Case(id: "base.test-string",
             script: "[ \"abc\" = \"abc\" ] && echo eq",
             expect: .exact("eq\n"), expectedExit: 0),
        Case(id: "base.arithmetic-precedence",
             script: "echo $((2 + 3 * 4))",
             expect: .exact("14\n"), expectedExit: 0),
        Case(id: "base.param-default-colon",
             script: "echo ${UNSET_SHELLTEST_XYZ:-fallback}",
             expect: .exact("fallback\n"), expectedExit: 0),
        Case(id: "base.param-length",
             script: "v=hello; echo ${#v}",
             expect: .exact("5\n"), expectedExit: 0),
        Case(id: "base.brace-range-for",
             script: "for i in {1..3}; do echo $i; done",
             expect: .exact("1\n2\n3\n"), expectedExit: 0),
        Case(id: "base.continue",
             script: "for i in 1 2 3; do if [ $i = 2 ]; then continue; fi; echo $i; done",
             expect: .exact("1\n3\n"), expectedExit: 0),
        Case(id: "base.break",
             script: "for i in 1 2 3; do if [ $i = 2 ]; then break; fi; echo $i; done",
             expect: .exact("1\n"), expectedExit: 0),
        Case(id: "base.local-scoping",
             script: "x=global; f() { local x=inner; echo $x; }; f; echo $x",
             expect: .exact("inner\nglobal\n"), expectedExit: 0),
        Case(id: "base.set-positional-shift",
             script: "set -- a b c; shift; echo $1",
             expect: .exact("b\n"), expectedExit: 0),
        Case(id: "base.printf-s",
             script: "printf '%s-%s' one two",
             expect: .exact("one-two"), expectedExit: 0),
        Case(id: "base.subshell-isolation",
             script: "x=1; (x=2); echo $x",
             expect: .exact("1\n"), expectedExit: 0),
        Case(id: "base.exit-code",
             script: "exit 3",
             expect: .exact(""), expectedExit: 3),
        Case(id: "base.ifs-split-unquoted",
             script: "x=\"a b\"; for w in $x; do echo $w; done",
             expect: .exact("a\nb\n"), expectedExit: 0),
        Case(id: "base.quoted-no-split",
             script: "x=\"a b\"; for w in \"$x\"; do echo $w; done",
             expect: .exact("a b\n"), expectedExit: 0),
        Case(id: "base.brace-group",
             script: "{ echo a; echo b; }",
             expect: .exact("a\nb\n"), expectedExit: 0),
        Case(id: "base.eval",
             script: "eval \"echo evaled\"",
             expect: .exact("evaled\n"), expectedExit: 0),
        Case(id: "base.read-builtin",
             script: "read x; echo \"got:$x\"",
             stdin: ["line1"],
             expect: .exact("got:line1\n"), expectedExit: 0),
        Case(id: "base.strip-suffix-simple",
             script: "v=file.txt; echo ${v%.txt}",
             expect: .exact("file\n"), expectedExit: 0),
        Case(id: "base.strip-prefix-simple",
             script: "v=/a/b/c; echo ${v##*/}",
             expect: .exact("c\n"), expectedExit: 0),

        // --- P1 known bugs (xfail until Phase 2) ---
        Case(id: "p1.double-bracket-basic",
             script: "[[ -n hello ]] && echo yes",
             expect: .exact("yes\n"), expectedExit: 0),
        Case(id: "p1.double-bracket-pattern",
             script: "x=hello.txt; [[ $x == *.txt ]] && echo match",
             expect: .exact("match\n"), expectedExit: 0),
        Case(id: "p1.double-bracket-quoted-literal",
             script: "x=hello.txt; [[ $x == \"*.txt\" ]] || echo literal",
             expect: .exact("literal\n"), expectedExit: 0),
        Case(id: "p1.double-bracket-mixed-quote-pattern",
             script: "x=a.txt; [[ $x == *\".txt\" ]] && echo mixed",
             expect: .exact("mixed\n"), expectedExit: 0),
        Case(id: "p1.double-bracket-compound",
             script: "[[ -n a && ( -z \"\" || -n \"\" ) ]] && echo logic",
             expect: .exact("logic\n"), expectedExit: 0),
        Case(id: "p1.double-bracket-numeric",
             script: "[[ 2 -lt 10 ]] && echo num",
             expect: .exact("num\n"), expectedExit: 0),
        Case(id: "p1.double-bracket-regex",
             script: "[[ hello123 =~ ^[a-z]+[0-9]+$ ]] && echo re",
             expect: .exact("re\n"), expectedExit: 0),
        Case(id: "p1.double-bracket-negate",
             script: "[[ ! -e /definitely/not/here ]] && echo notthere",
             expect: .exact("notthere\n"), expectedExit: 0),
        Case(id: "p1.dollar-at-fields",
             script: "set -- \"a b\" c; for a in \"$@\"; do echo \"[$a]\"; done",
             expect: .exact("[a b]\n[c]\n"), expectedExit: 0),
        Case(id: "p1.dollar-at-empty",
             script: "set --; for a in \"$@\"; do echo \"[$a]\"; done; echo end",
             expect: .exact("end\n"), expectedExit: 0),
        Case(id: "p1.dollar-at-forwarding",
             script: "g() { echo \"1:[$1] 2:[$2]\"; }; f() { g \"$@\"; }; f \"a b\" c",
             expect: .exact("1:[a b] 2:[c]\n"), expectedExit: 0),
        Case(id: "p1.dollar-at-adjacent",
             script: "set -- x y; for a in \"pre$@post\"; do echo \"[$a]\"; done",
             expect: .exact("[prex]\n[ypost]\n"), expectedExit: 0),
        Case(id: "p1.dollar-at-scalar-scrub",
             script: "set -- a b; x=$@; echo \"[$x]\"",
             expect: .exact("[a b]\n"), expectedExit: 0),
        Case(id: "p1.dollar-star-quoted",
             script: "set -- a b; echo \"[$*]\"",
             expect: .exact("[a b]\n"), expectedExit: 0),
        Case(id: "p1.param-noncolon-default",
             script: "u=\"\"; echo \"x${u-fb}x\"",
             expect: .exact("xx\n"), expectedExit: 0),
        Case(id: "p1.param-substring",
             script: "v=hello; echo ${v:1:3}",
             expect: .exact("ell\n"), expectedExit: 0),
        Case(id: "p1.param-replace",
             script: "v=hello; echo ${v/l/L}",
             expect: .exact("heLlo\n"), expectedExit: 0),
        Case(id: "p1.param-replace-all",
             script: "v=hello; echo ${v//l/L}",
             expect: .exact("heLLo\n"), expectedExit: 0),
        Case(id: "p1.strip-longest-prefix-glob",
             script: "f=archive.tar.gz; echo ${f%%.*}",
             expect: .exact("archive\n"), expectedExit: 0),
        Case(id: "p1.strip-multi-wildcard",
             script: "v=abXcdXef; echo ${v#*X*X}",
             expect: .exact("ef\n"), expectedExit: 0),
        Case(id: "p1.case-literal-dash-class",
             script: "case a- in [a-]*) echo yes;; *) echo no;; esac",
             expect: .exact("yes\n"), expectedExit: 0),
        Case(id: "p1.set-e-errexit",
             script: "set -e\nfalse\necho unreachable",
             expect: .notContains("unreachable"), expectedExit: 1),
        Case(id: "p1.set-e-not-positional",
             script: "set -e; echo \"p1:[$1]\"",
             expect: .exact("p1:[]\n")),
        Case(id: "p1.set-u-nounset",
             script: "set -u; echo $UNDEFINED_SHELLTEST_ZZZ; echo after",
             expect: .notContains("after"), expectedExit: 1),
        Case(id: "p1.pipefail",
             script: "set -o pipefail; false | true; echo $?",
             expect: .exact("1\n"), expectedExit: 0),
        Case(id: "p1.printf-width",
             script: "printf '%5d' 42",
             expect: .exact("   42"), expectedExit: 0),
        Case(id: "p1.printf-float",
             script: "printf '%.2f' 3.14159",
             expect: .exact("3.14"), expectedExit: 0),

        // --- Background jobs ---
        Case(id: "p2.background-job",
             script: "true & wait; echo done",
             expect: .contains("done")),
        Case(id: "p2.background-parallel",
             script: "sleep 0 & echo now; wait; echo after",
             expect: .contains("after"), expectedExit: 0),
        Case(id: "p2.job-dollar-bang",
             script: "true & p=$!; wait; [ \"$p\" -gt 0 ] && echo pidok",
             expect: .contains("pidok")),
        Case(id: "p2.background-isolation",
             script: "x=1; { x=2; } & wait; echo \"x:$x\"",
             expect: .contains("x:1")),
        Case(id: "p2.background-cd-isolated",
             script: "before=$(pwd); cd / & wait; after=$(pwd); [ \"$before\" = \"$after\" ] && echo cwdsafe",
             expect: .contains("cwdsafe")),
        Case(id: "p2.commandsub-options-no-leak",
             script: "x=$(set -u; echo sub); echo ${UNSET_LEAK_CHECK:-fine}",
             expect: .exact("fine\n"), expectedExit: 0),
        Case(id: "p2.nounset-length",
             script: "set -u; echo ${#MISSING_NOUNSET_XYZ}; echo after",
             expect: .notContains("after"), expectedExit: 1),
        Case(id: "p2.replace-pattern-var",
             script: "p=l; v=hello; echo ${v/$p/L}",
             expect: .exact("heLlo\n"), expectedExit: 0),
        Case(id: "p2.strip-pattern-var",
             script: "p=he; v=hello; echo ${v#$p}",
             expect: .exact("llo\n"), expectedExit: 0),
        Case(id: "p2.double-bracket-var-set",
             script: "zz=1; [[ -v zz ]] && echo isset; [[ -v NOPE_UNSET_ZZ ]] || echo unset",
             expect: .exact("isset\nunset\n"), expectedExit: 0),
        Case(id: "p2.double-bracket-option",
             script: "set -u; [[ -o nounset ]] && echo opt",
             expect: .exact("opt\n"), expectedExit: 0),
        Case(id: "p2.double-bracket-tty",
             script: "[[ -t 1 ]] && echo tty",
             expect: .exact("tty\n"), expectedExit: 0),
        Case(id: "p2.replace-quoted-pattern",
             script: "v=hello; echo ${v/\"l\"/L}",
             expect: .exact("heLlo\n"), expectedExit: 0),
        Case(id: "p2.replace-quoted-var-literal",
             script: "p='*'; v='a*b'; echo ${v/\"$p\"/X}",
             expect: .exact("aXb\n"), expectedExit: 0),
        Case(id: "p2.replace-unquoted-var-glob",
             script: "p='*'; v=abc; echo ${v/$p/X}",
             expect: .exact("X\n"), expectedExit: 0),
        Case(id: "p2.replace-quoted-slash",
             script: "v=xa/by; echo ${v/\"a/b\"/Z}",
             expect: .exact("xZy\n"), expectedExit: 0),

        // --- P2 known gaps (xfail until Phase 3) ---
        Case(id: "p2.arith-command-incr",
             script: "i=1; ((i++)); echo $i",
             expect: .exact("2\n"), expectedExit: 0),
        Case(id: "p2.brace-in-command-words",
             script: "echo {a,b}",
             expect: .exact("a b\n"), expectedExit: 0),
        Case(id: "p2.echo-hex-escape",
             script: "echo -e 'A\\x42C'",
             expect: .exact("ABC\n"), expectedExit: 0),
        Case(id: "p2.echo-octal-escape",
             script: "echo -e 'A\\0102C'",
             expect: .exact("ABC\n"), expectedExit: 0),

        // --- External tier (needs ios_system; `shelltest external`) ---
        Case(id: "ext.capture-basic",
             script: "x=$(ls /); echo \"len:${#x}\"",
             expect: .contains("len:"), expectedExit: 0, tier: .external),
        Case(id: "ext.script-exit-code",
             script: "ls /definitely_not_here_shelltest_12345; echo \"rc:$?\"",
             expect: .contains("rc:"), tier: .external),
        Case(id: "ext.capture-large",
             script: "x=$(awk 'BEGIN{for(i=0;i<9000;i++)print \"0123456789\"}'); echo ${#x}",
             expect: .contains("9899"),
             expectedExit: 0,
             tier: .external),
        Case(id: "ext.background-assignment-env",
             script: "FOO_BGTEST=xyz123 env & wait",
             expect: .contains("xyz123"),
             tier: .external),
        Case(id: "git-pipeline.clone-stdout-clean",
             script: "d=$(mktemp -d); git init \"$d/src\" >/dev/null; git -C \"$d/src\" config user.name shelltest; git -C \"$d/src\" config user.email shelltest@example.invalid; echo seed >\"$d/src/seed\"; git -C \"$d/src\" add seed; git -C \"$d/src\" commit -m seed >/dev/null; n=$(git clone --progress \"$d/src\" \"$d/dst\" | wc -c); rm -rf \"$d\"; echo \"$n\"",
             expect: .exact("0\n"),
             expectedExit: 0,
             tier: .external),
        Case(id: "git-pipeline.quiet-stderr-clean",
             script: "d=$(mktemp -d); git init \"$d/src\" >/dev/null; git clone -q \"$d/src\" \"$d/dst\" 2>\"$d/status\"; n=$(wc -c <\"$d/status\"); rm -rf \"$d\"; echo \"$n\"",
             expect: .exact("0\n"),
             expectedExit: 0,
             tier: .external),
        Case(id: "git-pipeline.auth-error-stderr",
             script: "git --password clone /definitely/not/a/repository | wc -c",
             expect: .exact("0\n"),
             expectedExit: 0,
             tier: .external),
    ]
}

#endif
