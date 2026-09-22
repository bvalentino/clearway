# Run the After create hook in a separate Setup tab

**Date:** 2026-09-22
**Base:** 66145eb214d293794647be6d0599737c1dc00220 (Release v2.0.0)

When Clearway creates a worktree and the project has an After create hook, the hook today is
pasted raw into the worktree's secondary panel, and that panel is forced open. The panel then takes
vertical space from the agent tab for as long as the worktree is on screen. This change runs the
hook in a second main-terminal tab titled "Setup" instead. The tab opens without taking focus or
becoming active, it always sits after the worktree's first tab, and it runs the hook with the same
PATH export and failure banner the Before remove hook gets. The secondary panel goes back to
following only "Open secondary terminal on start".

## Decisions

| # | Decision | Source |
| --- | --- | --- |
| 1 | The hook runs in a second main tab, not the secondary panel. The panel is no longer revealed or used by the hook. | Operator (TASK.md) |
| 2 | The tab is titled "Setup" for its whole lifetime. The shell's OSC title never replaces it. | Operator |
| 3 | The Setup tab is a login shell in the worktree directory. The hook is sent to it after the prompt is up, so the shell remains at a live prompt when the hook ends. The user closes the tab. | Operator |
| 4 | The hook is wrapped by `hookShellCommand`, the same PATH export and failure banner the Before remove hook uses. The wrapper is not changed, so the red `[hook failed: exit N]` banner prints on failure only. A zero exit prints nothing and returns to the prompt. | Operator (confirmed 2026-09-22: failure-only banner, wrapper unchanged) |
| 5 | Tab 1 stays active and first responder. The Setup tab never activates and never calls `transferFirstResponder`. | Operator |
| 6 | Ordering is structural, not timed. The Setup tab is appended by `appendTab` itself when it adds the **first** tab to a pane that has a pending Setup hook. Every first-tab path goes through `appendTab`: login shell, shell saved command, and the async agent paths (`startAgentTab`'s `Task`). So Setup is always appended right after tab 1, in the same runloop turn, whichever path built tab 1. | Mine. The alternatives lose: appending Setup from the create handler lands it before an agent tab that is still awaiting PATH. Inserting tab 1 at index 0 instead would leave a strip showing only "Setup" with no active tab during the PATH wait. Threading a completion through `pane(for:)`, `run`, and `startAgentTab` adds plumbing to three call sites for the same effect. |
| 7 | `appendTab` stays the one door for main tabs. It gains `name: String? = nil` and `activate: Bool = true`. Setup calls it with `name: "Setup", activate: false`. There is no second append path. | Mine. This keeps the invariant in `Sources/App/CLAUDE.md` ("the one door every main tab goes through"). |
| 8 | The pending hook is stored in its own per-worktree map (`pendingSetupHooks: [String: String]`), set by `markWorktreeCreated(_:afterCreateCommand:setupHook:)` and removed in `cleanupState`. It is not part of the `createdWorktrees` mark, because `takeFirstTabSource` consumes that mark when the pane is built, which is before an agent first tab lands. `setupHook:` is a required label, so the one production caller has to state it. | Mine |
| 9 | The hook line is built after `await ShellEnvironment.awaitPath()`, and the resolved path is passed to `hookShellCommand(_:path:)`. That function gains a `path` parameter that defaults to `ShellEnvironment.path`, so the Before remove call site does not change. The line is built late because it `export`s PATH inside a login shell that already has the user's full PATH. A baseline-only PATH read before resolution finishes would downgrade the PATH the hook sees. | Mine |
| 10 | Delivery is `awaitShellPrompt(on:)` followed by `sendPaste`. This is the same readiness gate `run(_:in:app:)` uses for shell commands. `sendPaste` keeps multi-line hooks intact, which `sendCommand` does not: it drops everything after the first newline. | Mine |
| 11 | The display title rule is one static function on `TerminalTab`: the name if there is one, otherwise the surface title, otherwise "Terminal". Both the chip and the close-confirmation dialog title (`ContentView.beginCloseTab`) use it, so the dialog reads `Close tab "Setup"?`. | Mine |
| 12 | `runHookInSecondary` and `revealSecondaryForHook` are deleted along with the test that pins them. Nothing else calls them. | Operator (panel obeys the setting only) |
| 13 | Edge case, accepted: if a saved `.agent` first tab refuses to launch (prompt-file write failure, `startAgentTab`'s `.argv` refusal), no first tab lands and the Setup hook stays pending. It then runs as tab 2 when the user next opens a tab in that worktree. If the pane is torn down first, `cleanupState` drops it. | Mine. This keeps "Setup is never tab 1" without adding a special failure path. |
| 14 | Before remove, the create sheet's "Run agent command after create" picker, hook storage and interpolation, ⌘T / ⌥⌘T / `+`, and task terminals are all unchanged. | Operator |
| 15 | A failed After create hook surfaces only as the red exit banner inside the background Setup tab. No chip mark, no activation. | Operator (confirmed 2026-09-22). Revisit with a Setup-chip failure mark only if missed failures prove costly. |

## Assumptions (verified)

1. The After create hook is read, interpolated, and blank-filtered by `WorktreeManager.hookCommand`, which returns `nil` for a blank or whitespace-only template (`Sources/App/WorktreeHooks.swift:18-21`, `Sources/App/Worktree.swift:236`). A blank hook therefore needs no new check.
2. The hook is currently run from `ContentView`'s `onChange(of: worktreeManager.lastCreatedBranch)` handler via `runHookInSecondary` (`Sources/App/ContentView.swift:369-376`). That function force-reveals the panel through `revealSecondaryForHook` (`Sources/App/TerminalManager+Panels.swift:16-30`).
3. `markWorktreeCreated` runs before `detailSelection = .worktree(wt)` in that handler (`ContentView.swift:366-367`). The pane is built later, by `activate` → `pane(for:)` on selection (`ContentView.swift:327`, `TerminalManager.swift:178`). So a mark set in `markWorktreeCreated` is in place before any tab is appended.
4. Every first-tab path ends in `appendTab`. The paths are `.loginShell` → `appendTab` (`TerminalManager.swift:201-202`); `.mainTerminalAgent` → `startAgentTab` → `appendTab` inside its `Task` after `awaitPath` (`TerminalManager+Agent.swift:74-107`); and `.savedCommand` → `run`, which is `appendTab` for `.shell` or `startAgentTab` for `.agent` (`TerminalManager+Commands.swift:12-35`).
5. `pane(for:)` registers the pane with zero tabs before it appends the first one (`TerminalManager.swift:189-191`). `appendTab` can also create the pane itself (`TerminalManager.swift:354-362`). So "the pane had no tabs before this append" identifies the first tab on both branches.
6. `appendTab` currently always sets `activeId` and calls `transferFirstResponder` (`TerminalManager.swift:350-351, 366`). No non-activating append exists.
7. `TerminalTab` has only `id` and `surface` (`Sources/App/TerminalTab.swift:10-13`). The chip title comes from `surface.title`, falling back to "Terminal" (`Sources/App/MainTerminalTabStrip.swift:87`), and the close dialog repeats that rule (`ContentView.swift:986`).
8. Only the active tab's surface is mounted (`ContentView.swift:888-892`). An inactive Setup surface still spawns its shell at creation: `ghostty_surface_new` runs in `SurfaceView.init` (`Sources/Ghostty/Ghostty.SurfaceView.swift:107-123`). Its `pwd` is set from the `GHOSTTY_ACTION_PWD` app action, not from rendering (`Sources/Ghostty/Ghostty.App.swift:266-270`). So `awaitShellPrompt` works on an unmounted surface, with its 750 ms fallback as the backstop (`TerminalManager+Commands.swift:98-113`).
9. `hookShellCommand` exports `ShellEnvironment.path`, runs the hook in a subshell, prints `[hook failed: exit %d]` in red when the status is non-zero, and `exit`s with the hook's status. It runs all of this inside `/bin/sh -c` (`Sources/App/ContentViewHelpers.swift:20-29`). Pasted into a login shell, the `exit` ends only that `/bin/sh`, so the login shell survives.
10. `ShellEnvironment.path` never starts a resolution and may be baseline-only. `awaitPath()` resolves one if none is known (`Sources/App/ShellEnvironment.swift:14-38`).
11. Closing a tab whose surface reports `needsConfirmQuit` goes through `tabCloseQueue` (`ContentView.swift:983-990`). While the pasted `/bin/sh` is the shell's foreground job, the Setup tab gets that confirmation with no new code.
12. A clean child exit closes a main tab (`TerminalManager.swift:457-460`). The Setup tab's child is the login shell, which does not exit when the hook ends, so the tab stays open.
13. The secondary panel's initial visibility is set only by `setInitialPanelVisibility` from `openSecondaryOnStartProvider` (`TerminalManager.swift:262-271`). With the reveal gone, nothing else touches it after creation.
14. `pendingSetupHooks` has to be cleared wherever `createdWorktrees` is. That place is `cleanupState` (`TerminalManager.swift:517-529`), which both `removeSurface` and `closeWorktree` reach.

No empirical probes were run. Every assumption above was checked by reading the code.

## Objective and success criteria

A worktree created with a non-blank After create hook opens on its agent/first-tab source at full
height, focused. The hook runs in a background "Setup" tab and leaves its output there. The criteria
are the TASK.md acceptance list:

- Two tabs: tab 1 is the first-tab source and tab 2 is "Setup", which shows the hook's output.
- Tab 1 is active and first responder from the start. It stays that way while Setup opens and while the hook runs, with no flicker to tab 2.
- This holds whether tab 1 is an agent (async), a saved shell command, or a login shell. Setup is always tab 2.
- The Setup chip reads "Setup" throughout, even after the shell sets its own title.
- When the hook ends, the tab is at a live prompt in the worktree directory. On failure the red exit-status banner is shown. There is no auto-close and no modal.
- A hook that needs a tool on the app's resolved PATH works.
- A blank or whitespace-only hook opens no Setup tab.
- The secondary panel after creation matches "Open secondary terminal on start", whether or not a hook is set.
- Closing Setup while the hook runs asks for the usual running-process confirmation.
- `./scripts/ci.sh` passes.

Tab order, focus, and the live transcript need a real `ghostty_app_t`. Build agents do not launch the
app, so the operator checks those criteria by hand.

## Commands

From `CLAUDE.md` `## Pipeline`:

| Step | Command |
| --- | --- |
| Every build task, and simplify (regression check) | `./scripts/ci.sh` |
| Sign-off (full gate) | `./scripts/ci.sh` |

Lint alone: `swiftlint lint --quiet`. Before sign-off, run `git status --porcelain` and report untracked
files. `default.profraw` is expected after a Debug launch.

## Files touched

- `Sources/App/TerminalTab.swift`: add `name: String?` to `TerminalTab`, and a static display-title rule (name, else surface title, else "Terminal").
- `Sources/App/TerminalManager.swift`: add `name:` / `activate:` to `appendTab`; add `pendingSetupHooks`; add `setupHook:` to `markWorktreeCreated`; add an internal `takeSetupHook(for:)` for tests; have the first-tab append trigger the Setup tab; clear the map in `cleanupState`; update the doc comment on `appendTab`.
- `Sources/App/TerminalManager+Setup.swift` (new): open the Setup tab through `appendTab(name: "Setup", activate: false)`, then run a `Task` that does `awaitPath` → `awaitShellPrompt` → `sendPaste(hookShellCommand(hook, path:))`.
- `Sources/App/TerminalManager+Panels.swift`: delete `runHookInSecondary` and `revealSecondaryForHook`.
- `Sources/App/ContentViewHelpers.swift`: add `path: String = ShellEnvironment.path` to `hookShellCommand`.
- `Sources/App/ContentView.swift`: in the post-create handler, pass the interpolated hook as `setupHook:` and drop the secondary call and its comment; have `beginCloseTab` use the display-title rule.
- `Sources/App/MainTerminalTabStrip.swift`: pass the tab's name into `TerminalTabChip` and use the display-title rule.
- `Tests/TerminalManagerTests.swift`: delete `test_runHookInSecondary_forcesSecondaryVisible_overridingOpenOnStartOff`; update the `markWorktreeCreated` call sites for `setupHook:`; add tests (below).
- `Sources/App/CLAUDE.md`: fix the handler's step list (lines ~210-219) and the `appendTab` door paragraph (~323), which no longer always activates and now spawns Setup after a created worktree's first tab.
- `Sources/Ghostty/CLAUDE.md:6`: this line cites `revealSecondaryForHook` as the pure-helper example. Point it at `TerminalManager.firstTabSource` instead.
- `README.md:58`: say the after-create hook runs in a "Setup" tab.

## Testing strategy

XCTest in `Tests/`, run by `./scripts/ci.sh`. Anything that needs a `ghostty_app_t` is untestable, so
each rule is lifted into something a test can reach:

- The display-title rule: a name wins over a non-empty surface title; no name and an empty title gives "Terminal"; no name and a title gives the title.
- The pending Setup hook: `markWorktreeCreated(..., setupHook: "x")` then `takeSetupHook` returns `"x"` once and `nil` after. A `nil` hook records nothing. `closeWorktree` / `removeSurface` clear it.
- Panel independence: with a setup hook marked, `secondaryVisible` after `setInitialPanelVisibility` equals the provider's value for both `true` and `false`.
- The hook line: `hookShellCommand("make setup", path: "/opt/bin:/usr/bin")` exports that escaped path, wraps the hook in a subshell, carries the failure banner, and is a `/bin/sh -c` invocation.

The ordering and no-activate rules live inside `appendTab` and cannot be exercised without a surface.
The operator checks them by hand (see Objective).

## Boundaries

- Always: route every main tab through `appendTab`; run `./scripts/ci.sh` after the last edit; keep `swiftlint` at zero errors.
- Ask first: changing `hookShellCommand`'s output (it is shared with Before remove); any change to the create sheet or hook storage.
- Never: reveal or write to the secondary panel from the hook; activate or focus the Setup tab; add a second tab-append path.

## Out of scope

- The Before remove hook and its modal sheet.
- The create sheet's "Run agent command after create" picker.
- Where or how hooks are configured, stored, or interpolated.
- The worktree-creation coordinator refactor (task EF9AF5CE).
- ⌘T / ⌥⌘T / `+` menu behavior and shortcuts.
- Task terminals.
- A success banner on zero exit. This would change `hookShellCommand` for Before remove too.
