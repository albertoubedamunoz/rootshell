# rootshell-helper

`rootshell-helper` is the unsandboxed macOS companion used by rootshell's
Standalone Mac Catalyst build. It creates local shell processes with PTYs and
passes the PTY file descriptors to the Catalyst app over Unix domain sockets.

The helper accepts commands only from the rootshell application signed as
`com.kk2.rootshell` by team `D97ZME3ET2`. It is packaged as a background-only
macOS app and communicates over Unix domain sockets in the provisioned
`group.com.kk2.ghostty` App Group container.

## Requirements

- macOS 15 or newer
- Xcode 26.1 or newer for contributor builds
- Xcode 26.5 (`17F42`) with macOS SDK 26.5 (`25F70`) for reproducing the
  currently validated rootshell release settings

## Build

An unsigned contributor build does not require rootshell signing credentials:

```bash
xcodebuild \
  -project rootshell.xcodeproj \
  -scheme rootshell-helper \
  -configuration Debug \
  CODE_SIGNING_ALLOWED=NO \
  build
```

Run the tests with:

```bash
xcodebuild test \
  -project rootshell.xcodeproj \
  -scheme rootshell-helper \
  -destination 'platform=macOS' \
  CODE_SIGNING_ALLOWED=NO
```

Forks that integrate the helper with another app must change the bundle IDs,
App Group, entitlements, and peer code-signing requirement together.

## Rootshell integration

The helper source and native macOS target live in the main Rootshell repository.
The Standalone Mac Catalyst target builds the helper from source and embeds it at
`Contents/Helpers/rootshell-helper.app` with Code Sign on Copy. No built helper
bundle is stored in Git. When the containing app is
exported with Developer ID and uploaded for notarization in Organizer, the
helper is distribution-signed and notarized as nested code.

The helper target uses `SKIP_INSTALL=YES` so it is embedded in the Rootshell
archive without appearing as a second top-level archive product.

## Security model

The helper runs outside the App Sandbox because PTY creation and the required
shell process setup are unavailable to the sandboxed Catalyst app. Command
socket clients are validated by the helper from `LOCAL_PEERTOKEN` with
Security.framework against rootshell's bundle identifier and signing team
before commands are decoded. Socket files live in the shared App Group
container, which is available only to appropriately provisioned applications.

Because the helper executes commands with the user's normal macOS privileges,
changes to peer validation, entitlements, socket permissions, or signing
identity should receive security review.

## License

rootshell-helper is available under the [MIT License](LICENSE). See
[`THIRD_PARTY_NOTICES`](THIRD_PARTY_NOTICES) for Ghostty attribution.
