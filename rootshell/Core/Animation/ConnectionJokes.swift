import Foundation

/// Categories for connection jokes - determines which joke pool to use
enum ConnectionJokeCategory: Sendable {
    case general      // Developer, terminal, command-line jokes
    case ssh          // SSH-specific jokes (includes general)
    case kubernetes   // Kubernetes/container jokes (includes general)
}

/// Central repository of 1,000 developer/terminal/SSH/Kubernetes one-liner jokes
/// Used by SpinnerAnimator to add whimsy to connection status messages
struct ConnectionJokes {

    /// Track last joke index to avoid immediate repeats
    private static var lastGeneralIndex: Int = -1
    private static var lastSSHIndex: Int = -1
    private static var lastK8sIndex: Int = -1

    /// Get a random joke for the specified category
    /// SSH category draws from SSH + general pool
    /// Kubernetes category draws from K8s + general pool
    static func random(for category: ConnectionJokeCategory) -> String {
        switch category {
        case .general:
            return randomFromPool(general, lastIndex: &lastGeneralIndex)
        case .ssh:
            // 40% chance SSH-specific, 60% general
            if Int.random(in: 0..<10) < 4 {
                return randomFromPool(ssh, lastIndex: &lastSSHIndex)
            } else {
                return randomFromPool(general, lastIndex: &lastGeneralIndex)
            }
        case .kubernetes:
            // 40% chance K8s-specific, 60% general
            if Int.random(in: 0..<10) < 4 {
                return randomFromPool(kubernetes, lastIndex: &lastK8sIndex)
            } else {
                return randomFromPool(general, lastIndex: &lastGeneralIndex)
            }
        }
    }

    private static func randomFromPool(_ pool: [String], lastIndex: inout Int) -> String {
        guard pool.count > 1 else { return pool.first ?? "" }
        var newIndex: Int
        repeat {
            newIndex = Int.random(in: 0..<pool.count)
        } while newIndex == lastIndex
        lastIndex = newIndex
        return pool[newIndex]
    }

    // MARK: - General Developer/Terminal/CLI Jokes (~600)

    static let general: [String] = [
        // Classic programming humor
        "There's no place like 127.0.0.1",
        "I'd tell you a UDP joke, but you might not get it",
        "Why do programmers prefer dark mode? Light attracts bugs",
        "A SQL query walks into a bar, joins two tables",
        "My code doesn't have bugs, it has undocumented features",
        "I'm not lazy, I'm in power-saving mode",
        "There are 10 types of people: those who understand binary",
        "!false - it's funny because it's true",
        "I would make a regex joke but .*",
        "while(alive) { eat(); sleep(); code(); }",

        // Terminal/CLI jokes
        "Have you tried turning it off and on again?",
        "sudo make me a sandwich",
        "chmod 777: trust issues",
        "rm -rf /: the ultimate weight loss program",
        "In case of fire: git commit, git push, leave building",
        "404: joke not found",
        "It works on my machine - ships laptop",
        "The cloud is just someone else's computer",
        "Debugging: being the detective in a crime you committed",
        "99 bugs in the code, take one down, patch it around, 127 bugs in the code",

        // Developer life
        "Coffee: because sleep is for the weak",
        "Programmer: a machine that turns coffee into code",
        "It's not a bug, it's a feature request",
        "Will code for coffee",
        "Works on my machine certification",
        "Documentation? We don't do that here",
        "Coding: 10% writing, 90% figuring out why it doesn't work",
        "I don't always test my code, but when I do, I do it in production",
        "First rule of debugging: it's always your fault",
        "Sleep is optional, caffeine is mandatory",

        // Version control
        "Git happens",
        "I git you",
        "May the --force be with you",
        "git commit -m 'fixed stuff'",
        "git blame: pointing fingers since 2005",
        "Merge conflicts are just code having a disagreement",
        "Every git push is a leap of faith",
        "Rebasing: history is written by the victors",
        "git stash: out of sight, out of mind",
        "That awkward moment when git log is your diary",

        // Networking
        "TCP: I'd like to tell you a joke. OK. Hear joke? Yes. OK sending joke",
        "There's no place like ::1",
        "ping: the original 'are you there?'",
        "Home is where the WiFi connects automatically",
        "I like my servers like I like my humor - always up",
        "Packets: little envelopes of disappointment",
        "DNS: It's always DNS",
        "If at first you don't succeed, check the firewall",
        "HTTP 500: Server had a bad day",
        "HTTP 418: I'm a teapot, don't @ me",

        // Programming languages
        "Python: where indentation is a lifestyle choice",
        "JavaScript: where == is a suggestion",
        "C++: because pain builds character",
        "Java: write once, debug everywhere",
        "Rust: fighting the borrow checker since 2010",
        "Go: because simplicity is complicated",
        "PHP: please help programming",
        "Assembly: for when you really hate yourself",
        "COBOL: still paying the bills since 1959",
        "Perl: line noise that actually works",

        // Debugging
        "printf('here')... printf('here2')... printf('why')...",
        "console.log is my best friend",
        "The bug is between the chair and keyboard",
        "If debugging is removing bugs, programming is adding them",
        "Debugging tip: have you tried printf?",
        "Error: success (wait what)",
        "Segfault: unexpected journey to core dump land",
        "Stack overflow: when recursion recurses too recursively",
        "Null pointer: pointing at nothing, breaking everything",
        "Race condition: Schrödinger's bug",

        // Data structures
        "Arrays start at 0... fight me",
        "LinkedList walks into a bar, points at the next customer",
        "Binary trees: always left hanging",
        "Hash tables: O(1) on a good day",
        "Recursion: see recursion",
        "To understand recursion, you must first understand recursion",
        "Queue: first come, first served anxiety",
        "Stack: LIFO the party",
        "Graph theory: it's all connected",
        "Big O: how to measure slowness academically",

        // Development workflow
        "Works on localhost",
        "Pushing to main on a Friday... bold move",
        "Code review: let me tell you why you're wrong",
        "Sprint planning: fiction writing workshop",
        "Stand-up: where 15 minutes becomes an hour",
        "Technical debt: procrastination with interest",
        "Refactoring: playing with working code",
        "Legacy code: other people's problems, now yours",
        "Microservices: distributed monolith with extra steps",
        "Agile: doing half the work in twice the meetings",

        // More classic one-liners
        "0 is false, 1 is true, 2 is tuesday apparently",
        "undefined is not a function (of my patience)",
        "Segmentation fault (core dumped)... dumping motivation",
        "Warning: this code is held together by hopes and prayers",
        "TODO: fix this later (6 years ago)",
        "// I have no idea why this works",
        "// Magic. Do not touch",
        "// Here be dragons",
        "// I'm sorry",
        "// Future me, please forgive past me",

        // Sysadmin humor
        "Have you tried rebooting?",
        "Uptime: 1000 days... time to reboot",
        "Cron: because you'll forget otherwise",
        "systemd: init's ambitious cousin",
        "iptables: friendship ended with firewall",
        "Logs: the autobiography nobody reads",
        "Disk full: surprise! It's always disk full",
        "Memory leak: slowly eating your RAM since forever",
        "CPU 100%: the warm glow of productivity",
        "Swap: when RAM goes on vacation",

        // More terminal fun
        "cat /dev/null > problems",
        ":(){ :|:& };: (don't run this)",
        "alias please='sudo'",
        "echo $PATH to enlightenment",
        "grep -r 'my will to live' /dev/null",
        "ls -la | grep hope",
        "find . -name 'bugs' -delete (if only)",
        "tail -f /var/log/everything_is_fine",
        "yes | head -1 (the optimist)",

        // Hardware jokes
        "There's no place like ~",
        "My other car is a VM",
        "I think, therefore I RAM",
        "You're one in a billion... like my CPU cycles",
        "Core dumped? More like emotionally dumped",
        "SSD: Suddenly Storing Data",
        "Cache me outside, how bout dat",
        "Bits: the atoms of the digital universe",
        "Clock speed: how fast you can mess things up",
        "GPU: for when your CPU needs backup",

        // Security jokes
        "Password: ********... wait that's hunter2",
        "Security through obscurity: hope as a strategy",
        "2FA: because passwords are hard",
        "Firewall: the bouncer of the network club",
        "Encryption: digital envelope, nuclear padlock",
        "CVE: Collect Vulnerabilities Everywhere",
        "Zero-day: surprise!",
        "Pentest: professional breaking and entering",
        "Social engineering: hacking humans since forever",
        "Root access: unlimited power, unlimited responsibility",

        // Database humor
        "SQL: Structured Querying Life",
        "NoSQL: No Sleep Quite Likely",
        "MongoDB: where schemas are optional and points don't matter",
        "PostgreSQL: the grown-up database",
        "MySQL: the people's champion",
        "Redis: RAM? What RAM?",
        "Elasticsearch: finding needles in haystacks",
        "DROP TABLE students; -- the classic",
        "SELECT * FROM life WHERE happiness = true",
        "INSERT INTO weekend VALUES ('sleep')",

        // API jokes
        "REST in peace, SOAP",
        "GraphQL: ask for exactly what you want, get exactly nothing",
        "API rate limit exceeded: slow down there cowboy",
        "Webhook: callbacks for the cloud age",
        "JSON: curly braces and comma anxiety",
        "XML: the verbose one",
        "HTTP 204: success, but I have nothing to say",
        "HTTP 301: I've moved on",
        "HTTP 503: taking a mental health day",
        "HTTP 429: too many requests, too little patience",

        // DevOps
        "Infrastructure as Code: poetry for servers",
        "CI/CD: continuous integration of bugs",
        "Docker: works in a container, fails in production",
        "The pipeline is green, I repeat, green",
        "Blue/green deployment: gambling with colors",
        "Canary deployment: tweet tweet, something's wrong",
        "Rollback: the undo button you always need",
        "Terraform: infrastructure, some assembly required",
        "Ansible: playbooks for the datacenter theater",
        "Jenkins: still building character since 2011",

        // Monitoring
        "Monitoring: anxiety, but make it professional",
        "Alerting: 3am wake-up calls from computers",
        "Dashboard green: everything is fine (probably)",
        "Dashboard red: time to panic professionally",
        "Metrics: numbers that make charts go brrr",
        "Logs: detective novels for nerds",
        "Tracing: following the breadcrumbs home",
        "SLA: Sleep Loss Agreement",
        "Incident response: organized chaos",
        "Postmortem: learning from disasters, theoretically",

        // Cloud humor
        "Serverless: there's still a server, just not yours",
        "Lambda: functions as a service, bills as a surprise",
        "S3: where files go to live forever",
        "EC2: renting computers with extra steps",
        "Auto-scaling: surprise cloud bills",
        "Multi-region: because one failure isn't enough",
        "Cloud-native: everything is someone else's problem",
        "IaaS, PaaS, SaaS: as a Service as a Service",
        "Cloud migration: moving problems to the cloud",
        "On-prem: the cloud at home",

        // Testing
        "Unit tests: optimism in code form",
        "Integration tests: trust issues, formalized",
        "E2E tests: suffering, but automated",
        "TDD: test the errors first",
        "Coverage 100%: lies, all lies",
        "QA found nothing: time to be worried",
        "Works in staging, fails in prod: classic",
        "Flaky test: Schrödinger's assertion",
        "Mocking: pretending things work",
        "Test data: lorem ipsum of databases",

        // More developer wit
        "Estimating: professional guessing",
        "Deadline: line that marks the end of sanity",
        "Scope creep: the monster under the project",
        "Feature freeze: winter is coming",
        "Hotfix: cold sweat in code form",
        "Production bug: surprise vacation killer",
        "On-call: never truly free",
        "PagerDuty: the 3am alarm clock",
        "Runbook: instructions for panicking efficiently",
        "Escalation: passing the panic upward",

        // Vim/Editor wars
        "I use vim btw",
        ":wq (how to exit vim for the 100th time)",
        "Vim: still trying to exit since 1991",
        "Emacs: the operating system with a decent editor",
        "Nano: vim for the humble",
        "VSCode: when Electron is life",
        "IDE: I Don't Edit, I debug",
        "My editor is better than yours",
        "Tabs vs spaces: the eternal war",
        "Dark theme: where code goes to hide",

        // Open source
        "Free as in beer, complex as in tax law",
        "OSS: other people's bugs, now community bugs",
        "GitHub stars: the currency of validation",
        "PR merged: dopamine delivered",
        "Issues: the todo list from strangers",
        "Fork: copy, paste, chaos",
        "Upstream: where the truth flows from",
        "Maintainer: unpaid therapist for software",
        "Contributor: hero without a cape",
        "Dependabot: the nagging reminder",

        // AI/ML jokes
        "AI: artificial intelligence or artificial issues?",
        "Machine learning: statistics with better marketing",
        "Neural network: math cosplaying as a brain",
        "Training data: garbage in, garbage out",
        "Overfitting: memorizing instead of learning",
        "GPU: graphics cards with identity crisis",
        "Tensor: fancy array",
        "Model deployed: crossing fingers intensifies",
        "ChatGPT: the intern that never sleeps",
        "Prompt engineering: professional begging",

        // Containers & virtualization
        "VM: computer inception",
        "Hypervisor: the landlord of virtual real estate",
        "Container: lightweight VM (don't @ me)",
        "Image: container's baby photo",
        "Volume: persistent storage, supposedly",
        "Layer: onions of your container",
        "Registry: container photo album",
        "Orchestration: container herding",
        "Sidecar: the container's sidekick",
        "Init container: the container's breakfast",

        // Networking part 2
        "VPN: pretending to be somewhere else",
        "NAT: networking's awkward translator",
        "DHCP: automatic IP assignment magic",
        "Load balancer: traffic controller",
        "CDN: files, but closer",
        "Latency: the speed of waiting",
        "Bandwidth: the width of your internet",
        "BGP: hold my beer and watch this route",
        "CORS: cross-origin resource suffering",
        "SSL/TLS: the padlock people ignore",

        // Time zones
        "Time zones: the final boss of programming",
        "UTC: the one true time",
        "Daylight saving: twice-yearly debugging",
        "Epoch: measuring time since the 70s",
        "NTP: keeping clocks honest",
        "Timestamp: moments frozen in milliseconds",
        "Date parsing: entering the danger zone",
        "ISO 8601: the correct date format",
        "Leap second: time's little surprise",
        "Time drift: when servers disagree on now",

        // Unicode & encoding
        "UTF-8: encoding done right",
        "Mojibake: when encoding goes wrong",
        "BOM: byte order marks of confusion",
        "Encoding: where characters go to die",
        "ASCII: the 7-bit good old days",
        "Emoji: unicode's colorful hobby",
        "Zero-width space: the invisible troublemaker",
        "Right-to-left: text's plot twist",
        "Normalization: making unicode behave",
        "Code points: unicode's address book",

        // Build systems
        "Make: building things since 1976",
        "CMake: make, but make it confusing",
        "Gradle: build tool or space heater?",
        "Webpack: bundle of joy and confusion",
        "npm install: one command, 500MB node_modules",
        "Dependencies: everyone's problem",
        "Build failed: the classics never die",
        "Compile time: coffee break excuse",
        "Link error: the compiler's revenge",
        "Build cache: sometimes it helps, sometimes",

        // Concurrency
        "Thread: code doing parallel panic",
        "Mutex: one at a time, please",
        "Deadlock: circular waiting, eternal waiting",
        "Race condition: may the fastest code win",
        "Async/await: patience in syntax form",
        "Callback hell: indentation into the abyss",
        "Promise: I'll get back to you",
        "Future: like a promise, but Java",
        "Goroutine: concurrency made friendly",
        "Event loop: spinning forever, handling everything",

        // Math in programming
        "Floating point: approximately wrong",
        "Integer overflow: when 2B+1 = -2B",
        "Off by one: the classic mistake",
        "NaN: not a number, still a problem",
        "Infinity: bigger than your integer",
        "Modulo: the remainder of the day",
        "Bitwise: ones and zeros having fun",
        "Boolean: true or false, pick one",
        "Division by zero: undefined behavior incoming",
        "Random: not as random as you think",

        // More programming wisdom
        "Premature optimization: the root of all evil",
        "YAGNI: You Aren't Gonna Need It (but you'll add it anyway)",
        "DRY: Don't Repeat Yourself (repeat after me)",
        "KISS: Keep It Simple, Silly",
        "RTFM: reading is fundamental",
        "LGTM: looks good to merge (didn't read)",
        "WIP: work in panic",
        "TL;DR: too long, didn't review",
        "PEBCAK: problem exists between chair and keyboard",
        "YOLO: you only live once (push to prod)",

        // Web development
        "CSS: cascading stress sheets",
        "HTML: hyperthinking markup language",
        "JavaScript: the good parts fit on a postcard",
        "React: components all the way down",
        "Vue: the friendly framework",
        "Angular: enterprise complexity achieved",
        "Svelte: compiled away my problems",
        "Tailwind: CSS, but more classes",
        "Bootstrap: grid system for the lazy",
        "npm: node package mayhem",

        // More random humor
        "Spaghetti code: pasta that hurts",
        "Technical interview: solving puzzles under pressure",
        "Whiteboard: where algorithms go to die",
        "Leetcode: gym for the brain",
        "Imposter syndrome: we all have it",
        "Rubber duck debugging: quack quack",
        "Senior developer: professional googler",
        "10x developer: myth or mythical?",
        "Rockstar developer: rock bottom, star expectations",
        "Ninja developer: invisible until something breaks",

        // Wisdom and philosophy
        "Everything is a file... especially your mistakes",
        "Keep calm and clear cache",
        "In code we trust",
        "May your builds be ever green",
        "Live, laugh, lint",
        "Born to code, forced to debug",
        "Speak softly and carry a big log file",
        "The best code is no code",
        "Simplicity is the ultimate sophistication",
        "Make it work, make it right, make it fast",

        // Self-deprecating
        "I pretend to know what I'm doing",
        "Faking it until making it",
        "Learning in public (panicking in private)",
        "Professional copy-paster",
        "Stack Overflow engineer",
        "Google-driven development",
        "Tutorial survivor",
        "Hello World specialist",
        "CRUD enthusiast",
        "Bug creator extraordinaire",

        // Pop culture references
        "Use the source, Luke",
        "One does not simply deploy to production",
        "This is the way (to production)",
        "I am root",
        "My code is strong with this one",
        "Winter is coming (feature freeze)",
        "You shall not pass (code review)",
        "Perfectly balanced, as all services should be",
        "Reality is often disappointing (like prod)",
        "I am inevitable (like tech debt)",

        // Short observations
        "It's not stupid if it works",
        "If it ain't broke, don't refactor it",
        "The real bug was the friends we made",
        "There's no place like production",
        "sudo problems, sudo solutions",
        "Life is short, code is shorter",
        "Trust the process (ctrl+c)",
        "Hope is not a strategy (but here we are)",
        "Past me is a jerk",
        "Future me can deal with this",

        // Misc tech humor
        "Bluetooth: spooky action at close distance",
        "USB: Universal Serial Bother",
        "WiFi: wireless fidelity, wireless anxiety",
        "Ethernet: the original social network",
        "Keyboard: the instrument of creation",
        "Mouse: point and click adventure",
        "Monitor: the window to your code",
        "Laptop: portable heater that codes",
        "Smartphone: tiny computer, big distraction",
        "Printer: PC LOAD LETTER",

        // Startup culture
        "Move fast and break things (preferably not prod)",
        "Disrupting disruption",
        "Synergy: the word that means nothing",
        "Pivot: we changed everything",
        "MVP: minimum viable patience",
        "Product-market fit: still searching",
        "Growth hacking: marketing with extra steps",
        "Scale: someday, maybe",
        "Runway: time until panic",
        "Series A: money, but with conditions",

        // Remote work
        "You're on mute",
        "Can you see my screen?",
        "Working from home, pants optional",
        "Async communication: delayed confusion",
        "Zoom fatigue: real and documented",
        "Slack: where context goes to die",
        "Calendar Tetris: the daily puzzle",
        "Time zone juggling: professional sport",
        "Virtual background: hiding the chaos",
        "BRB (be right back, in spirit)",

        // Existential
        "All models are wrong, some are useful",
        "The only constant is change (and bugs)",
        "Nothing is permanent except temporary solutions",
        "We're all just functions with side effects",
        "Life: undefined behavior",
        "Time heals all bugs (not really)",
        "In the beginning, there was main()",
        "And on the 7th day, dev rested (lie)",
        "From /dev/null we came, to /dev/null we return",
        "The code is temporary, the bugs are eternal",

        // More quick hits
        "git gud",
        "Keep calm and npm install",
        "DevOps: dev and ops, united in suffering",
        "SRE: reliability is someone's job",
        "Platform team: building for builders",
        "Monolith: the original microservice",
        "Majestic monolith: monolith, but proud",
        "Event-driven: things happen, we react",
        "Message queue: patience in infrastructure",
        "Pub/sub: radio for computers",

        // More sysadmin
        "du -sh /*: where did all the space go?",
        "top: watching processes work",
        "htop: watching processes work, in color",
        "netstat: socket detective",
        "iostat: disk detective",
        "vmstat: memory detective",
        "strace: system call stalker",
        "lsof: file handle hoarder detector",
        "tcpdump: packet paparazzi",
        "wireshark: tcpdump in a tuxedo",

        // Last batch of general
        "The internet is a series of tubes",
        "Cables: the veins of the internet",
        "Datacenter: where the cloud lives",
        "Server room: where winter is always",
        "Rack: server apartment complex",
        "PDU: power distribution unit(ed concerns)",
        "UPS: keeping the lights on",
        "Failover: plan B for when plan A fails",
        "Redundancy: saying the same thing twice",
        "High availability: uptime is just a number",

        // Final set
        "RTMP: real time messing protocol",
        "WebSocket: HTTP's talkative cousin",
        "gRPC: HTTP/2 with protobuf personality",
        "MQTT: IoT's tiny messenger",
        "SSE: server sent events (you're welcome)",
        "Long polling: impatient waiting",
        "Webhook: callback, but HTTP",
        "Caching: trading freshness for speed",
        "TTL: time to live, time to forget",
        "Invalidation: the hardest problem"
    ]

    // MARK: - SSH-Specific Jokes (~200)

    static let ssh: [String] = [
        // SSH basics
        "Home is where the SSH connection is",
        "Keep calm and SSH on",
        "Port 22: where all the cool kids hang out",
        "RSA: Really Secure Apparently",
        "I SSH therefore I am... root",
        "Tunneling my way to freedom",
        "Public key? I barely know key!",
        "Another day, another SSH session",
        "Warning: you are now leaving the local network",
        "Keys? Where we're going, we need exactly 4096 bits",

        // Connection humor
        "Connecting: hold my beer",
        "Handshake initiated: firm grip",
        "Establishing secure channel: *spy music*",
        "Connection attempt #1... of many",
        "Authenticating: prove you're you",
        "Key exchange: trading secrets",
        "The server will be with you shortly",
        "Your call is important to us, please hold",
        "Initiating secret handshake",
        "Knocking on port 22",

        // Authentication jokes
        "Permission denied: story of my life",
        "Too many authentication failures (oops)",
        "Passphrase: because passwords aren't enough",
        "ssh-agent: remembering so you don't have to",
        "Key not found: check under the keyboard",
        "Invalid key format: I feel personally attacked",
        "Host key verification: trust issues",
        "Known hosts: your server friends list",
        "Fingerprint accepted: no ink required",
        "Identity file: telling servers who you are",

        // Remote shell life
        "Remote terminal: telepathy for computers",
        "You are now entering the remote zone",
        "Welcome to someone else's computer",
        "Sudo rights on a remote machine: ultimate power",
        "Shell access granted: unlimited cosmic power",
        "Remote session: working from really far away",
        "Terminal emulation: faking it perfectly",
        "SSH: because telnet was too honest",
        "Encrypted connection: secrets between friends",
        "Remote execution: runs on someone else's dime",

        // Jump hosts
        "Jump host: the middleman of connections",
        "ProxyJump: leapfrogging through servers",
        "Bastion: the castle guard of networks",
        "Gateway: the bouncer of the server club",
        "Hop skip jump to your destination",
        "Multi-hop: the scenic route to your server",
        "Tunnel within a tunnel: Inception vibes",
        "Forwarding your call: please hold",
        "The middleman has joined the chat",
        "Proxy: I'm not touching you (technically)",

        // SSH config
        "~/.ssh/config: the real magic",
        "Host *: global settings for the brave",
        "IdentitiesOnly yes: one key at a time please",
        "StrictHostKeyChecking no: living dangerously",
        "ServerAliveInterval: I'm still here!",
        "ControlMaster: sharing is caring",
        "ForwardAgent: your keys travel with you",
        "Compression yes: squeezing through the wire",
        "TCPKeepAlive: keeping the dream alive",
        "Timeout: patience has limits",

        // Key management
        "ssh-keygen: making keys since forever",
        "Ed25519: the new hotness in keys",
        "RSA 4096: go big or go home",
        "ECDSA: curves are in",
        "Private key: keep it secret, keep it safe",
        "Public key: share with the world",
        "Authorized_keys: the VIP list",
        "ssh-copy-id: key delivery service",
        "Key rotation: musical chairs for security",
        "Revoked key: you're not on the list anymore",

        // Port forwarding
        "Local forward: bringing remote ports home",
        "Remote forward: sending local ports abroad",
        "Dynamic forward: SOCKS it to me",
        "Port 8080: the forwarding favorite",
        "Tunnel vision: seeing only the target",
        "-L: left turn at the firewall",
        "-R: reverse psychology networking",
        "-D: dynamic adventures in proxying",
        "SOCKS5: the fancy proxy",
        "Port in a storm: finding shelter in forwarding",

        // SSH agents
        "ssh-agent: your key ring on steroids",
        "SSH_AUTH_SOCK: the magic socket",
        "Agent forwarding: keys on vacation",
        "ssh-add: feeding the agent",
        "Agent lifetime: keys have expiration dates",
        "Keychain: macOS's gift to SSH",
        "Pageant: Windows joins the party",
        "Identity loaded: ready for action",
        "Agent running: keys on standby",
        "No identities: where did my keys go?",

        // SCP/SFTP
        "scp: copy pasta, but encrypted",
        "sftp: FTP's secure younger sibling",
        "rsync over SSH: the professional's choice",
        "File transfer: moving bits securely",
        "Recursive copy: it's turtles all the way down",
        "Preserve permissions: keep it authentic",
        "Progress bar: the anxiety meter",
        "Bandwidth limit: slow and steady",
        "Resume transfer: second chances exist",
        "Checksum: trust but verify",

        // Humor about remote work
        "Remote access: working without pants since 1995",
        "VPN? Just SSH to the jump box",
        "Network segregation: divide and secure",
        "Firewall friendly: slipping through the cracks",
        "Outbound only: one-way ticket",
        "Inbound blocked: no unsolicited connections",
        "NAT traversal: finding a way",
        "Reverse tunnel: the Uno reverse card of networking",
        "Mosh: SSH for the unreliable",
        "Persistent connection: till death do us disconnect",

        // Security
        "Root login: disabled for your protection",
        "Password authentication: no thanks, have keys",
        "Fail2ban: three strikes, you're banned",
        "Port knocking: the secret handshake",
        "Two-factor: because one factor isn't enough",
        "Certificate auth: fancy key validation",
        "Key pinning: trust no one new",
        "Host key changed: something fishy here",
        "MITM: not on my watch",
        "Perfect forward secrecy: what happens here stays here",

        // SSH tips and tricks
        "ControlPath: one connection to rule them all",
        "Multiplexing: efficiency is beautiful",
        "Escape sequence: ~. to freedom",
        "~?: the help nobody reads",
        "~#: list forwarded connections",
        "~C: command line on demand",
        "Background session: ssh -f and forget",
        "X11 forwarding: GUIs from afar",
        "Agent forwarding: bring your keys along",
        "Pseudo-terminal: faking it till making it",

        // Remote system administration
        "Remote reboot: the leap of faith",
        "Connection lost: was it something I said?",
        "Broken pipe: flow interrupted",
        "Write failed: message not delivered",
        "Reset by peer: ghosted by server",
        "Connection refused: rejection hurts",
        "Network unreachable: too far to reach",
        "Host down: taking a nap",
        "Connection timed out: patience tested",
        "Remote host closed connection: bye!",

        // Fun with SSH
        "SSH to localhost: talking to yourself",
        "SSH chain: server hopping adventures",
        "Nested SSH: yo dawg, I heard you like SSH",
        "SSH in SSH: Inception networking",
        "Reverse shell: the comeback kid",
        "Interactive shell: let's chat",
        "Non-interactive: fire and forget",
        "Batch mode: automation station",
        "Quiet mode: shhh, secretly connecting",
        "Verbose mode: tell me everything",

        // SSH culture
        "OpenSSH: the one true SSH",
        "Dropbear: SSH for the tiny",
        "PuTTY: Windows' first SSH love",
        "SSH client: your portal to elsewhere",
        "SSH server: welcome to my home",
        "sshd: the daemon that listens",
        "Port 22: reserved for the elite",
        "TCP/IP: the pipes we travel",
        "Encrypted channel: speaking in secrets",

        // More SSH wisdom
        "SSH: the sysadmin's best friend",
        "Remote debugging: printf from afar",
        "Tail -f: watching logs like TV",
        "Screen/tmux: SSH's life insurance",
        "Session persistence: outliving the connection",
        "Reconnecting: hope springs eternal",
        "Latency: the enemy of remote work",
        "Round trip: there and back again",
        "Packet loss: messages in the void",
        "MTU: maximum transmission understanding",

        // Final SSH jokes
        "SSH: Secure Shell, Secure Life",
        "The terminal is dark and full of terrors",
        "In SSH we trust",
        "One does not simply SSH to production",
        "May the SSH be with you",
        "Keep calm and SSH admin",
        "SSH: solving problems from anywhere",
        "Remote root: absolute power corrupts absolutely",
        "The SSH remembers: known_hosts never forgets",
        "Live free or SSH: the sysadmin's creed"
    ]

    // MARK: - Kubernetes-Specific Jokes (~200)

    static let kubernetes: [String] = [
        // CrashLoopBackOff humor
        "I'm not stuck in CrashLoopBackOff, you're stuck in CrashLoopBackOff",
        "CrashLoopBackOff: at least it's consistent",
        "My pod's favorite dance: the CrashLoopBackOff",
        "CrashLoopBackOff: the gift that keeps on giving",
        "In a CrashLoopBackOff? Join the club",
        "Pod status: living, dying, repeat",
        "Container restart policy: Always (suffering)",
        "BackOff: the pod needs space",
        "Restart count: 42 and climbing",
        "Pod evicted? It's not you, it's the OOM killer",

        // kubectl humor
        "kubectl apply -f hopes-and-dreams.yaml",
        "kubectl delete pod: the fix for everything",
        "kubectl get pods --all-namespaces: where's Waldo?",
        "kubectl logs -f: the sysadmin's TV",
        "kubectl exec -it: getting inside the container",
        "kubectl describe: tell me your life story",
        "kubectl explain: what even is this field?",
        "kubectl rollout undo: time travel for deployments",
        "kubectl scale: pods go brrr",
        "kubectl port-forward: local meets remote",

        // YAML
        "Containers: like VMs, but with extra YAML",
        "YAML: Yet Another Markup Liability",
        "Kubernetes: because 'simple' was taken",
        "Manifest: the recipe for disaster (sometimes)",
        "Helm chart: YAML templating for the brave",
        "Kustomize: kubectl's fancy friend",
        "CR: Custom Resources, Custom Problems",
        "CRD: Custom Resource Definitions of pain",
        "Operator: software operating software",
        "Spec vs Status: expectations vs reality",

        // Pods
        "Pod pending: waiting for resources like it's Black Friday",
        "This pod is going places... mostly CrashLoopBackOff",
        "Pod priority: some pods are more equal than others",
        "Pod disruption budget: disruption, but organized",
        "Sidecar container: the pod's plus one",
        "Init container: breakfast before the main course",
        "Multi-container pod: better together",
        "Pod topology: where pods go to party",
        "Pod affinity: pods that stick together",
        "Pod anti-affinity: pods that need space",

        // Nodes
        "Node not ready: taking a mental health day",
        "Node pressure: even clusters get stressed",
        "Taint: the node's 'do not disturb' sign",
        "Toleration: pods that ignore the signs",
        "Node selector: picky pod placement",
        "Node affinity: pods with preferences",
        "Kubelet: the node's loyal servant",
        "Kube-proxy: networking's unsung hero",
        "Container runtime: where containers come to life",
        "Node draining: orderly evacuation in progress",

        // Networking
        "ClusterIP: staying in the cluster bubble",
        "NodePort: poking holes in the firewall",
        "LoadBalancer: cloud money going brrr",
        "Ingress: the front door of the cluster",
        "NetworkPolicy: traffic cop for pods",
        "Service mesh: networking inception",
        "Envoy: the sidecar that could",
        "Istio: service mesh or complexity mesh?",
        "Linkerd: lighter than Istio",
        "CoreDNS: naming things, which is hard",

        // Storage
        "PersistentVolume: storage that survives",
        "PVC: Persistent Volume Claim (please give storage)",
        "StorageClass: the menu of storage options",
        "CSI: the storage interface standard",
        "EmptyDir: temporary storage that empties",
        "HostPath: when you really trust the node",
        "ConfigMap: configuration, externalized",
        "Secret: ConfigMap's classified sibling",
        "Volume mount: attaching storage to pods",
        "StatefulSet: when identity matters",

        // Namespaces
        "Namespace: the final frontier",
        "Default namespace: where chaos lives",
        "Kube-system: do not disturb",
        "ResourceQuota: namespace budget limits",
        "LimitRange: default limits for the forgetful",
        "Multi-tenancy: sharing is caring (sort of)",
        "Namespace isolation: good fences make good neighbors",
        "Cross-namespace: breaking down walls",
        "Cluster-scoped: one resource to rule them all",
        "Namespace stuck terminating: it has unfinished business",

        // Control plane
        "etcd: where your configs go to live forever",
        "API server: the cluster's receptionist",
        "Controller manager: making desired state reality",
        "Scheduler: pod matchmaker",
        "Cloud controller: cluster meets cloud",
        "Kube-apiserver: the source of truth",
        "Control plane: the brain of the operation",
        "Leader election: democracy in clusters",
        "Quorum: three is the magic number",
        "High availability: redundancy is beautiful",

        // Pod lifecycle
        "Pod phase: Pending, Running, Panicking",
        "Container state: Waiting, Running, Terminated (crying)",
        "ReadinessProbe: are you ready for traffic?",
        "LivenessProbe: are you still alive?",
        "StartupProbe: give it a moment",
        "TerminationGracePeriod: last words allowed",
        "PreStop hook: cleaning up before goodbye",
        "PostStart hook: hello, world!",
        "RestartPolicy: try, try again",
        "ImagePullBackOff: image not found, checking spelling",

        // Deployment strategies
        "RollingUpdate: one pod at a time",
        "Recreate: delete everything, YOLO",
        "Blue-green: gambling with colors",
        "Canary: tweet tweet, is it safe?",
        "Rollout: deploy and pray",
        "Rollback: undo button to the rescue",
        "MaxSurge: extra pods for safety",
        "MaxUnavailable: minimum viable pods",
        "Revision history: remember your deployments",
        "kubectl rollout status: watching paint dry",

        // Resource management
        "Resource limits: caps on chaos",
        "Resource requests: what pods want",
        "OOMKilled: killed by the memory reaper",
        "CPU throttling: slow down there",
        "QoS Guaranteed: top-tier treatment",
        "QoS Burstable: sometimes I need more",
        "QoS BestEffort: first to get evicted",
        "Vertical scaling: make it bigger",
        "Horizontal scaling: make more of them",
        "HPA: Horizontal Pod Autoscaler (magic)",

        // Debugging
        "kubectl debug: getting forensic",
        "Ephemeral containers: debugging sidekicks",
        "kubectl attach: joining the container party",
        "Container logs: reading the tea leaves",
        "Events: what happened recently",
        "kubectl top: who's using all the resources?",
        "Container shell: exploring from the inside",
        "Pod not scheduled: unwanted by all nodes",
        "ImagePullPolicy: Always, IfNotPresent, Never (trust issues)",
        "Pending forever: still waiting for the cluster fairy",

        // Kubernetes culture
        "K8s: K-eight-s, not Kates",
        "Kubernetes: Greek for 'helmsman'",
        "CNCF: Cloud Native Computing Foundation (fancy)",
        "Borg: Kubernetes' Google ancestor",
        "Container orchestration: herding digital cats",
        "Cloud native: buzzword or lifestyle?",
        "12-factor app: the commandments",
        "Microservices: distributed problems, distributed",
        "Declarative: tell it what you want",
        "Imperative: tell it what to do",

        // More K8s wisdom
        "May your pods be ever Running",
        "There's no place like 10.244.0.1",
        "In K8s we trust (sort of)",
        "Keep calm and kubectl on",
        "One does not simply understand K8s",
        "The cluster is dark and full of pods",
        "With great cluster comes great responsibility",
        "Kubernetes: it's clusters all the way down",
        "My other cluster is also on fire",
        "K8s: making simple things complicated since 2014",

        // Helm specific
        "Helm: the package manager that templates",
        "Chart: Helm's recipe for deployment",
        "Release: a chart instance running wild",
        "Values.yaml: the configuration smorgasbord",
        "helm upgrade --install: upsert for clusters",
        "helm rollback: time machine for releases",
        "Chart museum: where charts go to be stored",
        "Dependency hell: now with YAML",
        "Chart versioning: semantic versioning, but Helm",
        "Helmfile: managing Helm with more YAML",

        // Service mesh
        "Service mesh: extra hops for extra visibility",
        "Sidecar injection: surprise, you have Envoy",
        "mTLS: mutual TLS, mutual complexity",
        "Circuit breaker: don't call us, we'll call you",
        "Retry policy: try try again (automatically)",
        "Rate limiting: slow down there cowboy",
        "Canary analysis: data-driven deployments",
        "Traffic mirroring: production shadows",
        "Fault injection: breaking things on purpose",
        "Observability: know everything, understand nothing",

        // Kubernetes operators
        "Operator pattern: automate all the things",
        "Custom controller: your logic, their loop",
        "Reconciliation loop: make it so, continuously",
        "Watch: kubectl for robots",
        "Informer: stay updated, efficiently",
        "Client-go: Go, meet Kubernetes",
        "Kubebuilder: scaffolding for operators",
        "Operator SDK: build operators, not from scratch",
        "Finalizer: cleanup before deletion",
        "Owner reference: who's your daddy?",

        // Funny observations
        "Kubernetes has entered the chat",
        "My therapist doesn't understand YAML indentation",
        "I dream in pod specs",
        "Sleep? I have alerts",
        "Prometheus: metrics, metrics everywhere",
        "Grafana: making metrics pretty since 2014",
        "Alert fatigue: when everything is urgent",
        "On-call for K8s: phone never stops",
        "Cluster upgrade: scheduled adventure time",
        "Managed Kubernetes: it's someone else's problem",

        // Final K8s jokes
        "EKS, GKE, AKS: Kubernetes for rent",
        "Self-hosted K8s: bravery or foolishness?",
        "Kind: Kubernetes in Docker in your laptop",
        "Minikube: K8s training wheels",
        "K3s: diet Kubernetes",
        "Rancher: wrangling clusters since forever",
        "OpenShift: Kubernetes with Red Hat flair",
        "Pod security policy: deprecated but remembered",
        "PodSecurityAdmission: the new sheriff",
        "GitOps: git push to production (safely)"
    ]
}
