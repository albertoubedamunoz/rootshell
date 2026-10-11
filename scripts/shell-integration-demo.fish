#
# Demo shell integration for fish; see shell-integration-demo.sh for what it
# reports.
#
# Usage, locally or on a remote host with a copy of this file:
#   source scripts/shell-integration-demo.fish
# or add that line to ~/.config/fish/config.fish.
#
status is-interactive; or return
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
