# Clearway

A native macOS app for orchestrating AI sessions across git worktrees. Built on [Ghostty](https://ghostty.org).

Write tasks as markdown, queue them up, and Clearway dispatches each one to an AI session in its own worktree — with a project-centric sidebar for tracking progress, todos, notes, and prompts across every run.

## Architecture

Clearway is a Swift app that embeds [Ghostty's](https://ghostty.org) terminal emulator as a library. The UI is built with **SwiftUI** for app scaffolding (windows, layout) and **AppKit** for the terminal view itself — libghostty renders via Metal into an `NSView` and needs direct access to key events, mouse input, and the macOS input method system (`NSTextInputClient`), which SwiftUI doesn't expose.

### How the pieces fit together

```
┌─────────────────────────────────────────────┐
│  ClearwayApp (SwiftUI @main)                │
│  └── ContentView                            │
│      └── TerminalSurface (NSViewRepresentable) │
│          └── Ghostty.SurfaceView (NSView)   │
│              └── ghostty_surface_t (C API)  │
│                  └── libghostty (Zig/Metal) │
└─────────────────────────────────────────────┘
```

- **`ghostty/`** — upstream Ghostty as a git submodule, built into `GhosttyKit.xcframework` (a static library with C headers)
- **`Sources/Ghostty/`** — Swift wrappers around the libghostty C API
  - `Ghostty.App` — manages the global `ghostty_app_t` lifecycle and runtime callbacks (clipboard, close surface, actions)
  - `Ghostty.Config` — loads Ghostty configuration (`~/.config/ghostty/config`)
  - `Ghostty.SurfaceView` — `NSView` subclass that hosts a terminal surface, handles keyboard/mouse input and IME
  - `TerminalSurface` — thin SwiftUI wrapper via `NSViewRepresentable`
- **`Sources/App/`** — SwiftUI app entry point and content view
- **`project.yml`** — [XcodeGen](https://github.com/yonaskolb/XcodeGen) spec that generates `Clearway.xcodeproj`

### Key implementation details

- `ghostty_init()` must be called before any other libghostty API — we use a top-level `let` to ensure it runs at process startup before SwiftUI creates state objects
- The terminal surface is rendered by libghostty's Metal renderer; we don't draw anything ourselves
- Key input flows through `NSTextInputClient` (for IME/dead key support) then to `ghostty_surface_key()` with macOS virtual key codes
- Runtime callbacks (wakeup, clipboard read/write, close surface, actions) are registered via `ghostty_runtime_config_s` when creating the app

## Prerequisites

- [Zig](https://ziglang.org/) — `brew install zig`
- [XcodeGen](https://github.com/yonaskolb/XcodeGen) — `brew install xcodegen`
- [SwiftLint](https://github.com/realm/SwiftLint) — `brew install swiftlint`
- Xcode 16+

## Setup

```bash
./scripts/setup.sh
```

This will:
1. Initialize the Ghostty submodule
2. Build `GhosttyKit.xcframework` from source (takes a few minutes)
3. Generate the Xcode project

## Build & Run (Debug)

```bash
./scripts/build.sh   # build only
./scripts/run.sh     # build + launch
```

Or open `Clearway.xcodeproj` in Xcode and hit Run.

> **Note:** In git worktrees, the app is automatically named `Clearway (<worktree>)` so it doesn't conflict with the main build.

## Install

To build an optimized Release build and install it to `/Applications`:

```bash
./scripts/install.sh
```

After installing, Clearway will appear in Launchpad and Spotlight.

## Releasing (Signing & Notarization)

Clearway is distributed outside the Mac App Store, so Release builds must be **signed with a Developer ID Application certificate** and **notarized by Apple** for Gatekeeper to open them without warnings.

### One-time setup

1. **Developer ID Application certificate** — In your login keychain. Verify with:
   ```bash
   security find-identity -v -p codesigning | grep "Developer ID Application"
   ```
   Should print the identity referenced in `project.yml` (Release config).

2. **App Store Connect API key** — Generate at [App Store Connect → Users and Access → Integrations](https://appstoreconnect.apple.com/access/integrations/api) with the **Developer** role. Download the `.p8` file once (Apple does not let you download it again) and store it outside the repo:
   ```bash
   mkdir -p ~/.appstoreconnect && chmod 700 ~/.appstoreconnect
   mv ~/Downloads/AuthKey_*.p8 ~/.appstoreconnect/
   chmod 600 ~/.appstoreconnect/AuthKey_*.p8
   ```
   From the same page, note the **Key ID** (10-character identifier next to your key) and the **Issuer ID** (UUID at the top of the page). You will need both in step 3.

3. **Export the notarization environment variables** in your shell (add to `~/.zshrc` for persistence):
   ```bash
   export ASC_API_KEY_PATH=~/.appstoreconnect/AuthKey_<YOUR_KEY_ID>.p8
   export ASC_API_KEY_ID=<YOUR_KEY_ID>           # 10-char string, e.g. ABCDE12345
   export ASC_API_ISSUER_ID=<YOUR_ISSUER_UUID>   # UUID from App Store Connect
   ```

   All three are required — `scripts/notarize.sh` and `scripts/package-dmg.sh` will refuse to run if any are unset. They are intentionally not committed to the repo.

### Release flow

```bash
./scripts/release.sh        # builds Release, signs with Developer ID + hardened runtime, zips
./scripts/notarize.sh       # submits zip, waits, staples ticket, verifies with spctl
./scripts/package-dmg.sh    # wraps stapled .app in signed + notarized + stapled DMG
```

Outputs in `release/`:

- `Clearway-<version>-<sha>.zip` — signed but **not** notarized. Intermediate artifact.
- `Clearway-<version>-<sha>-notarized.zip` — signed and stapled. Valid to distribute if you prefer a zip.
- `Clearway-<version>-<sha>.dmg` — signed, notarized, and stapled DMG with a drag-to-Applications layout. **This is the preferred distributable.**

Both the DMG and the `.app` inside it are stapled, so extracting the app and deleting the DMG still works offline.

### Verifying a build manually

```bash
# DMG
spctl -a -t open --context context:primary-signature -vv release/Clearway-*.dmg
xcrun stapler validate release/Clearway-*.dmg

# Or the .app inside the notarized zip
unzip -o release/Clearway-*-notarized.zip -d /tmp/clearway-check
codesign -dvv /tmp/clearway-check/Clearway.app
spctl -a -vv /tmp/clearway-check/Clearway.app
xcrun stapler validate /tmp/clearway-check/Clearway.app
```

`spctl` should report `accepted, source=Notarized Developer ID` for both.

### Troubleshooting

If `./scripts/notarize.sh` reports `status=Invalid`, it will automatically fetch and print the detailed log from `notarytool`. The most common causes:

- **"The signature does not include a secure timestamp"** — `OTHER_CODE_SIGN_FLAGS = --timestamp` is missing from the Release config in `project.yml`.
- **"The executable requests the com.apple.security.get-task-allow entitlement"** — `CODE_SIGN_INJECT_BASE_ENTITLEMENTS = NO` is missing from the Release config. Xcode injects `get-task-allow=true` by default during `xcodebuild build`; disabling injection forces it to use only `Clearway.entitlements`.
- **New hardened runtime exception needed** — if `libghostty` starts requiring JIT, dyld env vars, etc., notarytool will name the exact entitlement key. Add it to `Clearway.entitlements` and rebuild.

Debug builds (`./scripts/build.sh`, `./scripts/run.sh`) still use ad-hoc signing (`CODE_SIGN_IDENTITY = "-"`) with hardened runtime off — the Release signing settings are scoped to the Release configuration only, so the local dev loop is unaffected.

## Linting

[SwiftLint](https://github.com/realm/SwiftLint) runs automatically as a post-build script phase in Xcode. To lint manually:

```bash
swiftlint lint --quiet
```

Configuration is in `.swiftlint.yml`.

## Rebuilding GhosttyKit

If you update the Ghostty submodule, rebuild the framework:

```bash
cd ghostty && zig build -Demit-xcframework=true -Doptimize=ReleaseFast
```
