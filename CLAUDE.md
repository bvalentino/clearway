# Clearway

Native macOS terminal app built on libghostty.

## Setup

```bash
./scripts/setup.sh
```

Requires: `zig`, `xcodegen`

## Build & Run (Debug)

```bash
./scripts/build.sh   # build only
./scripts/run.sh     # build + launch
```

## Architecture

- **ghostty/** — upstream ghostty submodule, built into `GhosttyKit.xcframework`
- **Sources/Ghostty/** — Swift wrappers around the libghostty C API
  - `Ghostty.swift` — namespace + logger
  - `Ghostty.Config.swift` — wraps `ghostty_config_t`
  - `Ghostty.App.swift` — wraps `ghostty_app_t`, runtime callbacks
  - `Ghostty.SurfaceView.swift` — `NSView` hosting a `ghostty_surface_t` (input, rendering)
  - `TerminalSurface.swift` — SwiftUI `NSViewRepresentable` wrapper
- **Sources/App/** — SwiftUI app entry point
- **project.yml** — xcodegen spec (generates `Clearway.xcodeproj`)

## Rebuilding GhosttyKit

```bash
cd ghostty && zig build -Demit-xcframework=true -Doptimize=ReleaseFast
```

## Key APIs

The libghostty C API (defined in `ghostty.h`) uses opaque pointer types:
- `ghostty_app_t` — one per process, manages config + surfaces
- `ghostty_surface_t` — one per terminal view
- `ghostty_config_t` — configuration

Key patterns:
- To run a command in a terminal without a login shell, pass `command:` to `Ghostty.SurfaceView(app, workingDirectory:, command:)`. Do NOT create a bare surface and then `sendCommand()` — that starts a login shell first, making the command visible in the prompt.
- Runtime callbacks are registered via `ghostty_runtime_config_s` when creating the app
- Surface userdata is set via `ghostty_surface_config_s.userdata` and retrieved via `ghostty_surface_userdata()`
- Key input uses `ghostty_input_key_s` with `keycode` (macOS virtual key code), not a key enum
- Mods use `GHOSTTY_MODS_*` constants (e.g. `GHOSTTY_MODS_SHIFT`, `GHOSTTY_MODS_CTRL`)

## Creating Tasks

Tasks live in `.clearway/tasks/<UUID>.md` as markdown files with YAML frontmatter. To create a task:

1. Generate a UUID (e.g. `uuidgen`)
2. Create `.clearway/tasks/<UUID>.md` with this format:

```markdown
---
id: <UUID>
title: "Short title"
status: new
worktree: null
created_at: <ISO 8601 timestamp>
updated_at: <ISO 8601 timestamp>
---

Task description goes here.
```

Statuses: `new`, `ready_to_start`, `in_progress`, `ready_for_review`, `done`, `canceled`

Always create tasks with status `new`. The app manages lifecycle transitions — `ready_to_start` means it's queued for automatic processing, so don't set that unless intended.
