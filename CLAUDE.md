# Clearway

Native macOS terminal app built on libghostty.

## Setup

```bash
./scripts/setup.sh
```

Requires: `zig`, `xcodegen`, `swiftlint`

## Build & Run (Debug)

```bash
./scripts/build.sh   # build only
./scripts/run.sh     # build + launch
```

## Linting

SwiftLint runs as a post-build script phase. To lint manually:

```bash
swiftlint lint --quiet
```

All new code must pass `swiftlint lint` with zero errors before committing. Warnings are acceptable for now but should not be introduced in new code.

## Architecture

- **ghostty/** — upstream ghostty submodule, built into `GhosttyKit.xcframework`
- **Sources/Ghostty/** — Swift wrappers around the libghostty C API
  - `Ghostty.swift` — namespace + logger
  - `Ghostty.Config.swift` — wraps `ghostty_config_t`
  - `Ghostty.App.swift` — wraps `ghostty_app_t`, runtime callbacks
  - `Ghostty.SurfaceView.swift` — `NSView` hosting a `ghostty_surface_t` (input, rendering)
  - `TerminalSurface.swift` — SwiftUI `NSViewRepresentable` wrapper
- **Sources/App/** — SwiftUI app entry point + task/worktree/workflow logic
- **project.yml** — xcodegen spec (generates `Clearway.xcodeproj`)

## Workflow engines

A project is driven by **one of two engines, selected by file presence — never both:**

- A valid `.clearway/WORKFLOW.json` (project root's `.clearway/`) → the new **agent-driven loop engine** owns the project.
- Absent (or malformed JSON) → the **legacy `WORKFLOW.md`** (`WorkflowConfig`) manual path, unchanged.

`WorkflowDefinition.hasJSONWorkflow(projectPath:)` is the gate: `true` only for a file that exists, decodes, and passes `validate()`. A malformed file reads as "no JSON workflow" and the project falls back to the legacy path. The new engine never reads `WORKFLOW.md`.

### WORKFLOW.json model (`WorkflowDefinition.swift`)

Decoded with `Codable` (snake_case JSON keys → camelCase Swift):

- `version` (Int), `start` (slug pointer into `actions`).
- `agent` (`AgentSettings`): `command` (default `"claude"`) + `timeoutMs` (`timeout_ms`, default 600_000). An omitted `agent` falls back entirely to defaults.
- `hooks` (optional `Hooks`): `afterCreate` (`after_create`) / `beforeRun` (`before_run`) shell commands.
- `actions: [String: Action]` — a **map keyed by frozen slug** (order is cosmetic). Each `Action` has `name` (editable display label), `instructions` (agent prompt), `routes` (`[outcome: targetSlug]`, v1 has a single `success` outcome; empty/absent = **terminal**), and the **reserved** `maxAttempts` (`max_attempts`) / `onMaxAttempts` (`on_max_attempts`).

`maxAttempts`/`onMaxAttempts` are **decoded and validated but NOT enforced in v1** (see loop guard below). Pointers (`start`, route values, `onMaxAttempts`) target slugs, never `name`. `validate()` rejects empty `actions`, a `start`/route/`onMaxAttempts` target that doesn't resolve, etc. Helpers: `isTerminal(_:)`, `legalNext(from:)` (sorted for deterministic injection).

### status-as-slug contract

`WorkTask.status` is a plain `String`, not an enum. Reserved values live in `WorkTask.ReservedStatus` (namespace of string constants):

- `new` / `ready_to_start` — backlog markers (pre-worktree), not the engine's concern.
- The **middle** is any action slug from `WORKFLOW.json`.
- Legacy fixed states (`in_progress` / `qa` / `ready_for_review` / `done` / `canceled`) exist in `ReservedStatus` too but are used **only by the legacy `WORKFLOW.md` path**.

Loop end-states are **derived, not stored**: **done** = status sits on a routeless (terminal) action; **paused** = `autopilot: false`; **halted** = the agent wrote an illegal/unknown slug (surfaces an `errorMessage`).

### The engine loop + injection contract

`WorkflowLoopEngine.decideTransition(running:written:autopilot:definition:)` is a **pure** function returning `.launch(slug:nextValue:)` / `.ignore` / `.halt(reason:)`. The stateful plumbing lives in `WorkTaskCoordinator+WorkflowEngine.swift` (`@MainActor`).

- **Seed.** On worktree creation in a JSON project, `seedWorkflowStatus` writes `status = start` (the engine's **only** write to `status` — the agent owns all advances) and defaults `autopilot = true`.
- **Watch.** On a `.clearway/TASK.md` reload (`handleTasksReloaded`), `advanceWorkflow` feeds the change through `decideTransition`: `S == P` or a backlog marker → ignore; a legal route (or `start` on first launch) → launch; an illegal/unknown slug → halt + surface `errorMessage`.
- **Launch.** `WorkflowLoopEngine.buildPrompt(instructions:nextValue:)` appends the injection contract:
  ```
  [Clearway] When finished, set `status:` in .clearway/TASK.md to: <next>
  Write it last.
  ```
  A **terminal** action (`nextValue == nil`) gets **no** advance contract — it runs once and the loop ends.
- **Trust.** `agent.command` / `hooks` execution is gated by `WorkflowDefinition.isTrusted` — a SHA-256 fingerprint of the file bytes + per-project UserDefaults approval, the same primitive the legacy `WorkflowConfig` uses (distinct key namespace). Untrusted → `.needsTrust`, surfaced, never run.

### Autopilot (`WorkTask.autopilot: Bool?`)

- Default `true` at creation **iff** the project has a valid `WORKFLOW.json`; legacy projects have no `autopilot` field.
- Toolbar play/pause control: `AutopilotButton` (in `AutopilotButton.swift`), **hidden** unless `isWorkflowJSONProject`. Click writes `autopilot` via `WorkTaskManager.setAutopilot`.
- Disable = **pause** (never interrupts a running agent — the running step finishes, nothing new launches). Enable = **resume** the current action (idempotent, `handleAutopilotFlip`). Restart (`resumeWorkflowsOnStartup` → `WorkflowLoopEngine.shouldResumeOnRestart`) auto-resumes only `autopilot: true` worktrees sitting on a real non-terminal action.

### Loop guard / manual kill

v1 has **no automatic attempt cap** (a single `attempt` counter couldn't bound a real fix↔test loop given the `S == P` ignore rule; `maxAttempts`/`onMaxAttempts` remain reserved/unenforced). The v1 loop-stopper is the **manual kill** — the "Stop Agent" context-menu item on the autopilot button (shown only while a step runs), wired to `WorkTaskCoordinator.manualKill`: it sets `autopilot = false` **and** terminates the running agent surface. This is the only affordance that interrupts a running agent.

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
