#!/bin/sh
# Run from the repository root; requires tmux and util-linux script.
set -eu
test_dir=$(mktemp -d "${TMPDIR:-/tmp}/rootshell-open-tmux.XXXXXX")
cleanup() {
    tmux -S "$test_dir/socket" kill-server >/dev/null 2>&1 || true
    rm -f "$test_dir/socket" "$test_dir/output"
    rmdir "$test_dir"
}
trap cleanup EXIT HUP INT TERM

script -q -e -c "tmux -S '$test_dir/socket' -f /dev/null -CC new-session -s url-test 'sleep 1; ./scripts/rootshell-open --clipboard https://example.com/native; sleep 1'" /dev/null > "$test_dir/output"
encoded=$(sed -n 's/.*\\033]52;c;\([^\\]*\)\\007.*/\1/p' "$test_dir/output")
test -n "$encoded"
payload=$(printf '%s' "$encoded" | base64 -d)
case "$payload" in
    rootshell-open-url:v1:*:https://example.com/native) ;;
    *) printf 'Native tmux did not forward the URL envelope\n' >&2; exit 1 ;;
esac
printf 'Native tmux -CC URL transport passed\n'
