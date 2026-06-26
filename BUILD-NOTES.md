# Build notes (local)

How this machine builds Runway. Not part of upstream — local setup only.

## Why this file exists

Upstream's `Package.swift` opts into Swift 6 **language mode** but relies on
**module-wide default `MainActor` isolation** that isn't expressed in the manifest
(the author had it set in their build environment). A stock `swift build` on a
plain toolchain therefore fails with ~74 main-actor isolation errors. Two things
are needed to build cleanly:

1. A **Swift 6.2+** toolchain (for the `defaultIsolation` package setting / flag).
2. A one-line manifest tweak scoping default `MainActor` isolation to the app target.

## Prerequisites

- Apple Silicon Mac, macOS 14+.
- `gh` CLI installed and authenticated (`brew install gh && gh auth login`) — the
  activity feed shells out to it.
- A **Swift 6.2** toolchain. This Mac's Xcode (15.3) only ships Swift 5.10, so a
  standalone toolchain was installed from swift.org:
  ```sh
  # downloaded + installed to ~/Library/Developer/Toolchains (no sudo):
  curl -fL -o swift-6.2.3.pkg \
    https://download.swift.org/swift-6.2.3-release/xcode/swift-6.2.3-RELEASE/swift-6.2.3-RELEASE-osx.pkg
  installer -pkg swift-6.2.3.pkg -target CurrentUserHomeDirectory
  ```
  Select it per-command with `TOOLCHAINS=swift` (resolves to the newest installed
  swift.org toolchain) — no need to change the system default.

## The local manifest change (in `Package.swift`)

```diff
-// swift-tools-version:6.0
+// swift-tools-version:6.2

         .executableTarget(
             name: "Runway",
             dependencies: [ .product(name: "GhosttyKit", package: "GhosttyKit") ],
-            path: "Sources/Runway"
+            path: "Sources/Runway",
+            swiftSettings: [.defaultIsolation(MainActor.self)]
         )
```

This is build config only — behaviour-neutral (the app is 100% main-thread
SwiftUI) and adds no network/keys. The setting is scoped to the `Runway` target
on purpose: applying it globally (e.g. via `-Xswiftc -default-isolation -Xswiftc
MainActor`) breaks GhosttyKit's C-function-pointer code.

## Build

```sh
cd ~/runway
TOOLCHAINS=swift ./build-app.sh release
open dist/Runway.app
```

If `codesign --verify dist/Runway.app` warns about resources after the script's
ad-hoc sign, re-seal it (the bundled framework ships read-only):

```sh
chmod -R u+w dist/Runway.app
codesign --force --sign - dist/Runway.app/Contents/Frameworks/CGhosttyKitBinary.framework
codesign --force --deep --sign - dist/Runway.app
codesign --verify --verbose dist/Runway.app   # -> "valid on disk"
```

Locally built, so there's no download-quarantine flag — Gatekeeper won't block it.

## After `git pull`

The `Package.swift` change is local and uncommitted. After pulling upstream:

- If upstream didn't touch `Package.swift`, your change is preserved — just rebuild.
- If it did, git will report a conflict / overwrite. Re-apply the diff above, then
  rebuild.

Tip: `git stash` before pulling, `git stash pop` after, or keep the change on a
local branch so it's easy to re-apply.
