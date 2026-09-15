# Plan: Commands View

**Date:** 2026-09-15
**Base:** d94b0b0f879606872a8b1a92e2f38ac144914339

Breaks down `docs/superpowers/specs/2026-09-14-commands-view.md`. Every design decision is settled
there; read it before starting a task, and read this file for what your task is and how it is
checked. The spec's decision numbers are cited inline so you can find the reasoning without reading
it end to end.

## Architecture decisions carried from the spec

1. **Storage is one global, ordered JSON file at `~/.clearway/commands.json`.** Array order *is*
   display order. The path is fixed, not derived from `settings.promptsDirectory`, and never exposed
   in Settings. (Decision 1)
2. **Written `0o600`, in the existing `~/.clearway/` directory**, beside `prompts/`. (Decision 1,
   assumption 10)
3. **No file watcher.** Clearway is the only writer and there is one manager per process.
   (Decision 7)
4. **The manager is process-wide**: a `@StateObject` on `ClearwayApp`, passed down with
   `.environmentObject` on the project `WindowGroup`, exactly like `projectList` and `caffeine`.
   Not per-window like `PromptManager`. (Decision 6)
5. **Names:** `SavedCommand` (model), `SavedCommandManager` (`ObservableObject`), `SavedCommandStore`
   (JSON I/O), `CommandsView`, `CommandEditorSheet`. A bare `Command` was rejected — `command` is
   already a pervasive `String` parameter name in this codebase. (Decision 5)
6. **A command's agent comes from a per-command `agent` field**, chosen in the editor from
   `agentAllowlist` (`AgentLaunch.swift:4`), never from Settings → Main Terminal. (Decision 2)
7. **Clicking a card opens the editor sheet; running happens only from the toolbar Run dropdown**,
   which is the only place with the worktree context a new tab needs. Delete lives in the sheet and
   in a card context menu. (Decision 3)
8. **The Commands destination is ⌃3** (Tasks ⌃1, Prompts ⌃2). The Ctrl+digit claim widens from
   `"1"…"2"` to `"1"…"3"`. ⌘⌃3 — a different combo, the retired aside shortcut — stays unclaimed.
   (Decision 4)
9. **Commands renders in the detail column** with `contentColumn` collapsed to
   `.navigationSplitViewColumnWidth(0)`, the shape `.worktree` already uses. No list/detail split:
   there is no detail, only a sheet. (Decision 8)
10. **Reorder is a plain `List` + `ForEach(...).onMove`**, the mechanism `SidebarView` already uses,
    and is disabled while the All/Terminal/Agent filter is on anything but All. (Decisions 9, 10)
11. **A terminal command runs by appending a shell tab and injecting text into the live surface**:
    `sendCommand` (text + Enter) when auto-run is on, `sendText` (text, no Enter) when off. Never as
    the surface's `command:` — a clean exit auto-closes the tab. (Decision 11, assumptions 2, 3)
12. **An agent command runs through the launcher**: auto-run on → `promoteLauncherToAgent` with the
    command's agent and prompt; auto-run off → the tab stays a launcher with `launcherDrafts[tabId]`
    pre-filled and addressed to that agent. (Decision 13)
13. **The per-tab agent reaches the launcher through `agentOverride`** — a new defaulted parameter on
    `appendLauncherTab` that both suppresses the "Settings command is None → promote to a login
    shell" branch and records the agent in a new non-`@Published` `launcherAgents: [UUID: String]`.
    (Decision 14, assumptions 4, 5, 6)
14. **The Run dropdown is disabled when the command list is empty *or* `ghosttyApp.app` is `nil`.**
    Both preconditions — CLAUDE.md's `PanelToggle` rule. (Decision 15)
15. **`DetailSelection.bottomPanelAction(for: .commands)` is `.noPanel`.** (Decision 18)
16. **A corrupt or unreadable `commands.json` logs a warning and loads as empty**, mirroring
    `WorktreeGroupStore.load`. The file is only rewritten on the next user change, so a transient
    read failure does not destroy data. (Decision 19)
17. **Nothing migrates.** A missing file is the empty list. (Decision 20)
18. **The subtitle "Saved actions for terminal or agents." stays** — the one piece of descriptive copy
    in the view, drawn into the operator's mock. (Decision 16)
19. **The auto-run checkbox reads "Append Enter to run immediately"** for both kinds, verbatim.
    (Decision 17)
20. **`project.yml` is not edited.** Sources are globbed by directory; new files appear once
    `xcodegen generate` runs, which `./scripts/ci.sh` does. (Assumption 1)
21. **No aside tab, no per-project commands, no placeholders or arguments.** (Spec, Out of scope)

## Implementation notes the spec left to the build

These are routes through existing API, not new design. They are written down so seven fresh agents
resolve them the same way.

- **Reaching the surface of a freshly appended shell tab.** `TerminalManager.panes` is `private` and
  `appendShellTab` returns only the tab id, so the run path looks the surface up with the existing
  accessor: `terminalManager.mainTabs(for: worktree.id).first { $0.id == tabId }?.surface`. Works on
  both `appendLauncherTab` branches (Settings command set, and "None"), which a second
  `promoteLauncher` call would not — it returns `nil` for a tab that is no longer a launcher.
- **`sendCommand` keeps only the first line** (`Ghostty.SurfaceView.swift:441-449`). A terminal
  command is a single shell line by construction; do not route multi-line text through it.
- **`SavedCommandStore` takes its directory as an `init` parameter defaulting to the expanded
  `~/.clearway`.** The default is the fixed path decision 1 requires; the parameter exists only so
  `SavedCommandStoreTests` can point at a temp root, the way `WorktreeGroupStore(projectPath:)` is
  tested. It is not a setting and is not read from `UserDefaults`.

## Regression check

Every task's check is the project's one runner:

```bash
./scripts/ci.sh
```

It runs `xcodegen generate` (without which the new Swift files are invisible to the build),
SwiftLint, the build and the full test suite. Do not hand-write an `xcodebuild` line: `build.sh`'s
`PRODUCT_NAME` override breaks `TEST_HOST`.

## Dependency graph

```
T1 (model + pure rules)
 └── T2 (store + manager)
      └── T3 (CommandsView + editor sheet + app-level manager)
           └── T4 (sidebar destination + detail wiring)
                └── T5 (⌃3 claim)

T6 (per-tab agent override)  ── independent of T1–T5
      │
      └── T7 (Run dropdown + run action)  ← also needs T1 (CommandLaunch) and T2 (manager)
```

Run T1 → T7 in order. T6 is logically independent of T1–T5, but it edits `ContentView.swift`, which
T4 and T7 also edit, so keeping the sequence avoids conflicts. Every task leaves the tree compiling
and the suite green.

### T1: The `SavedCommand` model and its two pure rules

**Files:** `Sources/App/SavedCommand.swift`, `Tests/SavedCommandTests.swift`

**What it does.** Adds the model, its `Kind` enum, the pure list filter and the pure launch resolver.
No I/O, no SwiftUI, no `TerminalManager`. This is the layer the spec splits out so the decision rules
are unit-testable — the same split `TerminalManager.revealSecondaryForHook` makes.

`Sources/App/SavedCommand.swift`:

- `struct SavedCommand: Codable, Equatable, Identifiable` with `id: UUID`, `name: String`,
  `kind: Kind`, `text: String`, `agent: String`, `autoRun: Bool`. `text` holds the shell line for a
  terminal command and the prompt for an agent command — one field, since a command is exactly one
  of the two.
- `enum Kind: String, Codable, CaseIterable` with `terminal` and `agent`. Decode of an unknown raw
  value must not crash the whole file load — give `SavedCommand` a custom `init(from:)` that falls
  back to `.terminal` for an unrecognized `kind`, or decode `kind` as `String` and map. Decide once
  here; `SavedCommandStoreTests` pins it (spec, Tests).
- `enum CommandFilter: String, CaseIterable { case all, terminal, agent }` and a pure
  `static func filter(_ commands: [SavedCommand], by: CommandFilter) -> [SavedCommand]`, plus
  `var isActive: Bool` (`self != .all`) on the filter, which is what `.moveDisabled` reads in T3.
- `enum CommandLaunch: Equatable` with `case shell(text: String, execute: Bool)` and
  `case agent(agent: String, prompt: String, submit: Bool)`, and a pure
  `static func launch(for command: SavedCommand) -> CommandLaunch` mapping `kind` + `autoRun` onto it.

`Tests/SavedCommandTests.swift`: `final class SavedCommandTests: XCTestCase` (no temp root needed).

- Filter: `.all` returns every command in input order; `.terminal` and `.agent` return only their
  kind, in input order; an empty input returns empty.
- Resolver: a terminal command with `autoRun` true → `.shell(text:, execute: true)`; false →
  `execute: false`. An agent command with `autoRun` true → `.agent(agent:, prompt:, submit: true)`;
  false → `submit: false`. The agent case carries the command's own `agent`, not any default.

**Acceptance criteria.**
1. `SavedCommand` round-trips through `JSONEncoder`/`JSONDecoder` unchanged (pinned in T2's store
   tests; this task only has to make it possible).
2. `SavedCommand.filter` and `CommandLaunch.launch(for:)` are pure `static` functions with no
   SwiftUI, Foundation-file or `TerminalManager` dependency, and are called by nothing yet.
3. Both are covered by `Tests/SavedCommandTests.swift`.

**Verification.**
- `./scripts/ci.sh` passes with `SavedCommandTests` present and green.
- `grep -n 'import' Sources/App/SavedCommand.swift` shows `Foundation` only.

### T2: `SavedCommandStore` and `SavedCommandManager`

**Files:** `Sources/App/SavedCommandStore.swift`, `Sources/App/SavedCommandManager.swift`,
`Tests/SavedCommandStoreTests.swift`, `CLAUDE.md`

**Depends on:** T1.

**What it does.** Adds JSON persistence and the observable ordered list on top of it, plus the one
CLAUDE.md sentence saying where commands live.

`Sources/App/SavedCommandStore.swift`:

- `init(directory: String = (("~/.clearway") as NSString).expandingTildeInPath)`; the file is
  `<directory>/commands.json`. The directory is created lazily on first save with `0o700` and the
  file written `0o600`, matching `PromptManager.swift:62`, `:66`.
- `load() -> [SavedCommand]` (or `async`, matching `WorktreeGroupStore.load`'s detached shape if you
  keep the manager's load off the main actor): a missing file returns `[]`; unreadable or
  undecodable data logs through `Ghostty.logger.warning` and returns `[]`, mirroring
  `WorktreeGroupStore.swift:64-70`. Never throws to the caller.
- `save(_ commands: [SavedCommand])`: encodes the array in order and writes it atomically
  (temp file + replace), as `WorktreeGroupStore.save` does.

`Sources/App/SavedCommandManager.swift`: `@MainActor final class SavedCommandManager: ObservableObject`
with `@Published private(set) var commands: [SavedCommand] = []`, and `load()`,
`create(_:)`/`add(_:)`, `update(_:)`, `delete(_:)`, `move(fromOffsets:toOffset:)`. Every mutation
updates `commands` then persists the whole array through the store. No file watcher (decision 7).

`Tests/SavedCommandStoreTests.swift`: subclass `TempRootTestCase` (`Tests/TestHelpers.swift:20`) with
`tempRootPrefix` overridden, and construct the store against `tempRoot`.

- Encode/decode round-trip preserves every field of a terminal command and of an agent command.
- Save-then-load preserves array order exactly as written (not sorted, not re-keyed).
- Load of a missing file returns `[]`.
- Load of a file containing garbage bytes returns `[]` and does not throw.
- Load of a well-formed file whose `kind` is an unknown string does not crash and yields the fallback
  decided in T1.

`CLAUDE.md`: one sentence under `Sources/App/` naming `SavedCommandStore.swift` as the owner of
`~/.clearway/commands.json`, that array order is display order, and that there is deliberately no
watcher because the app is the only writer. Keep it to two or three lines; do not restate the spec.

**Acceptance criteria.**
1. A round-trip through `save` then `load` returns an identical array, same order.
2. A missing, unreadable or corrupt file loads as empty and logs rather than throwing or crashing.
3. `SavedCommandManager` is `@MainActor`, publishes an ordered list, and persists on every mutation.
4. Nothing constructs a `SavedCommandManager` yet — this task adds no call sites.

**Verification.**
- `./scripts/ci.sh` passes with `SavedCommandStoreTests` green.
- `grep -rn 'commands.json' Sources/` matches only `SavedCommandStore.swift`.

### T3: `CommandsView`, `CommandEditorSheet`, and the process-wide manager

**Files:** `Sources/App/CommandsView.swift`, `Sources/App/CommandEditorSheet.swift`,
`Sources/App/ClearwayApp.swift`

**Depends on:** T2.

**What it does.** Builds the destination view and its sheet, and makes one manager exist for the
process. The view is not yet reachable — T4 wires the sidebar.

`Sources/App/ClearwayApp.swift`: `@StateObject private var savedCommandManager = SavedCommandManager()`
beside `projectList` and `caffeine` (`:127-129`), and `.environmentObject(savedCommandManager)` on the
project `WindowGroup`'s `ProjectWindow` beside the other three (`:159-161`). Load the list once —
`.task`/`.onAppear` on the window content, or in the manager's `init` — so every window sees the same
populated list.

`Sources/App/CommandsView.swift`:

- Reads `@EnvironmentObject private var savedCommandManager: SavedCommandManager`.
- Header: the title and the subtitle "Saved actions for terminal or agents." (decision 16 — this is
  the only descriptive copy the no-helper-text rule admits here; add none elsewhere).
- An All / Terminal / Agent filter control above the list, backed by `@State var filter: CommandFilter`.
- `List { ForEach(SavedCommand.filter(savedCommandManager.commands, by: filter)) { … } .onMove(…) }`
  with `.listStyle(.plain)` and card-styled rows — name, the command or prompt text, and a
  `Terminal` / `Agent` kind label. Follow `SidebarView.swift:223-228` for the `.onMove` shape.
- `.onMove` returns early when `filter.isActive`, and rows carry `.moveDisabled(filter.isActive)`
  (decision 10; mirrors `SidebarView.swift:221`, `:225`). A move that reaches the manager must be
  expressed against the *unfiltered* indices, which is exactly why it is refused while filtered.
- Tapping a row opens `CommandEditorSheet` for that command; a row context menu offers Delete.
- A floating `+` bottom-right, `.overlay(alignment: .bottomTrailing)` — reuse the button styling of
  `PromptsView.createButton` (`PromptsView.swift:51-66`) rather than inventing a second one. It opens
  an empty `CommandEditorSheet`.
- An empty state when there are no commands, in the shape `PromptsView` uses (`:17-26`).

`Sources/App/CommandEditorSheet.swift`: edits name, kind, agent (shown only for `.agent`, a picker
over `agentAllowlist`), the command/prompt text, and a checkbox labelled exactly "Append Enter to run
immediately". Save calls `create` or `update`; a Delete button calls `delete` and dismisses. Creating
and editing are the same sheet over an optional existing command.

**Acceptance criteria.**
1. One `SavedCommandManager` exists per process and is in the environment of every project window.
2. `CommandsView` renders name, text and kind label per card, filters on All / Terminal / Agent, and
   reorders by drag only while the filter is All.
3. `CommandEditorSheet` edits all six fields (agent only for the agent kind), saves through the
   manager, and can delete.
4. No new descriptive copy beyond the one subtitle.

**Verification.**
- `./scripts/ci.sh` passes (build + SwiftLint; these views have no unit tests — the pure rules they
  call are already covered by T1).
- `swiftlint lint --quiet` reports zero errors for the two new files.
- Manual, after T4 makes the view reachable: `./scripts/run.sh`, create two commands, drag to
  reorder, quit and relaunch, confirm the new order survived and is the same in a second project
  window.

### T4: The Commands sidebar destination

**Files:** `Sources/App/ContentView.swift`, `Sources/App/SidebarView.swift`,
`Tests/BottomPanelActionTests.swift`

**Depends on:** T3.

**What it does.** Adds the third destination and routes it to `CommandsView`.

- `Sources/App/ContentView.swift`: add `case commands` to `DetailSelection` (`:18-22`); answer it in
  `bottomPanelAction(for:)` with `.noPanel` — put it on the existing `case .prompts, .none:` arm
  (`:35`) so the switch stays exhaustive (decision 18). Add a hidden
  `Button("") { detailSelection = .commands }.keyboardShortcut("3", modifiers: .control).hidden()`
  directly after the ⌃2 button (`:365-367`). Add a `.commands` branch to `detailView` rendering
  `CommandsView()`. `contentColumn` (`:726-746`) needs no new branch: its `else` already collapses to
  `.navigationSplitViewColumnWidth(0)`, which is the shape decision 8 asks for.
- `Sources/App/SidebarView.swift`: a `commandsRow` below `promptsRow` (`:193-196`), built with the
  same `destinationRow(_:systemImage:shortcutHint:)` helper, hint `"⌃3"`, tagged
  `.tag(DetailSelection.commands)`, and listed in `body` after `promptsRow` (`:74`). Pick an SF Symbol
  in the register of `text.quote` and `tray` — `terminal` is taken by the empty-tab state; `command`
  or `bolt` fit.
- `Tests/BottomPanelActionTests.swift`: add `.commands` to
  `testDestinationsWithoutABottomPanelGetNothing` (`:27-30`), or a sibling assertion —
  `XCTAssertEqual(action(.commands), .noPanel)`.

Keep the `ContentView` additions small (assumption 13): the view body belongs in `CommandsView.swift`,
not here.

**Acceptance criteria.**
1. The sidebar shows Commands below Prompts, with a `⌃3` badge while Control is held, exactly like
   the other two rows.
2. Selecting it renders `CommandsView` across the full detail width with the middle column collapsed.
3. ⌘J greys out on Commands (`.noPanel`), asserted in `BottomPanelActionTests`.
4. ⌃1 and ⌃2 still select Tasks and Prompts.

**Verification.**
- `./scripts/ci.sh` passes, `BottomPanelActionTests` included.
- Manual: `./scripts/run.sh`, click Commands, hold Control and confirm the `⌃3` badge, confirm the
  middle column is gone and the View menu's bottom-panel item is greyed.
- ⌃3 from the sidebar works at this point; from a *focused terminal* it does not until T5.

### T5: Claim ⌃3 from focused terminal surfaces

**Files:** `Sources/App/AppKeyboardShortcuts.swift`, `Tests/AppKeyboardShortcutsTests.swift`,
`CLAUDE.md`

**Depends on:** T4. The handler must exist before the claim — a claimed combo no handler answers is
taken from the shell and dropped, which is the rule this file exists to enforce.

**What it does.** Widens the Ctrl+digit claim by one and moves ⌃3 from retired to claimed.

- `Sources/App/AppKeyboardShortcuts.swift`: in `claims(flags:chars:keyCode:)`, the scalar range
  becomes `scalar >= "1" && scalar <= "3"` (`:36-40`), and the comment above it that reads
  "Ctrl+1…2 → sidebar destinations" follows (`:33`). Nothing else in the table changes.
- `Tests/AppKeyboardShortcutsTests.swift`:
  - `testControlDigitIsClaimed` (`:55-61`) gains `XCTAssertTrue(claims([.control], "3"))`.
  - `testControlDigitBeyondTheSidebarDestinationsIsNotClaimed` (`:67-73`) drops its `"3"` assertion;
    `"0"`, `"4"`, `"6"`, `"9"` stay.
  - `testRetiredControlDigitThreeIsNotClaimed` (`:129-133`) and its doc comment are removed — ⌃3 is
    no longer retired.
  - `testRetiredCommandControlDigitsAreNotClaimed` (`:120-127`) is **untouched**: ⌘⌃3 is the retired
    aside shortcut, a different combo, and stays unclaimed (decision 4).
- `CLAUDE.md:134-137`: drop ⌃3 from the retired-pin list `(⌘⌃2, ⌘⌃3, ⌃3)`, and change "the Ctrl+digit
  claim therefore spans `"1"…"2"` — the sidebar's two destinations — and ⌃3 is retired with no alias"
  to span `"1"…"3"` over three destinations, with the ⌃3 retirement clause gone. Line `:143` (⌘⌃3 and
  ⌃⌘S retired in `PanelCommands`) is **not** edited.

**Acceptance criteria.**
1. `claims` returns true for ⌃1, ⌃2 and ⌃3, and false for ⌃0 and ⌃4…⌃9.
2. ⌘⌃3 is still not claimed, and its pin test is unchanged.
3. CLAUDE.md no longer describes ⌃3 as retired or the claim as spanning two destinations.

**Verification.**
- `./scripts/ci.sh` passes, `AppKeyboardShortcutsTests` included.
- Manual: `./scripts/run.sh`, focus a terminal surface, press ⌃3 → the sidebar selects Commands and
  no control code reaches the shell. Press ⌃1 and ⌃2 → Tasks and Prompts, unchanged. Press ⌃6 in
  `vim` → still `CTRL-^`.
- `grep -n '⌃3' CLAUDE.md` matches only the `PanelCommands` ⌘⌃3 line.

### T6: Per-tab agent override on launcher tabs

**Files:** `Sources/App/TerminalManager.swift`, `Sources/App/ContentView.swift`

**Depends on:** nothing. Ordered after T5 only because it shares `ContentView.swift` with T4 and T7.

**What it does.** Lets a launcher tab carry its own agent instead of inheriting Settings → Main
Terminal. Nothing passes an override yet; T7 is the first caller. This task is a no-op change in
observable behaviour and must be verified as such.

`Sources/App/TerminalManager.swift`:

- `var launcherAgents: [UUID: String] = [:]` beside `launcherDrafts` (`:205`), **not** `@Published`
  for the same reason `launcherDrafts` is not: the writes that matter are already accompanied by an
  explicit `objectWillChange.send()`.
- `appendLauncherTab(for:app:)` gains `agentOverride: String? = nil` (`:256`), so all existing call
  sites — `appendShellTab` (`:296`) and `ContentView.swift:140` — are unchanged. When it is non-`nil`:
  record `launcherAgents[newTab.id] = agentOverride`, and **skip** the
  `if mainCommandProvider() == nil { promoteLauncher(…) }` branch (`:279-281`), taking the
  `pendingFocusTabId` arm instead. Without that skip, an agent command would be swallowed into a bare
  login shell whenever Settings → Main Terminal is "None" (assumption 4).
- Clear `launcherAgents` at all five sites that clear `launcherDrafts`, or the stale agent leaks onto
  a recycled tab id: `:108` (`closeAll`), `:326` (`promoteLauncher`), `:364` (`closeMainTab`), `:459`
  (`removeSurface`), `:485` (`closeWorktree`) (assumption 6).

`Sources/App/ContentView.swift`: in the launcher branch (`:796-814`), resolve the agent once as
`terminalManager.launcherAgents[activeTab.id] ?? settings.resolvedMainTerminalCommand` and pass that
same value to both `PromptLauncherView(command:)` (`:797`) and the `promoteLauncherToAgent(command:)`
call in `onSubmit` (`:811`). Both, not one — mismatching them would render one agent's name and run
another's (assumption 5).

**Acceptance criteria.**
1. `appendLauncherTab` compiles unchanged at every existing call site.
2. With `agentOverride` nil, behaviour is byte-for-byte what it was, including the promote-to-shell
   branch when Settings → Main Terminal is "None".
3. With `agentOverride` non-`nil`, the tab stays a launcher regardless of that setting, and
   `launcherAgents[tabId]` holds the override.
4. `launcherAgents` is cleared everywhere `launcherDrafts` is.

**Verification.**
- `./scripts/ci.sh` passes; `TerminalManagerTests` still green.
- `diff <(grep -n 'launcherDrafts.remove\|launcherDrafts.removeAll' Sources/App/TerminalManager.swift)`
  against the same grep for `launcherAgents` — five sites each, same lines.
- Manual, both settings values: `./scripts/run.sh`, ⌘T with Settings → Main Terminal set to an agent
  → the prompt launcher appears as before; set it to "None", ⌘T → a login shell appears as before.

### T7: The Run dropdown and the run action

**Files:** `Sources/App/RunCommandMenu.swift`, `Sources/App/ContentView.swift`

**Depends on:** T1 (`CommandLaunch`), T2 (the manager), T6 (`agentOverride`).

**What it does.** Adds the toolbar `Menu` and the code that turns a `CommandLaunch` into a new tab in
the selected worktree. This is the task that settles the spec's one open question.

`Sources/App/RunCommandMenu.swift`: a `Menu` listing `savedCommandManager.commands` in saved order,
plus the run action. Resolve `CommandLaunch.launch(for: command)` (T1) and then:

- `.shell(text:execute:)` — `let tabId = terminalManager.appendShellTab(for: worktree, app: app)`,
  find the surface with `terminalManager.mainTabs(for: worktree.id).first { $0.id == tabId }?.surface`
  (see Implementation notes), then `surface.sendCommand(text)` when `execute`, `surface.sendText(text)`
  when not.
- `.agent(agent:prompt:submit:)` —
  `let tabId = terminalManager.appendLauncherTab(for: worktree, app: app, agentOverride: agent)`.
  With `submit`: `await terminalManager.promoteLauncherToAgent(tabId:in:app:command: agent, prompt: prompt)`
  (`TerminalManager+Launcher.swift:20-51`). Without: `terminalManager.launcherDrafts[tabId] = prompt`
  and leave the tab a launcher; `ContentView`'s T6 resolution already addresses it to `agent`.

`Sources/App/ContentView.swift`: one `ToolbarItem(placement: .primaryAction)` hosting the menu, placed
**before** the Archive item inside the existing `if selectedWorktree != nil` block (`:198-222`), and
`.disabled(savedCommandManager.commands.isEmpty || ghosttyApp.app == nil)`. Both conditions
(decision 15). Add the `@EnvironmentObject` for the manager. Keep the body in `RunCommandMenu.swift`.

**The injection-readiness gate — the spec's open question 1 (decision 12). This task must settle it
by running the app, not by reasoning about it.** The chosen gate is the first non-`nil`
`Ghostty.SurfaceView.pwd` (`Ghostty.SurfaceView.swift:29`, `@Published`, set from libghostty's PWD
action at `Ghostty.App.swift:268-270`), with a short fixed-delay fallback for shells where integration
is inactive. `runHookInSecondary`'s bare `asyncAfter(0.1)` (`TerminalManager+Panels.swift:16-22`) is
precedent for an *already running* shell only, so it does not transfer.

Verify against the running app and record what you observed, in the task's report and in a short
comment at the gate:

1. `./scripts/run.sh`, select a worktree, run a terminal command with "Append Enter" **on**. The
   command must appear on the prompt line and execute once — not be swallowed before the shell's line
   editor starts, and not land twice.
2. Repeat with "Append Enter" **off**. The text must sit on the prompt line, editable, unexecuted.
3. Repeat both with a shell whose Ghostty shell integration is inactive, so `pwd` never arrives and
   only the fallback fires. State the fallback duration you settled on and why.
4. Repeat both with Settings → Main Terminal set to "None" (the T6 branch) and to an agent.

If the `pwd` gate proves unreliable, fall back to the `runHookInSecondary` shape — a fixed delay with
no gate. That changes nothing in this plan but the timing constant; say so in the report.

**Acceptance criteria.**
1. With a worktree selected, a Run dropdown sits before Archive in the toolbar and lists every command
   in saved order.
2. It is greyed out when the list is empty, and when `ghosttyApp.app` is `nil`.
3. A terminal command opens a new tab with its text at the prompt — executed when "Append Enter" is
   checked, staged and editable when it is not.
4. An agent command opens a new tab running *that command's* agent: submitted immediately when
   checked, and otherwise a pre-filled launcher addressed to that agent — including when
   Settings → Main Terminal is "None".
5. The readiness gate has been observed against a live surface and its behaviour recorded.

**Verification.**
- `./scripts/ci.sh` passes.
- The four manual runs above, all four combinations of kind × auto-run, plus the two
  Settings → Main Terminal values for the agent kind.
- The empty-list and `ghostty_app_new`-failure disabled states: the first by deleting every command,
  the second by reading the code path — both conditions must be present in the `.disabled(...)`
  expression whether or not the second is reachable on a healthy machine.

## Risks

| Risk | Impact | Mitigation |
| --- | --- | --- |
| The `pwd` readiness gate does not fire, or fires before the shell reads input | High — terminal commands silently do nothing or double-run | T7 verifies against the live app across four combinations and falls back to a fixed delay (decision 12, open question 1) |
| A `launcherAgents` clear site is missed | Medium — a recycled tab id runs the wrong agent | T6 lists all five sites and its verification diffs them against `launcherDrafts` |
| A reorder computed against a filtered subset rewrites the wrong global positions | Medium — silent data corruption | T3 refuses the move while filtered, both in `.onMove` and via `.moveDisabled` (decision 10) |
| ⌃3 claimed before a handler exists | Low — one key taken from the shell and dropped | T5 is ordered after T4 for exactly this reason |

## Open questions

None for the operator. The spec's one open question (injection readiness) is assigned to T7, which
settles it empirically and reports what it found.

## Changelog

Operator change requests raised after the seven plan tasks were committed. Each is part of the
intended behaviour; no later stage should revert one as unintentional.

### C1: Command editor sheet field order and controls (after T7, commit `c36eae7`)

Requested by the operator from a hands-on check of the sheet. `Sources/App/CommandEditorSheet.swift`:

1. The kind picker is the **first** field and is labelled **"Command kind"** (was second, "Kind").
2. The name field is labelled **"Menu label"** (was "Name"). The stored property stays `name`.
3. The command text control is a multi-line `TextEditor` for **both** kinds, at the same 120 pt
   height for each, so the sheet does not resize when the kind changes. Terminal text keeps its
   monospaced font; the agent prompt keeps `.callout`. The comment justifying the single-line
   terminal field is removed — it is no longer true.

Run semantics for a multi-line terminal command are deliberately **unchanged** here:
`RunCommandMenu.run` and `Ghostty.SurfaceView.sendCommand` are untouched, and the operator is
deciding that separately. Recorded as decision 22 in the spec.

### C2: Multi-line terminal commands run line by line (after C1, commit `2f94443`)

The separate decision C1 deferred, taken by the operator from a hands-on check. A multi-line
terminal command is sent verbatim: every embedded newline is an Enter, so the lines run in order in
the user's own shell. "Append Enter to run immediately" governs the **trailing** Enter alone — on,
the last line runs too; off, it stays staged and editable on the prompt. Single-line behaviour is
unchanged. Agent commands are untouched: `buildAgentPromptCommand` already hands the prompt over as
one argv element.

| File | State |
| --- | --- |
| `Sources/App/SavedCommand.swift` | New `ShellSend` (`lines`, `runsLastLine`) carries the rule; `CommandLaunch.shell` takes one instead of `(text:execute:)`. |
| `Sources/Ghostty/Ghostty.SurfaceView.swift` | New `sendLines(_:runsLastLine:)`. `sendCommand` and `sendPaste` untouched. |
| `Sources/App/RunCommandMenu.swift` | The `.shell` arm is one `surface.sendLines(...)` call; the `execute` branch is gone. |
| `Tests/SavedCommandTests.swift` | Six new `ShellSend` tests; the four existing resolver assertions read `lines` / `runsLastLine`. |

**Why not change `sendCommand`.** It has one other caller — `TerminalManager.sendToActiveMainTab`
with `asCommand: true`, reached from `TodosPanelView.sendTodoToTerminal`. Its trim-to-first-line is
what keeps a pasted multi-line todo subject from executing itself, so it stays as it is and
`RunCommandMenu` stops routing through it.

**Why line-at-a-time, not one paste.** `ghostty_surface_text` is a paste (`Surface.zig:3234-3243`:
"if bracketed mode is on this will do a bracketed paste"), so a block with newlines in it lands
staged whole on one prompt — with auto-run off *both* lines would be staged, not just the last. One
`sendText` per line with an Enter between them is what makes a newline an Enter.

**Normalisation.** `\r\n` and a bare `\r` become `\n` first, so neither arrives as a second Enter;
then the whole string is trimmed of surrounding whitespace and newlines. The trim subsumes "strip
one trailing newline" and keeps the auto-run-on single-line path byte-identical to the old
`sendCommand`. It also makes the auto-run-**off** single-line path trim, which it did not before —
that path used to send the raw string. Deliberate: the old asymmetry was accidental, and leading or
trailing spaces on a staged prompt line are invisible.

## Build log

### T1: The `SavedCommand` model and its two pure rules

| File | State |
| --- | --- |
| `Sources/App/SavedCommand.swift` | New. `SavedCommand` + `Kind`, the custom `init(from:)` kind fallback, `CommandFilter` + `isActive`, `SavedCommand.filter(_:by:)`, `CommandLaunch` + `launch(for:)`. `import Foundation` only. |
| `Tests/SavedCommandTests.swift` | New. 12 tests: filter (four), `isActive`, resolver (six), JSON round-trip and unknown-kind decode. |
| `Clearway.xcodeproj/project.pbxproj` | Regenerated by `xcodegen generate` inside `./scripts/ci.sh`; the only diff is the two new file references. |
| `docs/superpowers/specs/2026-09-14-commands-view.md`, `docs/superpowers/plans/2026-09-14-commands-view.md` | Newly tracked. Both were untracked before this commit; versioned from the first build commit onward. |

**Evidence.** `./scripts/ci.sh` run against the tests before `SavedCommand.swift` existed:

```
❌ Tests/SavedCommandTests.swift:15:10: cannot find type 'SavedCommand' in scope
    ) -> SavedCommand {
❌ Tests/SavedCommandTests.swift:11:15: cannot find type 'SavedCommand' in scope
        kind: SavedCommand.Kind = .terminal,
** TEST FAILED **
```

**Deviations from the plan.** None to the code. Two decisions the plan left open were settled:

- The unknown-`kind` fallback is a custom `init(from:)` decoding `kind` as `String` and mapping,
  placed in an extension so the memberwise initializer survives. `encode(to:)` and `CodingKeys` stay
  synthesized, so the encoded shape is unchanged and `SavedCommandStoreTests` (T2) can pin it.
- `launch(for:)` is `static` on `CommandLaunch`, which is the spelling T7 already assumes
  (`CommandLaunch.launch(for: command)`).

**Environment fix, not a code change.** The worktree's `ghostty/` directory was empty, so the first
`ci.sh` run failed with `Unable to resolve module dependency: 'GhosttyKit'` before reaching the
tests. `./scripts/worktree-post-create.sh` had never been run here; running it copied the submodule
from the primary worktree. No tracked file changed as a result.

**Gate.** `./scripts/ci.sh` — passed, exit 0. 319 tests, 0 failures; `SavedCommandTests` passed.
`swiftlint lint` on both new files: 0 errors, 0 warnings.

### T2: `SavedCommandStore` and `SavedCommandManager`

**What landed.**

| Path | State |
| --- | --- |
| `Sources/App/SavedCommandStore.swift` | New. `init(directory:)` defaulting to the expanded `~/.clearway`; `load() async -> [SavedCommand]` (detached, missing/unreadable/undecodable → `[]` with a `Ghostty.logger.warning`); `save(_:) async throws` writing `commands.json.tmp` then `replaceItemAt`, directory `0o700`, file `0o600`. Shaped on `WorktreeGroupStore` minus the watcher. |
| `Sources/App/SavedCommandManager.swift` | New. `@MainActor final class … ObservableObject`, `@Published private(set) var commands`, `load()`, `add`, `update`, `delete`, `move(fromOffsets:toOffset:)`, each mutation persisting the whole array. |
| `Tests/SavedCommandStoreTests.swift` | New. 10 tests: round-trip of both kinds, encoded-shape pin, order preserved, directory/file permissions, no leftover `.tmp`, overwrite, missing file, corrupt bytes, missing field, unknown `kind` → `.terminal`. |
| `Tests/SavedCommandManagerTests.swift` | New. 7 tests: load in file order, load of a missing file, and add/update/delete/move each asserted in memory **and** read back from disk. |
| `CLAUDE.md` | One bullet under `Sources/App/`: `SavedCommandStore.swift` owns `~/.clearway/commands.json`, array order is display order, and there is deliberately no watcher. |
| `Clearway.xcodeproj/project.pbxproj` | Regenerated by `xcodegen generate` inside `./scripts/ci.sh`; the only diff is the four new file references. |

**Evidence.** The first `./scripts/ci.sh` run failed on two manager tests. Fire-and-forget saves —
one independent `Task` per mutation, as `WorktreeGroupManager.save` does it — reach the store's
serial write queue in scheduler order, not mutation order, so the *earlier* snapshot landed last and
the newer command never reached disk:

```
Failing tests:
	SavedCommandManagerTests.testAddAppendsAndPersists()
	SavedCommandManagerTests.testMoveReordersAndPersists()

✖ testAddAppendsAndPersists, XCTAssertEqual failed: ("[…name: "Dev"…]") is not equal to
  ("[…name: "Dev"…, …name: "Test"…]")
✖ testMoveReordersAndPersists, XCTAssertEqual failed: ("[…"Dev"…, …"Test"…, …"Review"…]") is not
  equal to ("[…"Review"…, …"Dev"…, …"Test"…]")
```

The fix chains each save onto the one before it (`pendingSave`), which is established synchronously
on the main actor at mutation time, so disk order follows mutation order. Both tests then passed.

**Deviations from the plan.**

- **One extra test file.** The plan's file table named only `Tests/SavedCommandStoreTests.swift`, but
  acceptance criterion 3 ("publishes an ordered list, and persists on every mutation") is about the
  manager, so `Tests/SavedCommandManagerTests.swift` covers it — the same store/manager test split
  `WorktreeGroupStoreTests` and `WorktreeGroupManagerTests` already use. It is what caught the
  ordering bug above.
- **`pendingSave` chaining** is not in the plan. It is not speculative: without it the two tests
  quoted above fail. `WorktreeGroupManager.save` still has the unchained shape; that is a pre-existing
  latent bug in another type and is left alone (see Follow-ups).
- **Load is explicit, not an `init` `Task`.** `WorktreeGroupManager` loads from its initializer, which
  is why `WorktreeGroupManagerTests` opens with a 100 ms sleep. `SavedCommandManager.load()` is an
  awaitable method instead, so the tests need no sleep and T3 chooses where the one load happens.
- The manager takes `store:` in its initializer (defaulted), which is how the tests point it at a
  temp root. No call site passes it.

**Gate.** `./scripts/ci.sh` — passed, exit 0. 336 tests, 0 failures. `git status --porcelain` before
the commit showed only the six paths above; no `default.profraw` (no Debug launch).

### T3: `CommandsView`, `CommandEditorSheet`, and the process-wide manager

**What landed.**

| Path | State |
| --- | --- |
| `Sources/App/CommandsView.swift` | New. Header (title + the one subtitle), segmented All/Terminal/Agent filter, `List` of card rows with `ForEach(...).onMove` guarded on `filter.isActive` and `.moveDisabled(filter.isActive)`, row tap → editor sheet, row context menu → Delete, empty state, floating `+` reusing `PromptsView.createButton`'s styling. Content is width-capped and centred, matching the mock. |
| `Sources/App/CommandEditorSheet.swift` | New. One sheet over an optional `SavedCommand`. Edits name, kind, agent (only for `.agent`, a picker over `agentAllowlist`), the command/prompt text and "Append Enter to run immediately". Save calls `add` or `update`; Delete calls `delete`. Save is disabled until name and text are both non-blank. |
| `Sources/App/ClearwayApp.swift` | `@StateObject savedCommandManager` beside `caffeine`, `.environmentObject(savedCommandManager)` and `.task { await savedCommandManager.load() }` on the project `WindowGroup`. |
| `Sources/App/SavedCommandManager.swift` | `load()` now reads once per process (`hasLoaded`, set before the read). |
| `Tests/SavedCommandManagerTests.swift` | One test: `testASecondLoadDoesNotRereadTheFile`. |
| `Clearway.xcodeproj/project.pbxproj` | Regenerated by `xcodegen generate` inside `./scripts/ci.sh`; the only diff is the two new file references. |

**Evidence.** `./scripts/ci.sh` with the `hasLoaded` guard removed from `load()`, everything else
unchanged:

```
Failing tests:
	SavedCommandManagerTests.testASecondLoadDoesNotRereadTheFile()

✖ testASecondLoadDoesNotRereadTheFile, XCTAssertEqual failed: ("[]") is not equal to
  ("[Clearway.SavedCommand(id: 167218E0-…, name: "Dev", kind: …terminal, text: "bin/dev",
  agent: "claude", autoRun: true)]")
```

The guard restored, the same command passes.

**Deviations from the plan.**

- **Where the one load happens.** The plan offered `.task`/`.onAppear` on the window content or the
  manager's `init`. `init` was tried and rejected: a `Task` fired from `init` races
  `SavedCommandManagerTests`, which constructs a manager in `setUp` and mutates it synchronously — the
  same reason T2 moved the load out of `init` in the first place. `.task` on the window content is
  per-*window*, not per-process, so the load-once guard moved into `load()` itself, which is where the
  requirement actually lives: every window asks, the first one reads. This is the one edit outside
  T3's file list, and it is what T2 explicitly left for T3 to settle.
- **The filter's empty state distinguishes the two cases** ("No commands" vs "No matching commands").
  Not new descriptive copy — it is the empty-state label `PromptsView` already carries, reading
  correctly when a filter, rather than an empty list, is what emptied the view.
- **The text field's shape follows the kind**: a single-line `TextField` for a terminal command
  (`sendCommand` keeps only the first line), a `TextEditor` for an agent prompt. Labels only, no
  helper text.
- `autoRun` defaults to `true` for a new command. The spec does not say; running immediately is the
  common case and the checkbox is visible and one click from the other state.

**Gate.** `./scripts/ci.sh` — passed, exit 0. 337 tests, 0 failures. `swiftlint lint --quiet`: no
output (0 errors, 0 warnings). `git status --porcelain` before the commit showed only the six paths
above; no `default.profraw` (no Debug launch).

### T4: The Commands sidebar destination

**What landed.**

| Path | State |
| --- | --- |
| `Sources/App/ContentView.swift` | `case commands` on `DetailSelection`; `.commands` added to the existing `.noPanel` arm of `bottomPanelAction(for:)`; a hidden ⌃3 button after the ⌃2 one; an `else if detailSelection == .commands { CommandsView() }` branch at the end of `detailView`'s `.ready` case. `contentColumn` untouched — its `else` already collapses to width 0. |
| `Sources/App/SidebarView.swift` | `commandsRow` (`destinationRow("Commands", systemImage: "bolt", shortcutHint: "⌃3")`, tagged `.commands`) below `promptsRow`, and listed after it in `body`. |
| `Tests/BottomPanelActionTests.swift` | `XCTAssertEqual(action(.commands), .noPanel)` in `testDestinationsWithoutABottomPanelGetNothing`. |

**Evidence.** `./scripts/ci.sh` with both source files reverted to HEAD and only the test assertion
present:

```
❌ Tests/BottomPanelActionTests.swift:29:32: type 'DetailSelection?' has no member 'commands'
        XCTAssertEqual(action(.commands), .noPanel)
	Testing cancelled because the build failed.
** TEST FAILED **
```

The sources restored, the same run passes. (The sources were copied aside and back, not stashed or
`git checkout`ed.)

**Deviations from the plan.** None. One choice the plan left open: the SF Symbol is `bolt`, not
`command`. Both were offered; `command` is the ⌘ glyph, which would read as a Command-key shortcut
in a row whose icon is replaced by a `⌃3` badge while Control is held.

**Gate.** `./scripts/ci.sh` — passed, exit 0 (`set -euo pipefail`, final line `==> CI passed.`).
337 tests, 0 failures; SwiftLint clean. `git status --porcelain` before the commit showed only the
three paths above — no `default.profraw` (no Debug launch), no `project.pbxproj` diff (no new files).

### T5: Claim ⌃3 from focused terminal surfaces

**What landed.**

| Path | State |
| --- | --- |
| `Sources/App/AppKeyboardShortcuts.swift` | The Ctrl+digit scalar range widened from `"1"…"2"` to `"1"…"3"`, and the comment above it from "Ctrl+1…2" to "Ctrl+1…3". Nothing else in the table changed. |
| `Tests/AppKeyboardShortcutsTests.swift` | `testControlDigitIsClaimed` gained `XCTAssertTrue(claims([.control], "3"))`; `testControlDigitBeyondTheSidebarDestinationsIsNotClaimed` dropped its `"3"` assertion and its doc comment now reads "Ctrl+4…9"; `testRetiredControlDigitThreeIsNotClaimed` and its doc comment removed. `testRetiredCommandControlDigitsAreNotClaimed` untouched — ⌘⌃3 is the retired aside combo and stays unclaimed. |
| `CLAUDE.md` | Retired-pin list is now `(⌘⌃2, ⌘⌃3)`; the claim spans `"1"…"3"` over the sidebar's three destinations; the "⌃3 is retired with no alias" clause is gone. The `PanelCommands` ⌘⌃3 line is unedited. |

**Evidence.** `./scripts/ci.sh` with the tests updated and `AppKeyboardShortcuts.swift` still at its
unwidened `"1"…"2"` range:

```
Test Suite 'AppKeyboardShortcutsTests' started at 2026-09-15 00:32:16.820.
    ✖ testControlDigitIsClaimed, XCTAssertTrue failed
Executed 336 tests, with 1 failure (0 unexpected) in 36.792 (36.969) seconds
Test Suite 'All tests' failed
```

The range widened, the same run passes.

**Deviations from the plan.** None. One line beyond the plan's list: the doc comment on
`testControlDigitBeyondTheSidebarDestinationsIsNotClaimed` said "Ctrl+3…9", which the dropped
assertion made false; it now says "Ctrl+4…9".

**Gate.** `./scripts/ci.sh` — passed, exit 0. 336 tests, 0 failures; SwiftLint clean.
`git status --porcelain` before the commit showed only the three paths above plus the plan document;
no `default.profraw` (no Debug launch).

### T6: Per-tab agent override on launcher tabs

**What landed.**

| File | State |
| --- | --- |
| `Sources/App/TerminalManager.swift` | `launcherAgents: [UUID: String]` beside `launcherDrafts`; `appendLauncherTab(for:app:agentOverride:)`; the promote-to-shell branch gated on `agentOverride == nil`; the override cleared at all five `launcherDrafts` sites |
| `Sources/App/ContentView.swift` | The launcher branch resolves `launcherAgent` once and passes it to both `PromptLauncherView(command:)` and the `promoteLauncherToAgent(command:)` call |
| `Tests/TerminalManagerTests.swift` | `test_closeAllSurfaces_clearsLauncherAgents` |

**Evidence.** The test written before the property existed, run on unmodified `TerminalManager.swift`:

```
Testing failed:
	Value of type 'TerminalManager' has no member 'launcherAgents'
❌ Tests/TerminalManagerTests.swift:280:17: value of type 'TerminalManager' has no member 'launcherAgents'
        manager.launcherAgents[tabId] = "grok"
Executed 0 tests — Testing cancelled because the build failed.
```

`closeAllSurfaces` is the only one of the five clear sites reachable from XCTest: the other four
need a pane, and a pane needs a real `ghostty_app_t`. The plan's grep parity check covers the rest
and passes — five `removeValue`/`removeAll` calls each, paired on adjacent lines:

```
108: launcherDrafts.removeAll()          109: launcherAgents.removeAll()
338: launcherDrafts.removeValue(tabId)   339: launcherAgents.removeValue(tabId)
377: launcherDrafts.removeValue(id)      378: launcherAgents.removeValue(id)
474: launcherDrafts.removeValue(tab.id)  475: launcherAgents.removeValue(tab.id)
502: launcherDrafts.removeValue(tab.id)  503: launcherAgents.removeValue(tab.id)
```

**Deviations from the plan.** Two, both narrowing.

1. The plan said to record `launcherAgents[newTab.id] = agentOverride` only when the override is
   non-`nil`. The assignment is unconditional instead: assigning `nil` to a `Dictionary` subscript
   removes the key, and the key is a freshly minted `UUID` with nothing to remove, so the branch
   would have been dead code.
2. The plan named the new parameter's effect but not the comment above the promote branch, which
   read "No main command configured → promote immediately to a login shell" and became false with
   the second term added. It now reads "No agent for this tab, from either source".

**Gate.** `./scripts/ci.sh` — passed, exit 0. 337 tests, 0 failures; SwiftLint clean.
`git status --porcelain` before the commit showed only the three paths above plus this plan
document; no `default.profraw` (no Debug launch).

**Not verified here.** The plan's two manual runs (⌘T with Settings → Main Terminal set to an agent,
and set to "None") are handed to the operator. Nothing in the tree passes an `agentOverride` yet, so
the only behaviour a manual run can check is that the nil path is unchanged.

### T7: The Run dropdown and the run action

**What landed.**

| Path | State |
| --- | --- |
| `Sources/App/RunCommandMenu.swift` | New. The toolbar `Menu` over `savedCommandManager.commands` in saved order, `.disabled` on empty-list **or** `ghosttyApp.app == nil`; the static `run(_:in:app:terminalManager:)` that resolves `CommandLaunch.launch(for:)` onto `TerminalManager`; the readiness gate `awaitShellPrompt`. |
| `Sources/App/ContentView.swift` | The worktree toolbar block's `if selectedWorktree != nil` becomes `if let runWorktree = selectedWorktree`, with a `ToolbarItem(placement: .primaryAction)` hosting `RunCommandMenu` **before** Archive. |
| `Clearway.xcodeproj/project.pbxproj` | Regenerated by `xcodegen generate` inside `./scripts/ci.sh`; the only diff is the one new file reference. |

**The readiness gate — the spec's open question 1 (decision 12), settled.**

Settled as chosen: **first non-`nil` `Ghostty.SurfaceView.pwd`, with a 750 ms fixed-delay fallback.**

The four required runs could not be driven through the toolbar: this environment has no Accessibility
permission (`osascript`/System Events times out with `-1712`), so there is no way to click a toolbar
menu. They were run instead through a temporary in-app probe that called `RunCommandMenu.run` on the
real `TerminalManager`, read the surface back with `ghostty_surface_read_text`, and proved execution
through the filesystem. The probe was deleted before this commit; its source and raw logs are in the
session scratchpad, not the repo.

Observed across three app launches (`./scripts/run.sh`), worktree `…/bvalentino/clearway`:

| Run | Gate released | `pwd` | Result |
| --- | --- | --- | --- |
| terminal, auto-run **on**, gated | 199–218 ms | reported | `➜ clearway echo S2 >> … // ➜ clearway git:(main)` — one clean prompt line, ran **once** |
| terminal, auto-run **off**, gated | 196–217 ms | reported | `➜ clearway git:(main) echo S3 >> …` staged, **not** executed; appending `; true` + Enter then executed it, so the text is on the prompt line and editable |
| terminal, auto-run **on**, **no gate** | 0 ms | — | still executed once, but the screen read back `echo S1 >> … // Last login: … // ➜ clearway echo S1 >> …`: the text is echoed **above the login banner** and replayed onto a half-built prompt |
| terminal, auto-run **off**, **no gate** | 0 ms | — | `echo S4 >> /tmp/t7probe/out.txtLast login: …` — the staged line **collides with** the banner |
| terminal, **shell integration inactive** (`/bin/dash -i`), auto-run on | 763 ms (fallback) | **NEVER** | `$ echo S9 >> …` on dash's prompt, ran once |
| terminal, **shell integration inactive**, auto-run off | 762 ms (fallback) | **NEVER** | `$ echo S10 >> …` staged on dash's prompt, not executed |
| agent, submit **on**, Settings → Main Terminal = `claude` | — | — | agent invoked with the prompt as one argv element: `AGENT[S5-PROMPT]` |
| agent, submit **off**, Settings = `claude` | — | — | `isLauncher=true draft=S6-PROMPT agent=<command's own agent>` |
| agent, submit **off**, Settings = **None** | — | — | `configuredMainTerminalCommand=nil`, still `isLauncher=true draft=S7-PROMPT agent=<command's own agent>` — the T6 `agentOverride` branch holds |
| agent, submit **on**, Settings = **None** | — | — | `AGENT[S8-PROMPT]` |

**Fallback duration: 750 ms**, recorded here and at the gate. Reasoning from the measurements above:
the prompt is up at ~200 ms on every integrated shell, so 750 ms is ~3.5x headroom, and it is only
paid by a shell that reports no `pwd` at all. The no-gate rows are why the gate stays: injecting
immediately *executes* correctly — the tty input queue buffers the text rather than dropping it — but
leaves a garbled tab, so "it runs" was not a sufficient test and a bare `asyncAfter` on the
`runHookInSecondary` shape was not needed.

One observation worth recording: `shell-integration = none` in `~/.config/ghostty/config` did **not**
stop `pwd` arriving for zsh (still 196–218 ms), so that config is not a way to reach the fallback
path. A shell Ghostty injects nothing into (`/bin/dash -i`) is.

**Deviations from the plan.** None to the code. The plan's manual-run instructions assume a human at
the toolbar; see the Accessibility note above for what was substituted and why.

**Gate.** `./scripts/ci.sh` — passed, exit 0. 337 tests, 0 failures. `git status --porcelain`
before the commit showed only the four paths above; no `default.profraw`.

### C2: Multi-line terminal commands run line by line

**What landed.** The file table is in Changelog C2 above.

**Evidence — the watched failure.** With `ShellSend.init` temporarily keeping only the first line
(the old `sendCommand` rule expressed in the new type), `./scripts/ci.sh` was red, exit 65:

```
✖ testMultiLineTerminalCommandSplitsIntoOneLinePerEnter, XCTAssertEqual failed:
  ("Optional(["cd /tmp"])") is not equal to ("Optional(["cd /tmp", "pwd"])")
✖ testMultiLineTerminalCommandWithoutAutoRunStagesOnlyItsLastLine, XCTAssertEqual failed:
  ("Optional(["cd /tmp"])") is not equal to ("Optional(["cd /tmp", "pwd"])")
✖ testTrailingNewlineDoesNotBecomeAnEmptyLastLine, XCTAssertEqual failed:
  ("Optional(["cd /tmp"])") is not equal to ("Optional(["cd /tmp", "pwd"])")
✖ testCarriageReturnsNormaliseToOneLineBreak, XCTAssertEqual failed:
  ("Optional(["cd /tmp"])") is not equal to ("Optional(["cd /tmp", "pwd", "ls"])")
✖ testInteriorBlankLineSurvives, XCTAssertEqual failed:
  ("Optional(["cd /tmp"])") is not equal to ("Optional(["cd /tmp", "", "pwd"])")
Executed 343 tests, with 5 failures
```

**Evidence — the running app.** The toolbar still cannot be driven here (no Accessibility
permission; see T7), so the same substitute was used: a temporary in-app probe calling the real
`RunCommandMenu.run`, reading the surface back with `ghostty_surface_read_text` and proving
execution through the filesystem. The probe was deleted before this commit; its source and raw log
are in the session scratchpad, not the repo. Run against `./scripts/build.sh` + `./scripts/run.sh`,
worktree `…/bvalentino/clearway`:

| Run | Command text | Result |
| --- | --- | --- |
| M1 — 2 lines, auto-run **on** | `cd /tmp` ⏎ `pwd >> out.txt` | `out.txt` = `/tmp`. Screen: `➜ clearway cd /tmp // ➜ /tmp pwd >> … // ➜ /tmp` — both lines ran, in order, in the same shell |
| M2 — 2 lines, auto-run **off** | `cd /tmp` ⏎ `pwd >> out2.txt` | `out2.txt` never created: the first line ran (prompt is now `/tmp`), the last is staged. Appending ` # edited` + Enter then wrote `/tmp` — staged **and** editable |
| M3 — 1 line, auto-run **on** | `echo M3 >> out.txt` | Ran exactly once. Unchanged |
| M4 — `\r\n` + trailing `\n` | `cd /tmp` ⏎ `pwd >> out.txt` | `out.txt` gained `/tmp`; screen shows two prompt lines and no stray empty Enter |
| M5 — 1 line, auto-run **off** | `echo M5 >> out.txt` | Staged on the prompt, nothing ran. Unchanged |

**Deviations from the plan.** None. C2 is an operator change request, not a plan task.

**Gate.** `./scripts/ci.sh` — see the commit; `git status --porcelain` was empty afterwards.
