#if !targetEnvironment(macCatalyst)

import Foundation

extension LocalShellSession {
    /// Displays help information
    func displayHelp() {
        let header = String(localized: "Available commands:", comment: "Help: main header")
        let fileOpsHeader = String(localized: "File Operations:", comment: "Help: file operations section header")
        let textEditorsHeader = String(localized: "Text Editors:", comment: "Help: text editors section header")
        let textProcHeader = String(localized: "Text Processing:", comment: "Help: text processing section header")
        let archivesHeader = String(localized: "Archives & Compression:", comment: "Help: archives section header")
        let networkHeader = String(localized: "Network:", comment: "Help: network section header")
        let mediaHeader = String(localized: "Media:", comment: "Help: media section header")
        let imgcatDesc = String(localized: "Display images inline (Kitty graphics protocol)", comment: "Help: imgcat description")
        let imgtextDesc = String(localized: "Extract text from images (OCR)", comment: "Help: imgtext description")
        let shellUtilHeader = String(localized: "Shell Utilities:", comment: "Help: shell utilities section header")
        let builtinHeader = String(localized: "Built-in Shell Commands:", comment: "Help: built-in commands section header")
        let helpDesc = String(localized: "Show this help message", comment: "Help: help command description")
        let historyDesc = String(localized: "Show command history", comment: "Help: history command description")
        let clearDesc = String(localized: "Clear the screen (Ctrl-L)", comment: "Help: clear command description")
        let resetDesc = String(localized: "Reset terminal state and clear scrollback", comment: "Help: reset command description")
        let exitDesc = String(localized: "Exit the shell (close tab)", comment: "Help: exit command description")
        let logoutDesc = String(localized: "Same as exit", comment: "Help: logout command description")
        let sourceDesc = String(localized: "Re-source .rootshellrc (or source <file>)", comment: "Help: source command description")
        let editrcDesc = String(localized: "Edit .rootshellrc ($EDITOR or vim)", comment: "Help: editrc command description")
        let editpromptDesc = String(localized: "Edit .promptrc.toml ($EDITOR or vim)", comment: "Help: editprompt command description")
        let reloadConfigDesc = String(localized: "Reload imported Ghostty keybind config", comment: "Help: reloadconfig command description")
        let shortcutsHeader = String(localized: "Keyboard Shortcuts:", comment: "Help: keyboard shortcuts section header")
        let ctrlADesc = String(localized: "Move to beginning of line", comment: "Help: Ctrl-A description")
        let ctrlEDesc = String(localized: "Move to end of line", comment: "Help: Ctrl-E description")
        let ctrlKDesc = String(localized: "Kill to end of line", comment: "Help: Ctrl-K description")
        let ctrlUDesc = String(localized: "Kill entire line", comment: "Help: Ctrl-U description")
        let ctrlYDesc = String(localized: "Yank back the last killed text", comment: "Help: Ctrl-Y description")
        let ctrlWDesc = String(localized: "Delete word backward", comment: "Help: Ctrl-W description")
        let ctrlLDesc = String(localized: "Clear screen", comment: "Help: Ctrl-L description")
        let ctrlCDesc = String(localized: "Interrupt current command", comment: "Help: Ctrl-C description")
        let ctrlDDesc = String(localized: "Exit on empty line (close tab)", comment: "Help: Ctrl-D description")
        let tabDesc = String(localized: "Auto-complete commands and paths", comment: "Help: Tab description")
        let arrowDesc = String(localized: "Navigate command history", comment: "Help: Up/Down description")
        let footer = String(localized: "For command-specific help, try: <command> --help or <command> -h", comment: "Help: footer tip")
        let vimDesc = String(localized: "Full-featured text editor", comment: "Help: vim description")
        let hxDesc = String(localized: "Helix modal text editor", comment: "Help: hx (Helix) description")
        let rfDesc = String(localized: "TUI file browser (miller columns)", comment: "Help: rf description")
        let devToolsHeader = String(localized: "Developer Tools:", comment: "Help: developer tools section header")
        let batDesc = String(localized: "Syntax-highlighted file viewer", comment: "Help: bat description")
        let jqDesc = String(localized: "JSON processor", comment: "Help: jq description")
        let gitDesc = String(localized: "Git operations (libgit2)", comment: "Help: git description")
        let gixDesc = String(localized: "Git operations (gitoxide)", comment: "Help: gix description")
        let rgDesc = String(localized: "Fast regex search (ripgrep)", comment: "Help: rg description")
        // say command disabled - crashes app (ios_system AVSpeechSynthesizer issue)

        let helpText = """
\(header)

\(fileOpsHeader)
  ls, pwd, cd, cat, cp, mv, rm, ln, mkdir, rmdir, touch, find, du, stat,
  chmod, chown, chflags, readlink

\(textEditorsHeader)
  vim, vi   - \(vimDesc)
  hx        - \(hxDesc)
  rf        - \(rfDesc)

\(textProcHeader)
  grep, egrep, fgrep, rg, sed, awk, wc, sort, uniq, diff, head, tail, tr, md5

\(archivesHeader)
  tar, cpio, unzip, bsdcat, gzip, gunzip, compress, uncompress, xz, unxz, xzcat

\(networkHeader)
  curl, ssh, scp, sftp, ssh-copy-id, mosh, roam, tssh, trzsz, croc,
  ping, ping6, mtr, mtr6, traceroute, traceroute6,
  nc, dig, host, nslookup, whois, ifconfig, wol,
  bssid, whatismyip, whatismyip4, whatismyip6

\(devToolsHeader)
  git       - \(gitDesc)
  bat       - \(batDesc)
  jq        - \(jqDesc)
  gix       - \(gixDesc)
  rg        - \(rgDesc)

\(mediaHeader)
  imgcat    - \(imgcatDesc)
  imgtext   - \(imgtextDesc)

\(shellUtilHeader)
  echo, env, printenv, setenv, export, unsetenv, date, uname, whoami, tee,
  uptime, open, openurl, pbcopy, pbpaste, alias

\(builtinHeader)
  help     - \(helpDesc)
  history  - \(historyDesc)
  clear    - \(clearDesc)
  reset    - \(resetDesc)
  source   - \(sourceDesc)
  editrc     - \(editrcDesc)
  editprompt - \(editpromptDesc)
  reloadconfig - \(reloadConfigDesc)
  exit       - \(exitDesc)
  logout   - \(logoutDesc)

\(shortcutsHeader)
  Ctrl-A   - \(ctrlADesc)
  Ctrl-E   - \(ctrlEDesc)
  Ctrl-K   - \(ctrlKDesc)
  Ctrl-U   - \(ctrlUDesc)
  Ctrl-Y   - \(ctrlYDesc)
  Ctrl-W   - \(ctrlWDesc)
  Ctrl-L   - \(ctrlLDesc)
  Ctrl-C   - \(ctrlCDesc)
  Ctrl-D   - \(ctrlDDesc)
  Tab      - \(tabDesc)
  Up/Down  - \(arrowDesc)

\(footer)

"""
        Task { @MainActor [weak self] in
            guard let self = self else { return }
            self.onOutput?(self.normalizeLineEndings(helpText))
            self.displayPrompt()
        }
    }

    /// Displays reset command help
    func displayResetHelp() {
        let helpText = """
usage: reset

Reset the terminal state and clear scrollback.

"""
        Task { @MainActor [weak self] in
            guard let self = self else { return }
            self.onOutput?(self.normalizeLineEndings(helpText))
            self.displayPrompt()
        }
    }

    /// Displays reloadconfig command help
    func displayReloadConfigHelp() {
        let helpText = """
usage: reloadconfig

Reload the imported Ghostty keybind config from ~/.ghostty/imported_keybinds.conf.
Use this after editing the file from a local shell or through a symlink in your home directory.

"""
        Task { @MainActor [weak self] in
            guard let self = self else { return }
            self.onOutput?(self.normalizeLineEndings(helpText))
            self.displayPrompt()
        }
    }

    /// Displays command history
    func displayHistory() {
        let commands = historyManager.recentCommands(limit: 50)
        if commands.isEmpty {
            Task { @MainActor [weak self] in
                guard let self = self else { return }
                let msg = String(localized: "No commands in history", comment: "History: empty history message")
                self.onOutput?(self.normalizeLineEndings(msg + "\n"))
                self.displayPrompt()
            }
            return
        }

        let historyText = commands.enumerated().map { index, command in
            String(format: "%4d  %@", commands.count - index, command)
        }.joined(separator: "\n") + "\n"

        Task { @MainActor [weak self] in
            guard let self = self else { return }
            self.onOutput?(self.normalizeLineEndings(historyText))
            self.displayPrompt()
        }
    }

    /// Displays SSH help with usage and keystore information
    func displaySSHHelp() {
        let keyManager = SSHKeyManager.shared
        let keyCount = keyManager.savedKeys.count
        var defaultKeyInfo = ""
        if let defaultID = keyManager.primaryDefaultKeyID,
           let defaultKey = keyManager.findKey(id: defaultID) {
            let name = defaultKey.name
            defaultKeyInfo = "  \(String(localized: "Default key:", comment: "SSH help: default key label")) \(name)\n"
        }

        let optionsHeader = String(localized: "Options:", comment: "Command help: options section header")
        let destHeader = String(localized: "Destination:", comment: "SSH help: destination section header")
        let keystoreHeader = String(localized: "Keystore:", comment: "SSH help: keystore section header")
        let keystoreManaged = String(localized: "Keys are managed in Settings > SSH Keys", comment: "SSH help: keystore managed note")
        let savedKeysMsg = String(localized: "You have \(keyCount) saved key(s)", comment: "SSH help: saved key count")
        let keystoreSelectKey = String(localized: "Use -i <keyname> to select a specific key", comment: "SSH help: select key note")
        let keystoreNoKey = String(localized: "If no key specified, uses default key or prompts for password", comment: "SSH help: no key note")
        let keystoreHistory = String(localized: "Connection history remembers which key was used per host", comment: "SSH help: connection history note")
        let agentHeader = String(localized: "Agent Forwarding:", comment: "SSH help: agent forwarding section header")
        let agentDesc = String(localized: "-A enables forwarding of your saved keys to the remote host", comment: "SSH help: agent forwarding description")
        let agentApproval = String(localized: "Use -AA to enable forwarding with auto-approval", comment: "SSH help: agent approval note")
        let hssHeader = String(localized: "Host Shorthand (HSS):", comment: "SSH help: HSS section header")
        let hssDesc = String(localized: "Use !shorthand syntax to expand hostnames via HSS config", comment: "SSH help: HSS description")
        let hssConfigure = String(localized: "Configure patterns in Settings > Host Shorthand", comment: "SSH help: HSS configure note")
        let examplesHeader = String(localized: "Examples:", comment: "Command help: examples section header")

        let helpText = """
usage: ssh [-p port] [-l user] [-i identity] [-J jumphost] [-A|-AA] [--tmux|--herdr] [--path] [-o option] destination [command]

\(optionsHeader)
  -p port       \(String(localized: "Connect to this port (default: 22)", comment: "SSH help: -p option"))
  -l user       \(String(localized: "Log in as this user", comment: "SSH help: -l option"))
  -i identity   \(String(localized: "Use this key (matches saved key names)", comment: "SSH help: -i option"))
  -J jumphost   \(String(localized: "Connect via jump host (ProxyJump)", comment: "SSH help: -J option"))
  -A            \(String(localized: "Enable SSH agent forwarding", comment: "SSH help: -A option"))
  -AA           \(String(localized: "Enable SSH agent forwarding with auto-approval", comment: "SSH help: -AA option"))
  --tmux        \(String(localized: "Auto-start tmux on the remote host", comment: "SSH help: --tmux option"))
  --herdr       \(String(localized: "Auto-start herdr on the remote host", comment: "SSH help: --herdr option"))
  --path        \(String(localized: "Prepend Rootshell's PATH wrapper for remote exec commands", comment: "SSH help: --path option"))
  -o option     \(String(localized: "Set SSH option (Port, User, ProxyJump, IdentityFile)", comment: "SSH help: -o option"))

\(destHeader)
  [user@]host[:port]    \(String(localized: "Standard format", comment: "SSH help: standard destination format"))
  [IPv6]:port           \(String(localized: "IPv6 with port", comment: "SSH help: IPv6 destination format"))
  command               \(String(localized: "Execute command on remote host instead of interactive shell", comment: "SSH help: remote command description"))

\(keystoreHeader)
  \(keystoreManaged)
  \(savedKeysMsg)
\(defaultKeyInfo)  \(keystoreSelectKey)
  \(keystoreNoKey)
  \(keystoreHistory)

\(agentHeader)
  \(agentDesc)
  \(agentApproval)

\(hssHeader)
  \(hssDesc)
  \(hssConfigure)

\(examplesHeader)
  ssh user@host.example.com
  ssh -p 2222 admin@server
  ssh -i mykey user@host
  ssh -J bastion user@internal
  ssh -A user@host
  ssh -AA user@host
  ssh --tmux user@host
  ssh --herdr user@host
  ssh --path user@host wish serve
  ssh user@host ls -la /tmp
  ssh user@host "echo hello"

"""
        Task { @MainActor [weak self] in
            guard let self = self else { return }
            self.onOutput?(self.normalizeLineEndings(helpText))
            self.displayPrompt()
        }
    }

    /// Display SCP help with usage information
    func displaySCPHelp() {
        let keyManager = SSHKeyManager.shared
        let keyCount = keyManager.savedKeys.count
        var defaultKeyInfo = ""
        if let defaultID = keyManager.primaryDefaultKeyID,
           let defaultKey = keyManager.findKey(id: defaultID) {
            let name = defaultKey.name
            defaultKeyInfo = "  \(String(localized: "Default key:", comment: "SSH help: default key label")) \(name)\n"
        }

        let optionsHeader = String(localized: "Options:", comment: "Command help: options section header")
        let fileSpecHeader = String(localized: "File Specifications:", comment: "SCP help: file specifications header")
        let keystoreHeader = String(localized: "Keystore:", comment: "SSH help: keystore section header")
        let keystoreManaged = String(localized: "Keys are managed in Settings > SSH Keys", comment: "SSH help: keystore managed note")
        let savedKeysMsg = String(localized: "You have \(keyCount) saved key(s)", comment: "SSH help: saved key count")
        let keystoreSameAsSSH = String(localized: "Uses same key lookup as ssh command", comment: "SCP/SFTP help: same key lookup note")
        let examplesHeader = String(localized: "Examples:", comment: "Command help: examples section header")

        let helpText = """
usage: scp [-prqvC] [-P port] [-i identity] [-J jump_host] [-o option]
           [-l limit] source ... target

\(optionsHeader)
  -r          \(String(localized: "Recursively copy directories", comment: "SCP help: -r option"))
  -p          \(String(localized: "Preserve modification times and permissions", comment: "SCP help: -p option"))
  -q          \(String(localized: "Quiet mode (no progress)", comment: "SCP help: -q option"))
  -v          \(String(localized: "Verbose mode", comment: "SCP help: -v option"))
  -C          \(String(localized: "Enable compression", comment: "SCP help: -C option"))
  -P port     \(String(localized: "Remote port (default: 22)", comment: "SCP help: -P option"))
  -i file     \(String(localized: "Identity file (matches saved key names)", comment: "SCP help: -i option"))
  -J host     \(String(localized: "Jump host (ProxyJump)", comment: "SCP help: -J option"))
  -o option   \(String(localized: "SSH option (Port, User, ProxyJump, IdentityFile)", comment: "SCP help: -o option"))
  -l limit    \(String(localized: "Bandwidth limit in KB/s", comment: "SCP help: -l option"))

\(fileSpecHeader)
  /local/path           \(String(localized: "Local file or directory", comment: "SCP help: local path"))
  user@host:path        \(String(localized: "Remote file or directory", comment: "SCP help: remote path"))
  host:path             \(String(localized: "Remote (uses current username)", comment: "SCP help: remote path no user"))
  'user@host:*.txt'     \(String(localized: "Remote with wildcard (quote to prevent local expansion)", comment: "SCP help: remote wildcard"))

\(keystoreHeader)
  \(keystoreManaged)
  \(savedKeysMsg)
\(defaultKeyInfo)  \(keystoreSameAsSSH)

\(examplesHeader)
  scp file.txt user@host:/path/       \(String(localized: "Upload file", comment: "SCP help: upload example"))
  scp user@host:/path/file.txt .      \(String(localized: "Download file", comment: "SCP help: download example"))
  scp -r dir/ user@host:/path/        \(String(localized: "Upload directory recursively", comment: "SCP help: recursive upload example"))
  scp 'user@host:/path/*.txt' .       \(String(localized: "Download with wildcard", comment: "SCP help: wildcard download example"))
  scp -P 2222 file.txt user@host:     \(String(localized: "Upload to alternate port", comment: "SCP help: alternate port example"))
  scp -J bastion file.txt internal:   \(String(localized: "Upload via jump host", comment: "SCP help: jump host example"))

"""
        Task { @MainActor [weak self] in
            guard let self = self else { return }
            self.onOutput?(self.normalizeLineEndings(helpText))
            self.displayPrompt()
        }
    }

    /// Display SFTP help with usage information
    func displaySFTPHelp() {
        let keyManager = SSHKeyManager.shared
        let keyCount = keyManager.savedKeys.count
        var defaultKeyInfo = ""
        if let defaultID = keyManager.primaryDefaultKeyID,
           let defaultKey = keyManager.findKey(id: defaultID) {
            let name = defaultKey.name
            defaultKeyInfo = "  \(String(localized: "Default key:", comment: "SSH help: default key label")) \(name)\n"
        }

        let optionsHeader = String(localized: "Options:", comment: "Command help: options section header")
        let keystoreHeader = String(localized: "Keystore:", comment: "SSH help: keystore section header")
        let keystoreManaged = String(localized: "Keys are managed in Settings > SSH Keys", comment: "SSH help: keystore managed note")
        let savedKeysMsg = String(localized: "You have \(keyCount) saved key(s)", comment: "SSH help: saved key count")
        let keystoreSameAsSSH = String(localized: "Uses same key lookup as ssh command", comment: "SCP/SFTP help: same key lookup note")
        let sftpHint = String(localized: "Once connected, type 'help' at the sftp> prompt for available commands.", comment: "SFTP help: interactive hint")
        let examplesHeader = String(localized: "Examples:", comment: "Command help: examples section header")

        let helpText = """
usage: sftp [-P port] [-i identity] [-J jump_host] [-o option] [user@]host

\(optionsHeader)
  -P port     \(String(localized: "Connect to port (default: 22)", comment: "SFTP help: -P option"))
  -i file     \(String(localized: "Identity file (matches saved key names)", comment: "SFTP help: -i option"))
  -J host     \(String(localized: "Jump host (ProxyJump)", comment: "SFTP help: -J option"))
  -o option   \(String(localized: "SSH option (Port, ProxyJump, IdentityFile, PreferredAuthentications)", comment: "SFTP help: -o option"))

\(keystoreHeader)
  \(keystoreManaged)
  \(savedKeysMsg)
\(defaultKeyInfo)  \(keystoreSameAsSSH)

\(sftpHint)

\(examplesHeader)
  sftp user@host                \(String(localized: "Connect to host", comment: "SFTP help: connect example"))
  sftp -P 2222 user@host        \(String(localized: "Connect to alternate port", comment: "SFTP help: alternate port example"))
  sftp -J bastion user@target   \(String(localized: "Connect via jump host", comment: "SFTP help: jump host example"))

"""
        Task { @MainActor [weak self] in
            guard let self = self else { return }
            self.onOutput?(self.normalizeLineEndings(helpText))
            self.displayPrompt()
        }
    }

    /// Displays Mosh/Roam help with usage and keystore information
    func displayMoshHelp() {
        let keyManager = SSHKeyManager.shared
        let keyCount = keyManager.savedKeys.count
        var defaultKeyInfo = ""
        if let defaultID = keyManager.primaryDefaultKeyID,
           let defaultKey = keyManager.findKey(id: defaultID) {
            let name = defaultKey.name
            defaultKeyInfo = "  \(String(localized: "Default key:", comment: "SSH help: default key label")) \(name)\n"
        }

        let optionsHeader = String(localized: "Options:", comment: "Command help: options section header")
        let destHeader = String(localized: "Destination:", comment: "SSH help: destination section header")
        let keystoreHeader = String(localized: "Keystore:", comment: "SSH help: keystore section header")
        let keystoreManaged = String(localized: "Keys are managed in Settings > SSH Keys", comment: "SSH help: keystore managed note")
        let savedKeysMsg = String(localized: "You have \(keyCount) saved key(s)", comment: "SSH help: saved key count")
        let keystoreSelectKey = String(localized: "Use -i <keyname> to select a specific key", comment: "SSH help: select key note")
        let keystoreNoKey = String(localized: "If no key specified, uses default key or prompts for password", comment: "SSH help: no key note")
        let keystoreHistory = String(localized: "Connection history remembers which key was used per host", comment: "SSH help: connection history note")
        let aboutHeader = String(localized: "About Roam/Mosh:", comment: "Mosh help: about section header")
        let aboutDesc1 = String(localized: "Roam uses our mosh-compatible protocol for robust mobile connections.", comment: "Mosh help: about line 1")
        let aboutDesc2 = String(localized: "Unlike SSH, it survives network changes, high latency, and", comment: "Mosh help: about line 2")
        let aboutDesc3 = String(localized: "roaming between WiFi and cellular. Sessions persist even when", comment: "Mosh help: about line 3")
        let aboutDesc4 = String(localized: "the app is backgrounded.", comment: "Mosh help: about line 4")
        let examplesHeader = String(localized: "Examples:", comment: "Command help: examples section header")

        let helpText = """
usage: roam [-p port] [-l user] [-i identity] [-J jumphost] [-A|-AA] [--tmux|--herdr] [--predict mode] destination
       mosh [-p port] [-l user] [-i identity] [-J jumphost] [-A|-AA] [--tmux|--herdr] [--predict mode] destination

\(optionsHeader)
  -p port         \(String(localized: "Connect to this port (default: 22)", comment: "Mosh help: -p option"))
  -l user         \(String(localized: "Log in as this user", comment: "Mosh help: -l option"))
  -i identity     \(String(localized: "Use this key (matches saved key names)", comment: "Mosh help: -i option"))
  -J jumphost     \(String(localized: "Connect via jump host (ProxyJump)", comment: "Mosh help: -J option"))
  -A              \(String(localized: "Enable SSH agent forwarding", comment: "Mosh help: -A option"))
  -AA             \(String(localized: "Enable SSH agent forwarding with auto-approval", comment: "Mosh help: -AA option"))
  --tmux          \(String(localized: "Auto-start tmux on the remote host", comment: "Mosh help: --tmux option"))
  --herdr         \(String(localized: "Auto-start herdr on the remote host", comment: "Mosh help: --herdr option"))
  --predict mode  \(String(localized: "Prediction mode: always, adaptive, never (default: always)", comment: "Mosh help: --predict option"))
  --server path   \(String(localized: "Path to mosh-server on remote (default: mosh-server)", comment: "Mosh help: --server option"))

\(destHeader)
  [user@]host[:port]    \(String(localized: "Standard format", comment: "SSH help: standard destination format"))
  [IPv6]:port           \(String(localized: "IPv6 with port", comment: "SSH help: IPv6 destination format"))

\(keystoreHeader)
  \(keystoreManaged)
  \(savedKeysMsg)
\(defaultKeyInfo)  \(keystoreSelectKey)
  \(keystoreNoKey)
  \(keystoreHistory)

\(aboutHeader)
  \(aboutDesc1)
  \(aboutDesc2)
  \(aboutDesc3)
  \(aboutDesc4)

\(examplesHeader)
  roam user@host.example.com
  mosh -p 2222 admin@server
  roam -i mykey user@host
  roam -AA user@host
  mosh --predict=adaptive user@host
  roam -J bastion user@internal
  mosh --tmux user@host
  mosh --herdr user@host

"""
        Task { @MainActor [weak self] in
            guard let self = self else { return }
            self.onOutput?(self.normalizeLineEndings(helpText))
            self.displayPrompt()
        }
    }

    /// Displays ssh-copy-id help with usage information
    func displaySSHCopyIDHelp() {
        let keyManager = SSHKeyManager.shared
        let keyCount = keyManager.savedKeys.count
        let defaultCount = keyManager.defaultKeyIDs.count
        var defaultKeyInfo = ""
        if let defaultID = keyManager.primaryDefaultKeyID,
           let defaultKey = keyManager.findKey(id: defaultID) {
            let name = defaultKey.name
            defaultKeyInfo = "  \(String(localized: "Default key:", comment: "SSH help: default key label")) \(name)"
            if defaultCount > 1 {
                defaultKeyInfo += " (+ \(defaultCount - 1) \(String(localized: "more", comment: "SSH help: additional keys count")))"
            }
            defaultKeyInfo += "\n"
        }

        let optionsHeader = String(localized: "Options:", comment: "Command help: options section header")
        let keystoreHeader = String(localized: "Keystore:", comment: "SSH help: keystore section header")
        let keystoreManaged = String(localized: "Keys are managed in Settings > SSH Keys", comment: "SSH help: keystore managed note")
        let savedKeysMsg = String(localized: "You have \(keyCount) saved key(s)", comment: "SSH help: saved key count")
        let keystoreWithoutI = String(localized: "Without -i, installs all default keys (or all keys if no defaults set)", comment: "ssh-copy-id help: default behavior note")
        let whatItDoesHeader = String(localized: "What it does:", comment: "ssh-copy-id help: what it does header")
        let step1 = String(localized: "Connects to the remote server via SSH", comment: "ssh-copy-id help: step 1")
        let step2 = String(localized: "Checks for already-installed keys (unless -f)", comment: "ssh-copy-id help: step 2")
        let step3 = String(localized: "Appends new keys to authorized_keys with correct permissions", comment: "ssh-copy-id help: step 3")
        let step4 = String(localized: "Verifies installation", comment: "ssh-copy-id help: step 4")
        let examplesHeader = String(localized: "Examples:", comment: "Command help: examples section header")

        let helpText = """
usage: ssh-copy-id [-fnp] [-i identity] [-t target] [-o option] [user@]hostname

\(optionsHeader)
  -i identity   \(String(localized: "Install this specific key (matches saved key names)", comment: "ssh-copy-id help: -i option"))
  -f            \(String(localized: "Force mode: skip duplicate check", comment: "ssh-copy-id help: -f option"))
  -n            \(String(localized: "Dry run: preview what would be installed", comment: "ssh-copy-id help: -n option"))
  -p port       \(String(localized: "Connect to this port (default: 22)", comment: "ssh-copy-id help: -p option"))
  -t path       \(String(localized: "Target authorized_keys path (default: ~/.ssh/authorized_keys)", comment: "ssh-copy-id help: -t option"))
  -o option     \(String(localized: "SSH option (Port, User, IdentityFile)", comment: "ssh-copy-id help: -o option"))
  -h            \(String(localized: "Show this help", comment: "ssh-copy-id help: -h option"))

\(keystoreHeader)
  \(keystoreManaged)
  \(savedKeysMsg)
\(defaultKeyInfo)  \(keystoreWithoutI)

\(whatItDoesHeader)
  1. \(step1)
  2. \(step2)
  3. \(step3)
  4. \(step4)

\(examplesHeader)
  ssh-copy-id user@host                \(String(localized: "Install default keys", comment: "ssh-copy-id help: default example"))
  ssh-copy-id -i mykey user@host       \(String(localized: "Install specific key", comment: "ssh-copy-id help: specific key example"))
  ssh-copy-id -n user@host             \(String(localized: "Preview what would be installed", comment: "ssh-copy-id help: dry run example"))
  ssh-copy-id -f user@host             \(String(localized: "Force install (skip duplicate check)", comment: "ssh-copy-id help: force example"))
  ssh-copy-id -p 2222 user@host        \(String(localized: "Use alternate port", comment: "ssh-copy-id help: alternate port example"))

"""
        Task { @MainActor [weak self] in
            guard let self = self else { return }
            self.onOutput?(self.normalizeLineEndings(helpText))
            self.displayPrompt()
        }
    }

    /// Displays tssh/trzsz help with usage and keystore information
    func displayTrzszHelp() {
        let keyManager = SSHKeyManager.shared
        let keyCount = keyManager.savedKeys.count
        var defaultKeyInfo = ""
        if let defaultID = keyManager.primaryDefaultKeyID,
           let defaultKey = keyManager.findKey(id: defaultID) {
            let name = defaultKey.name
            defaultKeyInfo = "  \(String(localized: "Default key:", comment: "SSH help: default key label")) \(name)\n"
        }

        let optionsHeader = String(localized: "Options:", comment: "Command help: options section header")
        let destHeader = String(localized: "Destination:", comment: "SSH help: destination section header")
        let keystoreHeader = String(localized: "Keystore:", comment: "SSH help: keystore section header")
        let keystoreManaged = String(localized: "Keys are managed in Settings > SSH Keys", comment: "SSH help: keystore managed note")
        let savedKeysMsg = String(localized: "You have \(keyCount) saved key(s)", comment: "SSH help: saved key count")
        let keystoreSelectKey = String(localized: "Use -i <keyname> to select a specific key", comment: "SSH help: select key note")
        let keystoreNoKey = String(localized: "If no key specified, uses default key or prompts for password", comment: "SSH help: no key note")
        let keystoreHistory = String(localized: "Connection history remembers which key was used per host", comment: "SSH help: connection history note")
        let aboutHeader = String(localized: "About tssh/trzsz:", comment: "Trzsz help: about section header")
        let aboutDesc1 = String(localized: "tssh is a roaming SSH client with file transfer support via trzsz.", comment: "Trzsz help: about line 1")
        let aboutDesc2 = String(localized: "Like Roam/Mosh, it survives network changes and high latency.", comment: "Trzsz help: about line 2")
        let aboutDesc3 = String(localized: "Sessions persist even when the app is backgrounded.", comment: "Trzsz help: about line 3")
        let aboutDesc4 = String(localized: "Uses QUIC or KCP for reliable UDP transport.", comment: "Trzsz help: about line 4")
        let examplesHeader = String(localized: "Examples:", comment: "Command help: examples section header")

        let helpText = """
usage: tssh [-p port] [-l user] [-i identity] [-J jumphost] [-A|-AA] [--tmux|--herdr] [--quic|--kcp] destination
       trzsz [-p port] [-l user] [-i identity] [-J jumphost] [-A|-AA] [--tmux|--herdr] [--quic|--kcp] destination

\(optionsHeader)
  -p port         \(String(localized: "Connect to this port (default: 22)", comment: "Trzsz help: -p option"))
  -l user         \(String(localized: "Log in as this user", comment: "Trzsz help: -l option"))
  -i identity     \(String(localized: "Use this key (matches saved key names)", comment: "Trzsz help: -i option"))
  -J jumphost     \(String(localized: "Connect via jump host (ProxyJump)", comment: "Trzsz help: -J option"))
  -A              \(String(localized: "Enable SSH agent forwarding", comment: "Trzsz help: -A option"))
  -AA             \(String(localized: "Enable SSH agent forwarding with auto-approval", comment: "Trzsz help: -AA option"))
  --tmux          \(String(localized: "Auto-start tmux on the remote host", comment: "Trzsz help: --tmux option"))
  --herdr         \(String(localized: "Auto-start herdr on the remote host", comment: "Trzsz help: --herdr option"))
  --quic          \(String(localized: "Force QUIC transport mode", comment: "Trzsz help: --quic option"))
  --kcp           \(String(localized: "Force KCP transport mode", comment: "Trzsz help: --kcp option"))
  --server path   \(String(localized: "Path to tssh server on remote", comment: "Trzsz help: --server option"))

\(destHeader)
  [user@]host[:port]    \(String(localized: "Standard format", comment: "SSH help: standard destination format"))
  [IPv6]:port           \(String(localized: "IPv6 with port", comment: "SSH help: IPv6 destination format"))

\(keystoreHeader)
  \(keystoreManaged)
  \(savedKeysMsg)
\(defaultKeyInfo)  \(keystoreSelectKey)
  \(keystoreNoKey)
  \(keystoreHistory)

\(aboutHeader)
  \(aboutDesc1)
  \(aboutDesc2)
  \(aboutDesc3)
  \(aboutDesc4)

\(examplesHeader)
  tssh user@host.example.com
  trzsz -p 2222 admin@server
  tssh -i mykey user@host
  tssh -AA user@host
  tssh --quic user@host
  trzsz -J bastion user@internal
  tssh --tmux user@host
  tssh --herdr user@host

"""
        Task { @MainActor [weak self] in
            guard let self = self else { return }
            self.onOutput?(self.normalizeLineEndings(helpText))
            self.displayPrompt()
        }
    }
}

#endif // !targetEnvironment(macCatalyst)
