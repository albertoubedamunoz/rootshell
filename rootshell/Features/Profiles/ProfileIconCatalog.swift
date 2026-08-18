import Foundation

/// One selectable icon in the profile icon picker.
struct ProfileIconEntry: Identifiable {
    let icon: ProfileIcon
    /// Name shown in the UI. SF Symbols use the raw symbol name;
    /// Nerd glyphs use their common name (proper nouns, not localized)
    let displayName: String
    /// Lowercase extra keywords for search matching
    let keywords: String
    var id: String { icon.storageString }

    func matches(_ lowercasedQuery: String) -> Bool {
        displayName.lowercased().contains(lowercasedQuery)
            || keywords.contains(lowercasedQuery)
            || icon.storageString.contains(lowercasedQuery)
    }
}

struct ProfileIconCategory: Identifiable {
    let title: LocalizedStringResource
    let entries: [ProfileIconEntry]
    var id: String { title.key }
}

private func sf(_ name: String, _ keywords: String) -> ProfileIconEntry {
    ProfileIconEntry(icon: .symbol(name), displayName: name, keywords: keywords)
}

private func nf(_ hexCodepoint: String, _ displayName: String, _ keywords: String = "") -> ProfileIconEntry {
    ProfileIconEntry(
        icon: ProfileIcon(storageString: ProfileIcon.nerdPrefix + hexCodepoint),
        displayName: displayName,
        keywords: keywords
    )
}

/// Curated icon sets for connection profiles. Nerd glyph codepoints are
/// from Nerd Fonts 3.4.0, the release bundled as SymbolsNerdFontMono
/// (and embedded in GhosttyKit for terminal fallback).
enum ProfileIconCatalog {

    // MARK: - SF Symbols (~120, superset of the original 28)

    static let symbolCategories: [ProfileIconCategory] = [
        ProfileIconCategory(title: "Servers & Network", entries: [
            sf("server.rack", "server rack datacenter"),
            sf("xserve", "xserve rack server"),
            sf("network", "network graph"),
            sf("globe", "globe web internet"),
            sf("globe.americas.fill", "globe americas earth world"),
            sf("globe.europe.africa.fill", "globe europe africa earth world"),
            sf("globe.asia.australia.fill", "globe asia australia earth world"),
            sf("wifi", "wifi wireless"),
            sf("wifi.router", "wifi router access point"),
            sf("antenna.radiowaves.left.and.right", "antenna radio broadcast"),
            sf("dot.radiowaves.left.and.right", "radiowaves signal broadcast"),
            sf("point.3.connected.trianglepath.dotted", "nodes mesh cluster connected"),
            sf("externaldrive.connected.to.line.below", "drive nas connected storage"),
            sf("cable.connector", "cable connector plug"),
            sf("powerplug.fill", "power plug outlet"),
            sf("bolt.horizontal.fill", "bolt connection flash"),
            sf("arrow.up.arrow.down", "arrows transfer sync up down"),
            sf("cloud.fill", "cloud"),
            sf("icloud.fill", "icloud cloud"),
        ]),
        ProfileIconCategory(title: "Devices", entries: [
            sf("desktopcomputer", "desktop computer imac"),
            sf("laptopcomputer", "laptop computer macbook"),
            sf("macmini.fill", "mac mini"),
            sf("macpro.gen3", "mac pro tower"),
            sf("display", "display monitor screen"),
            sf("display.2", "displays monitors dual screen"),
            sf("iphone", "iphone phone mobile"),
            sf("ipad", "ipad tablet"),
            sf("applewatch", "apple watch"),
            sf("visionpro", "vision pro headset"),
            sf("homepod.fill", "homepod speaker"),
            sf("tv.fill", "tv television"),
            sf("gamecontroller.fill", "game controller gaming"),
            sf("av.remote.fill", "remote control"),
            sf("cpu", "cpu chip processor"),
            sf("memorychip", "memory chip ram"),
            sf("internaldrive.fill", "internal drive disk ssd"),
            sf("externaldrive.fill", "external drive disk usb"),
            sf("opticaldiscdrive.fill", "optical disc drive dvd"),
            sf("printer.fill", "printer"),
            sf("camera.fill", "camera"),
        ]),
        ProfileIconCategory(title: "Security", entries: [
            sf("lock.fill", "lock secure"),
            sf("lock.open.fill", "lock open unlocked"),
            sf("lock.shield.fill", "lock shield secure"),
            sf("key.fill", "key"),
            sf("key.horizontal.fill", "key horizontal"),
            sf("shield.fill", "shield protect"),
            sf("shield.lefthalf.filled", "shield half protect"),
            sf("checkmark.shield.fill", "shield checkmark verified"),
            sf("exclamationmark.shield.fill", "shield warning alert"),
            sf("touchid", "touch id fingerprint"),
            sf("faceid", "face id"),
            sf("eye.fill", "eye watch monitor"),
            sf("eye.slash.fill", "eye slash hidden private"),
            sf("hand.raised.fill", "hand raised stop privacy"),
        ]),
        ProfileIconCategory(title: "Development", entries: [
            sf("terminal.fill", "terminal console shell"),
            sf("apple.terminal.fill", "apple terminal console shell"),
            sf("chevron.left.forwardslash.chevron.right", "code tags html"),
            sf("curlybraces", "curly braces code json"),
            sf("command", "command key"),
            sf("number", "number hash pound"),
            sf("function", "function math"),
            sf("sum", "sum sigma math"),
            sf("hammer.fill", "hammer build"),
            sf("wrench.and.screwdriver.fill", "wrench screwdriver tools"),
            sf("gearshape.fill", "gear settings config"),
            sf("gearshape.2.fill", "gears settings config"),
            sf("ladybug.fill", "ladybug bug debug"),
            sf("ant.fill", "ant bug debug"),
            sf("arrow.triangle.branch", "branch git fork"),
            sf("arrow.triangle.pull", "pull request merge"),
            sf("cube.fill", "cube package box"),
            sf("shippingbox.fill", "shipping box package deploy"),
            sf("square.stack.3d.up.fill", "stack layers 3d"),
            sf("cylinder.split.1x2.fill", "cylinder database"),
            sf("tray.full.fill", "tray inbox queue"),
        ]),
        ProfileIconCategory(title: "Files & Cloud", entries: [
            sf("folder.fill", "folder directory"),
            sf("doc.fill", "document file"),
            sf("doc.text.fill", "document text file"),
            sf("doc.on.doc.fill", "documents copy files"),
            sf("archivebox.fill", "archive box backup"),
            sf("books.vertical.fill", "books library"),
            sf("book.fill", "book docs manual"),
            sf("newspaper.fill", "newspaper news"),
            sf("paperclip", "paperclip attachment"),
            sf("link", "link chain url"),
            sf("icloud.and.arrow.up.fill", "cloud upload"),
            sf("icloud.and.arrow.down.fill", "cloud download"),
            sf("cloud.bolt.fill", "cloud bolt storm"),
        ]),
        ProfileIconCategory(title: "Nature & Weather", entries: [
            sf("leaf.fill", "leaf plant eco"),
            sf("tree.fill", "tree forest"),
            sf("flame.fill", "flame fire hot"),
            sf("drop.fill", "drop water"),
            sf("snowflake", "snowflake cold winter"),
            sf("sun.max.fill", "sun sunny day"),
            sf("moon.fill", "moon night"),
            sf("moon.stars.fill", "moon stars night"),
            sf("sparkles", "sparkles magic stars"),
            sf("cloud.rain.fill", "cloud rain"),
            sf("cloud.bolt.rain.fill", "cloud storm thunder"),
            sf("tornado", "tornado storm"),
            sf("hurricane", "hurricane storm cyclone"),
            sf("wind", "wind breeze"),
            sf("mountain.2.fill", "mountains peaks"),
            sf("pawprint.fill", "paw print pet animal"),
            sf("fish.fill", "fish"),
            sf("bird.fill", "bird"),
            sf("tortoise.fill", "tortoise turtle slow"),
            sf("hare.fill", "hare rabbit fast"),
            sf("lizard.fill", "lizard gecko"),
        ]),
        ProfileIconCategory(title: "Transport", entries: [
            sf("car.fill", "car auto"),
            sf("bolt.car.fill", "electric car ev"),
            sf("bus.fill", "bus"),
            sf("tram.fill", "tram train"),
            sf("airplane", "airplane plane flight"),
            sf("ferry.fill", "ferry boat ship"),
            sf("sailboat.fill", "sailboat boat"),
            sf("bicycle", "bicycle bike"),
            sf("scooter", "scooter"),
            sf("truck.box.fill", "truck delivery"),
            sf("fuelpump.fill", "fuel pump gas"),
        ]),
        ProfileIconCategory(title: "Objects & Tools", entries: [
            sf("house.fill", "house home"),
            sf("building.2.fill", "buildings office city"),
            sf("building.columns.fill", "building columns bank institution"),
            sf("lightbulb.fill", "lightbulb idea"),
            sf("flashlight.on.fill", "flashlight torch"),
            sf("alarm.fill", "alarm clock"),
            sf("stopwatch.fill", "stopwatch timer"),
            sf("timer", "timer countdown"),
            sf("calendar", "calendar date"),
            sf("bell.fill", "bell notification"),
            sf("tag.fill", "tag label"),
            sf("flag.fill", "flag marker"),
            sf("pin.fill", "pin location"),
            sf("mappin.and.ellipse", "map pin location"),
            sf("scope", "scope crosshair"),
            sf("target", "target bullseye"),
            sf("gift.fill", "gift present"),
            sf("crown.fill", "crown king"),
            sf("wand.and.stars", "wand magic"),
            sf("paintbrush.fill", "paintbrush art"),
            sf("scissors", "scissors cut"),
            sf("eyedropper", "eyedropper color"),
            sf("briefcase.fill", "briefcase work business"),
            sf("cart.fill", "cart shopping"),
            sf("basket.fill", "basket shopping"),
            sf("creditcard.fill", "credit card payment"),
            sf("banknote.fill", "banknote money cash"),
            sf("dice.fill", "dice game random"),
            sf("puzzlepiece.fill", "puzzle piece plugin"),
            sf("music.note", "music note audio"),
            sf("headphones", "headphones audio"),
            sf("mic.fill", "microphone mic audio"),
            sf("radio.fill", "radio"),
        ]),
        ProfileIconCategory(title: "People", entries: [
            sf("person.fill", "person user"),
            sf("person.2.fill", "people users team"),
            sf("person.3.fill", "people group crowd"),
            sf("person.crop.circle.fill", "person avatar account"),
            sf("person.badge.key.fill", "person key admin access"),
            sf("brain.head.profile", "brain head think ai"),
            sf("figure.walk", "figure walk person"),
            sf("graduationcap.fill", "graduation cap school study"),
            sf("stethoscope", "stethoscope doctor health"),
        ]),
        ProfileIconCategory(title: "Shapes & Symbols", entries: [
            sf("star.fill", "star favorite"),
            sf("heart.fill", "heart love favorite"),
            sf("bolt.fill", "bolt lightning flash"),
            sf("circle.fill", "circle"),
            sf("square.fill", "square"),
            sf("triangle.fill", "triangle"),
            sf("diamond.fill", "diamond"),
            sf("hexagon.fill", "hexagon"),
            sf("seal.fill", "seal badge"),
            sf("rosette", "rosette award ribbon"),
            sf("checkmark.circle.fill", "checkmark done success"),
            sf("xmark.circle.fill", "xmark close fail"),
            sf("exclamationmark.triangle.fill", "warning alert exclamation"),
            sf("questionmark.circle.fill", "question help"),
            sf("plus.circle.fill", "plus add"),
            sf("infinity", "infinity forever"),
            sf("asterisk", "asterisk wildcard"),
            sf("at", "at sign email"),
            sf("percent", "percent"),
        ]),
    ]

    // MARK: - Nerd Font glyphs (~100, Nerd Fonts 3.4.0)

    static let nerdCategories: [ProfileIconCategory] = [
        ProfileIconCategory(title: "OS & Distros", entries: [
            nf("e712", "Linux", "linux tux"),
            nf("f179", "Apple", "apple mac macos"),
            nf("e70f", "Windows", "windows microsoft"),
            nf("e73a", "Ubuntu", "ubuntu"),
            nf("e77d", "Debian", "debian"),
            nf("f303", "Arch Linux", "arch"),
            nf("f30a", "Fedora", "fedora"),
            nf("f304", "CentOS", "centos"),
            nf("e7bb", "Red Hat", "redhat rhel"),
            nf("f314", "SUSE", "suse opensuse"),
            nf("f300", "Alpine", "alpine"),
            nf("f313", "NixOS", "nixos nix"),
            nf("f30d", "Gentoo", "gentoo"),
            nf("f315", "Raspberry Pi", "raspberry raspbian"),
            nf("f30c", "FreeBSD", "freebsd bsd"),
            nf("e70e", "Android", "android"),
        ]),
        ProfileIconCategory(title: "Languages", entries: [
            nf("e73c", "Python", "python"),
            nf("e627", "Go", "go golang"),
            nf("e7a8", "Rust", "rust"),
            nf("e74e", "JavaScript", "javascript js"),
            nf("e628", "TypeScript", "typescript ts"),
            nf("e755", "Swift", "swift"),
            nf("e738", "Java", "java"),
            nf("e61e", "C", "c language"),
            nf("e61d", "C++", "cpp c plus"),
            nf("e739", "Ruby", "ruby"),
            nf("e73d", "PHP", "php"),
            nf("e769", "Perl", "perl"),
            nf("e620", "Lua", "lua"),
            nf("e777", "Haskell", "haskell"),
            nf("e62d", "Elixir", "elixir"),
            nf("e7b1", "Erlang", "erlang"),
            nf("e737", "Scala", "scala"),
            nf("e798", "Dart", "dart flutter"),
            nf("e634", "Kotlin", "kotlin"),
            nf("e6a9", "Zig", "zig"),
            nf("e736", "HTML", "html web"),
            nf("e749", "CSS", "css style"),
            nf("e718", "Node.js", "node nodejs"),
            nf("e7ba", "React", "react"),
        ]),
        ProfileIconCategory(title: "DevOps & Cloud", entries: [
            nf("f0868", "Docker", "docker container whale"),
            nf("f10fe", "Kubernetes", "kubernetes k8s"),
            nf("e7ad", "AWS", "aws amazon"),
            nf("ebd8", "Azure", "azure microsoft"),
            nf("f1a0", "Google", "google gcp cloud"),
            nf("e77b", "Heroku", "heroku"),
            nf("e7ae", "DigitalOcean", "digitalocean droplet"),
            nf("f1c0", "Database", "database db"),
            nf("f233", "Server", "server host"),
            nf("f0c2", "Cloud", "cloud"),
            nf("e767", "Jenkins", "jenkins ci"),
            nf("e776", "nginx", "nginx"),
            nf("e76e", "PostgreSQL", "postgresql postgres"),
            nf("e704", "MySQL", "mysql"),
            nf("e76d", "Redis", "redis"),
            nf("e7a4", "MongoDB", "mongodb mongo"),
        ]),
        ProfileIconCategory(title: "Git & VCS", entries: [
            nf("e702", "Git", "git"),
            nf("e709", "GitHub", "github"),
            nf("f296", "GitLab", "gitlab"),
            nf("f171", "Bitbucket", "bitbucket"),
            nf("e725", "Branch", "git branch"),
            nf("e727", "Merge", "git merge"),
            nf("e726", "Pull Request", "git pr"),
            nf("e729", "Commit", "git commit"),
        ]),
        ProfileIconCategory(title: "Terminal & Misc", entries: [
            nf("e795", "Terminal", "terminal shell prompt console"),
            nf("e62b", "Vim", "vim"),
            nf("f36f", "Neovim", "neovim nvim"),
            nf("e632", "Emacs", "emacs"),
            nf("ebc8", "tmux", "tmux"),
            nf("f188", "Bug", "bug debug"),
            nf("f0c3", "Flask", "flask lab experiment"),
            nf("f0ad", "Wrench", "wrench tool"),
            nf("f013", "Gear", "gear settings"),
            nf("f135", "Rocket", "rocket launch deploy"),
            nf("f06d", "Fire", "fire flame"),
            nf("f015", "Home", "home house"),
            nf("f023", "Lock", "lock secure"),
            nf("f084", "Key", "key"),
            nf("f132", "Shield", "shield protect"),
            nf("f0ac", "Globe", "globe world web"),
            nf("f1eb", "Wifi", "wifi wireless"),
            nf("f0e8", "Sitemap", "sitemap network topology"),
            nf("f07b", "Folder", "folder directory"),
            nf("f15b", "File", "file document"),
            nf("f004", "Heart", "heart love"),
            nf("f005", "Star", "star favorite"),
            nf("f0e7", "Bolt", "bolt lightning flash"),
            nf("f0f4", "Coffee", "coffee mug"),
            nf("f11b", "Gamepad", "gamepad game controller"),
            nf("f001", "Music", "music note audio"),
            nf("f030", "Camera", "camera photo"),
            nf("f019", "Download", "download"),
            nf("f093", "Upload", "upload"),
            nf("f1b2", "Cube", "cube package box"),
            nf("f1b3", "Cubes", "cubes packages modules"),
        ]),
    ]

    // MARK: - Lookup

    /// UI name for any icon, whether or not it is in the curated sets
    static func displayName(for icon: ProfileIcon) -> String {
        switch icon {
        case .symbol(let name):
            return name
        case .favicon(let customHost):
            return customHost ?? String(localized: "Website Icon")
        case .nerd:
            for category in nerdCategories {
                for entry in category.entries where entry.icon == icon {
                    return entry.displayName
                }
            }
            return icon.storageString
        }
    }

    // MARK: - Search

    static func search(_ query: String) -> (symbols: [ProfileIconEntry], nerd: [ProfileIconEntry]) {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return ([], []) }
        return (
            symbols: symbolCategories.flatMap(\.entries).filter { $0.matches(q) },
            nerd: nerdCategories.flatMap(\.entries).filter { $0.matches(q) }
        )
    }
}
