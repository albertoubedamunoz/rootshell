import Foundation

// MARK: - Failure Quip Category

/// Categories for failure quips - aligned with FailureCategory for easy mapping
enum FailureQuipCategory: Sendable {
    case timeout
    case authFailed
    case hostUnreachable
    case permissionDenied
    case networkError
    case general
}

// MARK: - Failure Quips

/// Collection of witty failure quips displayed during error animations
/// Mix of self-deprecating, pop culture, and absurdist humor
struct FailureQuips {

    /// Track last quip index per category to avoid immediate repeats
    private static var lastIndices: [FailureQuipCategory: Int] = [:]

    /// Get a random quip for the specified category
    static func random(for category: FailureQuipCategory) -> String {
        let pool: [String]
        switch category {
        case .timeout:
            pool = timeoutQuips
        case .authFailed:
            pool = authQuips
        case .hostUnreachable:
            pool = unreachableQuips
        case .permissionDenied:
            pool = permissionQuips
        case .networkError:
            pool = networkQuips
        case .general:
            pool = generalQuips
        }

        return randomFromPool(pool, category: category)
    }

    /// Map FailureCategory to FailureQuipCategory
    static func category(for failureCategory: FailureCategory) -> FailureQuipCategory {
        switch failureCategory {
        case .connectionTimeout:
            return .timeout
        case .authenticationFailed:
            return .authFailed
        case .hostUnreachable:
            return .hostUnreachable
        case .hostKeyRejected:
            return .permissionDenied
        case .channelFailed, .handshakeFailed:
            return .networkError
        case .networkError:
            return .networkError
        case .general:
            return .general
        }
    }

    private static func randomFromPool(_ pool: [String], category: FailureQuipCategory) -> String {
        guard pool.count > 1 else { return pool.first ?? "Oops." }
        var newIndex: Int
        let lastIndex = lastIndices[category] ?? -1
        repeat {
            newIndex = Int.random(in: 0..<pool.count)
        } while newIndex == lastIndex
        lastIndices[category] = newIndex
        return pool[newIndex]
    }

    // MARK: - Quip Collections

    /// Timeout-specific quips
    static let timeoutQuips: [String] = [
        "Some say it's still connecting to this day",
        "Waited so long I grew a beard",
        "Time flies when you're... not connecting",
        "The server is fashionably late. Very late.",
        "Connection timed out. My patience didn't.",
        "Time is relative. This timeout felt like years.",
        "Hello? Is anybody there? ...Hello?",
        "The server went for coffee and never came back",
        "Tick tock, tick tock... TIMEOUT!",
        "Still waiting. Any century now.",

        // Expanded timeout quips
        "The server is taking its sweet time. Very sweet.",
        "Connection? More like disconnection with extra steps",
        "I've seen glaciers move faster",
        "Plot twist: the server was asleep the whole time",
        "Somewhere, a packet is having an existential crisis",
        "The internet took a detour through 1995",
        "Loading... loading... still loading...",
        "This timeout brought to you by entropy",
        "The server is buffering. Infinitely.",
        "Patience is a virtue. I'm fresh out.",
        "The connection went on a coffee break. A long one.",
        "Time waits for no one. Neither does this timeout.",
        "My watch battery died waiting for this",
        "The server is contemplating the meaning of packets",
        "Connection speed: continental drift",
        "The bits are taking the scenic route",
        "Server response time: geological",
        "I could've walked there by now",
        "The timeout has timed out",
        "Waiting intensifies... then stops",
        "The server said 'be right back' three ice ages ago",
        "Your connection is in another time zone",
        "The server went to get milk and never returned",
        "Meanwhile, in a datacenter far, far away...",
        "This is taking longer than a Windows update",
        "The connection fell asleep on the job",
        "Server: 'Just five more minutes...'",
        "The packets got lost in a time warp",
        "Connection ETA: heat death of the universe",
        "Still buffering since the last millennium"
    ]

    /// Authentication failure quips
    static let authQuips: [String] = [
        "Password? I don't know her.",
        "Your key doesn't fit this lock",
        "Access denied. The bouncer is unimpressed.",
        "Wrong password club: population you",
        "The server didn't recognize you with that disguise",
        "Authentication failed. Have you tried being someone else?",
        "Knock knock. Who's there? Not you, apparently.",
        "Your credentials were rejected by the council",
        "Identity crisis: the server doesn't know who you are",
        "Permission to board denied, captain",

        // Expanded auth quips
        "The server asked for ID and you showed a library card",
        "Your password walked into a bar. The bar said 'we don't serve your type'",
        "Authentication: 0, Server: 1",
        "The server ran your credentials through a shredder",
        "Wrong secret handshake. Try again.",
        "You're not on the list. No, the other list either.",
        "The server's password detector is tingling",
        "Credentials rejected faster than a spam email",
        "Your key tried its best. It wasn't enough.",
        "The server said 'password' but meant 'no'",
        "Authentication failed successfully... wait, no",
        "The server played 'guess who' and you lost",
        "Your login attempt has been noted. And denied.",
        "The keys don't match. Not even close.",
        "Server: 'I'm sorry, I don't recall asking you'",
        "Your credentials had one job...",
        "The server's trust issues are showing",
        "Invalid credentials: please try again never",
        "You came to the wrong server, friend",
        "The password fairy didn't visit today",
        "Authentication rejected with prejudice",
        "Your key and this lock are not speaking",
        "The server checked twice. Still no.",
        "Credentials? The server ate them",
        "Your login was DOA",
        "The server is a tough crowd",
        "Authentication: task failed successfully",
        "Password strength: not strong enough",
        "The server's having trust issues today",
        "Your credentials were lost in translation"
    ]

    /// Host unreachable quips
    static let unreachableQuips: [String] = [
        "Is it down or are you just not its type?",
        "The host has left the building",
        "No route to host. GPS is confused too.",
        "The server is hiding. Very successfully.",
        "You can't reach what doesn't want to be reached",
        "That host? Never heard of it.",
        "The server is in another castle",
        "Distance makes the heart grow fonder, and the packets lost",
        "Unreachable. Like my fitness goals.",
        "The server is on a digital sabbatical",

        // Expanded unreachable quips
        "The server ghosted you before it was cool",
        "Host not found. Have you checked under the couch?",
        "The server is playing hide and seek. It's winning.",
        "Gone fishing. Indefinitely.",
        "The server took a wrong turn at the internet",
        "Unreachable: the server's favorite status",
        "That IP address leads to nowhere. Literally.",
        "The server has entered witness protection",
        "Host status: MIA",
        "The server is off the grid. Way off.",
        "You can't connect to what doesn't exist (anymore)",
        "The server has achieved invisibility",
        "Route not found. Rerouting... still not found.",
        "The host is on permanent vacation",
        "Server location: the Bermuda Triangle of networking",
        "The packets are asking for directions",
        "This server does not exist. Or does it?",
        "Host unreachable: it's not you, it's the void",
        "The server has disconnected from reality",
        "No signal. Not even one bar.",
        "The server packed up and moved",
        "Destination: unknown. Status: unreachable.",
        "The host pulled a disappearing act",
        "Server not found in this dimension",
        "The connection was swallowed by the internet abyss",
        "Host status: presumed offline",
        "The server has left the chat. Permanently.",
        "Your packets are lost in the wilderness",
        "The server is playing dead. Convincingly.",
        "Unreachable: the server's way of saying goodbye"
    ]

    /// Permission denied quips
    static let permissionQuips: [String] = [
        "Nope. Nope. Nope.",
        "You can't sit with us - The Server",
        "Door: SLAMMED",
        "The server said 'new phone who dis'",
        "Not on the guest list, sorry",
        "Access denied. This door doesn't open for just anyone.",
        "You shall not pass! - The Firewall",
        "Entry forbidden. The server has trust issues.",
        "Rejected! Like my pull requests.",
        "The server swiped left on you",

        // Expanded permission quips
        "The server's velvet rope is up",
        "Access level: peasant",
        "The VIP section is that way. You're not going that way.",
        "Permission denied with extreme prejudice",
        "The server said no, and it meant it",
        "Forbidden fruit remains forbidden",
        "Your clearance level: none",
        "The server built a wall. A big, beautiful wall.",
        "Access? In this economy?",
        "The server's guard dog says no",
        "Your invitation got lost in the mail",
        "Entry status: blocked, denied, and rejected",
        "The server's bouncer is extra bouncy today",
        "You need a higher security clearance for that",
        "The server has a strict 'no you' policy",
        "Permission: denied with attitude",
        "The host key said 'not today'",
        "Your access request was reviewed and mocked",
        "The firewall is feeling extra protective",
        "No entry. No exceptions. No kidding.",
        "The server is in exclusive mode",
        "Your name isn't on any list",
        "Access denied: did you try asking nicely?",
        "The server's keeping this one for itself",
        "Forbidden: the server's favorite word",
        "Entry blocked by committee decision",
        "The server's door has no handle on your side",
        "Permission level: absolutely not",
        "The server drew a line. You're on the wrong side.",
        "Rejected with a capital R"
    ]

    /// Network error quips
    static let networkQuips: [String] = [
        "The server ghosted you",
        "The internet elves are on strike",
        "Your packets took a wrong turn at Albuquerque",
        "Network error: the tubes are clogged",
        "Somewhere, a router is laughing at you",
        "The bits unionized and walked out",
        "Connection lost in the void between switches",
        "The network gnomes have gone home",
        "Packets? What packets? I didn't see any packets.",
        "The connection fell into a black hole",

        // Expanded network quips
        "The network gremlins strike again",
        "Your data went on an unscheduled vacation",
        "Connection status: it's complicated",
        "The network had other plans",
        "TCP handshake left you hanging",
        "The wire has trust issues",
        "Your packets are taking a gap year",
        "Network error: blame the cosmic rays",
        "The firewall sneezed",
        "Connection interrupted by reality",
        "The network hamster needs a break",
        "Your bits got scrambled in transit",
        "The connection went poof",
        "Network status: chaotic neutral",
        "The signal got lost in the noise",
        "Your connection pulled a Houdini",
        "Network error: solar flares, probably",
        "The packets are in the mail. The slow mail.",
        "Connection stability: nonexistent",
        "The network decided to take five",
        "Your data took a scenic detour",
        "The connection was eaten by the firewall",
        "Network glitch in the matrix",
        "The ethernet fairies are sleeping",
        "Connection dropped like a hot packet",
        "The network threw a tantrum",
        "Your signal got distracted",
        "Connection error: bad vibes detected",
        "The network is having a moment",
        "Your packets are on indefinite hold"
    ]

    /// General failure quips (mix of all tones)
    static let generalQuips: [String] = [
        // Self-deprecating
        "Well, that didn't work. Shocking, I know.",
        "I had one job...",
        "This is fine. Everything is fine.",
        "404: Connection skills not found",
        "Plot twist: it was my fault all along",
        "Achievement unlocked: Failed spectacularly",
        "At least I'm consistent at failing",

        // Pop culture references
        "Houston, we have a problem",
        "That's no moon... that's a timeout",
        "I'll be back (maybe)",
        "Winter is coming, and so is another retry",
        "One does not simply SSH into Mordor",
        "The server is dead, Jim",
        "I've got a bad feeling about this",
        "Reality is often disappointing - Thanos",

        // Absurdist
        "The electrons got lost. They're asking for directions.",
        "Your packets fell into a wormhole. Sorry.",
        "The hamster powering the server took a break",
        "Connection yeeted into the void",
        "The server is contemplating existence",
        "Error: Success was too easy, so we added drama",
        "Your request was eaten by a grue",
        "The bits got distracted by a passing neutrino",

        // Technical humor
        "Have you tried turning it off and on again?",
        "It works on my machine - ships laptop",
        "Debugging: being the detective in a crime you committed",
        "Error: success (wait what)",
        "It's not a bug, it's a surprise feature",
        "Works in localhost though",
        "sudo make it work (please?)",

        // Expanded self-deprecating
        "I tried my best. My best wasn't enough.",
        "Narrator: it did not, in fact, work",
        "Professional failure in progress",
        "Task failed. Task failed again. Repeat.",
        "Error: competence not found",
        "My bad. Entirely my bad.",
        "We gave it our all. Our all was insufficient.",
        "At least we failed together",
        "I promise I usually work",
        "Oops. Oops again. Triple oops.",
        "Failed, but make it look intentional",
        "Connection skills: still loading",
        "Error: enthusiasm exceeded ability",
        "Well... that was embarrassing",
        "I blame past me for this",
        "Future me will be so disappointed",
        "Adding this to my list of failures",
        "The connection had performance anxiety",
        "We don't talk about what just happened",
        "Pretending that didn't happen in 3... 2... 1...",

        // Expanded pop culture
        "May the reconnect be with you",
        "Fly, you fools! (to another server)",
        "To infinity and... connection error",
        "What we have here is a failure to communicate",
        "I am Groot. (The connection is not.)",
        "Inconceivable! (The connection failed.)",
        "Here's looking at you, error message",
        "You're gonna need a bigger timeout",
        "E.T. phone home... connection failed",
        "Life finds a way. Connections don't always.",
        "It's a trap! - Admiral Packet",
        "Elementary, my dear Watson. It's broken.",
        "Bond. Connection bond. Shaken, not connected.",
        "I see dead connections",
        "There is no spoon. There is also no connection.",
        "So long, and thanks for all the errors",
        "We're not in localhost anymore, Toto",
        "Luke, I am your error",
        "After all this time? Always failing.",
        "The cake is a lie. So is this connection.",
        "It's dangerous to go alone! Take this error.",
        "Do or do not. There is only try/catch.",

        // Expanded absurdist
        "The server wandered off to find itself",
        "Connection status: metaphysically challenged",
        "The bytes are having an existential crisis",
        "Error: server too busy questioning reality",
        "The connection transcended to a higher plane",
        "Server went to get some space milk",
        "The packets formed a union and went on strike",
        "Connection refused for philosophical reasons",
        "The server needed time to think about things",
        "Error: caught feelings instead of packets",
        "The connection got cold feet",
        "Server is dealing with imposter syndrome",
        "The network had a quarter-life crisis",
        "Error: success paradox detected",
        "The connection is in its villain arc",
        "Server went to therapy. Didn't help.",
        "The packets got lost finding themselves",
        "Connection refused to be defined by labels",
        "The server is having a main character moment",
        "Error: irony levels exceeded",
        "The connection ghosted itself",
        "Server went full chaotic neutral",

        // Expanded technical humor
        "The connection segfaulted emotionally",
        "Error code: ¯\\_(ツ)_/¯",
        "Connection.exe has stopped responding",
        "Stack trace: disappointment all the way down",
        "Undefined is not a connection",
        "NaN: Not a Network",
        "Connection threw an exception. Then threw hands.",
        "Error: expected success, got failure",
        "The connection panicked (not the good kind)",
        "Fatal error: hope not found",
        "Connection terminated with extreme prejudice",
        "Core dumped. Mood also dumped.",
        "Return code: sadness",
        "Error handling: unhandled",
        "The connection raised a white flag",
        "Catch block caught nothing but disappointment",
        "Connection status: FUBAR",
        "The socket said 'no more'",
        "Promise rejected. So was the connection.",
        "Async failure, synchronous disappointment",
        "Connection went out of scope",
        "Garbage collected: your hopes and dreams",

        // Expanded mix
        "Better luck next time (maybe)",
        "The universe said no today",
        "Connection failed with style",
        "We regret to inform you...",
        "Plot armor didn't help",
        "The RNG was not in your favor",
        "Critical fail on connection check",
        "Natural 1 on the connection roll",
        "The dice gods are not pleased",
        "Your connection card was declined",
        "The vibes were off. Way off.",
        "Mercury must be in retrograde",
        "The stars did not align. At all.",
        "Bad juju detected in the network stack",
        "The connection read the room and left",
        "Error: bad karma detected",
        "The network spirits are displeased",
        "Your connection feng shui needs work",
        "The server's chakras are misaligned",
        "Error: cosmic interference detected"
    ]
}
