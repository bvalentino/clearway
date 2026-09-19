# New tab opens a terminal — implementation plan

**Date:** 2026-09-18
**Base:** 6b1977af9df8e5ec36ef32e4a5ebb97ea8a6fbdd

Breaks down `docs/superpowers/specs/2026-09-18-new-tab-behavior.md`. Every design decision below is
carried from that spec; this document only orders the work and says how each piece is verified.

## Architecture decisions carried from the spec

- The prompt launcher is deleted outright. No tab is ever a launcher; `TerminalTab` holds a
  `Ghostty.SurfaceView` unconditionally and `TerminalTab.Kind` collapses away.
- ⌘T opens a plain login shell, always, independent of Settings → Main Terminal.
- ⌥⌘T opens the Settings → Main Terminal command, run bare via `buildBareCommand`. Its menu item is
  disabled (greyed, no-op) when Main Terminal is "None".
- The tab strip's `+` is a `Menu`: New Terminal (⌘T), then one row per `agentAllowlist` entry. The
  row matching the configured Main Terminal command carries ⌥⌘T; no other row carries one.
- A worktree's first tab follows the ⌥⌘T rule: the Main Terminal command if one is set, else a login
  shell.
- ⌘⇧T is retired. `NewShellTabMenuItem` and its focused value go, the `[.command, .shift]` `"t"`
  claim is dropped, and `AppKeyboardShortcutsTests` gains a not-claimed pin beside ⌘⌃2 / ⌘⌃3.
- `agentAllowlist` is reordered to `["claude", "codex", "grok"]` and gains a second reader — the `+`
  menu. One list, not a second hardcoded order beside it.
- `agentAllowlist` holds command names; the menu renders `.capitalized`.
- A Main Terminal command outside the allowlist: no `+` row carries ⌥⌘T, and ⌥⌘T still runs the
  configured command. The shortcut belongs to the setting, not to the list.
- An agent tab awaits `ShellEnvironment.awaitPath()` before building its command. A login-shell tab
  needs no await and stays fully synchronous, so ⌘T never defers a frame.
- A per-worktree in-flight marker covers the frame between an agent tab being asked for and its
  surface existing, in the shape of `beginTaskLaunch` / `endTaskLaunch`. While it is set the
  "⌘T for a new tab" empty state does not render, and a second ⌥⌘T is a no-op.
- A saved `.agent` command with `autoRun` on keeps the `buildAgentPromptCommand` mechanism: the
  prompt reaches the agent as one argv element in the tab's own command. Only the launcher hop goes.
- A saved `.agent` command with `autoRun` off opens the agent tab bare and pastes the prompt into it,
  unsubmitted, after `awaitShellPrompt`'s fallback window.
- `sendToActiveMainTab` loses its `.launcher` branch and keeps its `.surface` branch, so a Prompts or
  Todos play click pastes into whatever the active tab is running. It opens no tab of its own.
- `canSendToActiveMainTab` survives with its meaning narrowed to "there is an active surface".
  `TodosPanelView.swift:40` is its one reader and still needs a gate.
- `TerminalManager+Launcher.swift` is renamed `TerminalManager+Agent.swift` and keeps
  `buildBareCommand`, which `WorkTaskCoordinator.taskTerminalLaunchCommand` reads.
- The "⌘T for a new tab" empty-state copy does not change.

## Decisions this plan settles

The spec left two shapes to the plan. Both are settled here so a build agent needs no judgement.

**The in-flight marker (spec Decision 11).** A `@Published var agentLaunchesInFlight: Set<String>` on
`TerminalManager`, keyed by worktree id, with `beginAgentLaunch(for:) -> Bool` and
`endAgentLaunch(for:)` mirroring `beginTaskLaunch` / `endTaskLaunch`
(`TerminalManager+TaskTerminals.swift:65-71`). Unlike `taskLaunchesInFlight` it **is** `@Published`:
nothing else publishes during the window, and `detailView` has to re-render the moment it is set.
The claim is taken **synchronously** by `startAgentTab` before it spawns its `Task`, because a claim
taken inside the task body would land a runloop turn late and the empty state would flash for that
frame — which is the whole reason the marker exists.

**The `+` menu row rule.** A pure `agentMenuRows(agents:mainCommand:)` in
`Sources/App/AgentLaunch.swift`, beside the `agentAllowlist` it reads, returning
`[AgentMenuRow]`. `AgentMenuRow` carries the command, its `.capitalized` title and
`carriesMainTerminalShortcut`. It covers the agent rows only: the New Terminal row is fixed, always
first and always ⌘T, so it is written in the view rather than modelled as data. `AgentLaunch.swift`
rather than a new file because the rule derives from `agentAllowlist` and nothing else, and rather
than `MainTerminalTabStrip.swift` because the project keeps a model out of its view
(`OpenInApp.swift` / `OpenInMenu.swift`).

## Dependency graph

```
T1: agentAllowlist order + agentMenuRows rule
      │
      ▼
T2: new tab-creation API on the manager (appendTab, in-flight marker, startAgentTab)
      │
      ▼
T3: switch every door to it (pane first tab, ⌘T, the + menu, saved agent commands)
      │
      ▼
T4: ⌥⌘T replaces ⌘⇧T
      │
      ▼
T5: delete the launcher view and its now-dead Settings fallback
      │
      ▼
T6: collapse TerminalTab.Kind and the launcher machinery
      │
      ▼
T7: CLAUDE.md
```

The order is forced by what compiles and by what stays usable. The collapse in T6 touches nine files
at once if it is attempted first, so the launcher machinery is left standing and unreachable until
its last reader is gone. T2 adds API nothing calls yet; T3 makes it the only door that fires; T4 and
T5 remove the last callers of the old one; T6 deletes it. Every task leaves the app building and
every shortcut that worked before it still working — ⌘⇧T keeps opening a shell until T4 retires it.

## Task list

### T1: Reorder agentAllowlist and add the `+` menu row rule

**Files touched**

- `Sources/App/AgentLaunch.swift`
- `Tests/AgentMenuRowTests.swift` (new)

**What it does**

Reorders `agentAllowlist` to `["claude", "codex", "grok"]` and restates its doc comment: it is the
picker order for Settings → Main Terminal **and** the row order of the tab strip's `+` menu.

Adds the pure rule the `+` menu is built from:

```swift
/// One agent row of the tab strip's `+` menu. The New Terminal row above them is fixed and is not
/// modelled here.
struct AgentMenuRow: Equatable {
    /// The command as it is executed — the `agentAllowlist` spelling.
    let command: String
    /// Whether this row carries ⌥⌘T, the Settings → Main Terminal shortcut.
    let carriesMainTerminalShortcut: Bool

    var title: String { command.capitalized }
}

/// The `+` menu's agent rows. The row matching the configured Main Terminal command carries ⌥⌘T;
/// a nil or unlisted command leaves every row without one, and ⌥⌘T still runs the setting.
func agentMenuRows(agents: [String], mainCommand: String?) -> [AgentMenuRow] {
    agents.map { AgentMenuRow(command: $0, carriesMainTerminalShortcut: $0 == mainCommand) }
}
```

`Tests/AgentMenuRowTests.swift` pins the three cases the spec names, plus the order and the titles:

- `mainCommand: nil` → three rows, none carrying the shortcut.
- `mainCommand: "codex"` → exactly the Codex row carries it.
- `mainCommand: "fish"` (unlisted) → three rows, none carrying it.
- `agentMenuRows(agents: agentAllowlist, mainCommand: nil).map(\.command) == ["claude", "codex", "grok"]`
  and `.map(\.title) == ["Claude", "Codex", "Grok"]`.

The order assertion reads `agentAllowlist` itself, so reordering the list again without reordering
the menu is not possible — there is one list.

**Acceptance criteria**

- `agentAllowlist == ["claude", "codex", "grok"]`.
- `agentMenuRows` is pure, takes the list as a parameter, and marks at most one row.
- Settings → Main Terminal's picker lists None, claude, codex, grok in that order.
- `CommandEditorSheet`'s default agent (`agentAllowlist.first`) is still `claude`.

**Verification**

- `./scripts/ci.sh` passes, including the new `AgentMenuRowTests`.
- No behaviour outside the picker order changes; nothing reads `agentMenuRows` yet.

### T2: New tab-creation API on TerminalManager

**Files touched**

- `Sources/App/TerminalManager.swift`
- `Sources/App/TerminalManager+Launcher.swift` → `Sources/App/TerminalManager+Agent.swift` (renamed)
- `Sources/App/TerminalManager+Commands.swift`
- `Tests/TerminalManagerTests.swift`

**What it does**

Adds the API the rest of the change is built on. Nothing calls it yet and the launcher machinery is
untouched, so behaviour is unchanged after this task.

`TerminalManager.swift`:

```swift
/// Worktrees whose agent-tab launch is in flight: the command is not built yet because the launch
/// is awaiting the resolved PATH, so no tab exists and the pane can read as empty. `@Published`
/// because the empty-state gate in `detailView` is the only thing that changes when it is set.
@Published var agentLaunchesInFlight: Set<String> = []

/// Append a tab running `command` — or a login shell when it is nil — and activate it.
/// Creates the pane on the fly when it does not exist yet. The sole door: every main tab in the app
/// is made here.
@discardableResult
func appendTab(for worktree: Worktree, app: ghostty_app_t, command: String? = nil) -> Ghostty.SurfaceView
```

`appendTab` keeps the pane-creation branch of today's `appendLauncherTab` verbatim (secondary
surface, `openWorktreeIds`, `setInitialPanelVisibility`) and takes the surface's working directory
from `pane.secondary.initialWorkingDirectory` when the pane exists and `worktree.path` when it does
not — the split `appendLauncherTab` and `promoteLauncher` make between them today. It builds
`Ghostty.SurfaceView(app, workingDirectory:, command:)`, appends the tab, sets `activeId`, calls
`objectWillChange.send()` and `transferFirstResponder(to:)`, and returns the surface. In this task
the tab is still `TerminalTab(id: UUID(), kind: .surface(surface))`; T6 drops `Kind`.

The return is **non-optional**. Unlike `promoteLauncher` there is no "the tab stopped being a
launcher" failure: `app` is non-optional and the append always lands.

`TerminalManager+Agent.swift` (renamed from `+Launcher.swift`; its type doc comment is rewritten for
agent tabs): keeps `buildBareCommand` unchanged, keeps `promoteLauncherToAgent` for now — ContentView
still calls it until T5 — and gains:

```swift
/// Claims the worktree's agent launch, reporting whether the claim is this caller's. `false` means
/// a launch is already in flight and this one must abandon itself.
func beginAgentLaunch(for worktreeId: String) -> Bool { agentLaunchesInFlight.insert(worktreeId).inserted }

func endAgentLaunch(for worktreeId: String) { agentLaunchesInFlight.remove(worktreeId) }

/// Open a tab running `command`, an agent, in `worktree`.
///
/// Synchronous on purpose: the in-flight claim has to be taken in the caller's runloop turn, or the
/// "⌘T for a new tab" empty state renders for the frame before the `Task` starts. The await that
/// follows is what the claim covers.
///
/// `prompt` empty → the agent runs bare. With `submit` the prompt is handed to the agent as one argv
/// element (`buildAgentPromptCommand`); without it the tab opens bare and the prompt is pasted
/// unsubmitted once the surface settles — argv delivery cannot stage.
@MainActor
func startAgentTab(
    for worktree: Worktree,
    app: ghostty_app_t,
    command: String,
    prompt: String = "",
    submit: Bool = true
) {
    guard beginAgentLaunch(for: worktree.id) else { return }
    let worktreeId = worktree.id
    Task { @MainActor in
        let path = await ShellEnvironment.awaitPath()

        guard !prompt.isEmpty, submit else {
            let surface = appendTab(
                for: worktree,
                app: app,
                command: buildBareCommand(agentCommand: command, path: path)
            )
            endAgentLaunch(for: worktreeId)
            guard !prompt.isEmpty else { return }
            await Self.awaitShellPrompt(on: surface)
            surface.sendPaste(prompt)
            return
        }

        let launch = buildAgentPromptCommand(
            agentCommand: command,
            prompt: prompt,
            path: path,
            filePrefix: "clearway-agent-tab"
        )
        appendTab(for: worktree, app: app, command: launch.command)
        endAgentLaunch(for: worktreeId)
    }
}
```

The claim is released the moment the tab exists, not at the end of the body: a staged paste waits out
`awaitShellPrompt`'s 750 ms fallback and must not block ⌥⌘T for it. Nothing between the `await` and
each `endAgentLaunch` can return early, so no `defer` is needed.

`TerminalManager+Commands.swift`: drop `private` from `static func awaitShellPrompt` so
`startAgentTab` can reach it across files — `private` does not cross a file even within a type. Its
doc comment gains one line: an agent tab reports no `pwd`, so the staged-paste path always pays the
fallback window, which is the behaviour the spec chose. Nothing else in the file changes yet.

`Tests/TerminalManagerTests.swift`: add a `beginAgentLaunch` group modelled on the existing
`beginTaskLaunch` cases — a second claim on the same worktree loses, a claim on a different worktree
wins, and `endAgentLaunch` lets the next claim through. Reachable without a `ghostty_app_t`.

**Acceptance criteria**

- `TerminalManager+Launcher.swift` no longer exists; `TerminalManager+Agent.swift` holds
  `buildBareCommand`, `startAgentTab` and the claim pair.
- `startAgentTab` is not `async`: the claim is taken before its `Task` is spawned.
- A second `startAgentTab` for the same worktree while the first is in flight appends no tab.
- `appendTab` returns a non-optional surface and is the only place a `Ghostty.SurfaceView` for a main
  tab is constructed.
- Existing `buildBareCommand` and `buildAgentPromptCommand` cases pass unmodified.

**Verification**

- `./scripts/ci.sh` passes, including the new `beginAgentLaunch` cases. `xcodegen generate` inside it
  is what makes the renamed file visible to the build.
- `grep -rn 'TerminalManager+Launcher' . --exclude-dir=.git` returns nothing.
- App behaviour is unchanged by hand: ⌘T, ⌘⇧T, the `+` button and saved commands all still do what
  they did.

### T3: Every door opens a running tab

**Files touched**

- `Sources/App/TerminalManager.swift`
- `Sources/App/TerminalManager+Commands.swift`
- `Sources/App/MainTerminalTabStrip.swift`
- `Sources/App/ContentView.swift`

**What it does**

Switches the four ways a main tab is created onto T2's API. After this task no launcher tab is ever
created; the launcher code is unreachable but still compiled.

`TerminalManager.pane(for:app:projectPath:)`: build the pane with **no** tabs
(`MainTerminal(tabs: [], activeId: nil)`), register it, call `setInitialPanelVisibility`, then create
the first tab through the same door as everything else:

```swift
if let command = mainCommandProvider() {
    startAgentTab(for: worktree, app: app, command: command)
} else {
    appendTab(for: worktree, app: app)
}
return panes[key] ?? tp
```

The agent branch returns a pane with zero tabs and the in-flight marker already set — T3's ContentView
gate is what keeps that from rendering the empty state. The shell branch has its tab before
`pane(for:)` returns. Restate the comment that used to say "Main tab starts as a launcher".

`mainCommandProvider`'s doc comment is restated: it is the Settings → Main Terminal command, read for
a worktree's first tab and by `WorkTaskCoordinator.taskTerminalLaunchCommand`. It is no longer a
launcher decision.

`TerminalManager+Commands.swift`:

```swift
case .shell(let send):
    let surface = appendTab(for: worktree, app: app)
    Task { @MainActor in
        await Self.awaitShellPrompt(on: surface)
        for step in send.steps { ... }   // unchanged
    }

case .agent(let agent, let prompt, let submit):
    startAgentTab(for: worktree, app: app, command: agent, prompt: prompt, submit: submit)
```

The `guard let surface = appendShellTab(...) else { return }` goes with the optional return.

`MainTerminalTabStrip.swift`: `plusButton` becomes `plusMenu`, following `RunCommandMenu`'s shape
(`Menu { } label: { Image }` + `.menuIndicator(.hidden)`):

```swift
Menu {
    Button("New Terminal") { newTerminal() }
        .keyboardShortcut("t", modifiers: .command)
    ForEach(agentMenuRows(agents: agentAllowlist, mainCommand: settings.configuredMainTerminalCommand),
            id: \.command) { row in
        if row.carriesMainTerminalShortcut {
            Button(row.title) { newAgent(row.command) }
                .keyboardShortcut("t", modifiers: [.command, .option])
        } else {
            Button(row.title) { newAgent(row.command) }
        }
    }
} label: {
    Image(systemName: "plus") ...
}
.menuIndicator(.hidden)
.menuStyle(.borderlessButton)
.disabled(ghosttyApp.app == nil)
```

Both actions resolve `ghosttyApp.app` and the worktree the way `plusButton` does today, then call
`appendTab` / `startAgentTab`. The view needs
`@EnvironmentObject private var settings: SettingsManager`, which `clearwayChrome` already injects.

These two `.keyboardShortcut` declarations are the second declaration of ⌘T and ⌥⌘T — the File menu
items are the first. That is deliberate and, unlike the case `CLAUDE.md` warns about under
`PanelCommands.swift`, harmless: `.keyboardShortcut` is the only way SwiftUI renders the glyph beside
a menu row, the spec requires the glyphs, and whichever declaration wins runs the same action on the
same worktree. Note it beside the menu so a later reader does not "fix" it.

`ContentView.swift`:

- `newTabAction` calls `terminalManager.appendTab(for: worktree, app: app)`.
- The empty-state gate in `detailView`:

```swift
if pane.main.tabs.isEmpty {
    if terminalManager.agentLaunchesInFlight.contains(worktreeId) {
        Color.clear.frame(maxWidth: .infinity, maxHeight: .infinity)
    } else {
        VStack(spacing: 12) { ... }   // the "⌘T for a new tab" placeholder, unchanged
    }
}
```

`Color.clear` rather than nothing: an `EmptyView` collapses the `VStack` and the panels below it jump
for the frame. The placeholder's copy and layout are untouched.

The launcher branch below it is left in place for T5. `ContentView.swift` must not grow: the gate
adds three lines and T5 removes ~35, so the file is net-negative across the pair, but if the build
agent finds `file_length` newly tripped, split before adding.

**Acceptance criteria**

- Selecting a worktree for the first time with Main Terminal set lands in a tab running that command,
  with no empty state on the way; with it at "None", in a login shell.
- ⌘T and the `+` menu's New Terminal row each append a tab already running a login shell, focused.
- Each `+` agent row launches its own agent, whatever Main Terminal is set to.
- The `+` menu lists New Terminal (⌘T), Claude, Codex, Grok in that order, and only the row matching
  Main Terminal shows ⌥⌘T. At "None" no agent row shows one.
- Running a saved terminal command still stages or runs its last line per `ShellSend.steps`.
- Running a saved agent command with autoRun on opens a tab running that agent with the prompt
  delivered; with it off, the prompt is pasted unsubmitted into the running agent.
- No code path creates a `TerminalTab(id:kind: .launcher)` any more.

**Verification**

- `./scripts/ci.sh` passes. The existing `CommandLaunch` / `ShellSend` cases carry the saved-command
  rule unchanged.
- `grep -n 'kind: .launcher' Sources/App/TerminalManager.swift` returns only `appendLauncherTab`,
  which nothing now calls.
- Operator, by hand (a live `ghostty_app_t` is unreachable from XCTest): success criteria 1, 2, 4, 5
  and 7 of the spec.

### T4: ⌥⌘T replaces ⌘⇧T

**Files touched**

- `Sources/App/ClearwayApp.swift`
- `Sources/App/ContentView.swift`
- `Sources/App/AppKeyboardShortcuts.swift`
- `Tests/AppKeyboardShortcutsTests.swift`

**What it does**

`ClearwayApp.swift`: `NewShellTabActionKey` → `NewAgentTabActionKey`, `FocusedValues.newShellTabAction`
→ `newAgentTabAction`, and `NewShellTabMenuItem` → `NewAgentTabMenuItem` titled **New Agent Tab** with
`.keyboardShortcut("t", modifiers: [.command, .option])`. Its position in the
`CommandGroup(replacing: .newItem)` list is unchanged (straight after New Tab) and it stays
`.disabled(action == nil)`.

`ContentView.swift`: `newShellTabAction` → `newAgentTabAction`, and the Main Terminal precondition
moves **into the nil gate** — that nil is what greys the menu item out:

```swift
/// ⌥⌘T: append a tab running the Settings → Main Terminal command. Nil — so the menu item is
/// greyed — when no worktree is selected or Main Terminal is "None".
private var newAgentTabAction: (() -> Void)? {
    guard let worktree = selectedWorktree,
          let command = settings.configuredMainTerminalCommand else { return nil }
    return { [terminalManager, ghosttyApp] in
        guard let app = ghosttyApp.app else { return }
        terminalManager.startAgentTab(for: worktree, app: app, command: command)
    }
}
```

`ghosttyApp.app` stays inside the closure rather than in the gate: `newTabAction` and this one are the
pair `CLAUDE.md` names as the known exceptions to the "every precondition in the nil gate" rule, and
this task does not change that. The `.focusedSceneValue(\.newShellTabAction, …)` line becomes
`\.newAgentTabAction`.

`AppKeyboardShortcuts.swift`: `[.command, .shift]` loses `letter == "t"` and its comment loses "new
shell tab"; `[.command, .option]` becomes `letter == "b" || letter == "t"` with a comment naming the
aside toggle and the new agent tab. The `claims` doc comment's Cmd+Shift+T example — the reason
letters are matched lowercased — is retargeted to Cmd+Shift+N (New Group), which survives.

`Tests/AppKeyboardShortcutsTests.swift`:

- `testShiftedMenuLettersAreClaimedDespiteArrivingUppercased` drops its `"T"` assertion and keeps
  `"N"`; its doc comment names New Group.
- A new claimed pin: `XCTAssertTrue(claims([.command, .option], "t"), "New Agent Tab")`, plus
  `XCTAssertFalse` for `[.command, .option, .shift]` `"T"` and `[.command, .control]` `"t"`.
- A retired pin in the "Retired shortcuts" section beside ⌘⌃2 / ⌘⌃3:
  `XCTAssertFalse(claims([.command, .shift], "T"))`, with the convention's reason — nothing declares
  ⌘⇧T now, so claiming it would take a key from the shell and answer it with nothing.
- `testCommandTIsClaimed` stays: ⌘T is still claimed.

**Acceptance criteria**

- File ▸ New Agent Tab exists on ⌥⌘T, runs the Main Terminal command in the selected worktree, and is
  greyed out when Main Terminal is "None" or no worktree is selected.
- File ▸ New Shell Tab is gone and ⌘⇧T does nothing.
- `AppKeyboardShortcuts.claims` returns `true` for `[.command, .option]` + `"t"` and `false` for
  `[.command, .shift]` + `"T"`.
- ⌥⌘T reaches the app while a terminal surface has focus.

**Verification**

- `./scripts/ci.sh` passes, including the flipped and added pins.
- `grep -rn 'newShellTabAction\|NewShellTab' Sources Tests` returns nothing.
- Operator, by hand: spec success criteria 2, 3 and 6 with a terminal focused.

### T5: Delete the launcher view

**Files touched**

- `Sources/App/PromptLauncherView.swift` (deleted)
- `Sources/App/ContentView.swift`
- `Sources/App/TerminalManager+Agent.swift`
- `Sources/App/SettingsManager.swift`
- `Tests/SettingsManagerTests.swift`

**What it does**

Deletes `Sources/App/PromptLauncherView.swift`.

`ContentView.swift`: deletes the `else if let activeTab = pane.main.activeTab, activeTab.isLauncher`
branch of `detailView` in full — the `PromptLauncherView` construction, its `launcherAgent`
resolution, the `launcherDrafts` binding, `onSubmit`, `onOpenTerminal` and `onConsumeFocus`. The
`else if let activeSurface = pane.main.activeSurface` branch below it becomes the only branch after
the empty-state gate. Also restates the `onAppear` comment above
`terminalManager.mainCommandProvider = …`, which still says "Route the launcher decision".

`TerminalManager+Agent.swift`: deletes `promoteLauncherToAgent`, whose last caller was that branch.

`SettingsManager.swift`: deletes `resolvedMainTerminalCommand` and
`defaultMainTerminalCommand`. The launcher placeholder was their only production reader
(`ContentView.swift:828`); `mainTerminalCommand` initialises to `""`, so neither seeds anything and
neither is a picker row. `configuredMainTerminalCommand` — the one everything else reads — stays, with
its doc comment's "Used by the launcher to decide whether to show the prompt form" restated for the
first tab and ⌥⌘T.

`Tests/SettingsManagerTests.swift`: deletes `test_resolvedMainTerminalCommand_fallsBackToDefault_whenBlank`,
whose subject is gone. `test_configuredMainTerminalCommand_returnsTrimmedValue` stays.

**Acceptance criteria**

- `Sources/App/PromptLauncherView.swift` does not exist and nothing references `PromptLauncherView`.
- `promoteLauncherToAgent` is gone.
- `SettingsManager` exposes `configuredMainTerminalCommand` and no fallback.
- The detail column renders the active surface, the empty state, or the in-flight hold — nothing else.

**Verification**

- `./scripts/ci.sh` passes. `xcodegen generate` inside it is what makes the deletion visible to the
  build.
- `grep -rn 'PromptLauncherView\|promoteLauncherToAgent\|resolvedMainTerminalCommand\|defaultMainTerminalCommand' Sources Tests`
  returns nothing.
- `git status --porcelain` shows the deletion, not an untracked leftover.

### T6: Collapse TerminalTab.Kind and the launcher machinery

**Files touched**

- `Sources/App/TerminalTab.swift`
- `Sources/App/TerminalManager.swift`
- `Sources/App/MainTerminalTabStrip.swift`
- `Tests/TerminalTabKindTests.swift` (deleted)
- `Tests/TerminalManagerTests.swift`

**What it does**

`TerminalTab.swift`: `Kind`, `isLauncher` and `appendingToDraft` go; `TerminalTab` becomes
`let id: UUID` + `let surface: Ghostty.SurfaceView`. `MainTerminal.activeSurface` becomes
`activeTab?.surface` and `hasActiveTab` goes. `shellEscape` stays — `buildBareCommand` and
`buildAgentPromptCommand` both use it. `MainTerminal.contains`, `index(of:)` and `activeTab` are
unchanged. The type doc comment loses the launcher sentence.

`TerminalManager.swift` — deletions: `launcherDrafts`, `launcherAgents`, `pendingFocusTabId`,
`startsAsLoginShell`, `appendLauncherTab`, `appendShellTab`, `promoteLauncher`, and every
`launcherDrafts`/`launcherAgents` removal line in `closeAllSurfaces`, `closeMainTab`, `removeSurface`
and `closeWorktree` (`removeSurface`'s loop disappears entirely; `closeWorktree`'s keeps its
`closeSurface()` call).

`TerminalManager.swift` — non-optional surface fallout:

| Site | Becomes |
| --- | --- |
| `canSendToActiveMainTab` | `activeMainSurface != nil`, with its doc comment narrowed to "there is an active surface". `TodosPanelView.swift:40` keeps reading it. |
| `sendToActiveMainTab` | `guard let surface = activeMainSurface else { return }`, then the `asCommand` branch and `transferFirstResponder`. The `.launcher` branch goes. |
| `closeMainTab` | `removedTab.surface.closeSurface()`; `newActiveSurface` is non-optional. |
| `worktreeNeedsConfirmClose` | `$0.surface.needsConfirmQuit` |
| `allSurfaces` | `$0.main.tabs.map(\.surface)` |

`MainTerminalTabStrip.swift`: `chip(for:isActive:)` loses its `switch tab.kind` and always builds
`TerminalTabChip(surface: tab.surface, …)` — the `@ViewBuilder` attribute goes with the branch. The
auto-scroll comment at `:160-163` names `promoteLauncher`; the deferral is still needed because an
agent tab is appended from a `Task`, so the comment is rewritten to say that, not deleted.

`Tests/TerminalTabKindTests.swift` is deleted. Every case in it is a `.launcher` case, a
`hasActiveTab` case or an `appendingToDraft` case, and all three subjects are gone; what would remain
is `MainTerminal(tabs: [], activeId: nil).activeTab == nil`, which asserts nothing the type does not
say. The surviving `MainTerminal` behaviour needs a `Ghostty.SurfaceView` and so is unreachable from
XCTest, which is why the decision rules were lifted into `agentMenuRows`, `buildBareCommand` and
`AppKeyboardShortcuts.claims` instead.

`Tests/TerminalManagerTests.swift`: deletes `test_closeAllSurfaces_clearsLauncherAgents` and
`test_startsAsLoginShell_onlyWhenNeitherSourceNamesAnAgent` with their `MARK` headings. Renames the
`clearway-launcher` prefix in `test_buildAgentPromptCommand_usesFilePrefix` and the
`clearway-launcher-` assertion in `test_buildBareCommand_hasNoPromptFile_orCat` to
`clearway-agent-tab`, matching `startAgentTab`'s call. The other five `buildBareCommand` /
`buildAgentPromptCommand` cases and the `beginAgentLaunch` group are untouched.

**Acceptance criteria**

- `TerminalTab` has no `Kind` and its `surface` is non-optional.
- No symbol named `launcher` remains in `Sources/`.
- The tab strip renders one chip per tab, titled from its surface.
- Prompts play and the Todos panel still paste into the active tab's running process, and the Todos
  gate still disables with no active surface.

**Verification**

- `./scripts/ci.sh` passes, with the deleted test file picked up by `xcodegen generate`.
- `grep -ri launcher Sources` returns only `OpenInAppLauncher` — spec success criterion 9.
- `grep -rn 'launcherDrafts\|launcherAgents\|pendingFocusTabId\|isLauncher\|appendingToDraft\|hasActiveTab\|startsAsLoginShell\|appendShellTab\|appendLauncherTab\|promoteLauncher' Sources Tests`
  returns nothing.
- Operator, by hand: spec success criterion 8, and that closing the last tab shows the ⌘T empty state.

### T7: Update CLAUDE.md

**Files touched**

- `CLAUDE.md`

**What it does**

Brings the architecture notes in line with what shipped. No behaviour change.

- The `AppKeyboardShortcuts.swift` bullet: the retired-shortcut pin list gains ⌘⇧T beside ⌘⌃2 and
  ⌘⌃3, and the sentence naming the declaration sites gains the `+` menu's rows as a site that
  declares ⌘T and ⌥⌘T a second time on purpose, for the glyph.
- The `PanelCommands.swift` bullet's last line: `newTabAction` / `newShellTabAction` becomes
  `newTabAction` / `newAgentTabAction`.
- The `AgentLaunch.swift` bullet: `agentAllowlist` is `claude`, `codex`, `grok` and has **two**
  readers — Settings → Main Terminal's picker rows and `agentMenuRows`, the tab strip `+` menu's row
  rule, which also lives in that file. Still no launch is gated against it.
  `buildAgentPromptCommand`'s paragraph keeps its unquoted-`$1` warning verbatim; only "backs the
  prompt launcher's submit" becomes "backs a saved agent command's prompt".
- The `TerminalManager.appendLauncherTab` bullet is replaced by an `appendTab` / `startAgentTab`
  bullet: `appendTab` is the one door every main tab goes through, ⌘T passes no command, ⌥⌘T and a
  worktree's first tab pass the Settings → Main Terminal command through `buildBareCommand`, and
  `startAgentTab` is synchronous so its in-flight claim lands before the empty state can render. The
  `startsAsLoginShell` truth table and its "the rule is `static` so it is testable" sentence go with
  the method.
- The `Ghostty.SurfaceView` bullet's line about a focused surface swallowing Cmd combos is unchanged;
  the Ctrl+digit sentence is unchanged.

**Acceptance criteria**

- `CLAUDE.md` names no removed symbol.
- The retired-shortcut convention lists ⌘⇧T.

**Verification**

- `grep -n 'appendLauncherTab\|startsAsLoginShell\|newShellTabAction\|prompt launcher' CLAUDE.md`
  returns nothing.
- `./scripts/ci.sh` passes (unchanged by this task, run because sign-off follows it).

## Risks

| Risk | Impact | Handling |
| --- | --- | --- |
| The `+` menu declares ⌘T and ⌥⌘T a second time, and a view-hierarchy declaration beats a menu item (`CLAUDE.md`, `PanelCommands.swift`) | Low | Both declarations run the same action on the same worktree, so whichever wins is correct. `.keyboardShortcut` is the only way to render the glyph the spec requires. Noted in the source beside the menu. |
| A cold first launch makes `awaitPath()` slow, so a worktree's first agent tab holds an empty panel for seconds | Low | The in-flight marker means it holds blank rather than flashing the empty state, and `ClearwayApp.init` starts the resolution eagerly (spec Assumption 5). No spinner: the spec asks for no new copy. |
| `ContentView.swift` is past SwiftLint's `file_length` error and survives on a file-wide disable | Low | T3 adds three lines and T5 removes ~35. If the build agent trips the limit in T3, split the file before adding. |
| Settings → Main Terminal's footer ("Choose \"None\" to open new tabs directly in a login shell") is now inaccurate — ⌘T always opens a login shell | Low | Explicitly out of scope per the spec. Left as-is; recorded as a follow-up. |
| A staged agent prompt (autoRun off) always pays `awaitShellPrompt`'s full 750 ms, since an agent emits no OSC 7 `pwd` | Low | Accepted by spec Decision 13 — argv delivery cannot stage, and this is the closest surviving equivalent. |
| A prompt temp file leaks when its tab is closed before the agent exits (SIGHUP skips the recipe's `rm -f`) | Low | Pre-existing for every agent tab; the launcher had the same exposure after promotion. Not fixed here. |

## Build log

<!-- Each build task appends its entry here. -->

### T1: Reorder agentAllowlist and add the `+` menu row rule

**What landed**

| File | State |
| --- | --- |
| `Sources/App/AgentLaunch.swift` | `agentAllowlist` is `["claude", "codex", "grok"]`; its doc comment now names both readers. `AgentMenuRow` and `agentMenuRows(agents:mainCommand:)` added beside it, as the plan specifies. |
| `Tests/AgentMenuRowTests.swift` | New. Four cases: no main command, a listed one (`codex`), an unlisted one (`fish`), and the order/title pin read off `agentAllowlist` itself. |
| `Clearway.xcodeproj/project.pbxproj` | Regenerated by `xcodegen` to pick up the new test file. |

Nothing reads `agentMenuRows` yet — T3 wires the `+` menu to it. The only behaviour change is the
order of Settings → Main Terminal's picker rows. `agentAllowlist.first` is still `claude`, so
`CommandEditorSheet`'s default agent is unchanged.

**Evidence**

`testRowsFollowTheAllowlistOrder` was watched red against the old order: `agentAllowlist` was
temporarily restored to `["claude", "grok", "codex"]` and `./scripts/ci.sh` run, giving
`Executed 481 tests, with 2 failures`:

```
testRowsFollowTheAllowlistOrder()
    XCTAssertEqual failed: ("["claude", "grok", "codex"]") is not equal to ("["claude", "codex", "grok"]")
    XCTAssertEqual failed: ("["Claude", "Grok", "Codex"]") is not equal to ("["Claude", "Codex", "Grok"]")
```

The order was then restored and the gate re-run. The other three cases cannot be watched red: they
pin a function that did not exist before this task.

**Deviations**

One. The plan's sketch gives `AgentMenuRow.command` a doc comment ("The command as it is executed —
the `agentAllowlist` spelling"); it restates the field and was dropped per the project's comment
rule. The type doc, the `carriesMainTerminalShortcut` doc and the function doc are kept verbatim.

**Gate**

`./scripts/ci.sh` — exit status 0, `Executed 481 tests, with 0 failures`.
