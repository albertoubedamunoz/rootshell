#!/bin/bash
# Compile the real painter and Ghostty width table without building the app.
set -euo pipefail
repo_root=$(cd "$(dirname "$0")/../.." && pwd)
cd "$repo_root"
ghostty_slice=${GHOSTTY_CATALYST_SLICE:-build/dd/SourcePackages/artifacts/ghosttykit-rootshell/GhosttyKitAppStore/GhosttyKitAppStore.xcframework/ios-arm64_x86_64-maccatalyst}
if [[ ! -f "$ghostty_slice/libghostty-catalyst.a" ]]; then
    echo "GhosttyKit Catalyst artifact missing; set GHOSTTY_CATALYST_SLICE to its directory." >&2
    exit 1
fi
test_dir=$(mktemp -d)
trap 'rm -rf "$test_dir"' EXIT
xcrun swiftc -target "$(uname -m)-apple-ios17.0-macabi" \
    -sdk "$(xcrun --sdk macosx --show-sdk-path)" \
    -I "$ghostty_slice/Headers" \
    rootshell/Core/Foundation/DisplayWidth.swift \
    rootshell/Features/Herdr/HerdrEndpointWire.swift \
    rootshell/Features/Herdr/HerdrEndpointSurface.swift \
    rootshell/Features/Herdr/HerdrEndpointSelection.swift \
    scripts/tests/HerdrEndpointPainterTests.swift \
    "$ghostty_slice/libghostty-catalyst.a" \
    -framework Metal -framework QuartzCore -framework CoreText \
    -framework AppKit -framework IOSurface -lc++ -o "$test_dir/test"
"$test_dir/test"
