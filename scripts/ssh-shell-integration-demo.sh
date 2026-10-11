#!/usr/bin/env bash
#
# Demo shell integration for plain SSH sessions. The remote shell reports
# itself and its foreground command, so rootshell can show the shell's logo
# at a prompt and the program's logo (and a Running card) while it runs.
#
# It sends OSC 133 prompt marks plus OSC 7501 records under ids rootshell
# reads as shell reports (see rootshell/Features/ProgramIdentity):
#
#   state=idle:id=rootshell.shell:app=zsh                      at each prompt
#   state=working:id=rootshell.shell/cmd:app=htop:title=<b64>  before a command
#
# Other terminals see ordinary OSC 7501 records, or ignore them.
#
# Usage:
#   scripts/ssh-shell-integration-demo.sh [ssh options] destination
#       ssh in with the integration loaded for bash, zsh or fish. Nothing is
#       installed: the files live in a mktemp directory removed at startup.
#
#   scripts/ssh-shell-integration-demo.sh --snippet [fish]
#       print the integration to source by hand, e.g. on a host reached
#       through rootshell's own SSH client:
#         source <(scripts/ssh-shell-integration-demo.sh --snippet)   # bash, zsh
#
set -euo pipefail

posix_snippet() {
    cat <<'RSEOF'
# rootshell demo shell integration (bash, zsh)
if [ -z "${__rs_loaded-}" ] && { [ -n "${BASH_VERSION-}" ] || [ -n "${ZSH_VERSION-}" ]; }; then
__rs_loaded=1
if [ -n "${ZSH_VERSION-}" ]; then __rs_shell=zsh; else __rs_shell=bash; fi

__rs_osc() { printf '\033]%s\033\\' "$1"; }

__rs_report_command() {
    local cmd word app title
    cmd=${1//[[:cntrl:]]/ }
    # The title holds at most 192 bytes once decoded.
    cmd=${cmd:0:180}
    while [ "$(printf %s "$cmd" | wc -c)" -gt 180 ]; do cmd=${cmd%?}; done
    word=${cmd#"${cmd%%[![:space:]]*}"}
    word=${word%%[[:space:]]*}
    word=${word##*/}
    app=${word//[^A-Za-z0-9_.+-]/}
    app=${app:0:32}
    [ -n "$app" ] || app=command
    title=$(printf %s "$cmd" | base64 | tr -d '\n')
    __rs_osc "133;C"
    __rs_osc "7501;state=working:id=rootshell.shell/cmd:app=${app}:title=${title}"
}

__rs_prompt() {
    local code=$1
    if [ -n "${__rs_ran-}" ]; then
        __rs_osc "133;D;${code}"
        __rs_osc "7501;state=clear:id=rootshell.shell/cmd"
        __rs_ran=
    fi
    __rs_osc "7501;state=idle:id=rootshell.shell:app=${__rs_shell}"
    __rs_osc "133;A"
}

if [ "$__rs_shell" = zsh ]; then
    __rs_preexec() { __rs_ran=1; __rs_report_command "$1"; }
    __rs_precmd() { __rs_prompt $?; }
    autoload -Uz add-zsh-hook
    add-zsh-hook preexec __rs_preexec
    add-zsh-hook precmd __rs_precmd
else
    __rs_ready=
    __rs_debug() {
        [ -n "$__rs_ready" ] || return 0
        [ -z "${COMP_LINE-}" ] || return 0
        __rs_ready=
        __rs_ran=1
        local line
        line=$(HISTTIMEFORMAT= builtin history 1 2>/dev/null)
        # "  123  cmd" -> "cmd"; history may be off, so fall back.
        line=${line#"${line%%[![:space:]]*}"}
        line=${line#*[[:space:]]}
        line=${line#"${line%%[![:space:]]*}"}
        __rs_report_command "${line:-$BASH_COMMAND}"
    }
    __rs_precmd() { __rs_prompt "$__rs_status"; __rs_ready=1; }
    trap '__rs_debug' DEBUG
    PROMPT_COMMAND="__rs_status=\$?${PROMPT_COMMAND:+;$PROMPT_COMMAND};__rs_precmd"
fi
fi
RSEOF
}

fish_snippet() {
    cat <<'RSEOF'
# rootshell demo shell integration (fish)
if not set -q __rs_loaded
set -g __rs_loaded 1
# fish 4 sends OSC 133 itself; a second set would count every command twice.
set -g __rs_marks 1
if test (string split -f1 . -- $version) -ge 4
    set -e __rs_marks
end

function __rs_osc
    printf '\e]%s\e\\' $argv[1]
end

function __rs_preexec --on-event fish_preexec
    set -g __rs_ran 1
    set -l cmd (string replace -ra '[[:cntrl:]]' ' ' -- "$argv[1]")
    # The title holds at most 192 bytes once decoded.
    set cmd (string sub -l 180 -- "$cmd")
    while test (printf %s "$cmd" | wc -c) -gt 180
        set cmd (string sub -l (math (string length -- "$cmd") - 1) -- "$cmd")
    end
    set -l word (string split -n -m1 ' ' -- (string trim -- "$cmd"))[1]
    set -l app (string replace -ra '[^A-Za-z0-9_.+-]' '' -- (string replace -r '.*/' '' -- "$word"))
    set app (string sub -l 32 -- "$app")
    test -n "$app"; or set app command
    set -l title (printf %s "$cmd" | base64 | tr -d '\n')
    set -q __rs_marks; and __rs_osc "133;C"
    __rs_osc "7501;state=working:id=rootshell.shell/cmd:app=$app:title=$title"
end

function __rs_postexec --on-event fish_postexec
    set -l code $status
    set -q __rs_marks; and __rs_osc "133;D;$code"
    __rs_osc "7501;state=clear:id=rootshell.shell/cmd"
    set -e __rs_ran
end

function __rs_prompt --on-event fish_prompt
    __rs_osc "7501;state=idle:id=rootshell.shell:app=fish"
    set -q __rs_marks; and __rs_osc "133;A"
end
end
RSEOF
}

# Runs on the remote host under /bin/sh with the temp directory as $1. It
# writes the integration there, removes itself, and execs the login shell.
remote_boot() {
    cat <<'BOOTEOF'
d=$1
rm -f "$d/boot.sh"
shell=$(basename "${SHELL:-sh}")
case $shell in
bash)
    cat > "$d/rootshell.sh" <<'RSEOF'
BOOTEOF
    posix_snippet
    cat <<'BOOTEOF'
RSEOF
    cat > "$d/bashrc" <<RSEOF
# Read the login files bash -l would have, then the integration.
if [ -f ~/.bash_profile ]; then . ~/.bash_profile
elif [ -f ~/.bash_login ]; then . ~/.bash_login
elif [ -f ~/.profile ]; then . ~/.profile
fi
. "$d/rootshell.sh"
rm -f "$d/rootshell.sh" "$d/bashrc"
rmdir "$d"
RSEOF
    exec bash --rcfile "$d/bashrc" -i
    ;;
zsh)
    cat > "$d/rootshell.sh" <<'RSEOF'
BOOTEOF
    posix_snippet
    cat <<'BOOTEOF'
RSEOF
    # zsh reads .zshenv from ZDOTDIR; ours restores the user's ZDOTDIR so
    # .zprofile and .zshrc come from the usual place.
    cat > "$d/.zshenv" <<RSEOF
if [ -n "\${__RS_ZDOTDIR+x}" ]; then ZDOTDIR=\$__RS_ZDOTDIR; else unset ZDOTDIR; fi
unset __RS_ZDOTDIR
[ -f "\${ZDOTDIR:-\$HOME}/.zshenv" ] && . "\${ZDOTDIR:-\$HOME}/.zshenv"
. "$d/rootshell.sh"
rm -f "$d/rootshell.sh" "$d/.zshenv"
rmdir "$d"
RSEOF
    if [ -n "${ZDOTDIR+x}" ]; then export __RS_ZDOTDIR="$ZDOTDIR"; fi
    ZDOTDIR=$d exec zsh -l
    ;;
fish)
    cat > "$d/rootshell.fish" <<'RSEOF'
BOOTEOF
    fish_snippet
    cat <<'BOOTEOF'
RSEOF
    exec fish -l -C "source '$d/rootshell.fish'; rm -f '$d/rootshell.fish'; rmdir '$d'"
    ;;
*)
    echo "rootshell demo: no integration for $shell, starting it plain" >&2
    rmdir "$d"
    exec "${SHELL:-sh}" -l
    ;;
esac
BOOTEOF
}

case "${1-}" in
--snippet)
    if [ "${2-}" = fish ]; then fish_snippet; else posix_snippet; fi
    exit 0
    ;;
-h|--help|"")
    sed -n '2,24p' "$0" | sed 's/^# \{0,1\}//'
    exit 0
    ;;
esac

boot=$(remote_boot | base64 | tr -d '\n')
# Single quotes only, so the remote login shell (sh, bash, zsh or fish)
# passes the script to /bin/sh untouched.
remote="exec sh -c 'd=\$(mktemp -d) && echo $boot | base64 -d > \"\$d/boot.sh\" && exec sh \"\$d/boot.sh\" \"\$d\"'"
exec ssh -t "$@" "$remote"
