# New Tab Opens a Terminal

**Date:** 2026-09-18
**Base:** 6b1977af9df8e5ec36ef32e4a5ebb97ea8a6fbdd

Every main-panel tab currently starts as a *launcher*: a prompt text area with an "Open Shell / ESC"
button, which the user must submit or escape before anything runs. That screen is friction on the
way to a terminal. This change deletes it. ⌘T opens a login shell. ⌥⌘T opens the Settings → Main
Terminal command (claude, codex or grok). The tab strip's `+` opens a menu — New Terminal, Claude,
Codex, Grok — whose main-terminal row carries ⌥⌘T. The first tab of a worktree Clearway itself
just created follows the same rule as ⌥⌘T; a worktree that already existed opens a login shell
(Decision 19). ⌘⇧T ("New Shell Tab"), now a duplicate of ⌘T, is retired. Nothing in the app holds a prompt
draft any more: saved commands and Prompts that carry prompt text reach their agent through the
terminal it is running in.

## Decisions

| # | Question | Decision | Source |
| --- | --- | --- | --- |
| 1 | What happens to the prompt launcher? | Removed entirely — `PromptLauncherView`, `TerminalTab.Kind.launcher`, `launcherDrafts`, `launcherAgents`, `pendingFocusTabId`, `promoteLauncher`, `promoteLauncherToAgent`, `startsAsLoginShell`, `appendingToDraft`. No tab is ever a launcher; `TerminalTab` holds a `Ghostty.SurfaceView` unconditionally. | Operator |
| 2 | What does ⌘T open? | A plain login shell, always — independent of Settings → Main Terminal. | Operator (brief) |
| 3 | What does ⌥⌘T open? | The Settings → Main Terminal command, run bare via `buildBareCommand`. Disabled (menu item greyed, no-op) when Main Terminal is "None". | Operator (brief) |
| 4 | What does the tab strip's `+` show? | A menu: New Terminal, Claude, Codex, Grok — in that order. New Terminal shows ⌘T. The row matching the configured Main Terminal command shows ⌥⌘T; every other row shows none. With Main Terminal at "None" no agent row shows a shortcut. | Operator (brief) |
| 5 | What is a worktree's first tab? | ~~The Main Terminal command if one is set, else a plain login shell. Same rule as ⌥⌘T, so opening a worktree and pressing ⌥⌘T give the same thing.~~ **Superseded by Decision 19.** | Operator |
| 6 | What happens to ⌘⇧T? | Retired. `NewShellTabMenuItem` and its focused value are deleted, the `[.command, .shift]` `"t"` claim is dropped, and `AppKeyboardShortcutsTests` gains a not-claimed pin beside ⌘⌃2 / ⌘⌃3 — the project convention for a shortcut Clearway itself retires. | Operator |
| 7 | Where does the menu's agent order come from? | `agentAllowlist` is reordered to `["claude", "codex", "grok"]` and read by the `+` menu. One list, not a second hardcoded order beside it. Its other reader — Settings → Main Terminal's picker rows — reorders with it, which is the same order the menu shows. | Spec |
| 8 | How are agent names displayed? | `agentAllowlist` holds command names (`claude`), the menu renders `.capitalized` (`Claude`). The allowlist stays the command spelling because it is what gets executed. | Spec |
| 9 | What if Main Terminal holds a command not in the allowlist? | No `+` row carries ⌥⌘T, and ⌥⌘T still runs the configured command. `mainTerminalCommand` is a free `String` (`SettingsManager.swift:59`) and the picker is bound to it, so a stored value outside the list is reachable. The shortcut belongs to the setting, not to the list. | Spec |
| 10 | How does an agent tab get the resolved PATH? | The same way the launcher did: `await ShellEnvironment.awaitPath()`, then `buildBareCommand`. A login-shell tab needs no await (the shell resolves its own PATH) and stays fully synchronous, so ⌘T never defers a frame. | Spec |
| 11 | What covers the frame between an agent tab being asked for and its surface existing? | An in-flight marker per worktree on `TerminalManager`, the same shape as `beginTaskLaunch` / `endTaskLaunch` (`TerminalManager+TaskTerminals.swift:65-71`). While it is set, `detailView` renders neither the "⌘T for a new tab" placeholder nor a tab strip, so a worktree whose first tab is an agent does not flash the empty state. ~~It also makes a second ⌥⌘T during the wait a no-op rather than a second agent.~~ **Second sentence superseded by Decision 20.** | Spec |
| 12 | What happens to a saved command of kind `.agent` with `autoRun` on? | Unchanged mechanism: `buildAgentPromptCommand` hands the prompt to the agent as one argv element in the tab's own command. Only the launcher hop is removed. Pasting into a booting agent TUI instead would race its startup with no readiness signal to gate on — `awaitShellPrompt` keys on OSC 7 `pwd`, which an `exec`'d agent never emits. | Spec |
| 13 | What happens to a saved command of kind `.agent` with `autoRun` off ("stage, don't run")? | The agent tab opens bare and the prompt is pasted into it, unsubmitted, after `awaitShellPrompt`'s fallback window — the closest surviving equivalent of seeding the launcher draft. Argv delivery cannot stage. | Spec |
| 14 | What happens to the Prompts aside's play button? | Nothing at the call site. `sendToActiveMainTab(_:asCommand:)` loses its `.launcher` branch and keeps its `.surface` branch, so a prompt pastes into whatever the active tab is running. It still opens no tab of its own. | Operator (decision 1, read as: the draft branch is replaced by the paste branch) |
| 15 | Does `canSendToActiveMainTab` survive? | Yes, with its meaning narrowed to "there is an active surface". `TodosPanelView.swift:40` is its one reader and still needs a gate; folding it into `activeMainSurface != nil` at that call site would put the rule in the view. | Spec |
| 16 | Does `TerminalManager+Launcher.swift` survive? | The file is renamed to `TerminalManager+Agent.swift` and keeps `buildBareCommand` (read by `WorkTaskCoordinator.taskTerminalLaunchCommand`, `WorkTaskCoordinator+TaskTerminal.swift:49`) plus the new async agent-tab append. `promoteLauncherToAgent` goes. | Spec |
| 17 | Does the "⌘T for a new tab" empty-state copy change? | No. ⌘T still opens a tab, and the strip still hides itself at zero tabs (`MainTerminalTabStrip.swift:96-99`). | Spec |
| 18 | What happens to Settings → Main Terminal's footer ("Choose \"None\" to open new tabs directly in a login shell")? | Removed entirely, not reworded. It is false now that ⌘T always opens a login shell, and the standing rule is no helper text beneath a setting by default. The "None" picker row stays. | Operator (added at T7) |
| 19 | What is a worktree's first tab? (supersedes 5) | It depends on who created the worktree. A worktree Clearway itself created this session opens on the Main Terminal command, if one is set; a worktree that already existed opens a plain login shell, whether it is selected for the first time this session, on app launch, or reopened after its terminals were closed. The signal is a mark the creation path sets — `TerminalManager.markWorktreeCreated`, called from the one point every creation door funnels through (`WorktreeManager.lastCreatedBranch`) — never a timestamp. `takeFirstTabCommand` consumes it. | Operator (hands-on check, after T7) |
| 20 | Which launches may an in-flight marker refuse? (supersedes 11's second sentence) | Only ⌥⌘T. The marker stays the rendering gate for every agent launch, but refusing on it is `startAgentTab`'s `refuseWhenInFlight`, true for the ⌥⌘T door alone — a second press during the PATH wait is a repeat of the first, not a second agent. A saved `.agent` command passes `false` and always opens its own tab: the marker is per worktree and held across `await ShellEnvironment.awaitPath()`, so a second saved agent command started shortly after the first on a cold launch was silently dropped. Only the launch that owns the marker ends it, so a launch that passed it by cannot clear the gate out from under its owner. | Operator (review finding) |
| 21 | Is ⌥⌘T claimed when Main Terminal is "None"? | Claimed unconditionally. `AppKeyboardShortcuts.claims` is process-scoped and window-independent, so it cannot vary with a setting; the menu item greys out instead and the key stays claimed — the same shape as ⌘J / ⌘B, whose `PanelToggle` `nil` gate greys the item without releasing the combo to the shell. | Operator (review-pr step) |
| 22 | What does the detail pane show while a cold-launch PATH resolution stalls an agent-first worktree? | Nothing. The in-flight marker of Decision 11 suppresses the placeholder and the tab strip, and no spinner or other indicator replaces them. The wait is one runloop turn in every case but a cold first launch (Assumption 5), so an indicator would flash for a frame far more often than it would inform. | Operator (review-pr step) |

## Assumptions

Each was verified by reading the codebase at base `6b1977a`. No probe scripts or temporary files
were written, into the repo or the scratchpad; nothing here needed an empirical probe.

1. **The launcher is the only thing `TerminalTab.Kind` distinguishes.** `Kind` has exactly two cases,
   `.launcher` and `.surface(Ghostty.SurfaceView)` (`TerminalTab.swift:26-29`). `surface` and
   `isLauncher` are its only accessors (`TerminalTab.swift:32-41`). Deleting `.launcher` collapses
   `Kind` away and leaves `TerminalTab` as `id` + a non-optional surface.
2. **Every way to create a main tab goes through `appendLauncherTab`.** Its three callers are the
   `+` button (`MainTerminalTabStrip.swift:176`), ⌘T (`ContentView.swift:132`), and a saved agent
   command (`TerminalManager+Commands.swift:27`); `appendShellTab` wraps it
   (`TerminalManager.swift:318`), and the first tab of a pane is built inline by the same shape
   (`TerminalManager.swift:144`, `156`). There is no fourth door.
3. **A tab's surface can be created with a command up front.** `Ghostty.SurfaceView(_:workingDirectory:command:)`
   sets `cfg.command` (`Ghostty.SurfaceView.swift:61,80-91`), which is the pattern
   `CLAUDE.md § Key APIs` mandates over `sendCommand` into a fresh shell.
4. **An agent command needs an explicitly exported PATH; a login shell does not.**
   `buildBareCommand` wraps the agent in `/bin/sh -c 'export PATH="$2"; set -f; exec $1'`
   (`TerminalManager+Launcher.swift:61-65`), and its test says why — `~/.bun/bin/claude` is
   otherwise not found (`TerminalManagerTests.swift:200-208`). Passing `command: nil` spawns the
   configured shell, which resolves its own.
5. **`awaitPath()` returns without suspending once a full resolution has landed.**
   `ShellPathStore.awaitPath` returns `currentPath` immediately when `knownIsFull`
   (`ShellPathStore.swift:53-61`), and `ClearwayApp.init` starts the resolution eagerly
   (`ClearwayApp.swift:135`). So the in-flight window of Decision 11 is normally one runloop turn,
   and long only on a cold first launch.
6. **⌘T, ⌥⌘T and ⌘⇧T all need entries in `AppKeyboardShortcuts.claims`.** A focused surface swallows
   every Cmd combo not listed there, menu key equivalents included, because the view hierarchy is
   offered the equivalent before the main menu (`AppKeyboardShortcuts.swift:6-12`). ⌘T and ⌘⇧T `"t"`
   are claimed today (`AppKeyboardShortcuts.swift:47`, `:52`); `[.command, .option]` currently
   claims only `"b"` (`AppKeyboardShortcuts.swift:53-54`) and must gain `"t"`.
7. **⌥⌘T does not collide with anything.** `[.command, .option]` is claimed for `"b"` alone, and the
   only other Option-modified declaration in the app is the aside toggle
   (`ClearwayApp.swift:203-204`). Grep over `Sources` finds no other `.option` keyboard shortcut.
8. **`agentAllowlist` has two readers at base; this change makes a third.** ~~Exactly one reader
   today: `SettingsView.swift:11` renders the Main Terminal picker rows from it and nothing else
   imports it.~~ **Corrected at the review step.** `CommandEditorSheet.swift` was already a second
   reader at base `6b1977a` — its agent picker (`:58`), and `agentAllowlist.first` as a new saved
   command's default agent (`:21`) — and `agentMenuRows` makes a third. Reordering the list
   therefore reorders both pickers **and** changes which agent a newly created saved command
   defaults to, which is why that head entry is pinned by
   `AgentMenuRowTests.testFirstEntryIsTheNewSavedCommandDefault`.
9. **`buildAgentPromptCommand` has one call site.** `promoteLauncherToAgent`
   (`TerminalManager+Launcher.swift:38`). Decision 12 keeps the helper and moves that call to the
   saved-command path; its seven tests (`TerminalManagerTests.swift:91-186`) stay, with the
   `clearway-launcher` file prefix renamed to match its new caller.
10. **`appendingToDraft` is launcher-only.** Its one production caller is the `.launcher` branch of
    `sendToActiveMainTab` (`TerminalManager.swift:231`); the rest are its four tests
    (`TerminalTabKindTests.swift:46-61`). It and they go.
11. **The Prompts aside and the Todos panel already work against a live surface.**
    `sendPromptToTerminal` calls `sendToActiveMainTab(_:asCommand: false)` (`ContentView.swift:727`)
    and `TodosPanelView.swift:163` calls it with `asCommand: true`; both land in the `.surface`
    branch whenever the active tab is running something, which after this change is always.
12. **`ContentView.swift` is past SwiftLint's 1000-line `file_length` error and survives on a
    file-wide disable at line 1.** This change is net-negative there (the ~35-line launcher block
    goes, one focused value goes), so it needs no split — but it may not grow.
13. **`MainTerminalTabStrip`'s auto-scroll comment names `promoteLauncher`.**
    `MainTerminalTabStrip.swift:160-163` defers the scroll one runloop tick for "synchronous
    follow-up mutations like `promoteLauncher`". The deferral is still needed (an agent tab is
    appended from a `Task`), so the comment is rewritten, not deleted.

## Objective

Opening a terminal in Clearway costs no keystrokes beyond the shortcut.

### Success criteria

1. ⌘T, the File ▸ New Tab menu item, and the `+` menu's **New Terminal** row each append a tab
   already running a login shell, with keyboard focus in it. No intermediate screen, with Main
   Terminal set or at "None".
2. ⌥⌘T and the `+` menu's matching agent row each append a tab already running the Settings → Main
   Terminal command through `buildBareCommand`, with keyboard focus in it.
3. With Main Terminal at "None", the ⌥⌘T menu item is disabled and no `+` menu agent row shows a
   keyboard shortcut. Each agent row still launches its own agent.
4. The `+` menu lists exactly: New Terminal (⌘T), Claude, Codex, Grok — in that order.
5. Creating a worktree lands in a tab running the Main Terminal command, or a login shell when it
   is "None"; the "⌘T for a new tab" empty state is not shown on the way. Selecting a worktree
   that already existed lands in a login shell whatever Main Terminal holds. (Decision 19.)
6. ⌘⇧T does nothing, File ▸ New Shell Tab is gone, and `AppKeyboardShortcuts.claims` returns
   `false` for `[.command, .shift]` + `"T"`.
7. Running a saved agent command with "Append Enter to run immediately" on opens a tab running that
   agent with the prompt already delivered; with it off, the prompt is pasted unsubmitted into the
   running agent.
8. A Prompts play click pastes into the active tab's running process, unchanged.
9. No symbol named `launcher` remains in `Sources/` (`grep -ri launcher Sources/` returns only
   `OpenInAppLauncher`).
10. `./scripts/ci.sh` is green.

## Verification

```bash
./scripts/ci.sh
```

The project's single runner: regenerates the Xcode project (without which `PromptLauncherView.swift`'s
deletion and `TerminalManager+Agent.swift`'s addition are invisible to the build), lints, builds, and
runs the test suite. Do not substitute a hand-written `xcodebuild` line.

Before the sign-off stamp, `git status --porcelain`; a Debug launch leaves an un-gitignored
`default.profraw` behind.

Manual checks (operator, not an agent — per memory, build agents do not launch the app): success
criteria 1-5 and 7, which need a live `ghostty_app_t` and are unreachable from XCTest.

### What the tests can pin

Nothing that needs a `Ghostty.SurfaceView` is reachable from XCTest, so the decision rules are
lifted into pure helpers and those are tested — the split `TerminalManager.revealSecondaryForHook`
and `SurfaceView.claimsShortcut` already make:

- `AppKeyboardShortcuts.claims` — ⌥⌘T claimed, ⌘⇧T not claimed (retired pin), ⌘T still claimed.
- The `+` menu's rows: a pure function from `(agentAllowlist, configuredMainTerminalCommand)` to the
  rows and which one carries ⌥⌘T, covering "None", a listed command, and an unlisted command.
- `buildBareCommand` and `buildAgentPromptCommand` — existing pins carry over unchanged.
- `CommandLaunch.launch` — unchanged; the `.agent` case's consumer changes, not the rule.

## Files this touches

| File | Change |
| --- | --- |
| `Sources/App/PromptLauncherView.swift` | Deleted |
| `Sources/App/TerminalManager+Launcher.swift` | Renamed `TerminalManager+Agent.swift`; keeps `buildBareCommand`, gains the async agent-tab append, loses `promoteLauncherToAgent` |
| `Sources/App/TerminalTab.swift` | `Kind` and `isLauncher` removed, `TerminalTab.surface` non-optional, `appendingToDraft` and `hasActiveTab` removed |
| `Sources/App/TerminalManager.swift` | `pane(for:)` initial tab, `appendLauncherTab` → `appendTab`, `appendShellTab`, `promoteLauncher`/`startsAsLoginShell`/`launcherDrafts`/`launcherAgents`/`pendingFocusTabId` removed, `sendToActiveMainTab` and `canSendToActiveMainTab` simplified, in-flight marker added |
| `Sources/App/TerminalManager+Commands.swift` | `.agent` case rebuilt on the new append |
| `Sources/App/MainTerminalTabStrip.swift` | `+` becomes a `Menu`; the `.launcher` chip case goes |
| `Sources/App/ContentView.swift` | Launcher render block removed, `newShellTabAction` → `newAgentTabAction`, in-flight gate on the empty state |
| `Sources/App/ClearwayApp.swift` | `NewShellTabMenuItem` and its focused value replaced by a ⌥⌘T "New Agent Tab" item |
| `Sources/App/AppKeyboardShortcuts.swift` | `[.command, .option]` gains `"t"`; `[.command, .shift]` loses `"t"` |
| `Sources/App/AgentLaunch.swift` | `agentAllowlist` reordered to claude, codex, grok |
| `Sources/App/SettingsView.swift` | Main Terminal's footer copy removed (Decision 18) |
| `Tests/TerminalTabKindTests.swift` | Launcher and draft cases removed; the surviving `MainTerminal` cases kept |
| `Tests/TerminalManagerTests.swift` | `launcherAgents` and `startsAsLoginShell` cases removed; `buildAgentPromptCommand` / `buildBareCommand` cases kept |
| `Tests/AppKeyboardShortcutsTests.swift` | ⌘⇧T flips to a not-claimed pin; ⌥⌘T claimed |
| New test file | The `+` menu row rule |

## Out of scope

- **The Settings → Main Terminal picker's contents.** Only `agentAllowlist`'s order changes; no
  agent is added or removed, and the "None" row stays. Its footer copy is deleted per Decision 18.
- **The task terminal.** `WorkTaskCoordinator.toggleTaskTerminal` already skips the launcher and runs
  `buildBareCommand` directly (`WorkTaskCoordinator+TaskTerminal.swift:42-51`). Untouched.
- **The secondary terminal.** Always a plain shell; no launcher ever reached it.
- **Per-tab agent identity after launch.** A tab's chip title comes from the surface
  (`MainTerminalTabStrip.swift:73`); nothing records which agent opened a tab, and nothing needs to.
- **`WorktreeGroupStore.openFileWatcher`'s known fd leak** (`CLAUDE.md`), unrelated and still its own
  task.
- **Prompts opening a tab when none exists.** The play button's gate is unchanged; a worktree with no
  tab still swallows the click.
