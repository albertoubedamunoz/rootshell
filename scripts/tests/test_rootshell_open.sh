#!/bin/sh
# Run from the repository root; requires util-linux script and base64.
set -eu
test_dir=$(mktemp -d "${TMPDIR:-/tmp}/rootshell-open-test.XXXXXX")
trap 'rm -f "$test_dir/direct" "$test_dir/tmux" "$test_dir/expected"; rmdir "$test_dir"' EXIT HUP INT TERM

url='https://example.com/path?q=a&b=c#anchor'
encoded=$(printf '%s' "$url" | base64 | tr -d '\r\n')

# stdout is redirected by script; /dev/tty must still reach the PTY master.
env -u TMUX script -q -e -c "./scripts/rootshell-open '$url'" /dev/null > "$test_dir/direct"
printf '\033]777;rootshell;open-url;%s\007' "$encoded" > "$test_dir/expected"
cmp "$test_dir/expected" "$test_dir/direct"

TMUX=test script -q -e -c "./scripts/rootshell-open '$url'" /dev/null > "$test_dir/tmux"
printf '\033Ptmux;\033\033]777;rootshell;open-url;%s\007\033\\' "$encoded" > "$test_dir/expected"
cmp "$test_dir/expected" "$test_dir/tmux"

for invalid in 'file:///etc/passwd' 'javascript:alert(1)'; do
    if ./scripts/rootshell-open "$invalid" >/dev/null 2>&1; then
        printf 'Unexpected success for %s\n' "$invalid" >&2
        exit 1
    fi
done
if ./scripts/rootshell-open >/dev/null 2>&1; then exit 1; fi
if ./scripts/rootshell-open "$url" extra >/dev/null 2>&1; then exit 1; fi
printf 'rootshell-open PTY and argument checks passed\n'
