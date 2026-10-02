#!/bin/sh
# Run from the repository root; requires util-linux script and base64.
set -eu
test_dir=$(mktemp -d "${TMPDIR:-/tmp}/rootshell-open-test.XXXXXX")
trap 'rm -f "$test_dir/direct" "$test_dir/tmux" "$test_dir/expected" "$test_dir/clipboard" "$test_dir/clipboard-second" "$test_dir/wrapper"; rmdir "$test_dir"' EXIT HUP INT TERM

url='https://example.com/path?q=a&b=c#anchor'
encoded=$(printf '%s' "$url" | base64 | tr -d '\r\n')

# stdout is redirected by script; /dev/tty must still reach the PTY master.
env -u TMUX script -q -e -c "./scripts/rootshell-open '$url'" /dev/null > "$test_dir/direct"
printf '\033]1337;OpenURL=:%s\007' "$encoded" > "$test_dir/expected"
cmp "$test_dir/expected" "$test_dir/direct"

TMUX=test script -q -e -c "./scripts/rootshell-open '$url'" /dev/null > "$test_dir/tmux"
printf '\033Ptmux;\033\033]1337;OpenURL=:%s\007\033\\' "$encoded" > "$test_dir/expected"
cmp "$test_dir/expected" "$test_dir/tmux"

# --clipboard must stay unwrapped even inside tmux: native pane parsing and
# Mosh's c-selector clipboard state must receive the OSC 52 itself.
TMUX=test script -q -e -c "./scripts/rootshell-open --clipboard '$url'" /dev/null > "$test_dir/clipboard"
prefix=$(printf '\033]52;c;')
suffix=$(printf '\007')
wire=$(cat "$test_dir/clipboard")
case "$wire" in
    "$prefix"*"$suffix") ;;
    *) printf 'Missing unwrapped OSC 52 request\n' >&2; exit 1 ;;
esac
encoded_payload=${wire#"$prefix"}
encoded_payload=${encoded_payload%"$suffix"}
payload=$(printf '%s' "$encoded_payload" | base64 -d)
case "$payload" in
    rootshell-open-url:v1:*:"$url") ;;
    *) printf 'Invalid URL request envelope\n' >&2; exit 1 ;;
esac
request_fields=${payload#rootshell-open-url:v1:}
request_time=${request_fields%%:*}
request_fields=${request_fields#*:}
request_id=${request_fields%%:*}
case "$request_time" in ''|*[!0-9]*) exit 1 ;; esac
case "$request_id" in ''|*[!0-9a-f]*) exit 1 ;; esac
test "${#request_id}" -eq 32
env -u TMUX script -q -e -c "./scripts/rootshell-open --clipboard '$url'" /dev/null > "$test_dir/clipboard-second"
if cmp -s "$test_dir/clipboard" "$test_dir/clipboard-second"; then
    printf 'Repeated URL reused its request ID\n' >&2
    exit 1
fi

# The single-path wrapper must produce the same unwrapped clipboard request.
TMUX=test script -q -e -c "./scripts/rootshell-open-clipboard '$url'" /dev/null > "$test_dir/wrapper"
wire=$(cat "$test_dir/wrapper")
case "$wire" in
    "$prefix"*"$suffix") ;;
    *) printf 'Wrapper did not send an OSC 52 request\n' >&2; exit 1 ;;
esac
encoded_payload=${wire#"$prefix"}
encoded_payload=${encoded_payload%"$suffix"}
case "$(printf '%s' "$encoded_payload" | base64 -d)" in
    rootshell-open-url:v1:*:"$url") ;;
    *) printf 'Invalid wrapper envelope\n' >&2; exit 1 ;;
esac

for invalid in 'file:///etc/passwd' 'javascript:alert(1)'; do
    if ./scripts/rootshell-open "$invalid" >/dev/null 2>&1; then
        printf 'Unexpected success for %s\n' "$invalid" >&2
        exit 1
    fi
done
if ./scripts/rootshell-open >/dev/null 2>&1; then exit 1; fi
if ./scripts/rootshell-open "$url" extra >/dev/null 2>&1; then exit 1; fi
if ./scripts/rootshell-open --clipboard >/dev/null 2>&1; then exit 1; fi
printf 'rootshell-open PTY and argument checks passed\n'
