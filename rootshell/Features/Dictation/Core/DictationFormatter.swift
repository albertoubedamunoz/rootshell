//
//  DictationFormatter.swift
//  rootshell
//
//  Turns a recognized phrase into terminal input: shell-style symbols for
//  commands, cleaned-up prose for coding-agent prompts, and whole-utterance
//  voice commands. Pure and platform-independent so it can be unit tested.
//

import Foundation

nonisolated enum DictationKey: Equatable, Sendable {
    case escape, tab, up, down, backspace
    case control(Character)
}

nonisolated enum DictationAction: Equatable, Sendable {
    case text(String)
    /// Return, which runs a command or submits an agent prompt.
    case submit
    /// Remove the previous phrase.
    case scratchThat
    case key(DictationKey)
}

nonisolated struct DictationFormatter: Sendable {
    enum Style: Sendable { case command, prose, agent }

    struct Options: Sendable, Equatable {
        var style: Style
        var removeFillers = true
        var spokenCode = true
        var voiceCommands = false
        var quickReplies = false
    }

    let options: Options

    init(_ options: Options) { self.options = options }

    /// Actions for one phrase. Commands only match a whole utterance, or a
    /// trailing "press enter", so ordinary dictation never triggers them.
    func actions(for phrase: String) -> [DictationAction] {
        let spoken = Self.normalizedCommand(phrase)
        guard !spoken.isEmpty else { return [] }
        if options.voiceCommands, let command = Self.voiceCommand(spoken) { return [command] }
        if options.quickReplies, options.style == .agent, let reply = Self.quickReply(spoken) {
            return [.text(reply)]
        }
        if options.voiceCommands, let body = Self.strippingSubmitSuffix(phrase) {
            let text = format(body)
            return text.isEmpty ? [.submit] : [.text(text), .submit]
        }
        let text = format(phrase)
        return text.isEmpty ? [] : [.text(text)]
    }

    /// Formatting only, without command recognition.
    func format(_ phrase: String) -> String {
        var words = phrase.split(whereSeparator: \.isWhitespace).map(String.init)
        if options.removeFillers && options.style != .command { words = Self.removingFillers(words) }
        switch options.style {
        case .command:
            return Self.join(Self.commandTokens(words, spokenCode: options.spokenCode))
        case .prose:
            return Self.applyingLineBreaks(words.joined(separator: " "))
        case .agent:
            let tokens = options.spokenCode ? Self.agentTokens(words) : words.map { Token.word($0) }
            return Self.applyingLineBreaks(Self.join(tokens))
        }
    }

    /// Joins two phrases the way they were spoken.
    static func joining(_ previous: String, _ next: String) -> String {
        guard !previous.isEmpty else { return next }
        guard !next.isEmpty else { return previous }
        if previous.hasSuffix("\n") || next.hasPrefix("\n") { return previous + next }
        return previous + " " + next
    }

    // MARK: - Commands

    static func normalizedCommand(_ phrase: String) -> String {
        let scalars = phrase.lowercased().unicodeScalars.map {
            CharacterSet.punctuationCharacters.contains($0) ? " " : Character($0)
        }
        return String(scalars).split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    private static let submitPhrases: Set<String> = [
        "press enter", "enter", "press return", "return", "hit enter", "submit", "send it",
    ]

    static func voiceCommand(_ spoken: String) -> DictationAction? {
        if submitPhrases.contains(spoken) { return .submit }
        switch spoken {
        case "scratch that", "delete that", "undo that": return .scratchThat
        case "escape", "press escape", "interrupt": return .key(.escape)
        case "tab", "press tab", "complete": return .key(.tab)
        case "up arrow", "arrow up", "previous command": return .key(.up)
        case "down arrow", "arrow down", "next command": return .key(.down)
        case "backspace", "press backspace": return .key(.backspace)
        case "clear line": return .key(.control("u"))
        default: break
        }
        let words = spoken.split(separator: " ")
        if words.count == 2, words[0] == "control" || words[0] == "ctrl",
           let letter = controlLetter(String(words[1])) {
            return .key(.control(letter))
        }
        return nil
    }

    /// "control c", "control see", "control charlie".
    private static func controlLetter(_ word: String) -> Character? {
        if word.count == 1, let c = word.first, c.isLetter { return c }
        let spelled: [String: Character] = [
            "see": "c", "sea": "c", "dee": "d", "el": "l", "are": "r", "zee": "z", "zed": "z", "you": "u",
            "why": "y", "ex": "x", "bee": "b", "gee": "g", "kay": "k", "oh": "o", "pee": "p", "tee": "t",
            "charlie": "c", "delta": "d", "lima": "l", "romeo": "r", "zulu": "z", "uniform": "u", "alpha": "a",
            "echo": "e", "whiskey": "w",
        ]
        return spelled[word]
    }

    static func quickReply(_ spoken: String) -> String? {
        let numbers = ["one": "1", "two": "2", "three": "3", "four": "4", "five": "5",
                       "six": "6", "seven": "7", "eight": "8", "nine": "9"]
        if let digit = numbers[spoken] { return digit }
        if spoken.count == 1, let c = spoken.first, ("1"..."9").contains(c) { return spoken }
        switch spoken {
        case "yes", "yeah", "yep": return "y"
        case "no", "nope": return "n"
        default: return nil
        }
    }

    static func strippingSubmitSuffix(_ phrase: String) -> String? {
        let suffixes = ["and press enter", "then press enter", "press enter", "and send it", "send it", "and submit"]
        let spoken = normalizedCommand(phrase)
        guard let suffix = suffixes.first(where: { spoken.hasSuffix(" " + $0) }) else { return nil }
        // Drop the same number of words from the original phrase.
        var words = phrase.split(whereSeparator: \.isWhitespace)
        words.removeLast(min(words.count, suffix.split(separator: " ").count))
        var body = words.joined(separator: " ")
        while let last = body.last, last == "," || last == "." { body.removeLast() }
        return body
    }

    // MARK: - Fillers and line breaks

    private static let fillers: Set<String> = ["um", "uh", "uhm", "umm", "uhh", "erm", "hmm", "mm", "mhm"]

    static func removingFillers(_ words: [String]) -> [String] {
        var result: [String] = []
        var capitalizeNext = false
        for word in words {
            let core = word.lowercased().trimmingCharacters(in: .punctuationCharacters)
            if fillers.contains(core) {
                // "Um, so" keeps sentence case: "So".
                if result.isEmpty || result.last?.last.map({ ".?!".contains($0) }) == true,
                   word.first?.isUppercase == true { capitalizeNext = true }
                if let trailing = word.last, ".?!".contains(trailing), var last = result.popLast() {
                    last = last.trimmingCharacters(in: CharacterSet(charactersIn: ","))
                    result.append(last + String(trailing))
                }
                continue
            }
            var word = word
            if capitalizeNext, let first = word.first {
                word = first.uppercased() + word.dropFirst()
                capitalizeNext = false
            }
            result.append(word)
        }
        return result
    }

    static func applyingLineBreaks(_ text: String) -> String {
        var result = text
        for (spoken, replacement) in [("new paragraph", "\n\n"), ("new line", "\n"), ("newline", "\n")] {
            let pattern = ",?\\s*\\b\(spoken)\\b[,.]?\\s*"
            result = result.replacingOccurrences(of: pattern, with: replacement, options: [.regularExpression, .caseInsensitive])
        }
        return result
    }

    // MARK: - Tokens

    enum Token: Equatable {
        case word(String)
        /// Punctuation or an operator; glue removes the adjacent space.
        case symbol(String, glueLeft: Bool, glueRight: Bool)
    }

    static func join(_ tokens: [Token]) -> String {
        var out = ""
        var glueNext = true
        for token in tokens {
            switch token {
            case .word(let word):
                if !glueNext { out += " " }
                out += word
                glueNext = false
            case .symbol(let symbol, let left, let right):
                if !glueNext && !left { out += " " }
                out += symbol
                glueNext = right
            }
        }
        return out
    }

    /// `path` glues both sides except after a command word: "cd slash etc", "git add dot".
    private enum Glue { case none, left, right, both, path }

    private static let pathCommands: Set<String> = [
        "cd", "ls", "cat", "less", "more", "head", "tail", "vi", "vim", "nvim", "nano", "emacs", "hx", "code",
        "open", "rm", "cp", "mv", "mkdir", "rmdir", "touch", "source", "sudo", "chmod", "chown", "find", "grep",
        "rg", "pushd", "scp", "rsync", "tar", "du", "df", "stat", "bash", "sh", "zsh", "python", "python3",
        "node", "add", "diff", "restore", "checkout", "build", "run", "install", "init", "start",
    ]

    /// Longest phrases first; matched against lowercased, punctuation-free words.
    private static let symbols: [(words: [String], symbol: String, glue: Glue)] = [
        (["dash", "dash"], "--", .right), (["double", "dash"], "--", .right), (["minus", "minus"], "--", .right),
        (["and", "and"], "&&", .none), (["double", "ampersand"], "&&", .none),
        (["or", "or"], "||", .none), (["double", "pipe"], "||", .none),
        (["double", "greater", "than"], ">>", .none), (["greater", "than"], ">", .none),
        (["less", "than"], "<", .none), (["at", "sign"], "@", .both),
        (["dollar", "sign"], "$", .right), (["equal", "sign"], "=", .both), (["equals", "sign"], "=", .both),
        (["question", "mark"], "?", .left), (["exclamation", "mark"], "!", .left),
        (["open", "paren"], "(", .right), (["close", "paren"], ")", .left),
        (["open", "bracket"], "[", .right), (["close", "bracket"], "]", .left),
        (["open", "brace"], "{", .right), (["close", "brace"], "}", .left),
        (["dash"], "-", .right), (["hyphen"], "-", .right),
        (["dot", "dot"], "..", .path), (["dot"], ".", .path), (["slash"], "/", .path), (["backslash"], "\\", .both),
        (["tilde"], "~", .right), (["pipe"], "|", .none), (["ampersand"], "&", .none),
        (["append"], ">>", .none), (["star"], "*", .none), (["asterisk"], "*", .none),
        (["equals"], "=", .both), (["colon"], ":", .both), (["semicolon"], ";", .left),
        (["comma"], ",", .left), (["underscore"], "_", .both), (["dollar"], "$", .right),
        (["hash"], "#", .none), (["percent"], "%", .left), (["caret"], "^", .both), (["bang"], "!", .none),
    ]

    private static let caseIdioms: [(words: [String], transform: CaseTransform)] = [
        (["camel", "case"], .camel), (["pascal", "case"], .pascal), (["snake", "case"], .snake),
        (["kebab", "case"], .kebab), (["constant", "case"], .constant), (["all", "caps"], .upper),
    ]

    enum CaseTransform { case camel, pascal, snake, kebab, constant, upper }

    /// Words that end an identifier run in prose ("camel case user id for the form").
    private static let runStops: Set<String> = [
        "the", "a", "an", "for", "to", "in", "on", "of", "and", "or", "with", "from", "is", "that", "this",
        "then", "so", "but", "as", "at", "by", "into", "it", "its", "which", "when", "where", "please",
    ]

    /// A word as spoken: sentence punctuation dropped ("dot." matches "dot"),
    /// literal path characters kept ("file.txt" stays whole).
    private static func core(_ word: String) -> String {
        stripSentencePunctuation(word).lowercased()
            .trimmingCharacters(in: .punctuationCharacters.subtracting(CharacterSet(charactersIn: "-_/.~")))
    }

    private static func endsRun(_ word: String) -> Bool {
        guard let last = word.last else { return false }
        return ",.?!;:".contains(last)
    }

    private static func stripSentencePunctuation(_ word: String) -> String {
        var word = word
        while let last = word.last, ",.?!;:".contains(last) { word.removeLast() }
        while let first = word.first, "¿¡".contains(first) { word.removeFirst() }
        return word
    }

    static func applyCase(_ transform: CaseTransform, _ parts: [String]) -> String {
        let lower = parts.map { $0.lowercased() }.filter { !$0.isEmpty }
        switch transform {
        case .camel:
            guard let first = lower.first else { return "" }
            return first + lower.dropFirst().map(\.capitalized).joined()
        case .pascal: return lower.map(\.capitalized).joined()
        case .snake: return lower.joined(separator: "_")
        case .kebab: return lower.joined(separator: "-")
        case .constant: return lower.joined(separator: "_").uppercased()
        case .upper: return lower.joined(separator: " ").uppercased()
        }
    }

    private static func match(_ phrase: [String], in words: [String], at index: Int) -> Bool {
        guard index + phrase.count <= words.count else { return false }
        return zip(phrase, words[index...]).allSatisfy { $0 == core($1) }
    }

    /// Shell input: all spoken symbols, lowercase words, no sentence punctuation.
    static func commandTokens(_ words: [String], spokenCode: Bool) -> [Token] {
        var tokens: [Token] = []
        var quoteOpen: [String: Bool] = [:]
        var uppercaseNext = false
        var i = 0
        while i < words.count {
            // Quotes toggle open/closed so the pair hugs its contents.
            if let (count, mark) = quoteMark(words, at: i) {
                let open = !(quoteOpen[mark] ?? false)
                quoteOpen[mark] = open
                tokens.append(.symbol(mark, glueLeft: !open, glueRight: open))
                i += count
                continue
            }
            if spokenCode, let idiom = caseIdioms.first(where: { match($0.words, in: words, at: i) }) {
                let start = i + idiom.words.count
                let (parts, next) = identifierRun(words, from: start, stopWords: false)
                if !parts.isEmpty { tokens.append(.word(applyCase(idiom.transform, parts))) }
                i = next
                continue
            }
            if let entry = symbols.first(where: { match($0.words, in: words, at: i) }) {
                let (left, right): (Bool, Bool) = switch entry.glue {
                case .none: (false, false)
                case .left: (true, false)
                case .right: (false, true)
                case .both: (true, true)
                case .path:
                    if case .word(let previous)? = tokens.last, pathCommands.contains(previous.lowercased()) {
                        (false, true)
                    } else { (true, true) }
                }
                tokens.append(.symbol(entry.symbol, glueLeft: left, glueRight: right))
                uppercaseNext = entry.symbol == "$"
                i += entry.words.count
                continue
            }
            let word = stripSentencePunctuation(words[i])
            if !word.isEmpty {
                tokens.append(.word(uppercaseNext ? word.uppercased() : commandCase(word)))
            }
            uppercaseNext = false
            i += 1
        }
        return tokens
    }

    /// Parakeet capitalizes sentence starts and product names, and may spell
    /// short commands in caps (LS); shells want lowercase. Mixed case (macOS)
    /// and longer all-caps names (PATH) keep their case.
    private static func commandCase(_ word: String) -> String {
        let letters = word.filter(\.isLetter)
        guard letters.count > 1, let first = letters.first else { return word.lowercased() }
        let isTitle = first.isUppercase && letters.dropFirst().allSatisfy(\.isLowercase)
        let isShortCaps = letters.count <= 3 && letters.allSatisfy(\.isUppercase)
        return isTitle || isShortCaps ? word.lowercased() : word
    }

    private static func quoteMark(_ words: [String], at i: Int) -> (Int, String)? {
        if match(["single", "quote"], in: words, at: i) { return (2, "'") }
        if match(["double", "quote"], in: words, at: i) { return (2, "\"") }
        if match(["end", "quote"], in: words, at: i) || match(["close", "quote"], in: words, at: i) { return (2, "\"") }
        if match(["open", "quote"], in: words, at: i) { return (2, "\"") }
        if match(["quote"], in: words, at: i) || match(["unquote"], in: words, at: i) { return (1, "\"") }
        if match(["backtick"], in: words, at: i) || match(["back", "tick"], in: words, at: i) {
            return (match(["back", "tick"], in: words, at: i) ? 2 : 1, "`")
        }
        return nil
    }

    /// Words forming an identifier: until punctuation, a stop word (prose), or the end.
    private static func identifierRun(_ words: [String], from start: Int, stopWords: Bool) -> ([String], Int) {
        var parts: [String] = []
        var i = start
        while i < words.count {
            let word = words[i]
            if !parts.isEmpty {
                if stopWords, runStops.contains(core(word)) { break }
                // A spoken operator ends the identifier: "camel case my value equals".
                if !stopWords, symbols.contains(where: { match($0.words, in: words, at: i) }) { break }
            }
            parts.append(stripSentencePunctuation(word))
            i += 1
            if endsRun(word) { break }
        }
        return (parts, i)
    }

    /// Prompts for coding agents: keep prose, but honor explicit code idioms.
    static func agentTokens(_ words: [String]) -> [Token] {
        var tokens: [Token] = []
        var backtickOpen = false
        var i = 0
        func trailingPunctuation(_ word: String) -> Token? {
            guard let last = word.last, ",.?!;:".contains(last) else { return nil }
            return .symbol(String(last), glueLeft: true, glueRight: false)
        }
        while i < words.count {
            // "slash compact" at the start is an agent slash command.
            if i == 0, match(["slash"], in: words, at: 0), words.count >= 2 {
                let command = stripSentencePunctuation(words[1]).lowercased()
                tokens.append(.word("/" + command))
                i = 2
                continue
            }
            if match(["backtick"], in: words, at: i) || match(["back", "tick"], in: words, at: i) {
                backtickOpen.toggle()
                tokens.append(.symbol("`", glueLeft: !backtickOpen, glueRight: backtickOpen))
                if let punct = trailingPunctuation(words[i + (match(["back", "tick"], in: words, at: i) ? 1 : 0)]) {
                    tokens.append(punct)
                }
                i += match(["back", "tick"], in: words, at: i) ? 2 : 1
                continue
            }
            if let idiom = caseIdioms.first(where: { match($0.words, in: words, at: i) }) {
                let (parts, next) = identifierRun(words, from: i + idiom.words.count, stopWords: true)
                if !parts.isEmpty { tokens.append(.word(applyCase(idiom.transform, parts))) }
                if next > 0, let punct = trailingPunctuation(words[next - 1]) { tokens.append(punct) }
                i = next
                continue
            }
            // "at file main dot swift" -> @main.swift, a file mention.
            if match(["at", "file"], in: words, at: i) {
                // "Look at file x" keeps its "at": "Look at @x".
                if i > 0, ["look", "looking", "looked", "see"].contains(core(words[i - 1])) {
                    tokens.append(.word(words[i]))
                }
                let (parts, next) = identifierRun(words, from: i + 2, stopWords: true)
                let path = join(commandTokens(parts, spokenCode: false)).replacingOccurrences(of: " ", with: "")
                if !path.isEmpty { tokens.append(.word("@" + path)) }
                if next > 0, let punct = trailingPunctuation(words[next - 1]) { tokens.append(punct) }
                i = next
                continue
            }
            tokens.append(.word(words[i]))
            i += 1
        }
        return tokens
    }
}
