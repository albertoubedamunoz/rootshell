# Temporary visionOS compatibility override

This directory vendors the build sources and tests from
[`soto-project/soto-core` 7.14.0](https://github.com/soto-project/soto-core/tree/7.14.0),
commit `47454bf79649691da406978ae803b51b54246d6e`, the version previously pinned
by rootshell. The upstream manifests, licenses, notices, and contributor list
are retained.

The only upstream code change adds `os(visionOS)` to the Apple/Android branch
of `ConfigFileLoader.expandTildeInFilePath`. Without it, compiling SotoCore
for visionOS reaches `#error("Unsupported platform")`. visionOS uses the same
Darwin `getpwuid`/`getuid` implementation as the other Apple platforms.

`rootshell.xcodeproj` includes this directory as a local Swift package. Its
`soto-core` identity overrides Soto's transitive remote dependency, so normal
Xcode and command-line builds use the fix without a fork, sibling checkout,
cache edits, or a setup script. Soto itself remains the upstream dependency.

Validated with a full `rootshell-AppStore` build for the arm64 visionOS 27.0
simulator using Xcode 27.0. SwiftPM currently warns that the local and remote
dependencies share an identity, and says this may become an error in a future
version. The override resolves successfully with this toolchain; remove it
when a fixed upstream release is available.

## Removing the workaround

Once an upstream release includes the fix:

1. Remove the `Packages/soto-core` local package reference from the Xcode
   project and delete this directory.
2. Resolve packages to a compatible upstream SotoCore version containing the
   fix and commit the updated `Package.resolved`.
3. Build `rootshell-AppStore` for a visionOS simulator by device ID and verify
   that the resolved SotoCore package comes from upstream.

Until then, update this copy deliberately if changing Soto versions; a local
package overrides normal remote version selection.
