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

## Verifying a change

```bash
./scripts/ci.sh
```

Regenerates the Xcode project, lints, builds, and runs the test suite — the same gate `.github/workflows/ci.yml` applies to a PR. Use it instead of a hand-written `xcodebuild` line: new Swift files are invisible to the build until `xcodegen generate` runs, and `build.sh`'s `PRODUCT_NAME` override breaks `TEST_HOST`, so the tests fail to launch.

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
- **Sources/App/Clearway-Bridging-Header.h** — the only route to cmark-gfm's GFM extension API; the SPM package's umbrella header exposes just `cmark.h`, so `import cmark` cannot see it. Its four prototypes are hand-copied, so the package is pinned with `exactVersion` — a signature change in a later 2.x would not fail the build.
- swift-markdown was evaluated and rejected for the Markdown preview: it is parse-only, ships no HTML renderer, and wraps the same cmark-gfm already vendored.

## Workflow engine

A project's tasks are driven by the **agent-driven loop engine** (`WorkflowDefinition` + `WorkflowLoopEngine`), active when a valid `.clearway/WORKFLOW.json` (in the project root's `.clearway/`) is present. This is the only task-driving engine — the legacy `WORKFLOW.md` (`WorkflowConfig`) path has been fully retired.

`WorkflowDefinition.hasJSONWorkflow(projectPath:)` is the gate: `true` only for a file that exists, decodes, and passes `validate()`. A malformed or absent file reads as "no JSON workflow."

Agent spawning happens **only** through this engine. Starting a task (`startTask`) creates — or focuses — the worktree, and `completePendingLaunch` relocates its `TASK.md` into it; neither launches an agent. In a JSON project the seed-on-creation chokepoint (`seedWorkflowStatus`) then writes `status = start` and launches the agent. A project **without** a valid `WORKFLOW.json` gets the worktree and nothing else — the user drives the terminal and status by hand.

### WORKFLOW.json model (`WorkflowDefinition.swift`)

Decoded with `Codable` (snake_case JSON keys → camelCase Swift):

- `version` (Int), `start` (slug pointer into `actions`).
- `agent` (`AgentSettings`): `command` (empty/omitted → inherit Settings → Main Terminal at launch via `resolveAgentCommand`; explicit values like `"claude"` / `"grok"` / `"codex"` win) + `timeoutMs` (`timeout_ms`, default 600_000 — **decoded but NOT enforced in v1**, like the loop-guard fields). An omitted `agent` falls back entirely to defaults (empty command + default timeout).
- `hooks` (optional `Hooks`): `afterCreate` (`after_create`) / `beforeRun` (`before_run`) shell commands. **`after_create` is wired** — sourced via `workflowAfterCreateHook()` and run on worktree creation (`ContentView`'s `lastCreatedBranch` handler). It runs **in parallel** in the worktree's persistent secondary terminal (`TerminalManager.runHookInSecondary`, fed via `sendPaste`), **decoupled from the agent launch**: the agent seeds and launches immediately and never waits for the hook, and a failing hook can't block it (the command runs raw in the secondary terminal, so the user sees any failure inline). **`before_run` is decoded but NOT yet executed** (reserved; a per-action interactive hook sheet would break autopilot — wiring it would need a non-interactive run before each launch).
- `actions: [String: Action]` — a **map keyed by frozen slug** (order is cosmetic). Each `Action` has `name` (editable display label), `instructions` (agent prompt), `routes` (`[outcome: targetSlug]`, v1 has a single `success` outcome; empty/absent = **terminal**), and the **reserved** `maxAttempts` (`max_attempts`) / `onMaxAttempts` (`on_max_attempts`).

`maxAttempts`/`onMaxAttempts` are **decoded and validated but NOT enforced in v1** (see loop guard below). Pointers (`start`, route values, `onMaxAttempts`) target slugs, never `name`. `validate()` rejects empty `actions`, a `start`/route/`onMaxAttempts` target that doesn't resolve, and an action keyed by a reserved backlog marker (`new`/`ready_to_start` — the engine unconditionally ignores those, so such an action would be silently unreachable). Helpers: `isTerminal(_:)`, `legalNext(from:)` (sorted for deterministic injection).

### status-as-slug contract

`WorkTask.status` is a plain `String`, not an enum. Reserved values live in `WorkTask.ReservedStatus` (namespace of string constants):

- `new` / `ready_to_start` — backlog markers (pre-worktree), not the engine's concern.
- The **middle** is any action slug from `WORKFLOW.json`.
- Legacy fixed states (`in_progress` / `qa` / `ready_for_review` / `done` / `canceled`) still exist in `ReservedStatus` and back the **non-JSON status picker** (the manual status menu a project without `WORKFLOW.json` shows) plus display labels and badge colors — no engine drives them.

Loop end-states are **derived, not stored**: **done** = status sits on a routeless (terminal) action; **paused** = `autopilot: false`; **halted** = the agent wrote an illegal/unknown slug (surfaces an `errorMessage`).

### The engine loop + injection contract

`WorkflowLoopEngine.decideTransition(running:written:autopilot:definition:)` is a **pure** function returning `.launch(slug:nextValue:)` / `.ignore` / `.halt(reason:)`. The stateful plumbing lives in `WorkTaskCoordinator+WorkflowEngine.swift` (`@MainActor`).

- **Seed.** On worktree creation in a JSON project, `seedWorkflowStatus` writes `status = start` (the engine's **only** write to `status` — the agent owns all advances) and defaults `autopilot = true`. The `status` write is skipped for a **hidden** task — a manually-created worktree's shadow, which means no task is associated yet, so the seed leaves it on `in_progress` with no step to badge tabs with. The gate is on the *automatic* seed, not on the user: a step card's Set Current / Run writes whatever slug it is handed, hidden task or not, and such a worktree does then badge. The aside's **Create Task** button goes through `WorkTaskCoordinator.exposeTask` / `createTask`, which associate the task and then seed — and *that* is when such a worktree gains `start`. `autopilot` is still written on the first seed either way, since a `nil` would read as on.
- **Watch.** On a `.clearway/TASK.md` reload (`handleTasksReloaded`), `advanceWorkflow` feeds the change through `decideTransition`: `S == P` or a backlog marker → ignore; **while a step is running** (`P != nil`), `S` must be a legal route out of `P` or it halts; **while idle** (`P == nil` — after the seed, after a step's agent exits, or a manual status pick) any real action launches (no route validation — there's no active step to validate against); an unknown slug always halts + surfaces `errorMessage`. Route validation is thus enforced only mid-step, where a hallucinated advance actually needs guarding.
- **Manual status pick.** The task aside's status picker lists the `WORKFLOW.json` actions (`workflowActionSlugs()`, flow-ordered — reading the coordinator's **cached** definition, not a per-render disk load) and writes via `setWorkflowStatus`. A human pick may set **any** state and is **never route-validated**: it **terminates a live agent surface first** (steering, not stopping — autopilot is *not* paused, unlike `manualKill`; otherwise the superseded agent and the relaunched one would both run and the zombie's eventual status write would halt the loop), clears the running pointer (`runningAction`) so the watcher's `advanceWorkflow` takes the *idle* path (launch under autopilot / hold under pause) instead of validating a transition from the running action, and clears any halt + error so a halted loop recovers. This is why the picker never produces a "not a legal next" halt.
- **Launch.** `WorkflowLoopEngine.buildPrompt(instructions:nextValue:)` **prepends** a labeled `Context:` block — closed by a trailing `---` thematic break, and leading with the label (never a `---` fence) so it can't be mistaken for the task's own YAML frontmatter — to the action's own `instructions` (which land last, for highest-recency emphasis):
  ```
  Context:
  - The task in progress is .clearway/TASK.md.
  - The YAML frontmatter of the task is internal data not relevant to you. Only use it when needing to update it.
  - When done, set the `status:` field in the task's frontmatter to `<next>` as the last thing you do.

  ---
  ```
  A **terminal** action (`nextValue == nil`) gets the same preamble but with `set `completed: true` in the task's frontmatter` instead of the `status:` advance — it runs once and the loop ends.
- **No trust gate.** `WORKFLOW.json` is **not** trust-gated: it is treated as user-authored config, so the engine launches the resolved agent command (workflow `agent.command`, or Main Terminal when omitted) directly. Note the trade-off (maintainer-approved): the file is *repo*-authored — starting a task in a freshly cloned third-party repo with a `.clearway/WORKFLOW.json` runs its agent command and `hooks.after_create` with no approval step (mitigated by: the hook runs visibly in the secondary terminal, autopilot never auto-starts on open, and a worktree must be explicitly created). The launch goes through `WorkTaskCoordinator.workflowAgentLauncher` (a `nil`-in-production seam the harness tests override to observe a launch without a live Ghostty surface).

### Step badge on main tabs

Each main tab carries `TerminalTab.stepSlug: String?` — the workflow action it was opened under —
and `MainTerminalTabStrip` renders it as a pill before the tab title (`WorkflowStepBadge`). The tag
is **per-tab and historical**: it records the step current at creation and never changes, so tabs
opened before any step was current stay unbadged.

Every tab-creating path (`pane(for:app:projectPath:)`, `appendMainTab`, `appendLauncherTab`,
`newShellTab`) builds its tab through the private `TerminalManager.makeTab(_:in:)`, which stamps
the slug at construction from the `currentWorkflowStepProvider` seam — wired in `ContentView` to
`WorkTaskCoordinator.currentWorkflowStep(forWorktree:)`.

Two invariants make this smaller than it looks, and both are easy to break:

- **The source is the task's `status`, not `runningAction`.** `runningAction` holds a slug only
  while an agent process is alive, so it is empty for all of manual use — opening a worktree pauses
  autopilot, and a manual step pick clears it outright — and would leave every hand-opened tab
  unbadged. No launch path needs to pass its slug in, because each writes `status` *before* creating
  its tab: the engine launches the slug the agent just wrote, `seedWorkflowStatus` writes `start`
  first, and a step card's Run calls `setWorkflowActionCurrent` first.
- **The status is admitted only when it names an action** in the cached definition
  (`workflowDefinition?.actions[status] != nil`). That single gate is why nothing badges for the
  reserved backlog markers, for the legacy fixed states, or in a project with no `WORKFLOW.json` —
  and why no caller branches on `isWorkflowJSONProject`.

The badge takes its host chip's foreground colour (`.primary` when inactive, white on the
accent-filled active chip) rather than a per-step palette: the active chip is filled with the user's
*system* accent colour, which no fixed palette can be guaranteed to sit legibly on.

### Autopilot (`WorkTask.autopilot: Bool?`)

- Default `true` at creation **iff** the project has a valid `WORKFLOW.json` **and the task has content** (`WorkTask.hasContent` — a non-empty title or body). A manually-created worktree with a blank `TASK.md` seeds `autopilot: false` (paused, written explicitly — `nil` would read as on and launch anyway) and its toolbar button is **disabled** until the user gives it something to do. Non-JSON projects have no `autopilot` field.
- Toolbar play/pause control: `AutopilotButton` (in `AutopilotButton.swift`), **hidden** unless `isWorkflowJSONProject`. Click writes `autopilot` via `WorkTaskManager.setAutopilot`.
- Disable = **pause** (never interrupts a running agent — the running step finishes, nothing new launches). Enable = **resume** the current action (idempotent, `handleAutopilotFlip`).
- **Agent death pauses.** If the live agent exits **without having advanced `status` on disk** (crash, Ctrl-C, the user closing its terminal), `handleChildExited` → `pauseIfAgentDiedMidStep` writes `autopilot = false` — otherwise the worktree would sit idle with autopilot on and the engine's idle rule would respawn the same action on the next reload. "Died vs. advanced" is judged against a **fresh disk read** (`WorkTaskManager.freshStatus`), since a normal advance's exit can beat the debounced reload; disk is race-free (a dead process can't write afterwards). `handleMainTabClosed` leaves a still-live agent's bookkeeping in place so the exit stays attributable to `handleChildExited`.
- **Autopilot never auto-starts.** Opening a worktree (or having one open when the project loads) must not run a workflow on its own. The engine treats a persisted `autopilot: true` as a session-live flag that goes stale on restart: the **first time it observes a worktree** this session (`lastKnownAutopilot[branch] == nil`), `pauseStaleAutopilotOnFirstSight` flips it to `false` and launches nothing — unless the worktree is already running (a fresh create whose agent launched directly via `seedWorkflowStatus`, which is exempt). The loop only ever (re)starts on an explicit play (`handleAutopilotFlip` false→true) or a manual status pick. There is **no** startup auto-resume.

### Loop guard / manual kill

v1 has **no automatic attempt cap** (a single `attempt` counter couldn't bound a real fix↔test loop given the `S == P` ignore rule; `maxAttempts`/`onMaxAttempts` remain reserved/unenforced). The v1 loop-stopper is the **manual kill** — the "Stop Agent" context-menu item on the autopilot button (shown only while a step runs), wired to `WorkTaskCoordinator.manualKill`: it sets `autopilot = false` **and** terminates the running agent surface — the *pause-and-interrupt* affordance. (A manual status pick also terminates a running agent, but it *steers* the loop to the picked action without pausing autopilot.)

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
