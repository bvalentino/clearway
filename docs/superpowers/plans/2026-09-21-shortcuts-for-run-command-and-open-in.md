# Plan: Shortcuts for Run command and Open In

Breaks down `docs/superpowers/specs/2026-09-21-shortcuts-for-run-command-and-open-in.md`.

**Date:** 2026-09-21
**Base:** 4e93fceeb10f1dc984f3d33cdaec50223e95ac59 (Spec: shortcuts for Run command and Open In)

## Architecture decisions carried from the spec

- Each key is declared **once**, on its Worktree-menu item. No hidden `.keyboardShortcut` button
  anywhere, and no `.keyboardShortcut` on the toolbar's Run or Open In buttons — a second
  declaration lands in a layer that silently wins (D1, and the `PanelCommands` rule in
  `Sources/App/CLAUDE.md`).
- ⌥⌘R pops the **toolbar** Run split button's live `NSMenu` through AppKit. There is no fallback
  behaviour: if the control is not found, the action does nothing (D2, D3, and the Risks section).
- The pop is: recursive search of `NSApp.keyWindow`'s content view tree for an
  `NSSegmentedControl` whose `labelForSegment(0)` equals `SavedCommandManager.runButtonTitle`, then
  `menuForSegment(1)`, then `popUpMenuPositioningItem(nil, at: <control's bottom-left in its own
  coordinates>, in: control)`. The label match is what rules out `CommandsView`'s
  `.pickerStyle(.segmented)` filter and the Open In split button (D3, A6, A7).
- The Worktree menu has **five** rows, in order: "Run \<name>" (⌘R), "Run…" (⌥⌘R), a Run submenu,
  "Open in \<label>" (⌘O), an "Open in" submenu. The fifth row exists because a SwiftUI `Menu` used
  as a submenu row has no action closure for AppKit's key-equivalent dispatch to fire (D4, A5).
  The operator accepted this row on 2026-09-21.
- ⌘R, ⌥⌘R and ⌘O are claimed **unconditionally** in `AppKeyboardShortcuts.claims`, like ⌘T. The
  table is pure and holds no window state; a terminal surface only has focus on the worktree
  destination, where all three are live (D5).
- The menu items reach per-window state through **two** focused **scene** values published by
  `ContentView`: `WorktreeRunActions?` and `WorktreeOpenInActions?`. Each carries its list, its
  primary, its title and its closures. `nil` greys the items out. Two values, not one, because
  they gate on different preconditions (D6, D7).
- `WorktreeRunActions` is nil when no worktree is selected or `ghosttyApp.app == nil`.
  `WorktreeOpenInActions` is nil when there is no selected worktree path or
  `settings.openInApps.isEmpty` (D8).
- With no saved commands, "Run \<name>" renders "Run" and is disabled; the Run submenu and "Run…"
  stay enabled so "Add Command…" is reachable. With an empty app list, "Open in \<label>" **and**
  the Open in submenu are both disabled (D9, D10).
- The submenu's "Add Command…" posts a new `Notification.Name.clearwayAddCommand` with the focused
  window's `SavedCommandManager` as `object`; `RunCommandMenu` observes it and sets its existing
  `showCommandEditor`. One presenter of `CommandEditorSheet`, not two (D11, A10).
- **No duplicated action bodies.** Run's record-then-launch and Open In's launch-then-alert have
  exactly one implementation each, moved out of the two menu views; the toolbar views are handed
  the action they call. `OpenInMenu.presentFailure` must not be written a second time (D12).
- One `CommandMenu("Worktree")` in `ClearwayApp.commands`; SwiftUI places it after View (D13).
- `ContentView.swift` is at 1011 lines against a 1000-line `file_length` **error**, carried by the
  file-wide disable at line 1. `sidePanelTabStrip` + `sidePanelTabButton` are extracted into
  `Sources/App/SidePanelTabStrip.swift` **before** anything is added (D14, A12).
- The `swiftlint:disable file_length` at `ContentView.swift:1` and the
  `swiftlint:disable:next type_body_length` at line 54 both **stay**. The file lands near 980
  lines, over the 700-line warning threshold, and the project forbids new warnings (D15).
- ⌥⌘O is not claimed and nothing declares it (D16).
- Out of scope: moving Remove Worktree or any other toolbar action into the Worktree menu;
  changing what Run or Open In do or how a primary is chosen; per-command or per-app shortcuts; the
  sidebar's right-click Open In submenu; the tab strip `+` menu and the File menu; retiring
  `ContentView`'s SwiftLint disables.

## Regression check

Every task below verifies with the project's one command, from `CLAUDE.md`'s `## Pipeline` section:

```
./scripts/ci.sh
```

It regenerates the Xcode project — without which new Swift files are invisible to the build —
lints, builds and runs the suite. Do not hand-write an `xcodebuild` line.

Criteria 1–5, 8 and 11 of the spec are operator hand-checks; no task claims them.

## Dependency graph

```
T1 (extract SidePanelTabStrip — makes room in ContentView)
      │
      └── T2 (action structs + focused-value keys; toolbar views take them)
                │
                ├── T3 (ToolbarSplitButtonMenu: the AppKit reach for ⌥⌘R)
                │         │
                ├── T4 (.clearwayAddCommand → RunCommandMenu's sheet)
                │         │
                │         │
                └────────┴── T5 (the Worktree menu's five items)
                                   │
                                   └── T6 (claim ⌘R / ⌥⌘R / ⌘O + pin the table)
                                             │
                                             └── T7 (rewrite the CLAUDE.md notes this falsifies)
```

T1 first: `ContentView.swift` cannot take another line until the strip moves out. T2 is the
foundation every menu item stands on and changes no behaviour. T3 and T4 are independent of each
other and both feed T5. T6 lands **after** T5 so no key is claimed from the shell before a handler
exists for it. T7 describes the shape T5 and T6 create.

### T1: Extract the side panel tab strip out of ContentView

**Files:** `Sources/App/ContentView.swift`, `Sources/App/SidePanelTabStrip.swift` (new)

**What it does.** Moves `sidePanelTabStrip` and `sidePanelTabButton(for:)`
(`ContentView.swift:954-1010`) into a new `struct SidePanelTabStrip: View` in its own file. The
strip's whole input is three things ContentView already computes:

- `selection: Binding<SidePanelTab>` — bound to ContentView's `@State sidePanelTab`
- `tabs: [SidePanelTab]` — ContentView's `availableSidePanelTabs`
- `effectiveTab: SidePanelTab` — ContentView's `effectiveSidePanelTab`, which clamps the stored tab
  to the available set and must stay in ContentView, since it is read by the `switch` at line 893

The call site at `ContentView.swift:891` becomes
`SidePanelTabStrip(selection: $sidePanelTab, tabs: availableSidePanelTabs, effectiveTab: effectiveSidePanelTab)`.

Both `@available(macOS 26.0, *)` branches, the `glassEffect` capsule, the accessibility element and
label, the pre-26 `.pickerStyle(.segmented)` fallback and its trailing `Divider()` move across
verbatim. Nothing about the rendering changes.

`ContentView.swift`'s two SwiftLint disables stay (D15). Do not add a doc comment restating the
type name; the file is new but the project's comment rule still applies.

**Acceptance criteria.**
1. `Sources/App/SidePanelTabStrip.swift` exists and holds the strip and its per-tab button; neither
   symbol remains in `ContentView.swift`.
2. `wc -l Sources/App/ContentView.swift` is under 1000.
3. `swiftlint lint --quiet` reports zero errors and no **new** warnings against the pre-change
   baseline.
4. The rendered strip is unchanged: same two availability branches, same modifiers, same
   `Divider()` below the pre-26 picker.

**Verification.** `./scripts/ci.sh` green. Criteria 1 and 2 read off `wc -l` and `grep -n
"sidePanelTabStrip\|sidePanelTabButton" Sources/App/ContentView.swift` (the only hit must be the
`SidePanelTabStrip(...)` call). Criterion 4 by diffing the moved bodies against
`git show HEAD:Sources/App/ContentView.swift | sed -n '954,1010p'`.

### T2: Give Run and Open In one shared action implementation each, and publish them

**Files:** `Sources/App/WorktreeCommands.swift` (new), `Sources/App/RunCommandMenu.swift`,
`Sources/App/OpenInMenu.swift`, `Sources/App/ContentView.swift`

**Depends on:** T1.

**What it does.** Creates the two action structs and the two focused-value keys, and moves the two
action bodies out of the menu views so the toolbar and the menu bar share one implementation each
(D12). **This task adds no menu and changes no behaviour** — the toolbar must look and act exactly
as it does at HEAD when it lands.

In `Sources/App/WorktreeCommands.swift`:

- `struct WorktreeRunActions` carrying what a menu row needs without reaching into the environment:
  the primary command, the title (`SavedCommandManager.runButtonTitle`), the **full** saved-command
  list in display order (not `menuCommands` — the menu bar's submenu lists every command, spec
  criterion 6), and a `run: (SavedCommand) -> Void` closure. `popRunMenu` is added by T3.
- `struct WorktreeOpenInActions` carrying the primary app, the title
  (`SettingsManager.openInButtonTitle`), the **full** `openInApps` list in display order, and an
  `open: (OpenInApp) -> Void` closure.
- `WorktreeRunActionsKey` / `WorktreeOpenInActionsKey` conforming to `FocusedValueKey`, and the two
  `FocusedValues` computed properties, in the shape of `Sources/App/PanelCommands.swift:9-36`.
- The one implementation of each action body, so neither is written twice:
  - Run: `savedCommandManager.recordLastRun(command)` **before** the `ghosttyApp.app` guard (the
    recorded pick is the pick, not the successful launch — `RunCommandMenu.swift:79-83` and the
    CLAUDE.md note), then `terminalManager.run(command, in: worktree, app: app)`.
  - Open In: optionally `settings.recordOpenInUse(app)`, then
    `await OpenInAppLauncher.launch(command:path:)`, then on `.failed` the `NSAlert` currently in
    `OpenInMenu.presentFailure` (`OpenInMenu.swift:102-109`), verbatim including the
    `OpenInAppLauncher.failureMessage(command:detail:)` body and the single OK button.

In `Sources/App/RunCommandMenu.swift`: the view takes the run action rather than building it.
`recordLastRun` and `terminalManager.run` must no longer appear in this file. Everything else
stays: the two `Menu` declarations, `.id(savedCommandManager.menuCommands)`, the primary resolved
**inside** the `primaryAction:` closure rather than captured by the branch's `if let`, the
`.disabled(ghosttyApp.app == nil)`, and the `.sheet` hanging outside that `.disabled`.

In `Sources/App/OpenInMenu.swift`: the toolbar variant (`remembersLastUsed == true`) takes the open
action. The sidebar variant keeps its current call shape — a plain submenu over `settings.openInApps`
whole, no `primaryAction:`, no recording — but routes its launch through the same shared
implementation, so `NSAlert` is constructed in exactly one place in the tree. `.id(settings.menuOpenInApps)`
stays on the toolbar variant.

In `Sources/App/ContentView.swift`: add `@EnvironmentObject private var savedCommandManager:
SavedCommandManager` (it is already in the environment — `ProjectWindow.swift:149`), build the two
structs as computed properties returning `nil` per D8, hand them to the two toolbar items at lines
197-208, and add two `.focusedSceneValue` lines beside the six at lines 103-108.

**Acceptance criteria.**
1. `grep -rn "NSAlert" Sources/App/OpenInMenu.swift Sources/App/WorktreeCommands.swift` shows the
   Open In failure alert constructed exactly once across the whole tree.
2. `grep -n "recordLastRun\|terminalManager.run" Sources/App/RunCommandMenu.swift` returns nothing.
3. `ContentView` publishes `\.worktreeRunActions` and `\.worktreeOpenInActions` as focused **scene**
   values; each is `nil` exactly per D8 (run: no selected worktree, or `ghosttyApp.app == nil`;
   open in: no selected worktree path, or `settings.openInApps.isEmpty`).
4. The toolbar is unchanged in behaviour: Run still shows the primary command's name, still runs it
   on a click, still records it; Open In still shows `settings.openInButtonTitle`, still opens and
   records; the sidebar's context submenu still lists every app and records nothing.
5. No `.keyboardShortcut` is added anywhere in this task.

**Verification.** `./scripts/ci.sh` green. Criteria 1, 2 and 5 by grep. Criterion 3 by reading
`ContentView.body` and the two computed properties. Criterion 4 is behaviour a test cannot reach
(both paths need a `ghostty_app_t` or `NSWorkspace`), so it is read off the diff: the moved bodies
must be identical statement-for-statement to the ones at
`git show HEAD:Sources/App/RunCommandMenu.swift` and `:Sources/App/OpenInMenu.swift`.

### T3: The AppKit reach that pops the toolbar Run dropdown

**Files:** `Sources/App/ToolbarSplitButtonMenu.swift` (new), `Sources/App/WorktreeCommands.swift`,
`Sources/App/ContentView.swift`

**Depends on:** T2.

**What it does.** Adds the `@MainActor` helper that ⌥⌘R calls, adds
`popRunMenu: () -> Void` to `WorktreeRunActions`, and fills it at `ContentView`'s construction site.

```swift
@MainActor
enum ToolbarSplitButtonMenu {
    static func popUp(labelled label: String) { … }
}
```

- Start at `NSApp.keyWindow?.contentView` and walk `subviews` recursively, depth first.
- Match the first `NSSegmentedControl` whose `labelForSegment(0) == label`
  (`NSSegmentedControl.h:77`). The caller passes `SavedCommandManager.runButtonTitle`, which is the
  primary command's name. That is what rules out `CommandsView`'s filter picker and the Open In
  split button (D3).
- Read `menuForSegment(1)` (`NSSegmentedControl.h:80`). If it is nil, return.
- `menu.popUpMenuPositioningItem(nil, at: NSPoint(x: 0, y: control.bounds.maxY), in: control)`,
  adjusted for the control's `isFlipped` so the menu hangs below the button rather than over it.
  `NSMenu.h:74-78` documents that with a nil item the menu's top-left (or top-right in RTL) content
  corner lands at the given location in the view's coordinates; it returns `false` when tracking was
  cancelled, which is the Escape case and needs no handling.
- **If no control matches, do nothing.** No fallback to another control, no fallback to a different
  behaviour, no alert (D2 and the spec's Risks section).

Concurrency: the helper is a plain `@MainActor` enum with plain Swift function types. It forms **no**
`@convention(c)` and **no** `@convention(block)` closure and installs no `DispatchSource`, so the
trap documented in `CLAUDE.md`'s Concurrency section does not apply and no `nonisolated static`
factory is needed here.

Then set `WorktreeRunActions.popRunMenu` at `ContentView`'s construction site to
`{ ToolbarSplitButtonMenu.popUp(labelled: savedCommandManager.runButtonTitle) }`.

**Acceptance criteria.**
1. `ToolbarSplitButtonMenu.popUp(labelled:)` exists, is `@MainActor`, searches the key window's view
   tree recursively and matches on segment 0's label.
2. Given no matching control, it returns having done nothing — no alert, no other control popped,
   no `assertionFailure`.
3. It reads `menuForSegment(1)` and pops it with `popUpMenuPositioningItem(_:at:in:)`; nothing else
   in the tree calls either API.
4. `WorktreeRunActions.popRunMenu` calls it with `savedCommandManager.runButtonTitle`.
5. No `@convention(c)` or `@convention(block)` literal is introduced.

**Verification.** `./scripts/ci.sh` green — this is compile-and-lint coverage only. The helper needs
a live realized toolbar, so it is unreachable from XCTest for the same reason
`AppKeyboardShortcutsTests` records for `performKeyEquivalent`; **write no test that fakes a view
tree for it**. Criteria 1-5 are read off the source. Popping the real dropdown is the operator's
hand-check (spec criterion 3).

### T4: Open the command editor from the menu bar

**Files:** `Sources/App/AppNotifications.swift`, `Sources/App/RunCommandMenu.swift`

**Depends on:** T2.

**What it does.** Adds `static let clearwayAddCommand = Notification.Name("clearway.addCommand")`
beside `clearwayNewGroup` (`AppNotifications.swift:4`), and has `RunCommandMenu` observe it:

```swift
.onReceive(NotificationCenter.default.publisher(for: .clearwayAddCommand)) { note in
    guard note.object as? SavedCommandManager === savedCommandManager else { return }
    showCommandEditor = true
}
```

The identity guard is the point of the `object` — without it every mounted `RunCommandMenu` in
every open project window presents the sheet, which is the bug `NewGroupCommand` scopes around
(`ClearwayApp.swift:411`, `SidebarView.swift:175`). Put the `.onReceive` on `RunCommandMenu.body`
beside the existing `.sheet`, **outside** the `.disabled(ghosttyApp.app == nil)` so the editor's
own controls never inherit a disabled environment.

`RunCommandMenu`'s existing "Add Command…" button keeps setting `showCommandEditor` directly. The
menu-bar row posting the notification is T5's work.

**Acceptance criteria.**
1. `.clearwayAddCommand` exists in `AppNotifications.swift`.
2. `RunCommandMenu` sets `showCommandEditor` on receiving it, and only when the notification's
   `object` is identically its own `savedCommandManager`.
3. The `.onReceive` sits outside the `.disabled(…)`, beside the `.sheet`.
4. Nothing else presents `CommandEditorSheet(command: nil)` as a result of this change —
   `ContentView` gains no sheet.

**Verification.** `./scripts/ci.sh` green. Criteria 1-4 by reading `RunCommandMenu.body` and
`grep -rn "CommandEditorSheet" Sources/App/`.

### T5: The Worktree menu

**Files:** `Sources/App/WorktreeCommands.swift`, `Sources/App/ClearwayApp.swift`

**Depends on:** T2, T3, T4.

**What it does.** Adds the five menu-item views to `WorktreeCommands.swift` and one
`CommandMenu("Worktree")` to `ClearwayApp.body`'s `.commands` block, after the
`CommandGroup(replacing: .sidebar)` so SwiftUI places it after View (D13).

Each item reads its focused value with `@FocusedValue`, the way `PanelToggleMenuItem` and
`NewTabMenuItem` do, and is `.disabled` when that value is `nil`:

| Row | Title | Key | Action | Disabled when |
| --- | --- | --- | --- | --- |
| 1 | `run?.title` (i.e. `runButtonTitle`, "Run" on an empty list) | ⌘R | `run.primary.map(run.run)` | `run == nil` **or** `run.primary == nil` |
| 2 | "Run…" | ⌥⌘R | `run?.popRunMenu()` | `run == nil` |
| 3 | "Run" submenu | none | see below | `run == nil` |
| 4 | `openIn?.title` (i.e. `openInButtonTitle`) | ⌘O | `openIn.primary.map(openIn.open)` | `openIn == nil` |
| 5 | "Open in" submenu | none | see below | `openIn == nil` |

Row 3's submenu lists **every** saved command in display order — not `menuCommands`, which omits
the primary; the menu bar has no label half, so the full list is what a reader expects — then a
`Divider()`, then "Add Command…" which posts `.clearwayAddCommand` with the focused
`SavedCommandManager` as `object`. Choosing a command calls `run.run(command)`, which records it as
the primary, so rows 1 and the toolbar retitle (spec criterion 6, 8). The `Divider()` is
conditional on a non-empty list, the way `RunCommandMenu.items` guards it — AppKit renders a menu
whose only content is a separator as a stray line.

Row 5's submenu lists every app in `settings.openInApps` in display order, a `Divider()`, then
"Edit Apps…", which uses the same `SettingsLink` under `#available(macOS 14, *)` /
`NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)` pair as
`OpenInMenu.editAppsButton` (`OpenInMenu.swift:72-80`). Because row 5 is disabled on an empty app
list (D10), that door is unreachable from here in that state — deliberate; Settings is reachable
from the app menu.

Because each struct is rebuilt every time `ContentView.body` re-evaluates, and `ContentView`
observes both `SavedCommandManager` and `SettingsManager`, an add/remove/reorder/rename in either
list reaches the menu with no relaunch and no `.id` key (spec criterion 9). The `.id` workaround
applies only to a realized toolbar `NSSegmentedControl`; a `CommandMenu` is rebuilt by SwiftUI.

**No `.keyboardShortcut` is added to `RunCommandMenu`, `OpenInMenu` or any toolbar item** (D1), and
⌥⌘O is not declared (D16).

**Acceptance criteria.**
1. A "Worktree" menu exists in `ClearwayApp.commands` with exactly the five rows above, in that
   order.
2. ⌘R is on row 1, ⌥⌘R on row 2, ⌘O on row 4, and each appears in the tree exactly once
   (`grep -rn 'keyboardShortcut("r"\|keyboardShortcut("o"' Sources/App/` returns three lines, all in
   `WorktreeCommands.swift`).
3. Rows 1, 2 and 3 are disabled when `worktreeRunActions == nil`; rows 4 and 5 when
   `worktreeOpenInActions == nil`. Row 1 is additionally disabled on an empty command list while
   rows 2 and 3 stay enabled (D9).
4. Row 3's submenu lists every saved command, then a divider, then "Add Command…"; row 5's lists
   every Open In app, then a divider, then "Edit Apps…".
5. Row 3's "Add Command…" posts `.clearwayAddCommand` with the focused `SavedCommandManager` as
   `object`.
6. `ContentView` and the toolbar views declare no keyboard shortcut.

**Verification.** `./scripts/ci.sh` green. Criteria 1-6 are read off `WorktreeCommands.swift`,
`ClearwayApp.swift` and the greps named. Menu rendering, the grey-out states and the titles
tracking the primary are the operator's hand-checks (spec criteria 1-5, 8, 10, 11) — `CommandMenu`
and `@FocusedValue` need a running app and are unreachable from XCTest.

### T6: Claim ⌘R, ⌥⌘R and ⌘O from focused terminal surfaces

**Files:** `Sources/App/AppKeyboardShortcuts.swift`, `Tests/AppKeyboardShortcutsTests.swift`

**Depends on:** T5.

**What it does.** Adds the three letters to `claims` (`AppKeyboardShortcuts.swift:42-57`):

- `case [.command]:` gains `|| letter == "r" || letter == "o"` — run primary command, open in
  primary app.
- `case [.command, .option]:` gains `|| letter == "r"` — pop the Run dropdown.

Update the two existing trailing comments so each clause still names every key it claims.
`[.command, .shift]` is **not** touched: ⇧⌘R is not claimed.

In `Tests/AppKeyboardShortcutsTests.swift`, using the existing `claims(_:_:_:)` helper, add a
section pinning both directions (spec criterion 12):

- claimed: `claims([.command], "r")`, `claims([.command], "o")`,
  `claims([.command, .option], "r")`
- not claimed: `claims([.command, .option], "o")` (⌥⌘O — D16),
  `claims([.command, .control], "r")` (⌃⌘R), `claims([.command, .shift], "r")` (⇧⌘R)

Follow the file's existing naming (`testCommandJIsClaimed`,
`testCommandJWithExtraModifiersIsNotClaimed`) and give each negative assertion a message naming why
the combo is declined, as `testCommandShiftBracketsAreClaimed` does.

**Acceptance criteria.**
1. `claims` returns true for ⌘R, ⌘O and ⌥⌘R, and false for ⌥⌘O, ⌃⌘R and ⇧⌘R.
2. The new tests fail against the pre-change `claims` — run them before editing
   `AppKeyboardShortcuts.swift` and record the failure.
3. The clause comments name every key their clause claims.
4. No other clause of `claims` changes.

**Verification.** `./scripts/ci.sh` green, which runs `AppKeyboardShortcutsTests`. Criterion 2 is
the red step: write the tests first, run `./scripts/ci.sh`, watch the six assertions fail, then add
the claims and re-run. Criterion 4 by diffing `AppKeyboardShortcuts.swift`.

### T7: Rewrite the per-file notes this change falsifies

**Files:** `Sources/App/CLAUDE.md`

**Depends on:** T6.

**What it does.** Three statements in `Sources/App/CLAUDE.md` become false with T5 and T6, and one
new mechanism has no note at all.

1. **`OpenInMenu` / `RunCommandMenu` entry, line 563** — "The menu claims **no** keyboard shortcut,
   so `AppKeyboardShortcuts` has no entry for it." Now false for both. Replace with: the two actions
   carry ⌘R and ⌘O, declared **only** on the Worktree menu's rows in `WorktreeCommands.swift`, never
   on the toolbar buttons, and all three keys have `AppKeyboardShortcuts` entries.
2. **`AppKeyboardShortcuts.swift` entry, lines 3-15** — the list of declaration sites (`ContentView`'s
   hidden buttons and `NSEvent` monitor, `ClearwayApp`'s menu commands, the tab strip's `+` menu
   rows) must gain `WorktreeCommands.swift`.
3. **`PanelCommands.swift` entry, lines 16-22** — the "declared **only** on its menu item, a hidden
   button would win" rule now governs three more keys. Say so, or generalise the rule out of the
   `PanelCommands` entry so the Worktree menu is covered by name.
4. **New note** for `ToolbarSplitButtonMenu.swift`: why ⌥⌘R reaches into AppKit at all (a SwiftUI
   submenu row has no action closure for key-equivalent dispatch to fire — the no-body rule already
   recorded in the Plan/sidebar submenu entry), how the control is found (segment-0 label equals
   `runButtonTitle`, which is what distinguishes it from `CommandsView`'s filter picker and the
   Open In split button), that it does nothing when no control matches, and that it is fragile
   because it depends on SwiftUI continuing to realize a toolbar `Menu` with `primaryAction:` as an
   `NSSegmentedControl` — accepted by the operator over a fallback behaviour.
5. **New note** for the Worktree menu itself: the five rows, why there are five and not four, the
   two focused scene values and what nils each, and `.clearwayAddCommand`'s identity guard.

Write these into the existing entries rather than appending a new section; keep the file's voice.

**Acceptance criteria.**
1. `grep -n "claims \*\*no\*\* keyboard shortcut" Sources/App/CLAUDE.md` returns nothing.
2. The `AppKeyboardShortcuts` entry names `WorktreeCommands.swift` as a declaration site.
3. There is a note covering `ToolbarSplitButtonMenu.swift` and one covering the Worktree menu,
   each stating what the code actually does at the end of T6.
4. No statement in the file contradicts the tree — in particular, nothing still says Run or Open In
   claim no key.

**Verification.** `./scripts/ci.sh` green (SwiftLint does not read Markdown, but the gate must stay
green through the commit). Criteria 1-4 by reading the file against the diff of T1-T6.

## Operator hand-check

The suite reaches none of the UI. After T7, ask the operator to confirm, in a project window with a
worktree selected and at least one saved command and one Open In app:

1. ⌘R runs the primary command in the worktree's main terminal and the Run button retitles.
2. ⌘R does the same with focus inside a terminal surface; the shell never sees it.
3. ⌥⌘R pops the toolbar Run dropdown; Escape closes it; a row runs that command.
4. ⌘O opens the worktree in the primary app, from a terminal too, with the same failure alert.
5. The Worktree menu shows the five rows in order with the right glyphs.
6. All five grey out with no worktree selected, on Tasks/Commands/Prompts, and on a standalone
   Task/Prompt/Settings window; "Run \<name>" greys on an empty command list while "Run…" and the
   Run submenu stay live; both Open In rows grey on an empty app list.
7. Editing either list in Settings or the Commands view is reflected in the menu without relaunch.

## Risks

| Risk | Impact | Mitigation |
| --- | --- | --- |
| SwiftUI stops realizing the toolbar split button as an `NSSegmentedControl`, or the label is not readable from it | ⌥⌘R silently does nothing | T3 does nothing rather than guessing at another control; the note added in T7 records the dependency so the next reader knows where to look. Operator accepted this over a fallback (D2). |
| `ContentView.swift` grows past 1000 lines again | `file_length` **error**, CI red | T1 lands first and the plan adds only two `.focusedSceneValue` lines and one `@EnvironmentObject` to that file. |
| ⌘R / ⌘O claimed before a handler exists | The key is taken from the shell and dropped | T6 is ordered after T5. |
| The `.clearwayAddCommand` post reaches every open window's `RunCommandMenu` | Two sheets | Identity guard on the notification's `object`, the `NewGroupCommand` precedent (T4 criterion 2). |

## Build log

### T1: Extract the side panel tab strip out of ContentView

| File | State |
| --- | --- |
| `Sources/App/SidePanelTabStrip.swift` | New. `struct SidePanelTabStrip: View` with `@Binding var selection: SidePanelTab`, `let tabs: [SidePanelTab]`, `let effectiveTab: SidePanelTab`, plus the private `@available(macOS 26.0, *) tabButton(for:)`. |
| `Sources/App/ContentView.swift` | 1011 → 956 lines. `sidePanelTabStrip` and `sidePanelTabButton(for:)` deleted with their `// MARK:`; the aside `VStack` now builds `SidePanelTabStrip(selection: $sidePanelTab, tabs: availableSidePanelTabs, effectiveTab: effectiveSidePanelTab)`. `effectiveSidePanelTab` and `availableSidePanelTabs` stay, still read by the `switch` below the strip. Both SwiftLint disables kept (D15). |
| `Clearway.xcodeproj/project.pbxproj` | Regenerated by `xcodegen` inside `ci.sh`: three lines registering the new file. |

Evidence. This task moves code and adds no behaviour, so there is no regression test to watch fail;
the bar is that the rendering is identical. Verified by diffing the moved bodies against
`git show HEAD:Sources/App/ContentView.swift | sed -n '954,1010p'` — the only differences are the
declaration line (`@ViewBuilder private var sidePanelTabStrip` → `var body`, which `View` supplies
the builder for) and the four renames forced by the move: `availableSidePanelTabs` → `tabs`,
`$sidePanelTab` → `$selection`, `sidePanelTab = tab` → `selection = tab`,
`effectiveSidePanelTab` → `effectiveTab`, `sidePanelTabButton(for:)` → `tabButton(for:)`. Both
`@available(macOS 26.0, *)` branches, the `glassEffect` capsule and its stroke, the accessibility
element and label, every padding value, the `.pickerStyle(.segmented)` fallback and its trailing
`Divider()` are byte-identical.

Acceptance criteria. 1: `grep -n "sidePanelTabStrip\|sidePanelTabButton" Sources/App/ContentView.swift`
returns nothing; the one hit for `SidePanelTabStrip` is the call at line 891. 2: `wc -l` is 956,
under 1000. 3: `swiftlint lint --quiet` prints nothing and exits 0, against a pre-change baseline
that also printed nothing — zero errors, no new warnings. 4: the diff above.

Deviations from the plan: none.

Gate: `./scripts/ci.sh` — passed. 783 tests, 0 failures; SwiftLint clean; `==> CI passed.`
