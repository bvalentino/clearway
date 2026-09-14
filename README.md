# Clearway

A native macOS app for orchestrating AI sessions across git worktrees. Built on [Ghostty](https://ghostty.org).

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

> **Note:** `install.sh` builds a signed Release, which requires the code signing setup described in [RELEASING.md](./RELEASING.md). For day-to-day development, use `./scripts/build.sh` or `./scripts/run.sh` from the section above.

## Linting

[SwiftLint](https://github.com/realm/SwiftLint) runs automatically as a post-build script phase in Xcode. To lint manually:

```bash
swiftlint lint --quiet
```

Configuration is in `.swiftlint.yml`.

## Tasks

Clearway keeps a task backlog per project. **Start Now** on a task creates its worktree (or focuses the existing one), moves the task's `TASK.md` into it, and runs the project's after-create hook in the worktree's secondary terminal. The task moves to *In Progress* and stays there: Clearway launches no agent of its own, and nothing advances the status for you.

Terminal tabs start on whatever Settings → Main Terminal names. The agent CLIs Clearway knows are `claude`, `grok` and `codex`; picking *None* opens a plain login shell instead.

Ctrl-C in an agent's terminal, or closing its tab, ends it.

## Architecture

See [ARCHITECTURE.md](./ARCHITECTURE.md) for the libghostty wrapper, Swift/AppKit/SwiftUI layering, runtime callback flow, and instructions for rebuilding the GhosttyKit framework.

## Releasing

See [RELEASING.md](./RELEASING.md) for code signing, the auto-update pipeline, the local update dry-run procedure, and per-release commands.
