#!/bin/bash
set -euo pipefail

# Create a project-local Zig library tree with the Darwin visionOS/tvOS fixes
# required by GhosttyKit. The installed Zig toolchain is never modified.
#
# Usage: patch-zig.sh --zig <zig executable> --output <directory>

ZIG_BIN=""
OUTPUT_DIR=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --zig)
            ZIG_BIN="${2:-}"
            shift 2
            ;;
        --output)
            OUTPUT_DIR="${2:-}"
            shift 2
            ;;
        *)
            echo "ERROR: unknown option: $1" >&2
            exit 1
            ;;
    esac
done

if [[ -z "$ZIG_BIN" || ! -x "$ZIG_BIN" ]]; then
    echo "ERROR: --zig must name an executable Zig compiler" >&2
    exit 1
fi
if [[ -z "$OUTPUT_DIR" ]]; then
    echo "ERROR: --output is required" >&2
    exit 1
fi

ZIG_ENV="$($ZIG_BIN env)"
SOURCE_LIB_DIR="$(sed -n 's/^[[:space:]]*\.lib_dir = "\([^"]*\)",/\1/p' <<<"$ZIG_ENV")"
if [[ -z "$SOURCE_LIB_DIR" || ! -d "$SOURCE_LIB_DIR/std" ]]; then
    echo "ERROR: could not determine Zig lib_dir from '$ZIG_BIN env'" >&2
    exit 1
fi

VERSION="$($ZIG_BIN version)"
MARKER="$OUTPUT_DIR/.rootshell-zig-version"
TOOLCHAIN_ID="$VERSION|$SOURCE_LIB_DIR"
if [[ ! -f "$MARKER" || "$(<"$MARKER")" != "$TOOLCHAIN_ID" ]]; then
    rm -rf "$OUTPUT_DIR"
    mkdir -p "$OUTPUT_DIR"
    ditto "$SOURCE_LIB_DIR" "$OUTPUT_DIR"
    printf '%s\n' "$TOOLCHAIN_ID" > "$MARKER"
fi

ABI="$OUTPUT_DIR/std/debug/Dwarf/abi.zig"
C="$OUTPUT_DIR/std/c.zig"
FS="$OUTPUT_DIR/std/fs.zig"
DIR="$OUTPUT_DIR/std/fs/Dir.zig"

for file in "$ABI" "$C" "$FS" "$DIR"; do
    if [[ ! -f "$file" ]]; then
        echo "ERROR: expected Zig stdlib file missing: $file" >&2
        exit 1
    fi
done

replace_line() {
    local file="$1" from="$2" to="$3" label="$4"
    if grep -qF "$to" "$file"; then
        return
    fi
    if ! grep -qF "$from" "$file"; then
        echo "ERROR: unsupported Zig stdlib layout while patching $label" >&2
        exit 1
    fi
    sed -i '' "s|$from|$to|" "$file"
}

replace_line "$ABI" \
    '            .macos, .ios, .watchos => switch (reg_number) {' \
    '            .macos, .ios, .tvos, .watchos, .visionos => switch (reg_number) {' \
    "Darwin aarch64 mcontext"

# Zig 0.15.2 only selects Darwin's 64-bit inode symbol variants for macOS.
# Mac Catalyst is represented as iOS + macabi, so x86_64 Catalyst otherwise
# calls the legacy symbols while interpreting their output as the modern ABI.
replace_line "$C" \
    '    .macos => switch (native_arch) {' \
    '    .macos, .ios, .tvos, .watchos, .visionos => switch (native_arch) {' \
    "Darwin x86_64 inode symbols"

INODE_SELECTOR_COUNT="$(grep -cF '    .macos, .ios, .tvos, .watchos, .visionos => switch (native_arch) {' "$C" || true)"
if [[ "$INODE_SELECTOR_COUNT" -ne 4 ]]; then
    echo "ERROR: expected four patched Darwin inode symbol selectors; found $INODE_SELECTOR_COUNT" >&2
    exit 1
fi

replace_line "$FS" \
    '    .linux, .macos, .ios, .freebsd, .openbsd, .netbsd, .dragonfly, .haiku, .solaris, .illumos, .plan9, .emscripten, .wasi, .serenity => posix.PATH_MAX,' \
    '    .linux, .macos, .ios, .tvos, .watchos, .visionos, .freebsd, .openbsd, .netbsd, .dragonfly, .haiku, .solaris, .illumos, .plan9, .emscripten, .wasi, .serenity => posix.PATH_MAX,' \
    "PATH_MAX"

replace_line "$DIR" \
    '    .macos, .ios, .freebsd, .netbsd, .dragonfly, .openbsd, .solaris, .illumos => struct {' \
    '    .macos, .ios, .tvos, .watchos, .visionos, .freebsd, .netbsd, .dragonfly, .openbsd, .solaris, .illumos => struct {' \
    "Iterator struct"

replace_line "$DIR" \
    '                .macos, .ios => return self.nextDarwin(),' \
    '                .macos, .ios, .tvos, .watchos, .visionos => return self.nextDarwin(),' \
    "nextDarwin dispatch"

if ! grep -q '        \.visionos,' "$DIR"; then
    TEMP_FILE="$(mktemp)"
    awk '
        BEGIN { inserted = 0; prev1 = ""; prev2 = "" }
        {
            if (!inserted && prev2 == "        .macos," && prev1 == "        .ios," && $0 == "        .freebsd,") {
                print "        .tvos,"
                print "        .watchos,"
                print "        .visionos,"
                inserted = 1
            }
            print
            prev2 = prev1
            prev1 = $0
        }
        END { if (!inserted) exit 2 }
    ' "$DIR" > "$TEMP_FILE" || {
        rm -f "$TEMP_FILE"
        echo "ERROR: unsupported Zig stdlib layout while patching iterateImpl" >&2
        exit 1
    }
    cp "$TEMP_FILE" "$DIR"
    rm -f "$TEMP_FILE"
fi

printf '%s\n' "$OUTPUT_DIR"
