#!/bin/bash
#
# uninstall-helper.sh
#
# Removes what scripts/install-helper.sh set up: stops the LaunchAgent, deletes
# its plist, the installed rootshell-helper.app, and its log. The Standalone
# app's own embedded helper is not touched.

set -euo pipefail

LABEL="com.kk2.rootshell-helper"
HELPER_BUNDLE_ID="com.kk2.rootshell-helper"
HELPER_NAME="rootshell-helper.app"

PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
LOG="$HOME/Library/Logs/rootshell-helper.log"
DOMAIN="gui/$(id -u)"
KEEP_APP=0
APP=""

usage() {
    cat <<USAGE
Usage: uninstall-helper.sh [OPTIONS]

Stops the rootshell-helper LaunchAgent and removes it. The installed helper's
location is read from the LaunchAgent; if that is already gone, it falls back
to /Applications/$HELPER_NAME.

OPTIONS
  -a, --app PATH    The installed $HELPER_NAME to remove, overriding the
                    location found above.

      --keep-app    Stop and unregister the helper but leave the app in place.

  -h, --help        Show this help.

Local shells open through this helper are closed.
USAGE
}

die() { echo "error: $*" >&2; exit 1; }

while [ $# -gt 0 ]; do
    case "$1" in
        -a|--app) [ $# -ge 2 ] || die "$1 needs a path"; APP="$2"; shift 2 ;;
        --keep-app) KEEP_APP=1; shift ;;
        -h|--help) usage; exit 0 ;;
        *) usage >&2; die "unknown option: $1" ;;
    esac
done

if [ -z "$APP" ] && [ -f "$PLIST" ]; then
    EXEC=$(/usr/libexec/PlistBuddy -c "Print :ProgramArguments:0" "$PLIST" 2>/dev/null || true)
    [ -n "$EXEC" ] && APP="${EXEC%/Contents/MacOS/*}"
fi
APP="${APP:-/Applications/$HELPER_NAME}"
APP="${APP%/}"

# Never delete anything but the helper, and never from inside another app.
if [ "$KEEP_APP" -eq 0 ] && [ -e "$APP" ]; then
    BUNDLE_ID=$(/usr/libexec/PlistBuddy -c "Print :CFBundleIdentifier" "$APP/Contents/Info.plist" 2>/dev/null || true)
    [ "$BUNDLE_ID" = "$HELPER_BUNDLE_ID" ] || die "$APP is not $HELPER_BUNDLE_ID; not removing it"
    case "$APP" in
        */Contents/Helpers/*) die "$APP is embedded in another app; not removing it" ;;
    esac
fi

if launchctl print "$DOMAIN/$LABEL" >/dev/null 2>&1; then
    echo "Stopping the helper"
    launchctl bootout "$DOMAIN/$LABEL" 2>/dev/null || true
else
    echo "The helper is not loaded"
fi

if [ -f "$PLIST" ]; then
    rm -f "$PLIST"
    echo "Removed $PLIST"
fi

if [ "$KEEP_APP" -eq 0 ] && [ -e "$APP" ]; then
    rm -rf "$APP"
    echo "Removed $APP"
fi

if [ -f "$LOG" ]; then
    rm -f "$LOG"
    echo "Removed $LOG"
fi

echo "Uninstalled."
