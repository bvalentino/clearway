# Attribute a task terminal's agent activity to its task, not to main

**Date:** 2026-09-21
**Base:** a311a93ea1bef98532c90eaefee8a89d96a4c9b9

Every agent-capable surface is stamped at creation with a surface id and a worktree id, and a task's
bottom terminal is stamped with the **main worktree's path** because that is its working directory
(`TerminalManager+TaskTerminals.swift:22-24,91-96`). So planning a task with an agent command lights
main's sidebar dot while nothing runs in main. This replaces the worktree id on the wire with one
tagged *activity owner* — `worktree:<path>` or `task:<uuid>` — so a task terminal names its task.
`AgentActivityStore` then derives a per-task phase alongside the per-worktree one, and the task's row
in the Tasks list carries the same dot a worktree row carries, with the same precedence and the same
hues. Main's dot goes back to reflecting only agents running in main's own terminals.

## Decisions

| # | Question | Decision | Source |
| --- | --- | --- | --- |
| 1 | What identity does a task surface carry instead of the main path? | Its **task id**, the UUID the task file's frontmatter serialises (`WorkTask.swift:69`, read back at `WorkTask.swift:138`). It is the only identity a task surface has that survives a Clearway relaunch — the surface id does not — which is the same reasoning that put the worktree path beside the surface id in PR #247. | Operator (brief) + Spec |
| 2 | How do a worktree id and a task id share one wire field? | One tagged string, `AgentActivityOwner`, with cases `worktree(String)` and `task(UUID)`, encoded `worktree:<path>` and `task:<uuid>` and decoded by splitting on the **first** colon. The framing stays exactly two preamble lines, so `AgentHookEnvelope.parse` keeps its shape and the forwarder keeps its `printf '%s\n%s\n'`. A path containing a colon survives, because only the leading tag is taken. | Spec |
| 3 | Why not a third preamble line carrying the task id, empty when absent? | Rejected. It makes the invalid states representable — neither set, both set — and pushes the "which one wins" decision into either the parser or the shell. The tagged single value makes "exactly one owner" the only shape that parses. | Spec |
| 4 | Why not keep `CLEARWAY_WORKTREE_ID` and put `task:<uuid>` in it? | Rejected. The name would be false for half the values it carries and every reader would have to know that. The variable is renamed to `CLEARWAY_ACTIVITY_OWNER`, and `AgentHookIdentity.worktreeIdKey` becomes `ownerKey`. | Spec |
| 5 | Why not two env vars with the script picking between them? | Rejected. `Sources/App/CLAUDE.md` holds the forwarder to deciding nothing — three guards, one `nc` round trip, an unconditional `exit 0`. A `${CLEARWAY_TASK_ID:+…}` fallback is a decision written in `/bin/sh`, in the one component with no test that can reach it. | Spec |
| 6 | What does the rename cost? | An agent **already running** under a pre-rename build carries `CLEARWAY_WORKTREE_ID` and not `CLEARWAY_ACTIVITY_OWNER`, so the reinstalled forwarder exits on its second guard and that agent's dot stays dark until its next `SessionStart`. One-time, at the upgrade only. A compatibility fallback reading either name was rejected as a stopgap. | Spec |
| 7 | Does `Ghostty.SurfaceView` learn what a task is? | No. Its init parameter is renamed `worktreeId:` → `activityOwner: String?` and stays an opaque string it never interprets, so `Sources/Ghostty` keeps knowing nothing about the hook feature (`Sources/Ghostty/CLAUDE.md:14-21`). The provider signature `(UUID, String?) -> [(key: String, value: String)]` is unchanged; only `AgentHookIdentity.environment` learns the owner type. | Spec |
| 8 | What does the store key on? | `AgentSurfaceState.worktreeId: String` becomes `owner: AgentActivityOwner`. The derivation splits in two: `worktreePhases: [String: AgentPhase]` over worktree owners only, and a new `taskPhases: [UUID: AgentPhase]` over task owners only. Each key type is then exactly what its reader holds — a path in the sidebar, a `UUID` in the task list — with no stringly-typed lookup at either end. | Spec |
| 9 | Why not one `[AgentActivityOwner: AgentPhase]` the readers index with a case? | Rejected as the worse trade: it buys one derivation instead of two and costs a `Hashable` key plus a rewrite of the sidebar's call site (`SidebarView.swift:523`), while every reader still has to name its own case. Two dictionaries leave the worktree readers untouched. | Spec |
| 10 | Do task rows get subagent child rows? | No — out of scope per the brief. `worktreeSubagents` is filtered to worktree owners, so a task surface's roster contributes no key and nothing renders. It still counts as work: `effectivePhase` lifts a surface holding a live subagent to `.working` before any derivation sees it (`AgentActivityStore.swift:27-29`), so a task whose lead is between turns with a background subagent still shows the working dot. | Operator (brief) + Spec |
| 11 | Where does the dot rendering live? | `WorktreeRow`'s private `ActivityDot`, its `Dot` enum and the pulsing-glow block are lifted into one internal `AgentActivityDot` view with a nested `Kind` (`waiting` / `working` / `notification`). Both rows render it, so hue, size, tooltip and the glow animation cannot drift between them. `WorktreeRow.dot(phase:hasNotification:isOpen:)` keeps its name, signature and tests; only its return type becomes `AgentActivityDot.Kind?`, which `WorktreeRowTests` does not spell out. | Spec |
| 12 | What is the task row's own rule? | A pure static beside its view, `WorkTaskRow.dot(phase:) -> AgentActivityDot.Kind?`: waiting, then working, then nothing. No `hasNotification` and no `isOpen` — a task terminal raises no notification (brief, out of scope) and a retired surface has already left the store, so there is no closed-but-stale state to gate. Duplicating the three-way worktree static was rejected: the extra arguments would be constants at the only call site. | Operator (brief) + Spec |
| 13 | How does the task row reach the phase? | `WorkTaskListView` takes `@EnvironmentObject private var agentActivity: AgentActivityMonitor` and passes `agentActivity.taskPhases[task.id] ?? .idle` into the row. The monitor is injected on the project `WindowGroup` (`ClearwayApp.swift:175`) and the list renders inside it (`ContentView.swift:754`), so it resolves. | Spec |
| 14 | How does the dot sit beside the existing `terminal` glyph? | Both on the row's trailing edge, glyph first then dot, in the existing `HStack` after the `Spacer()` (`WorkTaskListView.swift:351-356`). The glyph keeps its meaning — a terminal with a live foreground process, agent or not — and the dot is about agent state. | Spec (brief leaves this to the engineer) |
| 15 | Which surfaces still carry no owner? | The before-remove hook sheet (`ContentView.swift:707`) and the debug terminal (`DebugTerminalSheet.swift:47`), unchanged: they pass no owner, the pairs omit the key, and the forwarder's second guard fires. | Spec |
| 16 | Does a task terminal opened before its project path is known get an owner? | Yes, and this is a small behaviour gain: `taskSurface(for:app:projectPath:)` is called with an optional `projectPath` and today stamps `worktreeId: nil` when it is absent, so such a surface is invisible to the pipeline. A task id is always present, so a task terminal now always carries an owner. | Spec |
| 17 | Do the retirement doors need new work? | No. Every door already reports by surface id: `closeTaskTerminal` (`TerminalManager+TaskTerminals.swift:58`), the replace-on-launch path (`:88`), the dead-child path (`TerminalManager.swift:425`), and the window-close sweep, whose `allSurfaces` already includes `taskSurfaces.values` (`TerminalManager.swift:554-556`, `retireAllSurfaces` at `:116`). Retirement is owner-agnostic and stays so. | Spec (verified) |
| 18 | Is main's dot suppressed again? | No. PR #247's un-suppression stands (`SidebarView.swift:523` reads the phase for every worktree including main). The bug is the attribution, not the rendering: once a task surface names its task, nothing is left attributing task work to main. | Spec |
| 19 | What happens to a task terminal when its task is promoted to a worktree? | Start Now → Create **closes it**, retiring any agent surface under `.task(id)`. The link `confirmCreate` writes takes the task out of `backlogTasks`, which is the only renderer of `taskPhases`, so an agent left running there would light no dot anywhere — not the task's row, which no longer renders, and not main's, which this change took it off. Closing was chosen over leaving the agent stranded and invisible, and over widening the change to the aside card. It is the one part of the write `abandonPendingCreate` cannot unwind. | Operator (after review-pr) |
| 20 | Where does that close live — beside the link write, or on the success path? | Beside the link write, in `WorkTaskCoordinator.confirmCreate` (`:116`), before `git worktree add` runs. The build agent proposed moving it to `completePendingCreate` so a failed create would keep the terminal; the operator chose to keep it eager, next to the frontmatter write it belongs to. Consequence: a failed create restores the task to the backlog without its terminal. | Operator (after T7) |
| 21 | Does promote confirm before closing a terminal with a live process, as Delete and Plan do? | No. Both of those ask first (`WorkTaskListView.swift:180`, `:197`, each on "There are processes still running in this task's terminal."); promote closes without asking. Operator's reason: promote is an explicit action on the task, so the close is part of what was asked for. | Operator (after T7) |
| 22 | What happens to a task-terminal launch that is already in flight when the task leaves the list? | It **opens nothing**. Both doors — Cmd+J's launch and `planTask` — claim the task's terminal, suspend on `await ShellEnvironment.awaitPath()`, and would otherwise open a surface a moment after the close that took the task's row away, putting it back in the state D19 exists to prevent. Each re-reads the task after the await through the same rule its entry guard reads — still in `tasks`, still naming no worktree — so **Delete counts as well as promote**: a deleted task has no row for its terminal to report to either. The rule gates minting only: on the toggle door the entry guard is `hasSurface || taskIsStillInBacklog`, because `TaskDetailView` renders a linked task and draws its toggle, and refusing to hide a surface the task already has would strand a live agent in a pane no press can collapse. No new state: the `defer` already on both paths releases the launch claim either way. The plan door's await lives inside `TerminalManager.run`, so `run` takes the resolved `path` as a parameter and the coordinator owns the suspension — otherwise the guard could not see a change that landed during it. | Operator (after review-pr, widened to Delete after T8) |

## Assumptions

Every assumption was verified against the codebase at base `a311a93`. No third-party SDK or API is
integrated, configured or upgraded by this change, so no vendor documentation was fetched. No probe
scripts were written, in the repo or the scratchpad.

1. **A task terminal is stamped with the main worktree's path today.** `taskSurface(for:app:projectPath:)`
   passes `worktreeId: projectPath` (`Sources/App/TerminalManager+TaskTerminals.swift:24`) and
   `openTaskTerminal(for:app:projectPath:command:)` passes `worktreeId: projectPath`
   (`:91-96`). Both comment the conflation in place (`:22-23`). The Plan door reaches the second of
   those through `TerminalManager+Commands.swift:66,80` with `directory` =
   `WorkTaskCoordinator.planWorkingDirectory` = the main worktree's path
   (`WorkTaskCoordinator.swift:194-196`), which is exactly main's worktree id.

2. **A task id is stable across relaunches; a surface id is not.** `Ghostty.SurfaceView` mints
   `let surfaceId = UUID()` per instance (`Sources/Ghostty/Ghostty.SurfaceView.swift:38`).
   `WorkTask.serialize` writes `id: <uuid>` into the frontmatter (`Sources/App/WorkTask.swift:69`)
   and `parse` prefers that value over the caller-supplied one (`:135-138`).

3. **`worktreeId` is init-only on `SurfaceView`.** It is a parameter (`:75`) consumed by
   `Self.agentEnvironment(surfaceId, worktreeId)` (`:92`) and stored nowhere, so renaming it to
   `activityOwner` touches no read site — every caller supplies the value at construction.

4. **The task list is inside the project window.** `ContentView.swift:754` renders
   `WorkTaskListView` and `ClearwayApp.swift:175` injects `agentActivity` on the project
   `WindowGroup`, so the `@EnvironmentObject` resolves there. The standalone Task window
   (`WorkTaskWindow.swift`) is a separate scene with no such injection, which is why it is out of
   scope.

5. **The task list shows backlog tasks only.** `backlogTasks` filters `worktree == nil`
   (`WorkTaskListView.swift:45`). A task that has a worktree lives in that worktree's aside, whose
   card is out of scope.

6. **Every env-var and forwarder name has exactly one Swift home plus its pins.**
   `CLEARWAY_WORKTREE_ID` appears at `Sources/App/AgentHookScript.swift:48,50,74,82` and in
   `Tests/AgentHookSettingsTests.swift:143,149,161`, `Tests/AgentActivityMonitorTests.swift:192`,
   `Tests/AgentHookIdentityTests.swift:15,55`. Nothing in `scripts/`, `README.md` or
   `Sources/Ghostty` names it.

7. **The forwarder and the managed block are reconciled by content, not by version.**
   `AgentHookInstaller.installScript` rewrites the script whenever its bytes differ
   (`Sources/App/AgentHookInstaller.swift:55-58`) and `merge` writes only when the re-serialised
   document differs. So changing the script body reinstalls it on the next enable with no migration
   step, and the hook entries — which name only the script path — do not change at all.

8. **Retirement is keyed on the surface id alone.** `AgentActivityStore.retire(surfaceId:)`
   (`:156-159`) and `AgentActivityMonitor.retire(surfaceId:)` (`:57-60`) never mention a worktree,
   so every existing door keeps working against an owner it knows nothing about.

## Objective

An agent running in a task's bottom terminal lights that task's row in the Tasks list. Main's
sidebar dot reflects only agents running in main's own terminals.

## Success criteria

Behavioural, checked by the operator against the running app:

- Plan a backlog task with an agent command while main's terminals are idle: main's row shows no
  dot; the task's row shows the pulsing orange working dot while the agent works.
- The agent hits a permission prompt: the task's row shows the static purple waiting dot; main stays
  dark.
- The agent finishes its turn with no background subagents: the task's dot goes away.
- The same three outcomes for an agent started through the task terminal's Main Terminal command
  (Cmd+J launch) rather than Plan.
- An agent working in one of main's own tabs still lights main's dot; worktree dots are unchanged.
- Closing the task's terminal, or launching Plan again over it, while an agent is working clears the
  task's dot.
- Closing the project window while a task agent is working and reopening the project leaves no stale
  dot on the task.
- Quitting and relaunching Clearway while a task agent is working: its next hook event lights the
  task's row, not main.
- Two tasks with agents at once each light their own row only.
- Promoting a task with a working agent through Start Now → Create closes its task terminal: the
  task leaves the list with no dot left behind, and main stays dark.
- Promoting a task whose terminal launch is still in flight — Cmd+J or Plan pressed, the shell PATH
  not yet resolved — opens no terminal when that launch resumes, on either door. The task leaves
  the list with nothing running under it.
- Deleting a task whose terminal launch is still in flight does the same: no terminal opens when
  that launch resumes, on either door.

Mechanical, checked by the suite:

- `AgentActivityStoreTests` covers task-scoped attribution and retirement the way it covers
  worktrees today: a task owner contributes to `taskPhases` and not to `worktreePhases`, a worktree
  owner the reverse, a task owner contributes no `worktreeSubagents` key, and retiring a task
  surface clears its task phase.
- `AgentHookEnvelopeTests` pins both tags round-tripping through the two-line preamble, an untagged
  or unknown-tag second line being refused, and a `worktree:` path keeping its spaces and any inner
  colon.
- `AgentHookIdentityTests` round-trips both owner kinds from `AgentHookIdentity.environment` through
  the forwarder's `printf` to `AgentHookEnvelope.parse`, and keeps the no-owner surface unparseable.
- `AgentHookSettingsTests` pins the renamed key on the stamped environment and in the forwarder's
  guards.
- A `WorkTaskRow.dot(phase:)` test pins waiting over working over nothing.
- A `WorkTaskCoordinatorTests` case pins that `confirmCreate` closes the promoted task's terminal.
- `TaskTerminalLaunchCommandTests` cases pin that a task promoted through `confirmCreate`, and one
  deleted through `deleteTask`, both read as gone to a launch that resumes afterwards, while a
  backlog task does not.
- `./scripts/ci.sh` passes.

## Verification commands

From the project's `## Pipeline` section, unchanged:

```
./scripts/ci.sh
```

The regression check for every build task and the full gate at sign-off are the same command; it
regenerates the Xcode project, lints, builds and runs the suite. `git status --porcelain` before any
CI stamp, and expect the un-gitignored `default.profraw` after any Debug launch.

## Files this change touches

Sources:

- `Sources/App/AgentHookEvent.swift` — add `AgentActivityOwner` beside the envelope that carries it;
  `AgentHookEnvelope.worktreeId: String` becomes `owner: AgentActivityOwner`, and `parse` refuses a
  second line that does not decode.
- `Sources/App/AgentHookScript.swift` — `worktreeIdKey` → `ownerKey` (`CLEARWAY_ACTIVITY_OWNER`);
  `AgentHookIdentity.environment(surfaceId:worktreeId:)` → `(surfaceId:owner:)` taking
  `AgentActivityOwner?`; the forwarder's second guard and its `printf` take the new name.
- `Sources/App/AgentActivityStore.swift` — `AgentSurfaceState.owner`; `worktreePhases` and
  `worktreeSubagents` filtered to worktree owners; new `taskPhases`.
- `Sources/App/AgentActivityMonitor.swift` — publish `taskPhases` beside the two existing values,
  change-gated the same way.
- `Sources/Ghostty/Ghostty.SurfaceView.swift` — init parameter `worktreeId:` → `activityOwner:`.
- `Sources/App/TerminalManager.swift` (`:171`, `:325-338`, `:464`) and
  `Sources/App/TerminalManager+TaskTerminals.swift` (`:24`, `:91-96`) — pass a tagged owner.
- `Sources/App/WorktreeRow.swift` — lift `ActivityDot`, the `Dot` enum and the glow block into
  `AgentActivityDot` with a nested `Kind`.
- `Sources/App/WorkTaskListView.swift` — `WorkTaskRow` gains `phase`, its `dot(phase:)` static and
  the trailing dot; the list observes the monitor and passes the phase in.
- `Sources/App/WorkTaskCoordinator.swift` — `confirmCreate` closes the promoted task's terminal
  (D19).
- `Sources/App/WorkTaskCoordinator+TaskTerminal.swift` and
  `Sources/App/TerminalManager+Commands.swift` — both launch doors re-read the task after their
  await and abandon a launch whose task has left the backlog, promoted or deleted;
  `run(_:inTaskTerminalFor:…)` takes the resolved `path` instead of awaiting it (D22).
- `Sources/App/CLAUDE.md` — the agent-pipeline notes that state the framing ("two preamble lines —
  surface id, worktree id"), "Two ids, not one", and "The monitor publishes two values, not three".
- `Sources/Ghostty/CLAUDE.md` — the `agentEnvironment` note's mention of `worktreeId`.

Tests:

- `Tests/AgentActivityStoreTests.swift`, `Tests/AgentHookEnvelopeTests.swift`,
  `Tests/AgentHookIdentityTests.swift`, `Tests/AgentHookSettingsTests.swift`,
  `Tests/AgentActivityMonitorTests.swift` — the owner rename and the new task derivation.
- `Tests/WorktreeRowTests.swift` — unchanged in substance; it never spells `WorktreeRow.Dot`.
- `Tests/WorkTaskCoordinatorTests.swift` — the promote closing the task's terminal (D19).
- `Tests/TaskTerminalLaunchCommandTests.swift` — the rule a resumed launch re-reads the task
  through (D22).
- One new test target file for `WorkTaskRow.dot`. `ci.sh` runs `xcodegen generate`, without which a
  new Swift file is invisible to the build.

## Out of scope

- Subagent child rows and the in-flight tool name for task terminals. Dot only.
- Any change to where a task terminal runs; its working directory stays the main worktree's path.
- `WorkTaskCard` in the aside and the standalone Task window; neither shows a dot.
- A badge on the Tasks sidebar destination itself.
- Notification (blue) dots on task rows: task terminals raise none today and this adds none.
- Re-suppressing main's dot.

## Accepted risks

- A `SIGKILL`ed agent in a task terminal pins the task's dot until its next `SessionStart` — the
  same trade-off worktrees already carry, and the direct consequence of nothing in the pipeline
  having a clock.
- The aside card and the standalone Task window show no activity for a task whose row in the list is
  lit.
- An agent already running when the user upgrades past this change loses its dot until its next
  `SessionStart` (Decision 6).
