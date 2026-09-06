#!/bin/bash
# Measure cold-launch time to first interactive session.
#
# Wall-clock from `open` until this process logs Ghostty "Session ready".
#
# Usage:
#   ./scripts/measure-cold-launch.sh [path-to.app] [iterations]
#
set -euo pipefail

APP="${1:-}"
ITERATIONS="${2:-5}"
SETTLE_SECONDS="${SETTLE_SECONDS:-3}"
TIMEOUT_SECONDS="${TIMEOUT_SECONDS:-90}"

if [[ -z "$APP" ]]; then
  matches=( "$HOME"/Library/Developer/Xcode/DerivedData/rootshell-*/Build/Products/DebugStandalone-maccatalyst/rootshell*.app )
  if [[ ${#matches[@]} -eq 1 && -d "${matches[0]}" ]]; then
    APP="${matches[0]}"
  else
    echo "usage: $0 /path/to/rootshell*.app [iterations]" >&2
    echo "found ${#matches[@]} candidate app(s); pass the path explicitly." >&2
    exit 1
  fi
fi

if [[ ! -d "$APP" ]]; then
  echo "app not found: $APP" >&2
  exit 1
fi

PROCESS_NAME=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' "$APP/Contents/Info.plist" 2>/dev/null || basename "$APP" .app)

echo "App:        $APP"
echo "Process:    $PROCESS_NAME"
echo "Iterations: $ITERATIONS"
echo "KPI:        wall-clock open → Session ready"
echo

kill_apps() {
  killall "$PROCESS_NAME" rootshell-helper 2>/dev/null || true
  if [[ "$PROCESS_NAME" != "rootshell" ]]; then
    killall rootshell 2>/dev/null || true
  fi
  sleep "$SETTLE_SECONDS"
}

median() {
  local -a sorted=()
  local n line
  if (($# == 0)); then
    echo "n/a"
    return
  fi
  while IFS= read -r line; do
    sorted+=("$line")
  done < <(printf '%s\n' "$@" | sort -n)
  n=${#sorted[@]}
  if ((n % 2 == 1)); then
    echo "${sorted[$((n / 2))]}"
  else
    local a="${sorted[$((n / 2 - 1))]}"
    local b="${sorted[$((n / 2))]}"
    echo $(((a + b) / 2))
  fi
}

samples=()

for ((i = 1; i <= ITERATIONS; i++)); do
  echo "── run $i/$ITERATIONS ──"
  kill_apps

  log_file=$(mktemp)
  /usr/bin/log stream \
    --level info \
    --style compact \
    --predicate 'subsystem == "com.kk2.rootshell" AND category == "ghostty"' \
    >"$log_file" 2>&1 &
  log_pid=$!
  sleep 1

  start_ns=$(python3 -c 'import time; print(time.time_ns())')
  open -n "$APP"

  # Wait for the new process, then require its PID in the ready line so we
  # never accept a stale "Session ready" replayed from a prior launch.
  pid=""
  deadline=$((SECONDS + TIMEOUT_SECONDS))
  while (( SECONDS < deadline )); do
    pid=$(pgrep -n -x "$PROCESS_NAME" 2>/dev/null || true)
    if [[ -n "$pid" ]]; then
      break
    fi
    sleep 0.05
  done

  if [[ -z "$pid" ]]; then
    kill "$log_pid" 2>/dev/null || true
    wait "$log_pid" 2>/dev/null || true
    rm -f "$log_file"
    echo "  TIMEOUT: process $PROCESS_NAME did not start" >&2
    continue
  fi

  ready=0
  # Match: <process>[<pid>:...] ... Session ready
  ready_pattern="${PROCESS_NAME}\\[${pid}:"
  while (( SECONDS < deadline )); do
    if grep -E "${ready_pattern}" "$log_file" 2>/dev/null | grep -F 'Session ready' >/dev/null 2>&1; then
      ready=1
      break
    fi
    sleep 0.1
  done
  end_ns=$(python3 -c 'import time; print(time.time_ns())')

  kill "$log_pid" 2>/dev/null || true
  wait "$log_pid" 2>/dev/null || true
  rm -f "$log_file"

  if (( ready == 0 )); then
    echo "  TIMEOUT: no Session ready for pid $pid within ${TIMEOUT_SECONDS}s" >&2
    continue
  fi

  ms=$(( (end_ns - start_ns) / 1000000 ))
  samples+=("$ms")
  echo "  open → Session ready: ${ms}ms (pid $pid)"
done

kill_apps

echo
echo "══ summary ══"
echo "open→Session ready  n=${#samples[@]}  median=$(median "${samples[@]:-}")ms  samples=${samples[*]:-none}"
