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

## Task workflows (`WORKFLOW.md`)

A project can define task-lifecycle behavior in a `WORKFLOW.md` at its root. The file uses YAML frontmatter for configuration and a markdown body as the agent prompt template.

State commands surface a play button next to the status picker in the task aside panel. Clicking it pastes the rendered command into the active terminal. Recognized keys under `state_commands`: `in_progress`, `ready_for_review`, `done`, `canceled`.

```markdown
---
agent:
  command: claude
state_commands:
  ready_for_review: /codex:adversarial-review
---
Work on the following task:

{{ task.title }}

{{ task.body }}
```

Template variables (substituted as `{{ var }}`, shell-escaped inside commands):

- `task.title`, `task.body`, `task.id`, `task.worktree`, `task.path`
- `attempt`
- `status.<name>` for each status raw value

## Architecture

See [ARCHITECTURE.md](./ARCHITECTURE.md) for the libghostty wrapper, Swift/AppKit/SwiftUI layering, runtime callback flow, and instructions for rebuilding the GhosttyKit framework.

## Releasing

See [RELEASING.md](./RELEASING.md) for code signing, the auto-update pipeline, the local update dry-run procedure, and per-release commands.
