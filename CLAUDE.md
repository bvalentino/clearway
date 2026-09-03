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
  - `Ghostty.SurfaceView.swift` — `NSView` hosting a `ghostty_surface_t` (input, rendering).
    Nothing on it is reachable from XCTest: an instance is needed to call anything, and the
    initializer needs a real `ghostty_app_t`. So any decision rule here is lifted out into a pure
    helper that gets tested instead — the same split `TerminalManager.revealSecondaryForHook` makes
    for panel visibility.
    A focused surface swallows **every** Cmd/Ctrl combo, encoding it for the shell, unless the app
    claims it via `SurfaceView.claimsShortcut` — a provider wired in `ContentView.onAppear` to
    `AppKeyboardShortcuts.claims`. A SwiftUI `.keyboardShortcut` declared without a matching entry
    there is unreachable whenever a terminal has focus, which is why the table and the declarations
    live in the same layer.
  - `TerminalSurface.swift` — SwiftUI `NSViewRepresentable` wrapper
- **Sources/App/** — SwiftUI app entry point + task/worktree/workflow logic
  - `AppKeyboardShortcuts.swift` — the combos the app claims from focused terminal surfaces, plus the
    layout-independent key codes its `NSEvent` monitor matches on. Add a shortcut here in the same
    change that declares it.
  - Agent and terminal launch logic lives on `WorkTaskCoordinator`, never in a view: a view resolves
    no command and awaits nothing, it calls a coordinator method. This is what lets one behavior carry
    several entry points without the decision being written once per door.
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
- `agent` (`AgentSettings`): `command` (empty/omitted → inherit Settings → Main Terminal at launch via `resolveAgentCommand`; an **allowlisted** value like `"claude"` / `"grok"` / `"codex"` wins — see **Per-entry agent**) + `timeoutMs` (`timeout_ms`, default 600_000 — **decoded but NOT enforced in v1**, like the loop-guard fields). An omitted `agent` falls back entirely to defaults (empty command + default timeout).
- `hooks` (optional `Hooks`): `afterCreate` (`after_create`) / `beforeRun` (`before_run`) shell commands. **`after_create` is wired** — sourced via `workflowAfterCreateHook()` and run on worktree creation (`ContentView`'s `lastCreatedBranch` handler). It runs **in parallel** in the worktree's persistent secondary terminal (`TerminalManager.runHookInSecondary`, fed via `sendPaste`), **decoupled from the agent launch**: the agent seeds and launches immediately and never waits for the hook, and a failing hook can't block it (the command runs raw in the secondary terminal, so the user sees any failure inline). **`before_run` is decoded but NOT yet executed** (reserved; a per-action interactive hook sheet would break autopilot — wiring it would need a non-interactive run before each launch).
- `actions: [String: Action]` — a **map keyed by frozen slug** (order is cosmetic). Each `Action` has `name` (editable display label), `instructions` (agent prompt), `routes` (`[outcome: targetSlug]`, v1 has a single `success` outcome; empty/absent = **terminal**), and the **reserved** `maxAttempts` (`max_attempts`) / `onMaxAttempts` (`on_max_attempts`).

Both `Planning` and `Action` also carry an optional `model` and `command` (`nil` = unset) — see
**Per-entry model** and **Per-entry agent** below.

`maxAttempts`/`onMaxAttempts` are **decoded and validated but NOT enforced in v1** (see loop guard below). Pointers (`start`, route values, `onMaxAttempts`) target slugs, never `name`. `validate()` rejects empty `actions`, a `start`/route/`onMaxAttempts` target that doesn't resolve, and an action keyed by a reserved backlog marker (`new`/`ready_to_start` — the engine unconditionally ignores those, so such an action would be silently unreachable). Helpers: `isTerminal(_:)`, `legalNext(from:)` (sorted for deterministic injection).

### status-as-slug contract

`WorkTask.status` is a plain `String`, not an enum. Reserved values live in `WorkTask.ReservedStatus` (namespace of string constants):

- `new` / `ready_to_start` — backlog markers (pre-worktree), not the engine's concern.
- The **middle** is any action slug from `WORKFLOW.json`.
- Legacy fixed states (`in_progress` / `qa` / `ready_for_review` / `done` / `canceled`) still exist in `ReservedStatus` and back the **non-JSON status picker** (the manual status menu a project without `WORKFLOW.json` shows) plus display labels and badge colors — no engine drives them.

Loop end-states are **derived, not stored**: **done** = status sits on a routeless (terminal) action; **paused** = `autopilot: false`; **halted** = the agent wrote an illegal/unknown slug (surfaces an `errorMessage`).

### The engine loop + injection contract

`WorkflowLoopEngine.decideTransition(running:written:autopilot:definition:)` is a **pure** function returning `.launch(slug:nextValue:)` / `.ignore` / `.halt(reason:)`. The stateful plumbing lives in `WorkTaskCoordinator+WorkflowEngine.swift` (`@MainActor`).

- **Seed.** On worktree creation in a JSON project, `seedWorkflowStatus` writes `status = start` (the engine's **only** write to `status` — the agent owns all advances) and defaults `autopilot = true`. The `status` write is skipped for a **hidden** task — a manually-created worktree's shadow, which means no task is associated yet, so the seed leaves it on `in_progress` with no step to badge tabs with — and `advanceWorkflow` ignores a hidden task whose status names no action, since that status is Clearway's own marker and the unknown-slug halt would otherwise fire on it (from the seed *and* every later reload) and stick. The gate is on the *automatic* seed, not on the user: a step card's Set Current / Run writes whatever slug it is handed, hidden task or not, and such a worktree does then badge. The aside's **Create Task** button goes through `WorkTaskCoordinator.exposeTask` / `createTask`, which associate the task and then seed — and *that* is when such a worktree gains `start`. `autopilot` is still written on the first seed either way, since a `nil` would read as on.
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

### Per-entry model

`planning.model` and each action's `model` name the model that entry's agent launches on.
`applyModel(to:model:)` (in `AgentLaunch.swift`) appends `--model <model>` to an **already-resolved**
command, and returns it untouched unless both hold:

- **The command is a known agent** — first whitespace-separated token, last path component, in
  `agentsAcceptingModelFlag` (`claude`, `codex`, `grok`). All three were verified to take the same
  `--model <value>` long form: `claude --model`; `codex -m, --model <MODEL>` (openai/codex,
  `codex-rs/utils/cli/src/shared_options.rs`, shared options flattened into both the interactive TUI
  and `exec`); `grok -m, --model <MODEL>` (https://docs.x.ai/build/cli/reference). **Verify any new
  agent against its own docs before adding it** — appending a flag a CLI does not accept turns a
  working launch into a broken one, which is the whole point of the gate. `npx claude` and
  `env FOO=1 claude` read as unknown and get the no-flag path — an accepted miss, never a broken launch.
- **The value is a single non-empty word.** It lands in `buildAgentPromptCommand`'s *unquoted*
  command expansion (`$1 "$(cat "$2")"`), which **word-splits**, so a multi-word value would reach
  the agent as extra argv words. That is the whole risk: unquoted parameter expansion is never
  re-scanned for shell operators, so `sonnet; curl x` arrives as the literal argv words `sonnet;`,
  `curl`, `x` and nothing executes. This is a well-formedness check, **not** an injection guard —
  do not re-tighten it to a charset on security grounds. It deliberately admits provider-prefixed
  and tagged IDs (`openai/gpt-5`, `gpt-oss:20b`), which non-claude agents use.

A failing value is **dropped, never an error**: the agent launches with no flag and `validate()` stays
permissive, because failing validation would make the whole file read as "no JSON workflow" and
silently disable autopilot over a typo. The editor's Model field flags a multi-word value `Invalid` inline
(reusing the same affordance that renders `Required`). Since the allowlist landed (see **Per-entry
agent**) an off-allowlist `agent.command` no longer reaches the launch at all, so the resolved command
is always a known agent unless Settings → Main Terminal itself holds one that isn't — the one
remaining silent drop, which the editor does not flag. A *typo* is not caught either — this is not a known-model list, and model names are per-agent, so `opus` under `codex`
fails in the agent terminal, not in Clearway.

`agentsAcceptingModelFlag` and `agentAllowlist` hold the same three names today but are separate
lists with separate contracts: the allowlist says what Clearway can launch (it renders Settings →
Main Terminal's picker rows in `SettingsView` as well as the editor's), the gate names what accepts
`--model`. Adding an agent to one does not add it to the other.

There is **no workflow-wide default model** — each entry is independent, and an omitted model means
"no flag", not "inherit".

Applied at three launch sites: `planningAgentCommand` (Plan), `performLaunch` (autopilot), and the
**Run in New Terminal** launcher tab. The last two resolve through `workflowAgentCommand(for:action:)`;
`planningAgentCommand` applies `applyModel` itself, since planning has no `Action` to pass, and reads
the coordinator's cached `rawWorkflowDefinition` rather than loading from disk per launch. Routing the
two action sites through one helper is what keeps a step's model with the agent it was authored
against: **the model and the command must travel together**. A workflow that
sets `agent.command: "codex"` while Settings → Main Terminal is `claude` would otherwise launch
`claude --model gpt-5.4-codex` from that tab, which claude rejects outright (exit 1, "There's an issue
with the selected model") — a broken launch, exactly what `agentsAcceptingModelFlag` exists to
prevent. So `runWorkflowAction` stamps the whole resolved command onto `TerminalTab.launcherCommand`
(alongside `stepSlug`), and `ContentView` reads it back as
`activeTab.launcherCommand ?? settings.resolvedMainTerminalCommand`, passing that one value to both
`PromptLauncherView(command:)` (the placeholder) and the submit — so the launcher never understates
what it will run. Nothing else stamps it, so a plain Cmd+T tab still falls back to Main Terminal and
launches bare even while step-badged, and the value dies with the tab. **Run in Current Terminal**
carries neither model nor agent — it pastes into whichever agent the active tab is already
running, so a `codex` step run that way lands in a live `claude`. There is no launch to resolve or
flag.

A stamped tab is also **exempt from the Main Terminal "None" shortcut**. `appendLauncherTab` normally
promotes straight to a login shell when `mainCommandProvider() == nil`, which would discard the stamp
before anything could read it (the tab becomes a `.surface`, and `ContentView` reads `launcherCommand`
only while `isLauncher`) — the step's prompt would then be pasted into a shell instead of run.
`resolveAgentCommand` never returns empty, so a step run always *has* an agent to launch; the
promotion is therefore gated on `command == nil`, keeping the launcher up for step runs while Cmd+T
still opens a login shell. The stamp itself is observed in tests through
`WorkTaskCoordinator.launcherTabAppender`, a `nil`-in-production seam beside `workflowAgentLauncher` —
`appendLauncherTab` needs a live `ghostty_app_t`, so without it the whole "Run in New Terminal" wiring
is unpinnable. The promotion gate above stays untestable for that same reason.

### Per-entry agent

`planning.command` and each action's `command` name the agent that entry launches on, overriding
`agent.command` for that entry only — which is what makes mixing agents inside one workflow possible
(implement on `claude`, review on `codex`). `resolveAgentCommand(entryCommand:workflowCommand:)`
walks four levels and takes the first that yields an agent:

1. the entry's own `command`
2. the workflow-wide `agent.command`
3. Settings → Main Terminal
4. `SettingsManager.defaultMainTerminalCommand`

Levels 1–2 are gated by `agentAllowlist` (`claude`, `grok`, `codex`), matched on the value's **last
path component** — so `/opt/homebrew/bin/claude` is admitted and **launched verbatim**, never
rewritten to a bare `claude` (the last component gates the check, never the launch, matching
`acceptsModelFlag`, which also tests the last component and never rewrites). The whitespace check
runs **before** the path check and is what makes the rest true: `lastPathComponent` splits on `/`
alone, so without it `/Users/me/My Tools/claude` and `claude --dangerously-skip-permissions /claude`
both pass — the first launches broken (the command expands unquoted and word-splits) and the second
smuggles the flags the allowlist exists to exclude. It is also what keeps the two gates agreeing:
`acceptsModelFlag` tests the *first* whitespace-separated token, so a whitespace-bearing value that
slipped through here would silently lose its `--model`. A *relative*
path (`./claude`) is admitted the same way and runs from the worktree; deliberately not tightened,
since the repo-authored file already runs arbitrary shell through `hooks.after_create` (see **No
trust gate**) — a rule here would guard a door standing next to an open one.

Three invariants hold this together:

- **The gate is launch-time only, never `validate()`.** An off-allowlist value falls through to the
  next level and is otherwise ignored. Failing validation would make the whole file read as "no JSON
  workflow" and silently disable autopilot over a typo — the same rule `model` follows.
- **Level 3 is deliberately ungated.** The Settings picker already constrains it, and gating it would
  disturb the Cmd+T "None" login-shell path (`appendLauncherTab` promotes to a login shell on a `nil`
  command).
- **The editor's pinned Agent row hides below the save bar.** `performSave` deletes the file when it
  would hold neither actions nor planning, so a workflow-wide agent set on an empty editor would be
  discarded — and, on a hand-authored agent-only file, would delete it on the first touch. The row
  renders only when there is something to persist, matching the actions header, which is likewise
  hidden in the empty state.
- **`agentAllowlist` and `agentsAcceptingModelFlag` stay separate lists** even though both hold the
  same three names: one says what Clearway may *launch* — it is the single source for both the
  Settings → Main Terminal picker's rows and the editor's Agent pickers — the other what accepts
  `--model`. Adding an agent to one does not add it to the other. After this change every workflow-launched command is
  allowlisted, so the model-flag gate is always true on that path — it is kept as the seam that holds
  the two contracts apart.

**Knowingly breaking:** a multi-word workflow-wide `agent.command` (e.g.
`"claude --dangerously-skip-permissions"`) used to be honored verbatim and now falls through to
Settings → Main Terminal. Exempting the workflow-wide level would reinstate a two-rule split; instead
the loss is loud — the editor's flagged row names the agent that runs instead (resolved through
`resolveAgentCommand`, so it can never name a stale level), and README documents it.

`command` and `model` compose: `applyModel` still runs on the *already-resolved* command, so an entry
naming its own agent gets that agent's `--model` flag. Both action launch sites route through
`workflowAgentCommand(for:action:)` and Plan through `planningAgentCommand`, which is what keeps a
step's model with the agent it was authored against.

The editor stores all three values as **raw strings** (`WorkflowEditorModel.agentCommand`,
`EditorAction.command`, `EditorPlanning.command`), not an enum — an enum would collapse a
hand-authored off-allowlist value on open. The pickers offer `Default` plus the three agents; a
stored value that is not exactly one of them keeps its own selected row, unflagged when it is honored
(a path to an agent) and flagged with its consequence when it is not — the flag names the agent that
actually runs instead, resolved by `resolveAgentCommand` with that entry's own value removed, since a
hard-coded level would be wrong whenever the level above it is unset. `toDefinition` now takes
`agent.command` from the model and carries only the reserved `timeoutMs` from `base`;
`AgentSettings.encode(to:)` omits both fields when they are at their defaults, so naming an agent on a
previously agent-free file doesn't newly write a `timeout_ms` the user never asked for.

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

- Default `true` at creation **iff** the project has a valid `WORKFLOW.json` **and the task has content** (`WorkTask.hasContent` — a non-empty title or body). A manually-created worktree with a blank `TASK.md` seeds `autopilot: false` (paused, written explicitly — `nil` would read as on and launch anyway) and its toolbar button is **disabled** until the user gives it something to do — as it also is while the task is a hidden shadow with no current step, since the engine ignores such a worktree and play would have nothing to start. Non-JSON projects have no `autopilot` field.
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
