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

## Task workflows (`.clearway/WORKFLOW.json`)

A project can define its task pipeline in `.clearway/WORKFLOW.json`. When that file is present and valid, Clearway drives each worktree's task through it: every step launches an agent with that step's instructions, and the agent advances the task by writing the next step's slug into the task's YAML frontmatter. Without the file, you get the worktree and nothing else — you drive the terminal and the status by hand.

Edit it from the **Workflow** section in the sidebar, or by hand.

```json
{
  "version": 1,
  "start": "build",
  "agent": { "command": "claude" },
  "actions": {
    "build": {
      "name": "Build",
      "instructions": "Implement the task. Run the test suite before you finish.",
      "routes": { "success": "review" }
    },
    "review": {
      "name": "Review",
      "instructions": "Review the diff for correctness and clarity. Do not commit."
    }
  }
}
```

### Actions

`actions` is a map keyed by **slug** — the value that lands in the task's `status:` field. Order in the file is cosmetic; flow comes from the pointers.

- `name` — display label. Cosmetic, so renaming it never breaks the graph.
- `instructions` — the prompt handed to the agent for this step.
- `routes` — outcome → target slug. v1 has a single outcome, `success`. Omit `routes` to make the action **terminal**: the loop ends there.
- `model` — optional model for this step (see [Models](#models)).

`start` names the slug a new worktree begins on. Every pointer (`start`, route targets) must resolve to an action or the file is rejected, and a rejected file reads the same as no file at all. `new` and `ready_to_start` are reserved backlog markers and cannot be used as slugs.

> `agent.timeout_ms`, `max_attempts`, and `on_max_attempts` are accepted and validated, but **not enforced in v1** — they are reserved for a future loop guard. Setting them bounds nothing today; **Stop Agent** is the only thing that halts a running step.

### Agent

```json
"agent": { "command": "codex" }
```

The CLI Clearway launches for each step — e.g. `claude`, `codex`, `grok`. Omit `command` (or the whole `agent` object) to inherit the Main Terminal command from Settings.

### Hooks

```json
"hooks": { "after_create": "bin/setup" }
```

`after_create` runs in the worktree's secondary terminal just after the worktree is created. It runs in parallel with the agent, so a slow or failing hook never blocks the first step — you see its output inline.

### Planning

```json
"planning": { "instructions": "/plan-task {{ task.path }}" }
```

A manual step that sharpens a task *before* a worktree exists, so it sits outside the action graph and has no slug. This is the only field that takes template variables — `{{ task.title }}`, `{{ task.body }}`, `{{ task.id }}`, `{{ task.worktree }}`, `{{ task.path }}`. Action `instructions` are passed through verbatim.

A file may hold only `planning` and no actions, enabling the planning step without turning on the automated loop. `planning` also takes an optional `model`.

### Models

Any action, and the `planning` entry, may name the model its agent runs on:

```json
{
  "planning": { "instructions": "/plan-task {{ task.path }}", "model": "fable" },
  "actions": {
    "build":  { "name": "Build",  "instructions": "…", "routes": { "success": "review" } },
    "review": { "name": "Review", "instructions": "…", "model": "opus" }
  }
}
```

`model` is free text — whatever the agent accepts, e.g. an alias (`fable`, `sonnet`, `opus`) or a full ID (`claude-opus-4-8`, `gpt-5.4-codex`, `grok-4`). It is appended to the launch as `--model <model>` for the agents verified to accept that flag: `claude`, `codex` and `grok`. Any other command is launched unchanged, since a flag an agent doesn't take would break the launch. Omit `model` (or leave the editor field blank) and the step launches with no flag, on whatever model that agent defaults to.

Model names are per-agent — `opus` under `codex` is rejected by codex, not by Clearway. Each entry is independent, too: there is no workflow-wide default to inherit from.

A value with a space in it is ignored at launch rather than rejecting the file; the editor flags it **Invalid** as you type.

### Running a workflow

Clearway prepends a short context block to each action's `instructions`, telling the agent where the task lives and what to write when it finishes — the next slug for a routed action, `completed: true` for a terminal one. You write only the instructions.

Autopilot is per-worktree and never starts on its own: reopening a project leaves every worktree paused until you press play. Use the toolbar play/pause to resume, and **Stop Agent** in its context menu to end a running step.

## Architecture

See [ARCHITECTURE.md](./ARCHITECTURE.md) for the libghostty wrapper, Swift/AppKit/SwiftUI layering, runtime callback flow, and instructions for rebuilding the GhosttyKit framework.

## Releasing

See [RELEASING.md](./RELEASING.md) for code signing, the auto-update pipeline, the local update dry-run procedure, and per-release commands.
