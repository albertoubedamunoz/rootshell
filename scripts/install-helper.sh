#!/bin/bash
#
# install-helper.sh
#
# Copies rootshell-helper out of the Standalone build and registers it as a
# per-user LaunchAgent, so the sandboxed App Store / TestFlight build can open
# local shells. The helper starts at login and is restarted if it exits.
#
# Undo with scripts/uninstall-helper.sh.

set -euo pipefail

LABEL="com.kk2.rootshell-helper"
HELPER_BUNDLE_ID="com.kk2.rootshell-helper"
TEAM_ID="D97ZME3ET2"
APP_GROUP="group.com.kk2.ghostty"
HELPER_NAME="rootshell-helper.app"

FROM="/Applications/rootshell.app"
DEST_DIR="/Applications"
ALLOW_UNNOTARIZED=0

PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
LOG="$HOME/Library/Logs/rootshell-helper.log"
SOCKET="$HOME/Library/Group Containers/$APP_GROUP/commands.sock"
DOMAIN="gui/$(id -u)"

usage() {
    cat <<USAGE
Usage: install-helper.sh [OPTIONS]

Installs rootshell-helper from the Standalone build and starts it at login.
Running it again updates an existing install in place.

OPTIONS
  -d, --dest DIR          Directory to install $HELPER_NAME into.
                          Default: $DEST_DIR

  -f, --from PATH         The Standalone rootshell.app to copy the helper from,
                          or a $HELPER_NAME directly.
                          Default: $FROM

      --allow-unnotarized Skip the Gatekeeper notarization check. The team and
                          identifier are still verified. For development builds
                          signed with Apple Development.

  -h, --help              Show this help.
USAGE
}

die() { echo "error: $*" >&2; exit 1; }

while [ $# -gt 0 ]; do
    case "$1" in
        -d|--dest) [ $# -ge 2 ] || die "$1 needs a directory"; DEST_DIR="$2"; shift 2 ;;
        -f|--from) [ $# -ge 2 ] || die "$1 needs a path"; FROM="$2"; shift 2 ;;
        --allow-unnotarized) ALLOW_UNNOTARIZED=1; shift ;;
        -h|--help) usage; exit 0 ;;
        *) usage >&2; die "unknown option: $1" ;;
    esac
done

bundle_id() {
    /usr/libexec/PlistBuddy -c "Print :CFBundleIdentifier" "$1/Contents/Info.plist" 2>/dev/null || true
}

# Resolve the source helper: either the Standalone app's embedded copy or a
# helper bundle passed directly.
FROM="${FROM%/}"
if [ "$(bundle_id "$FROM")" = "$HELPER_BUNDLE_ID" ]; then
    SRC="$FROM"
else
    SRC="$FROM/Contents/Helpers/$HELPER_NAME"
    [ -d "$SRC" ] || die "no helper at $SRC
Is $FROM the Standalone build? The App Store build does not include the helper.
Pass the Standalone app with --from."
fi
[ "$(bundle_id "$SRC")" = "$HELPER_BUNDLE_ID" ] || die "$SRC is not $HELPER_BUNDLE_ID"

echo "Verifying $SRC"
codesign --verify --strict "$SRC" || die "code signature is invalid"
REQUIREMENT="identifier \"$HELPER_BUNDLE_ID\" and anchor apple generic and certificate leaf[subject.OU] = \"$TEAM_ID\""
codesign --verify -R="$REQUIREMENT" "$SRC" 2>/dev/null \
    || die "not signed by team $TEAM_ID as $HELPER_BUNDLE_ID"
if [ "$ALLOW_UNNOTARIZED" -eq 0 ]; then
    spctl --assess --type execute "$SRC" 2>/dev/null \
        || die "Gatekeeper rejected the helper (not notarized?). Use --allow-unnotarized for a development build."
fi

DEST_DIR="${DEST_DIR%/}"
DEST="$DEST_DIR/$HELPER_NAME"
EXECUTABLE="$DEST/Contents/MacOS/rootshell-helper"
[ "$SRC" != "$DEST" ] || die "source and destination are the same: $DEST"

# Only replace something that is itself the helper.
if [ -e "$DEST" ] && [ "$(bundle_id "$DEST")" != "$HELPER_BUNDLE_ID" ]; then
    die "$DEST exists and is not $HELPER_BUNDLE_ID; refusing to replace it"
fi

# Stop a previous install before replacing its files.
if launchctl print "$DOMAIN/$LABEL" >/dev/null 2>&1; then
    echo "Stopping the running helper"
    launchctl bootout "$DOMAIN/$LABEL" 2>/dev/null || true
fi

# Note a previous install elsewhere; it is left in place.
if [ -f "$PLIST" ]; then
    OLD_EXEC=$(/usr/libexec/PlistBuddy -c "Print :ProgramArguments:0" "$PLIST" 2>/dev/null || true)
    if [ -n "$OLD_EXEC" ] && [ "$OLD_EXEC" != "$EXECUTABLE" ]; then
        echo "note: a previous install at ${OLD_EXEC%/Contents/MacOS/*} is no longer used; remove it if you like"
    fi
fi

echo "Installing to $DEST"
mkdir -p "$DEST_DIR"
[ -w "$DEST_DIR" ] || die "cannot write to $DEST_DIR; choose another with --dest"
STAGING="$DEST_DIR/.$HELPER_NAME.installing"
rm -rf "$STAGING"
ditto "$SRC" "$STAGING"
rm -rf "$DEST"
mv "$STAGING" "$DEST"

mkdir -p "$(dirname "$PLIST")" "$(dirname "$LOG")"
cat > "$PLIST" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>$LABEL</string>
    <key>ProgramArguments</key>
    <array>
        <string>$EXECUTABLE</string>
        <string>--app-group</string>
        <string>$APP_GROUP</string>
    </array>
    <key>AssociatedBundleIdentifiers</key>
    <string>$HELPER_BUNDLE_ID</string>
    <key>LimitLoadToSessionType</key>
    <string>Aqua</string>
    <key>ProcessType</key>
    <string>Interactive</string>
    <key>RunAtLoad</key>
    <true/>
    <key>KeepAlive</key>
    <true/>
    <key>StandardErrorPath</key>
    <string>$LOG</string>
</dict>
</plist>
PLIST
plutil -lint -s "$PLIST" || die "generated an invalid $PLIST"

echo "Starting the helper"
launchctl bootstrap "$DOMAIN" "$PLIST"

# The helper binds its socket within milliseconds of starting.
for _ in $(seq 1 30); do
    [ -S "$SOCKET" ] && break
    sleep 0.1
done

PID=$(launchctl print "$DOMAIN/$LABEL" 2>/dev/null | awk '/^\tpid = / { print $3 }')
if [ -n "$PID" ] && [ -S "$SOCKET" ]; then
    echo "Installed. rootshell-helper is running (pid $PID) and will start at login."
    echo "If it stops appearing after a reboot, allow it under System Settings > General > Login Items & Extensions."
else
    echo "Installed, but the helper does not appear to be running. See $LOG" >&2
    exit 1
fi
