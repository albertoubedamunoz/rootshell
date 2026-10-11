#
# Demo shell integration for bash and zsh (fish: shell-integration-demo.fish).
# The shell reports itself and its foreground command, so rootshell can show
# the shell's logo at a prompt and the program's logo (and a Running card)
# while it runs.
#
# It sends OSC 133 prompt marks plus OSC 7501 records under ids rootshell
# reads as shell reports (see rootshell/Features/ProgramIdentity):
#
#   state=idle:id=rootshell.shell:app=zsh                      at each prompt
#   state=working:id=rootshell.shell/cmd:app=htop:title=<b64>  before a command
#
# Other terminals see ordinary OSC 7501 records, or ignore them.
#
# Usage, locally or on a remote host with a copy of this file:
#   source scripts/shell-integration-demo.sh
# or add that line to ~/.bashrc or ~/.zshrc.
#
if [ -z "${__rs_loaded-}" ] && { [ -n "${BASH_VERSION-}" ] || [ -n "${ZSH_VERSION-}" ]; } &&
    case $- in *i*) true ;; *) false ;; esac; then
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
