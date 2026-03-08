# wtpad

A native macOS terminal app built on [libghostty](https://ghostty.org/docs/about#libghostty).

## Architecture

wtpad is a Swift app that embeds [Ghostty's](https://ghostty.org) terminal emulator as a library. The UI is built with **SwiftUI** for app scaffolding (windows, layout) and **AppKit** for the terminal view itself — libghostty renders via Metal into an `NSView` and needs direct access to key events, mouse input, and the macOS input method system (`NSTextInputClient`), which SwiftUI doesn't expose.

### How the pieces fit together

```
┌─────────────────────────────────────────────┐
│  WtpadApp (SwiftUI @main)                   │
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
- **`project.yml`** — [XcodeGen](https://github.com/yonaskolb/XcodeGen) spec that generates `wtpad.xcodeproj`

### Key implementation details

- `ghostty_init()` must be called before any other libghostty API — we use a top-level `let` to ensure it runs at process startup before SwiftUI creates state objects
- The terminal surface is rendered by libghostty's Metal renderer; we don't draw anything ourselves
- Key input flows through `NSTextInputClient` (for IME/dead key support) then to `ghostty_surface_key()` with macOS virtual key codes
- Runtime callbacks (wakeup, clipboard read/write, close surface, actions) are registered via `ghostty_runtime_config_s` when creating the app

## Prerequisites

- [Zig](https://ziglang.org/) — `brew install zig`
- [XcodeGen](https://github.com/yonaskolb/XcodeGen) — `brew install xcodegen`
- Xcode 16+

## Setup

```bash
./scripts/setup.sh
```

This will:
1. Initialize the Ghostty submodule
2. Build `GhosttyKit.xcframework` from source (takes a few minutes)
3. Generate the Xcode project

## Build & Run

```bash
xcodebuild -project wtpad.xcodeproj -scheme wtpad -configuration Debug build
open ~/Library/Developer/Xcode/DerivedData/wtpad-*/Build/Products/Debug/wtpad.app
```

Or open `wtpad.xcodeproj` in Xcode and hit Run.

## Rebuilding GhosttyKit

If you update the Ghostty submodule, rebuild the framework:

```bash
cd ghostty && zig build -Demit-xcframework=true -Doptimize=ReleaseFast
```
