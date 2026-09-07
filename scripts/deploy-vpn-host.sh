#!/bin/bash
# Rebuild the native VPN artifact bundled by rootshell-Standalone.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
cd "$PROJECT_DIR"

usage() {
    echo "Usage: $0 [--build-only] [--output /path/to/rootshellvpn.app]"
    echo
    echo "Default: universal Release build, Developer ID signing, notarization and"
    echo "stapling, then replacement of rootshell/Resources/rootshellvpn.app."
    echo "--build-only: unsigned compile check, saved to build/vpn-host/rootshellvpn.app."
    echo "              Cannot run as a VPN; never replaces the bundled artifact."
    echo
    echo "Signing identity comes from Configuration/Identity.xcconfig and its"
    echo "optional DeveloperSettings.xcconfig. Signed builds require:"
    echo "  DEVELOPER_ID    Exact Developer ID Application certificate name or SHA-1"
    echo "  NOTARY_PROFILE Keychain profile previously created with notarytool"
    echo "  HOST_PROFILE   Developer ID host provisioning profile"
    echo "  SYSEXT_PROFILE Developer ID tunnel provisioning profile"
    echo "  SIGNING_KEYCHAIN Optional keychain containing that signing identity"
    echo "Profiles default to scripts/rootshellvpn{,-tunnel}.provisionprofile."
    echo "Optional: VPN_BUNDLE_VERSION (UTC timestamp by default),"
    echo "          VPN_DERIVED_DATA (default: build/vpn-host/DerivedData)."
}

fail() { echo "ERROR: $*" >&2; exit 1; }
log() { echo "[$(date '+%H:%M:%S')] $*"; }
BUILD_ONLY=false
DEST=""
while [[ $# -gt 0 ]]; do
    case "$1" in
        --build-only) BUILD_ONLY=true; shift ;;
        --output) [[ $# -ge 2 && -n "$2" ]] || fail "--output needs a path"; DEST="$2"; shift 2 ;;
        --help|-h) usage; exit 0 ;;
        *) fail "Unknown option: $1 (see --help)" ;;
    esac
done
command -v python3 >/dev/null || fail "python3 is required"
BUNDLED="$PROJECT_DIR/rootshell/Resources/rootshellvpn.app"
if [[ -z "$DEST" ]]; then
    if $BUILD_ONLY; then DEST="$PROJECT_DIR/build/vpn-host/rootshellvpn.app"; else DEST="$BUNDLED"; fi
fi
[[ "$(basename "$DEST")" == rootshellvpn.app ]] || fail "--output must end in rootshellvpn.app"
mkdir -p "$(dirname "$DEST")"
DEST="$(cd "$(dirname "$DEST")" && pwd -P)/rootshellvpn.app"
[[ ! -L "$DEST" ]] || fail "Output must not be a symlink"
if $BUILD_ONLY && [[ "$DEST" == "$BUNDLED" ]]; then fail "--build-only cannot replace the bundled artifact"; fi
if ! $BUILD_ONLY; then
    [[ -n "${DEVELOPER_ID:-}" ]] || fail "Set DEVELOPER_ID to your Developer ID Application identity"
    [[ -n "${NOTARY_PROFILE:-}" ]] || fail "Set NOTARY_PROFILE to your notarytool keychain profile"
    HOST_PROFILE="${HOST_PROFILE:-$SCRIPT_DIR/rootshellvpn.provisionprofile}"
    SYSEXT_PROFILE="${SYSEXT_PROFILE:-$SCRIPT_DIR/rootshellvpn-tunnel.provisionprofile}"
    [[ -f "$HOST_PROFILE" ]] || fail "Missing HOST_PROFILE: $HOST_PROFILE"
    [[ -f "$SYSEXT_PROFILE" ]] || fail "Missing SYSEXT_PROFILE: $SYSEXT_PROFILE"
fi

WORK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/rootshell-vpn.XXXXXX")"
trap 'rm -rf "$WORK_DIR"' EXIT
VPN_BUNDLE_VERSION="${VPN_BUNDLE_VERSION:-$(date -u '+%Y%m%d%H%M%S')}"
[[ "$VPN_BUNDLE_VERSION" =~ ^[1-9][0-9]*$ ]] || fail "VPN_BUNDLE_VERSION must be a positive integer"
if [[ -d "$DEST" ]]; then
    OLD_VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$DEST/Contents/Info.plist")"
    python3 -c 'import sys; sys.exit(0 if int(sys.argv[1]) > int(sys.argv[2]) else 1)' \
        "$VPN_BUNDLE_VERSION" "$OLD_VERSION" || fail "VPN_BUNDLE_VERSION must exceed existing version $OLD_VERSION"
fi

BUILD_ARGS=(-project rootshell.xcodeproj -scheme rootshellvpn
    -configuration Release -destination 'generic/platform=macOS'
    -derivedDataPath "${VPN_DERIVED_DATA:-$PROJECT_DIR/build/vpn-host/DerivedData}"
    'ARCHS=arm64 x86_64' ONLY_ACTIVE_ARCH=NO
    "CONFIGURATION_BUILD_DIR=$WORK_DIR/products"
    "CURRENT_PROJECT_VERSION=$VPN_BUNDLE_VERSION"
    DEAD_CODE_STRIPPING=YES LLVM_LTO=YES_THIN
    CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY=)
log "Resolving VPN build identity..."
xcodebuild -project rootshell.xcodeproj -target rootshellvpn -target tunnel \
    -configuration Release -sdk macosx CODE_SIGNING_ALLOWED=NO \
    -showBuildSettings -json > "$WORK_DIR/settings.json"
if $BUILD_ONLY; then
    python3 "$SCRIPT_DIR/vpn-signing.py" "$WORK_DIR/settings.json" "$WORK_DIR"
else
    SIGNING_ARGS=(--host-profile "$HOST_PROFILE" --tunnel-profile "$SYSEXT_PROFILE"
        --signing-identity "$DEVELOPER_ID")
    if [[ -n "${SIGNING_KEYCHAIN:-}" ]]; then SIGNING_ARGS+=(--keychain "$SIGNING_KEYCHAIN"); fi
    python3 "$SCRIPT_DIR/vpn-signing.py" "$WORK_DIR/settings.json" "$WORK_DIR" "${SIGNING_ARGS[@]}"
fi
identity() { plutil -extract "$1" raw -o - "$WORK_DIR/identity.json"; }
TEAM_ID="$(identity team)"
HOST_ID="$(identity host_id)"
SYSEXT_ID="$(identity tunnel_id)"
log "Building $HOST_ID and $SYSEXT_ID (team $TEAM_ID, version $VPN_BUNDLE_VERSION)..."
xcodebuild "${BUILD_ARGS[@]}" build

APP="$WORK_DIR/products/rootshellvpn.app"
SYSEXT="$APP/Contents/Library/SystemExtensions/$SYSEXT_ID.systemextension"
[[ -d "$APP" && -d "$SYSEXT" ]] || fail "Build did not produce the expected host and system extension"
for bundle in "$APP" "$SYSEXT"; do
    executable="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' "$bundle/Contents/Info.plist")"
    xcrun lipo "$bundle/Contents/MacOS/$executable" -verify_arch arm64 x86_64
    xcrun strip -S -x "$bundle/Contents/MacOS/$executable"
done
if ! $BUILD_ONLY; then
    SIGNING_IDENTITY="$(identity signing_identity)"
    CODESIGN_ARGS=(--force --options runtime --timestamp --sign "$SIGNING_IDENTITY")
    if [[ -n "${SIGNING_KEYCHAIN:-}" ]]; then CODESIGN_ARGS+=(--keychain "$SIGNING_KEYCHAIN"); fi
    cp "$SYSEXT_PROFILE" "$SYSEXT/Contents/embedded.provisionprofile"
    cp "$HOST_PROFILE" "$APP/Contents/embedded.provisionprofile"
    log "Signing system extension and host..."
    codesign "${CODESIGN_ARGS[@]}" \
        --entitlements "$WORK_DIR/tunnel.entitlements" "$SYSEXT"
    codesign "${CODESIGN_ARGS[@]}" \
        --entitlements "$WORK_DIR/host.entitlements" "$APP"
    for bundle in "$SYSEXT" "$APP"; do
        codesign --verify --strict --verbose=2 "$bundle"
        info="$(codesign -dvv "$bundle" 2>&1)"
        [[ "$info" == *"Authority=Developer ID Application:"* ]] || fail "Not Developer ID signed: $bundle"
        [[ "$info" == *"TeamIdentifier=$TEAM_ID"* ]] || fail "Signing certificate belongs to a different team"
        codesign -d --extract-certificates="$WORK_DIR/signing-cert" "$bundle"
        actual_identity="$(shasum -a 1 "$WORK_DIR/signing-cert0" | awk '{print toupper($1)}')"
        [[ "$actual_identity" == "$SIGNING_IDENTITY" ]] || fail "Signed certificate differs from the profile-validated identity"
    done
    log "Notarizing and stapling..."
    ditto -c -k --keepParent "$APP" "$WORK_DIR/rootshellvpn.zip"
    xcrun notarytool submit "$WORK_DIR/rootshellvpn.zip" --keychain-profile "$NOTARY_PROFILE" --wait
    xcrun stapler staple "$APP"
    xcrun stapler validate "$APP"
    spctl --assess --verbose=2 --type execute "$APP"
fi

# Copy completely before replacing the old artifact. Keep a recoverable backup.
STAGE="$(mktemp -d "$(dirname "$DEST")/.vpn-stage.XXXXXX")"
ditto "$APP" "$STAGE/rootshellvpn.app"
if [[ -e "$DEST" ]]; then
    BACKUP="$PROJECT_DIR/build/vpn-host/backups"
    mkdir -p "$BACKUP"
    BACKUP="$(mktemp -d "$BACKUP/artifact.XXXXXX")/rootshellvpn.app"
    mv "$DEST" "$BACKUP"
    log "Previous artifact saved to $BACKUP"
fi
if ! mv "$STAGE/rootshellvpn.app" "$DEST"; then
    if [[ -n "${BACKUP:-}" ]]; then mv "$BACKUP" "$DEST"; fi
    fail "Could not install the new artifact"
fi
rmdir "$STAGE"
log "Created $DEST"
if $BUILD_ONLY; then
    log "Unsigned compile check only; use a signed, notarized build to run the VPN."
else
    log "Rebuild rootshell-Standalone to bundle this host. No system extension was activated."
fi
