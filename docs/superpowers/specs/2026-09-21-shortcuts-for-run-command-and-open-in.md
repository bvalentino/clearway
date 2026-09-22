# Shortcuts for Run command and Open In

**Date:** 2026-09-21
**Base:** 8d032a4 (Require pipeline load generators to bound their own lifetime (#251))

The worktree toolbar's Run and Open In split buttons are reachable only by mouse and appear nowhere
in the menu bar. This change adds a top-level **Worktree** menu carrying both actions, gives the
primary Run command ⌘R and the primary Open In app ⌘O, and gives ⌥⌘R and ⌥⌘O doors onto those
buttons' dropdowns so a non-primary command or app can be picked without the mouse. All four keys
are claimed from focused terminal surfaces the way the app's other shortcuts are.

## Decisions

| # | Question | Decision | Why |
| --- | --- | --- | --- |
| D1 | Where is each key declared? | On its Worktree-menu item only. No hidden `.keyboardShortcut` button, no glyph on the toolbar buttons. | Operator constraint, and the `PanelCommands` rule: a hidden button declares the key a second time in a layer that silently wins (`Sources/App/CLAUDE.md`, PanelCommands entry). |
| D2 | What does ⌥⌘R do? | Pops the **toolbar** Run split button's live `NSMenu`, via AppKit. | Operator constraint: "falling back to a different behaviour is not acceptable". |
| D3 | How is that dropdown popped? | Recursive search of the key window's view tree for the realized `NSSegmentedControl` whose segment 0 label equals `SavedCommandManager.runButtonTitle`, then `menuForSegment(1)` → `popUp(positioning: nil, at: <control bottom-left>, in: control)`. | The only handles AppKit exposes; see A6/A7. Matching on the label rules out the other segmented controls in the window (`CommandsView`'s `.pickerStyle(.segmented)` filter, and the Open In split button). |
| D4 | Which item carries ⌥⌘R? | A **fifth** item, "Run…", directly below "Run <name>" and above the Run submenu. **Accepted by the operator, 2026-09-21.** | The task's four-item shape has no home for it: a SwiftUI `Menu` used as a submenu row exposes no action closure that AppKit's key-equivalent dispatch could fire (A5). Flagged to the operator, who accepted the extra row rather than a different ⌥⌘R behaviour. |
| D5 | Is ⌘R / ⌥⌘R / ⌘O claimed conditionally on the item being enabled? | No — claimed unconditionally in `AppKeyboardShortcuts.claims`, like ⌘T and ⌘J. | `claims` is a pure static table with no window state (`Sources/App/AppKeyboardShortcuts.swift:30`); ⌘T is already claimed while New Tab is greyed. A terminal surface only has focus on the worktree destination, where all three are live, so the "claim exactly what is handled" rule is satisfied in every state a shell can see the key in. |
| D6 | How do the menu items reach per-window state? | Two focused **scene** values published by `ContentView`, `WorktreeRunActions?` and `WorktreeOpenInActions?`, each carrying its list, its primary and its closures. `nil` greys the items out. | The established gate (`PanelToggle`, `newTabAction`); `ContentView.body` re-evaluates on `SavedCommandManager` / `SettingsManager` changes, so the titles and submenus track edits with no relaunch. |
| D7 | Two focused values or one? | Two. | They gate differently: Run needs `ghostty_app_t`, Open In needs a non-empty app list. One struct would have to carry both gates and grey the wrong half. |
| D8 | What exactly nils each value? | `WorktreeRunActions` — no selected worktree, or `ghosttyApp.app == nil`. `WorktreeOpenInActions` — no selected worktree path, or `settings.openInApps.isEmpty`. | Mirrors each toolbar counterpart exactly: `RunCommandMenu` is `.disabled(ghosttyApp.app == nil)` (`RunCommandMenu.swift:23`) and the Open In toolbar item is omitted on an empty list (`ContentView.swift:202`). |
| D9 | "Run <name>" with no saved commands? | Item renders "Run" and is disabled; the Run submenu stays enabled so "Add Command…" is reachable. | Task in-scope list. Matches `RunCommandMenu`, which is a plain menu holding the door alone in that state. |
| D10 | "Open in" submenu with an empty app list? | Disabled, so "Edit Apps…" is unreachable from it. | Task states the asymmetry: only Run's submenu is called out as staying enabled. The toolbar item also disappears on an empty list, and Settings is reachable from the app menu. |
| D11 | How does the submenu's "Add Command…" open the editor sheet? | A new `Notification.Name.clearwayAddCommand` posted with the focused window's `SavedCommandManager` as `object`; `RunCommandMenu` observes it and sets its existing `showCommandEditor`. | The `NewGroupCommand` precedent (`ClearwayApp.swift`, `.clearwayNewGroup` scoped to the window's `WorktreeGroupManager`). Keeps one presenter of the sheet rather than a second one on `ContentView`. |
| D12 | Duplicate action bodies between toolbar view and menu item? | No. Each action has one implementation, shared. Run's record-then-launch and Open In's launch-then-alert move out of the two menu views into the action structs the toolbar views are handed. | `OpenInMenu.presentFailure` (`OpenInMenu.swift:102`) is private and must not be written twice; the same for `RunCommandMenu.run` (`RunCommandMenu.swift:79`), which records before the `ghosttyApp.app` guard on purpose. |
| D13 | Where does the Worktree menu sit? | One `CommandMenu("Worktree")` in `ClearwayApp.commands`, which SwiftUI places after View. | Task leaves the position to the engineer; after View and before Window reads correctly for a window-scoped noun. |
| D14 | `ContentView.swift` split | Extract `sidePanelTabStrip` + `sidePanelTabButton` (`ContentView.swift:956-1010`) into `Sources/App/SidePanelTabStrip.swift` before adding anything. | Project constraint: the file is 1011 lines against a 1000-line `file_length` **error** and survives only on the file-wide disable at line 1. The strip is the most self-contained chunk — one binding, one worktree id, the tab list. |
| D15 | Does the split retire `// swiftlint:disable file_length`? | No. Keep it. | The file lands near 980 lines, over the 700-line **warning** threshold; removing the disable would introduce a new warning, which the project forbids. `type_body_length` stays disabled for the same reason. |
| D16 | Is ⌥⌘O claimed? | No. Nothing declares it. **Superseded by D17.** | "Claim exactly what the app handles"; a claimed combo with no handler is taken from the shell and dropped. |
| D17 | Does Open In get the dropdown key too? | Yes. A **sixth** row, "Open in…" (⌥⌘O), between "Open in \<label>" and the Open in submenu, popping the toolbar's Open In dropdown through `ToolbarSplitButtonMenu.popUp(labelled:)` with `SettingsManager.openInButtonTitle`. ⌥⌘O is claimed in `AppKeyboardShortcuts`. **Operator-requested during the hands-on check, 2026-09-21.** | Run and Open In are the same control in two copies, so the keyboard reach should be the same too: ⌘O opens the primary app, ⌥⌘O picks another. The row has to be real for the same reason "Run…" does (D4, A5), and the helper already takes the label as a parameter — segment 0 of the Open In button reads "Open in Fork", confirmed in the lldb session recorded in the plan's Changelog. Enablement mirrors "Open in \<label>": `.disabled(actions == nil)`, which is already nil on an empty app list, where no toolbar button exists to pop. D16 stood only while nothing declared the key. |

## Assumptions

Each verified against the tree at `8d032a4`. No probe scripts were written into the repo; nothing
here required one.

| # | Assumption | Evidence |
| --- | --- | --- |
| A1 | Nothing in Clearway declares ⌘R, ⌥⌘R or ⌘O today, and `AppKeyboardShortcuts.claims` claims none of them. | `Sources/App/AppKeyboardShortcuts.swift:42-57` — `[.command]` matches only `t/w/j/b/n` and the comma key code; `[.command, .option]` only `b/t`. `grep` over `Sources/App` finds no `keyboardShortcut("r"` or `keyboardShortcut("o"`. |
| A2 | The app is not a document app, so SwiftUI generates no File ▸ Open on ⌘O. There is no `DocumentGroup`; the scenes are `WindowGroup`/`Settings` and `.newItem` is already replaced wholesale. | `Sources/App/ClearwayApp.swift:181-263`. |
| A3 | Menu-bar key equivalents are offered to the view hierarchy first and so need a `claims` entry, exactly as ⌘T does. | `Sources/App/AppKeyboardShortcuts.swift:6-10`; `NewTabMenuItem` declares ⌘T at `ClearwayApp.swift:301` and `claims` lists `"t"`. |
| A4 | A focused **scene** value is the app's gating mechanism for menu items, and `nil` greys the item out on a standalone Task/Prompt/Settings window. | `Sources/App/PanelCommands.swift:41-56` (`.disabled(panel == nil)`); published at `ContentView.swift:262-267`. |
| A5 | A submenu row cannot carry ⌥⌘R. AppKit's dispatch "triggers that menu item's action", and a SwiftUI `Menu` used as a submenu row has no action closure to trigger — its only action-bearing initializer is `primaryAction:`, which SwiftUI documents as firing on a click of the control's body, and a menu row has no body. | `MacOSX27.0.sdk/…/AppKit.framework/Headers/NSMenu.h:143-145`: "if the event is a key down event that matches the key equivalent of a menu item in the receiver or, recursively, any menu item in a submenu of the receiver, then this triggers that menu item's action (if the item is enabled)". The no-body rule is already recorded in `Sources/App/CLAUDE.md` (Plan/sidebar submenu entry) and restated in the task's own constraints. |
| A6 | The toolbar Run split button is realized as an `NSSegmentedControl` whose dropdown is a real `NSMenu` attached to a segment. | Recorded in `Sources/App/CLAUDE.md` (split-button note), verified against the running app during the split-button change; it is the reason `RunCommandMenu` carries `.id(savedCommandManager.menuCommands)` (`RunCommandMenu.swift:55`). |
| A7 | AppKit exposes both halves needed to pop it: reading the segment's menu and popping a menu at a point in a view. | `AppKit.framework/Headers/NSSegmentedControl.h:77,80` — `- (nullable NSString *)labelForSegment:(NSInteger)segment;` and `- (nullable NSMenu *)menuForSegment:(NSInteger)segment;`. `AppKit.framework/Headers/NSMenu.h:74-78` — `- (BOOL)popUpMenuPositioningItem:(nullable NSMenuItem *)item atLocation:(NSPoint)location inView:(nullable NSView *)view`, documented as: "If item is nil, the menu is positioned such that the top left or right of the menu content frame is at the given location… The method returns YES if menu tracking ended because an item was selected, and NO if menu tracking was cancelled for any reason." Both read from the local macOS 27.0 SDK on 2026-09-21. Escape therefore closes it and a row runs its command with no extra work. |
| A8 | `SavedCommandManager` already resolves everything the menu needs off the view: `primaryCommand`, `runButtonTitle`, `menuCommands`, `recordLastRun`. `SettingsManager` mirrors it with `primaryOpenInApp`, `openInButtonTitle`, `menuOpenInApps`, `recordOpenInUse`. | `SavedCommandManager.swift:28-39,108-112`; `SettingsManager.swift:129-151`. |
| A9 | `SavedCommandManager` is per-project and already in `ContentView`'s environment; `SettingsManager` is app-wide. | `ProjectWindow.swift:149,161` and `ClearwayApp.swift:142`. |
| A10 | A window-scoped notification posted with a manager as `object` is the app's existing way to drive a per-window sheet from the menu bar. | `Sources/App/AppNotifications.swift:4`; `NewGroupCommand` in `ClearwayApp.swift`. |
| A11 | The detail toolbar is rendered whatever `ghosttyApp.readiness` is — only `RunCommandMenu` gates on the app handle — so "Ghostty not ready" greys Run and leaves Open In live, matching D8. | `ContentView.swift:196-225` (toolbar on `detailView`), `ContentView.swift:794-807` (readiness switch inside the detail body), `RunCommandMenu.swift:23`. |
| A12 | `ContentView.swift` is at the limit: 1011 lines against `file_length` error 1000, carried by the file-wide disable. | `wc -l` = 1011; `.swiftlint.yml` `file_length: {warning: 700, error: 1000}`; `ContentView.swift:1`. |

## Objective

A worktree's saved command runs and its Open In app launches from the keyboard, and both actions are
visible in the menu bar with their keys, from a focused terminal as well as from the app chrome.

### Success criteria

The task's acceptance criteria, unchanged, plus what D4 and D17 change:

1. With a worktree selected and ≥1 saved command, ⌘R runs the primary command in that worktree's
   main terminal; the Run button's label then names it, as after a click.
2. ⌘R behaves identically with focus inside a terminal surface — the key never reaches the shell.
3. ⌥⌘R pops the toolbar Run dropdown; Escape closes it; choosing a row runs that command.
4. ⌘O opens the worktree path in the primary Open In app, including from a focused terminal, with
   the same last-used recording and the same failure alert.
5. A **Worktree** menu carries, in order: "Run <name>" (⌘R), "Run…" (⌥⌘R), a Run submenu, "Open in
   <label>" (⌘O), "Open in…" (⌥⌘O), an Open in submenu.
6. The Run submenu lists every saved command in display order, then a divider, then "Add Command…";
   choosing a command runs it and records it as primary; the door opens `CommandEditorSheet`.
7. The Open in submenu lists every app in display order, then a divider, then "Edit Apps…";
   choosing an app opens the worktree in it and records it as primary; the door opens Settings.
8. Menu titles track the primary — after running a different command or opening in a different app,
   menu and toolbar labels agree.
9. Adding, removing, reordering or renaming in either list is reflected in the menu without a
   relaunch.
10. All six items are disabled with no worktree selected, on Tasks/Commands/Prompts, and on a
    standalone Task/Prompt/Settings window. "Run <name>" is disabled on an empty command list;
    "Open in <label>", "Open in…" and the Open in submenu are disabled on an empty app list; the Run
    submenu and "Run…" stay enabled on an empty command list.
11. Pressing any of the four keys in a disabled state does nothing and does not reach the shell.
12. ⌘R, ⌥⌘R, ⌘O and ⌥⌘O are added to `AppKeyboardShortcuts` in the same change as their rows, with
    `AppKeyboardShortcutsTests` pinning the four claims and pinning ⌃⌘R and ⇧⌘R as **not** claimed.
13. `./scripts/ci.sh` passes.
14. ⌥⌘O pops the toolbar Open In dropdown; Escape closes it; choosing a row opens the worktree in
    that app. (D17; added after the hands-on check, so it follows criterion 13 rather than
    renumbering the list the plan's tasks cite.)

## Verification

Both the regression check on every build task and the full gate at sign-off are the same command,
copied from the project's `## Pipeline` section:

```
./scripts/ci.sh
```

Manual checks the suite cannot reach — criteria 1-5, 8, 11 — are the operator's, by hand. The keys'
claim table (criterion 12) is unit-tested; `performKeyEquivalent`, which consumes it, needs a live
`ghostty_app_t` and stays unreachable from XCTest, as `AppKeyboardShortcutsTests` already records.

## Files this touches

Changed:

- `Sources/App/AppKeyboardShortcuts.swift` — add `"r"` and `"o"` to the `[.command]` case, and `"r"`
  and `"o"` (D17) to `[.command, .option]`.
- `Sources/App/ClearwayApp.swift` — the new `CommandMenu("Worktree")`.
- `Sources/App/ContentView.swift` — publish the two focused scene values; remove the extracted
  tab strip; hand the toolbar views their action structs.
- `Sources/App/RunCommandMenu.swift` — take the run action rather than building it; observe
  `.clearwayAddCommand`.
- `Sources/App/OpenInMenu.swift` — the toolbar variant takes the open action; the sidebar variant is
  untouched in behaviour.
- `Sources/App/AppNotifications.swift` — `clearwayAddCommand`.
- `Sources/App/CLAUDE.md` — the `AppKeyboardShortcuts`, `PanelCommands` and Open In/Run entries all
  state that these two actions claim no key; all three need correcting, and the new AppKit reach
  needs its own note.
- `Tests/AppKeyboardShortcutsTests.swift` — the claim pins.

Added:

- `Sources/App/WorktreeCommands.swift` — the two focused-value keys, the action structs, and the
  six menu-item views.
- `Sources/App/ToolbarSplitButtonMenu.swift` — the `nonisolated`-free, `@MainActor` AppKit helper
  that finds the realized segmented control by its segment-0 label and pops its segment menu.
- `Sources/App/SidePanelTabStrip.swift` — the extraction that makes room in `ContentView`.

## Out of scope

- Moving Remove Worktree or any other toolbar action into the Worktree menu.
- Changing what Run or Open In do, how a primary is chosen, or how either list is stored.
- Shortcuts for individual saved commands or individual apps.
- The sidebar's right-click Open In submenu.
- The tab strip `+` menu and the File menu.
- Retiring `ContentView.swift`'s `file_length` / `type_body_length` disables (D15).

## Risks

- **The AppKit reach for ⌥⌘R is the fragile part.** It depends on SwiftUI continuing to realize a
  toolbar `Menu` with `primaryAction:` as an `NSSegmentedControl` (A6) and on the label text being
  readable from it (A7). Both are verifiable only against the running app; if the control is not
  found the helper must do nothing rather than guess at another control. The operator accepted this
  fragility in preference to a fallback behaviour.
- **⌘R and ⌘O are taken from every terminal program** that wanted them. Accepted by the operator,
  consistent with the app's other claimed keys.
