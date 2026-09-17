# Commands View

**Date:** 2026-09-15
**Base:** d94b0b0f879606872a8b1a92e2f38ac144914339

Clearway can save reusable *prompts* but not reusable *actions*. This change adds **Commands**: named,
ordered, globally-stored things a user runs in a worktree. A command is either a **terminal** command
(a shell line such as `bin/dev`) or an **agent** command (a prompt fed to a named agent such as
`claude`). Running one opens a new tab in the currently selected worktree and either executes it
immediately or leaves it staged for the user to press Enter. Commands are created, edited, reordered
and deleted from a new third sidebar destination (⌃3), and run from a **Run** dropdown added to the
worktree toolbar beside Archive / secondary terminal / aside.

## Decisions

| # | Question | Decision | Source |
| --- | --- | --- | --- |
| 1 | Where are commands stored? | One global, ordered JSON file at `~/.clearway/commands.json`. Array order **is** display order; drag-and-drop rewrites the array. Path is fixed, **not** derived from `settings.promptsDirectory` (which is user-configurable, `SettingsManager.swift:83-93`) and not exposed in Settings. | Operator |
| 2 | Which agent does an agent command use? | A per-command `agent` field, chosen in the editor from `agentAllowlist` (`AgentLaunch.swift:4`). **Not** Settings → Main Terminal. That setting keeps its single existing reader. | Operator |
| 3 | What does clicking a command card do? | Opens the editor sheet. Running happens only from the worktree's Run dropdown, which is the only place with the worktree context a new tab needs. Delete lives in the sheet and in a card context menu. | Operator |
| 4 | Which shortcut does the Commands destination get? | ⌃3 (Tasks ⌃1, Prompts ⌃2, Commands ⌃3). The Ctrl+digit claim in `AppKeyboardShortcuts.claims` widens from `"1"…"2"` to `"1"…"3"` (`AppKeyboardShortcuts.swift:33-40`); the `testRetiredControlDigitThreeIsNotClaimed` pin flips to a claimed assertion and ⌃3 leaves `testControlDigitBeyondTheSidebarDestinationsIsNotClaimed`. The separate ⌘⌃3 pin (the retired aside shortcut) **stays** not-claimed — a different combo. CLAUDE.md's two sentences describing the ⌃3 retirement are updated. | Operator |
| 5 | What are the types called? | `SavedCommand` (model), `SavedCommandManager` (`ObservableObject`), `SavedCommandStore` (JSON I/O), `CommandsView`, `CommandEditorSheet`. A bare `Command` was rejected: `command` is already a pervasive `String` parameter and property name in this codebase (`Ghostty.SurfaceView.init(command:)`, `promoteLauncher(command:)`, `hookShellCommand`, `mainCommandProvider`, `buildAgentPromptCommand`), so `let command: Command` beside `let command: String` costs more than the two extra syllables. `CommandManager` alone was rejected for not matching its model's name. | Spec author |
| 6 | Is the manager per-window or process-wide? | **Process-wide**, a `@StateObject` on `ClearwayApp` passed down with `.environmentObject`, exactly like `projectList` and `caffeine` (`ClearwayApp.swift:127-129`, `:159-161`). Storage is global, so the manager is global; this removes cross-window drift by construction. `PromptManager` is per-window *and* watches its directory (`PromptManager.swift:137-147`) because prompts are edited from separate `PromptWindow` scenes and the directory is user-configurable — neither applies here. | Spec author |
| 7 | Does `commands.json` get a file watcher? | No. Clearway is its only writer and there is exactly one manager instance in the process. A watcher would be machinery for a case that cannot arise inside the app. Hand-editing the file while Clearway is running is out of scope. | Spec author |
| 8 | Which column does the Commands view render in? | The **detail** column, with `contentColumn` collapsed to `.navigationSplitViewColumnWidth(0)` — the same shape the `.worktree` case already uses (`ContentView.swift:738-740`). Tasks and Prompts split list/detail because they *have* a detail; Commands opens a sheet instead (decision 3), so a split would leave an empty pane. This also matches the operator's mock: one wide pane, centred cards, floating `+` bottom-right. | Spec author |
| 9 | How is the card list reordered? | A `List` with `.listStyle(.plain)`, card-styled rows, and `ForEach(...).onMove`. `SidebarView` already gets native macOS drag-reorder this way with no edit mode (`SidebarView.swift:223-228`, `:298-303`), so this is the existing mechanism rather than a hand-rolled `.draggable`/`.dropDestination` pair. | Spec author |
| 10 | Can the list be reordered while the All/Terminal/Agent filter is on? | No. `.onMove` guards on the filter and rows get `.moveDisabled(filterIsActive)`, mirroring how the sidebar disables moves while its search filter is active (`SidebarView.swift:221`, `:225`). A move computed against a filtered subset would silently rewrite the wrong global positions. | Spec author |
| 11 | How does a **terminal** command run? | Append a new shell tab to the selected worktree (`TerminalManager.appendShellTab`, `TerminalManager.swift:295-300`) and inject the command text into it once the surface is live: `sendCommand` (text + Enter) when auto-run is on, `sendText` (text, no Enter) when off. Both are reachable — `sendText` is internal and `Sources/Ghostty` and `Sources/App` compile into the one `Clearway` target (`project.yml:22-26`). Passing the command as the surface's `command:` was rejected: a clean exit auto-closes the tab (`TerminalManager.swift:415-424`), so `bin/test` would vanish with its output, and it cannot serve the auto-run-off case at all. One mechanism for both halves of one checkbox. | Spec author |
| 12 | When is the injection safe? | The surface must be at a shell prompt. The gate is `Ghostty.SurfaceView.pwd` becoming non-`nil` — it is `@Published` (`Ghostty.SurfaceView.swift:29`) and set from libghostty's PWD action (`Ghostty.App.swift:268-270`), which shell integration emits at the prompt — with a short fixed-delay fallback for shells where integration is inactive. `runHookInSecondary`'s bare `asyncAfter(0.1)` (`TerminalManager+Panels.swift:16-22`) is precedent only for an **already running** shell and is not sufficient for a freshly spawned one. **Open:** the exact gate and fallback duration are to be confirmed against the running app in the build stage (see Open Questions). | Spec author |
| 13 | How does an **agent** command run? | Append a launcher tab carrying a **per-tab agent override** (the command's `agent`). Auto-run on → immediately `promoteLauncherToAgent(tabId:in:app:command: <agent>, prompt: <text>)` (`TerminalManager+Launcher.swift:20-51`), so the agent starts with the prompt already submitted. Auto-run off → the tab stays a launcher with `launcherDrafts[tabId]` pre-filled, and the user edits and submits. This reuses the launcher end to end rather than inventing a second path. | Spec author |
| 14 | How does the per-tab agent reach the launcher? | `TerminalManager.appendLauncherTab` gains an `agentOverride: String?` parameter defaulting to `nil`, so every existing call site is unchanged. Non-`nil` does two things: it suppresses the "Settings command is None → promote straight to a login shell" branch (`TerminalManager.swift:279-281`), which would otherwise swallow an agent command whenever Settings → Main Terminal is "None", and it records the agent in a new non-`@Published` `launcherAgents: [UUID: String]` beside `launcherDrafts` (`TerminalManager.swift:205`). `ContentView` resolves the launcher's agent as `launcherAgents[tab.id] ?? settings.resolvedMainTerminalCommand` for both the rendered `command:` (`ContentView.swift:797`) and `onSubmit` (`:810`). Cleared at each of `launcherDrafts`' five clear sites. | Spec author |
| 15 | Where does the Run dropdown live and when is it enabled? | A `Menu` toolbar item in the `if selectedWorktree != nil` block of `ContentView`'s `.toolbar` (`ContentView.swift:198-222`), placed before Archive. It is disabled when the command list is empty **or** `ghosttyApp.app` is `nil`. Both preconditions, not just the first: CLAUDE.md's `PanelToggle` rule — an enabled control whose action needs a live `ghostty_app_t` renders enabled and silently does nothing when `ghostty_app_new` failed. | Spec author |
| 16 | Does the "Saved actions for terminal or agents." subtitle survive the no-helper-text rule? | Yes. The global style rule admits copy that was asked for, and the operator drew this line into the mock. It is the only descriptive copy in the view. | Spec author |
| 17 | Is the auto-run checkbox labelled the same for both kinds? | Yes — "Append Enter to run immediately", verbatim from the brief, for terminal and agent alike. For an agent command it means the launcher submits itself instead of waiting. | Operator |
| 18 | What does `DetailSelection.bottomPanelAction` return for `.commands`? | `.noPanel`. The switch is exhaustive by design (`ContentView.swift:31-37`), so the new case must be answered; Commands hosts no bottom panel, so ⌘J greys out there as it does on Prompts. `BottomPanelActionTests` gains the assertion. | Spec author |
| 19 | What happens to a corrupt or unreadable `commands.json`? | Log a warning and load as empty, mirroring `WorktreeGroupStore.load` (`WorktreeGroupStore.swift:64-70`). The file is only rewritten when the user next changes something, so a transient read failure does not destroy data on its own. | Spec author |
| 20 | Does anything migrate? | No. There is no prior commands storage and no prior on-disk format. A missing file is the empty list. | Spec author |
| 21 | Does the worktree aside panel get a Commands tab? | No. `SidePanelTab` (`ContentViewHelpers.swift:31-41`) keeps Task / Todos / Prompts. The brief asks for a sidebar destination and a toolbar dropdown; an aside tab is neither. | Spec author |
| 22 | How is the editor sheet laid out? | Kind first, labelled "Command kind"; then "Menu label" (the `name` field); then Agent for the agent kind; then the command or prompt text as a multi-line `TextEditor` for **both** kinds at one fixed height, so the sheet does not resize when the kind changes. Supersedes the build-stage assumption that a terminal command is one shell line and needs only a `TextField`. Run semantics are unchanged — `RunCommandMenu.run` and `sendCommand` still send one line — and what a multi-line terminal command should do is a separate decision. Raised from a hands-on check after T7; see the plan's Changelog C1. | Operator |
| 23 | What does a multi-line terminal command do? | It is sent verbatim: every embedded newline is an Enter, so the lines run in order in the user's own shell. "Append Enter to run immediately" governs the **trailing** Enter alone — on, the last line runs too; off, it stays staged and editable on the prompt. Single-line behaviour is unchanged, and agent commands are unaffected. Supersedes decision 22's "run semantics are unchanged" and the plan's decision 11. Raised from a hands-on check after C1; see the plan's Changelog C2. | Operator |
| 24 | What does the Run dropdown show in the toolbar? | The text label **"Run command"**, not an icon. The `play` `Image` is gone. The `.help("Run a saved command")` tooltip goes with it: on an icon-only button the tooltip was the control's only name, on a text button it restates the visible label, which the no-helper-text rule refuses. The disabled gating (decision 15) and the menu items are untouched. Raised from a hands-on check after C2; see the plan's Changelog C3. | Operator |
| 25 | How is the Run dropdown drawn in the toolbar? | As an icon-only button: the `play` `Image` is back, `.help("Run a saved command")` is back with it because on an icon-only control the tooltip is the control's name, and the chevron SwiftUI's `Menu` draws is hidden with `.menuIndicator(.hidden)` so it matches the neighbouring Archive, secondary terminal and aside buttons. No `.menuStyle` is set — those neighbours set no `.buttonStyle` either. **Supersedes decision 24.** The disabled gating (decision 15) and the menu items stay untouched. Raised from a hands-on check after C3; see the plan's Changelog C4. | Operator |
| 26 | How are the four worktree toolbar buttons grouped? | Each sits in its **own** Liquid Glass capsule. On macOS 26 adjacent toolbar items sharing one placement are drawn inside one shared background; a `ToolbarSpacer(.fixed, placement: .primaryAction)` between each adjacent pair breaks that into four. Apple's *Adopting Liquid Glass* names this the spacer's job: "You can create a fixed spacer to separate items that share a background using these APIs:", listing `SpacerSizing.fixed` / `ToolbarSpacer` for SwiftUI. The spacers only take effect when the `.toolbar` block is attached to the **detail column's content**, not to the `NavigationSplitView` itself: attached to the split view, SwiftUI routes the `ToolbarItem`s into the detail section but hoists every `ToolbarSpacer` into the leading sidebar section, so the four buttons stay adjacent and share one capsule. That hoisting ignores the spacer's `placement:` argument — `.primaryAction`, `.secondaryAction` and `.automatic` all land leading. `.flexible` was rejected — it pushes items to opposite ends of the toolbar. `ToolbarItemGroup` per button changes nothing (still one capsule) and `.sharedBackgroundVisibility(.hidden)` removes the glass rather than splitting it — Apple's reference says "Hiding the effect will cause the item to be placed in its own grouping", and in the running app it leaves the four buttons with no capsule at all. `ToolbarSpacer` is macOS 26.0+, so each spacer is gated with `if #available(macOS 26, *)`; on macOS 13–25 the toolbar is unchanged. The buttons, their order and their gating are untouched. Raised from a hands-on check after C4, corrected by a second hands-on check; see the plan's Changelog C5. | Operator |
| 27 | How is the Commands view's page chrome drawn? | Natively. The in-body "Commands" title, the "Saved actions for terminal or agents." subtitle, the hand-drawn `Divider()` and the 720 pt centred content-width frames are all gone; the window title reads "Commands" instead of the project name, and the All/Terminal/Agent segmented picker moves into `.toolbar { ToolbarItem(placement: .primaryAction) }`, where `PromptListView` and `WorkTaskListView` already put theirs. The single column (decision 8) and the editor-as-sheet (decision 3) are kept. **Supersedes decision 16** — the subtitle was drawn into the mock, and the mock is what this change is correcting — and the "centred cards, floating `+`" half of decision 8. The title is resolved in `ContentView`'s `navigationTitle` property, not by a `.navigationTitle` inside `CommandsView`: that modifier sits outside the `NavigationSplitView` and overrides anything a column sets, measured in a standalone probe. Raised from a HIG review after C5; see the plan's Changelog C6. | Operator |
| 28 | How is a command drawn in the list? | As a plain row in a `List(selection:)` with `.listStyle(.inset)`, mirroring `PromptListView.promptList` and `WorkTaskListView.taskList`: the name, the command text beneath it in a monospaced caption, and the kind capsule badge trailing — the badge stays. `CommandCard`'s rounded-rectangle background is gone, so rows get the native selection highlight, focus ring and keyboard navigation. Click-to-edit, the context-menu delete, `.onMove` reordering disabled while a filter is active (decision 10), and the empty state are unchanged. The row's tap sets the selection itself, because the gesture consumes the click the list would otherwise have selected with. **Supersedes decision 9**'s `.listStyle(.plain)` and card-styled rows; the reorder mechanism it chose is untouched. | Operator |
| 29 | How is a new command created? | From a toolbar `+` carrying `.help("New command")`, in the same `.primaryAction` group as the filter picker, and from a **New Command** item in `ClearwayApp`'s `CommandGroup(replacing: .newItem)` beside New Tab / New Shell Tab / New Task. It carries **no** key equivalent, so `AppKeyboardShortcuts.claims` is untouched. The item is gated on a `newCommandAction` focused **scene** value that `CommandsView` publishes itself — the `PanelCommands.swift` pattern — so it is `nil`, and the item greyed out, whenever Commands is not the showing destination, including in a standalone Task/Prompt/Settings window. The floating circular `+` is gone. **Supersedes** the floating `+` in decision 8. | Operator |
| 30 | Does the floating circular `+` survive anywhere else in the app? | No — it is retired app-wide on this branch. Decision 29 removed it from `CommandsView`; the same shape (a `.plain`-styled circular button in `.overlay(alignment: .bottomTrailing)`) remained in `PromptListView`, `WorkTaskListView`, `PromptsView` and `TodosPanelView` — the fourth found by grep, beyond the three the HIG review named. Each becomes a toolbar `+` `Image(systemName: "plus")` at `.primaryAction` with a `.help()` tooltip as its name, first in the group, exactly as decision 29 did. `PromptListView` and `WorkTaskListView` already had a `.toolbar`, so the item joins it; `PromptsView` and `TodosPanelView` are aside-panel views and declare their own, which reaches the window toolbar's detail section because the aside renders inside `detailView`. The two `square.and.pencil` glyphs become `plus` so all four read the same. The create actions themselves are unchanged. A **New Prompt** item joins `CommandGroup(replacing: .newItem)` on the decision 29 pattern — no key equivalent, gated on a `newPromptAction` focused scene value that `PromptListView` publishes, so it greys out off the Prompts destination and in standalone windows. **New Task already existed** and is untouched, including its gating, which is a project window rather than the Tasks destination. No keyboard shortcut is added, changed or claimed. Raised from a hands-on check after C6; see the plan's Changelog C7. | Operator |
| 31 | Does a toolbar `+` share a Liquid Glass capsule with the items beside it? | No — on every view that has one it sits in its **own** capsule, by decision 26's mechanism: a single `if #available(macOS 26, *) { ToolbarSpacer(.fixed, placement: .primaryAction) }` beside the `+` `ToolbarItem`. The rest of each toolbar's grouping is left alone; only the `+` is pulled out. Which side the spacer goes on depends on where the view's toolbar content lands in the merged window toolbar. `CommandsView`, `PromptListView` and `WorkTaskListView` declare their own toolbar and their `+` is its first item, so the spacer **follows** it. `PromptsView` and `TodosPanelView` are aside panels rendered inside `ContentView.detailView`, and SwiftUI merges a nested view's toolbar content **after** the enclosing view's: their `+` arrives last, behind `detailView`'s four worktree items, so the break that separates it is the one on its **leading** side and the spacer precedes the item. A spacer placed after it lands at the trailing end of the toolbar and separates nothing — measured, both ways, with the decision 26 `NSToolbarView` probe; see the plan's Changelog C8. `ToolbarSpacer` stays macOS 26.0+, so every spacer keeps its `if #available(macOS 26, *)` guard and macOS 13–25 is unchanged. The `+` buttons themselves, their order, their actions and their gating are untouched. Raised from a hands-on check after C7. | Operator |
| 32 | How does the editor's command/prompt `TextEditor` match the "Menu label" field above it? | Two changes, nothing else. **Font:** `.body` for an agent prompt and `.body.monospaced()` for a terminal command, replacing `.callout` (12 pt) — the `TextField` above it uses the default body (13 pt), so the two now read at one size. **Focus:** `TextEditor` draws no focus ring on macOS, so focus is tracked with `@FocusState` and the existing rounded border is stroked `Color.accentColor` at 2 pt — the system ring weight — while focused and `.quaternary` at 1 pt otherwise. The 120 pt height, the 4 pt inner padding and the `Color(.textBackgroundColor)` fill are kept, and every other control in the sheet is untouched. Raised from a hands-on check after C8; see the plan's Changelog C9. | Operator |


## Assumptions

Each verified against the codebase at base `d94b0b0`. No probe scripts or temporary files were written
into the repo; nothing empirical was needed beyond reading.

1. **New Swift files need no `project.yml` edit.** `project.yml:25-26` declares
   `sources: - path: Sources` and the test target adds `Tests` by path, so `xcodegen generate` — which
   `./scripts/ci.sh` runs — picks up new files by directory.
2. **`Sources/Ghostty` and `Sources/App` are one compilation unit.** A single `Clearway` application
   target with one `sources` entry (`project.yml:21-26`), so `Ghostty.SurfaceView.sendText` — declared
   without an access modifier at `Sources/Ghostty/Ghostty.SurfaceView.swift:433` — is reachable from
   `Sources/App`. `sendCommand` (`:441`) and `sendPaste` (`:454`) both append Enter unconditionally
   (`:448`, `:458`), so `sendText` is the only way to stage a line without running it.
3. **A main tab whose child exits cleanly closes itself.** `TerminalManager.replaceSurface` closes the
   tab when `childExitCode == 0` and keeps it on a non-zero exit (`TerminalManager.swift:417-425`).
   This is what rules out running a terminal command as the surface's `command:` (decision 11).
4. **`appendLauncherTab` promotes straight to a shell when Settings → Main Terminal is "None".**
   `if mainCommandProvider() == nil { promoteLauncher(...) }` at `TerminalManager.swift:279-281`. An
   agent command must not be caught by that branch, which is why `agentOverride` gates it
   (decision 14). The sibling check in `pane(for:)` (`:154`) is not on this path: `appendLauncherTab`
   creates a missing pane itself (`:263-272`) rather than routing through `pane(for:)`.
5. **The launcher's agent currently comes only from Settings.** `ContentView` passes
   `settings.resolvedMainTerminalCommand` to both `PromptLauncherView(command:)` and the `onSubmit`
   promotion (`ContentView.swift:797`, `:811`). Without a per-tab override, an agent command with
   auto-run off would pre-fill a prompt that then runs the *wrong* agent.
6. **`launcherDrafts` is keyed by tab id and has five clear sites.** Declared at
   `TerminalManager.swift:205`; cleared at `:108` (`closeAll`), `:326` (`promoteLauncher`), `:364`
   (`closeMainTab`), `:459` (`removeSurface`) and `:485` (`closeWorktree`). `launcherAgents` follows
   the same key and all five sites — missing one would leak a stale agent onto a recycled tab id.
7. **`DetailSelection` is never serialized.** `enum DetailSelection: Hashable` with no `Codable`
   conformance (`ContentView.swift:18`); its only holders are the two `@State` properties at `:65-66`.
   Adding a `.commands` case cannot invalidate stored state.
8. **`.onMove` on a plain `List` gives macOS drag reorder with no edit mode.** Already relied on by the
   sidebar's two reorderable sections (`SidebarView.swift:223-228`, `:298-303`) on the same
   macOS 13.0 deployment target (`project.yml:4-5`).
9. **`agentAllowlist` has exactly one reader today.** `SettingsView.swift:11`; the only other match in
   `Sources` and `Tests` is its declaration (`AgentLaunch.swift:4`). Adding the editor's picker as a
   second reader changes no launch gating — nothing is gated against the list.
10. **`~/.clearway/` is the established global directory.** `SettingsManager.defaultPromptsDirectory`
    is `"~/.clearway/prompts"` (`SettingsManager.swift:83`) and `PromptManager` creates its directory
    with `0o700` (`PromptManager.swift:62`, `:142`). `commands.json` sits beside `prompts/` there and
    is written `0o600`, matching how prompt files are created (`PromptManager.swift:66`).
11. **⌃3 is currently pinned as retired, and ⌘⌃3 is a separate pin.**
    `Tests/AppKeyboardShortcutsTests.swift:131-133` asserts `claims([.control], "3") == false`;
    `:124-127` asserts the unrelated `[.command, .control]` variants stay unclaimed. `:66-72` also
    lists `"3"` among the digits beyond the destination range. Decision 4 touches the first and third
    and leaves the second alone.
12. **The worktree toolbar block is guarded by `selectedWorktree != nil`.**
    `ContentView.swift:198-222` — Archive, secondary-terminal and aside buttons all live inside it, so
    the Run dropdown inherits the same gate for free.
13. **SwiftLint's `file_length` warns at 700 lines and errors at 1000** (`.swiftlint.yml`).
    `ContentView.swift` is 987 lines and already carries `// swiftlint:disable file_length` (line 1).
    The additions to it must stay small; anything larger belongs in the new files (see Files).

## Objective

A user with a repository full of repeated actions — start the dev server, run the test suite, ask
Claude to review the PR — saves each one once and runs it in any worktree with two clicks, without
retyping it or remembering which agent to invoke.

### Success criteria

1. The sidebar shows a third destination, **Commands**, below Prompts, selected by click or ⌃3, with
   the ⌃3 badge appearing while Control is held like the other two rows.
2. The Commands view lists every saved command as a card showing its name, its command or prompt text,
   and a `Terminal` / `Agent` kind label, with an All / Terminal / Agent filter above the list and a
   floating `+` button bottom-right.
3. `+` opens an empty editor sheet; clicking a card opens that card's editor sheet. The sheet edits
   name, kind, agent (agent kind only), command/prompt text and the "Append Enter to run immediately"
   checkbox, and can delete the command. A card's context menu can also delete it.
4. Dragging a card to a new position reorders the list, the new order persists across app restart, and
   dragging is unavailable while a filter other than All is active.
5. Commands survive an app restart and are identical in every open project window — one global file.
6. With a worktree selected, a **Run** dropdown in the toolbar lists every command in saved order. It
   is greyed out when there are no commands.
7. Choosing a **terminal** command opens a new tab in the current worktree with the command text at the
   shell prompt: already executed when "Append Enter" is checked, staged and editable when it is not.
8. Choosing an **agent** command opens a new tab running that command's agent. With "Append Enter"
   checked, the agent starts with the prompt already submitted. Unchecked, the tab shows the prompt
   launcher pre-filled with the prompt text and addressed to that command's agent — including when
   Settings → Main Terminal is "None".
9. A focused terminal surface no longer swallows ⌃3; ⌃1 and ⌃2 are unchanged, and ⌘⌃3 is still not
   claimed.
10. `./scripts/ci.sh` is green.

## Verification

Copied from the project's `## Pipeline` section — one command serves as both the regression check and
the full gate:

```
./scripts/ci.sh
```

It runs `xcodegen generate`, SwiftLint, the build and the test suite. Do not hand-write an
`xcodebuild` line: new Swift files are invisible to the build until `xcodegen generate` runs, and
`build.sh`'s `PRODUCT_NAME` override breaks `TEST_HOST`.

Manual check, for the behaviours XCTest cannot reach (every criterion above involving a live surface):

```
./scripts/run.sh
```

Before any CI stamp, run `git status --porcelain` and report untracked or ignored files. Expect the
un-gitignored `default.profraw` after any Debug launch.

### Tests

New pure helpers, following the project's existing split of decision rules out of view and surface code:

- `Tests/SavedCommandStoreTests.swift` — encode/decode round-trip, order preserved as written, missing
  file loads empty, corrupt file logs and loads empty, unknown `kind` string does not crash the load.
  Mirrors `WorktreeGroupStoreTests`.
- `Tests/SavedCommandTests.swift` — the pure filter (`All` / `Terminal` / `Agent`) and the pure launch
  resolver: `SavedCommand` → a `CommandLaunch` value (`.shell(text:execute:)` /
  `.agent(agent:prompt:submit:)`). This is the `TerminalManager.revealSecondaryForHook` split — the
  rule is unit-tested, the surface work that consumes it is not.
- `Tests/AppKeyboardShortcutsTests.swift` — ⌃3 flips from a retired pin to a claimed assertion;
  `"4"…"9"` and `"0"` stay unclaimed; the ⌘⌃3 pin is untouched.
- `Tests/BottomPanelActionTests.swift` — `.commands` returns `.noPanel`.

## Files

New:

| Path | Contents |
| --- | --- |
| `Sources/App/SavedCommand.swift` | The `SavedCommand` model, its `Kind` enum, the pure filter, and the `CommandLaunch` resolver. |
| `Sources/App/SavedCommandStore.swift` | Load/save of `~/.clearway/commands.json`. |
| `Sources/App/SavedCommandManager.swift` | `@MainActor ObservableObject`: published ordered list, create / update / delete / move, persistence. |
| `Sources/App/CommandsView.swift` | The destination: header, filter, card list, `+` button, sheet presentation. |
| `Sources/App/CommandEditorSheet.swift` | The create/edit sheet. |
| `Sources/App/RunCommandMenu.swift` | The toolbar `Menu` and the run action that resolves a `CommandLaunch` onto `TerminalManager`. |
| `Tests/SavedCommandStoreTests.swift`, `Tests/SavedCommandTests.swift` | See Tests above. |

Changed:

| Path | Change |
| --- | --- |
| `Sources/App/ContentView.swift` | `DetailSelection.commands` case + its `bottomPanelAction` arm; the ⌃3 hidden button beside ⌃1/⌃2; the `.commands` branch in `detailView`; the Run toolbar item; the launcher's agent resolved through `launcherAgents`. |
| `Sources/App/SidebarView.swift` | `commandsRow` below `promptsRow`, tagged `.commands`, hint `⌃3`. |
| `Sources/App/AppKeyboardShortcuts.swift` | Ctrl+digit claim widens to `"1"…"3"`; the comment naming "two destinations" follows. |
| `Sources/App/TerminalManager.swift` | `agentOverride` parameter on `appendLauncherTab`; `launcherAgents` storage and its three clear sites. |
| `Sources/App/ClearwayApp.swift` | `@StateObject` `SavedCommandManager` + `.environmentObject` on the project `WindowGroup`. |
| `Sources/Ghostty/Ghostty.SurfaceView.swift` | `sendLines(_:runsLastLine:)`, the line-at-a-time primitive decision 23 needs. |
| `Tests/AppKeyboardShortcutsTests.swift`, `Tests/BottomPanelActionTests.swift` | See Tests above. |
| `CLAUDE.md` | The two `AppKeyboardShortcuts` sentences describing ⌃3's retirement and the `"1"…"2"` span; a short note on where commands live. |

## Out of scope

- Per-project commands, or a Settings field for the commands file path. Storage is global and fixed
  (decisions 1, 7).
- Running a command anywhere but a worktree's main-terminal tabs — not from the secondary terminal, the
  task terminal, the aside, or the Tasks destination.
- A keyboard shortcut per command, or a Commands entry in the menu bar.
- A Commands tab in the worktree aside panel (decision 21).
- Importing commands from `package.json`, `Makefile`, `mise.toml` or similar.
- Command arguments, placeholders or variable substitution. A command is a literal string.
- Watching `commands.json` for external edits (decision 7).
- Any change to Settings → Main Terminal, to `agentAllowlist`'s membership, or to how the existing
  prompt launcher behaves when no command override is present.

## Open questions

1. **Injection readiness for terminal commands** (decision 12). The gate — first non-`nil` `pwd`, with a
   fixed-delay fallback — is chosen from the code but has not been observed against a live surface,
   and the fallback duration is unpicked. A brand-new shell may or may not consume PTY input delivered
   before it enters its line editor. The build stage settles this by running the app; if the gate
   proves unreliable, the fallback is the `runHookInSecondary` shape (a fixed delay, no gate), which
   changes nothing in this spec but the timing constant.
