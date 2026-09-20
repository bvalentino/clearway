# Move the Task Terminal Toggle to the Status Bar

**Date:** 2026-09-20
**Base:** b4369a5adaf99c58d5c7dcee82041c99b37c2f60

The show/hide control for a task's bottom terminal is an icon button in the Tasks toolbar, sitting
between Copy task and the `…` menu. PR #221 made the same move for the worktree destination: the
toolbar carries *actions* on the selected thing, while a bottom terminal is a panel of the detail
pane the status bar already sits under. This change moves the control out of `WorkTaskListView`'s
toolbar and into the trailing edge of `TaskDetailView`'s path bar, and deletes the toolbar item and
the two now-unread private members behind it. Nothing about what the control does changes.

## Decisions

| # | Question | Decision | Source |
| --- | --- | --- | --- |
| 1 | Which control moves? | The `.primaryAction` `ToolbarItem` wrapping `Button(action: toggleTaskTerminal)` with the `rectangle.bottomhalf.inset.filled` icon (`WorkTaskListView.swift:119-126`). Every other item in that toolbar — `+`, Start Now, Copy task, `…`, the edit/preview Picker — stays exactly where it is. | Operator |
| 2 | Where exactly does it land? | The trailing end of `TaskDetailView.pathBar(for:)`'s `HStack`, directly after the existing `Spacer()` (`TaskDetailView.swift:195`). The path text keeps the leading edge. | Operator |
| 3 | Who owns the action after the move? | `TaskDetailView` itself. It gains one `@EnvironmentObject private var workTaskCoordinator: WorkTaskCoordinator` and calls `workTaskCoordinator.toggleTaskTerminal(taskId: taskId, app: app)` behind a `guard let app = ghosttyApp.app`. It is **not** parameterised the way `WorktreeStatusBar` takes `secondaryVisible` / `onToggleSecondary`. That view does receive its subject (`let worktree: Worktree?`, `ContentViewHelpers.swift:82`), so "it does not know what it draws" is not the reason; the reasons are that it declares only `worktreeManager` and `portMonitor` (`ContentViewHelpers.swift:86-87`) and would have to take a `TerminalManager` dependency purely to compute visibility, and that its `onToggleSecondary` is `ContentView.toggleSecondaryTerminal` (`ContentView.swift:614-616`), a `withAnimation` wrapper shared with the ⌘J path. `TaskDetailView` needs neither: it already holds `taskId` (line 15), `terminalManager` (line 12) and `ghosttyApp` (line 10), reads `terminalVisible` off them (lines 35-37), and `WorkTaskCoordinator.toggleTaskTerminal` animates nothing. Parameterising would also mean a new private method on `ContentView`, which is at 1014 lines against SwiftLint's 1000-line `file_length` error and only builds on its file-wide disable — CLAUDE.md says the next addition there needs a split first. This change adds nothing to `ContentView`. | Spec author |
| 4 | How does the toolbar item's `.disabled(selectedTask == nil \|\| ghosttyApp.readiness != .ready)` carry over? | It does not: **both** halves become structural at the new site, so the button carries no `.disabled` at all. `pathBar` is only reachable inside `body`'s `if let task` (`TaskDetailView.swift:46`, `121`), so a task always exists where the button renders; and `TaskDetailView` is constructed only inside `readinessDetailView`'s `.ready` branch (`ContentView.swift:810-811`, `934`), while `Ghostty.App.readiness` is written only in `init()` (`Ghostty.App.swift:39`, `49`, `84`), so the view cannot be on screen while readiness is anything else. The old toolbar site needed the modifier because `WorkTaskListView` renders outside that readiness switch; the new one does not. | Operator |
| 5 | Why no `readiness` gate on the button? | Decision 4 makes one unreachable. The `guard let app = ghosttyApp.app` stays inside the action, where the launch actually needs the pointer — the same split as `plan`. Had a view gate been needed it would have read `readiness`, not `ghosttyApp.app`: `readiness` is `@Published` (`Ghostty.App.swift:25`), while `app` is a plain computed property over `appHandle` with no change to publish (`Ghostty.App.swift:31`), so a view gated on it has nothing to re-evaluate against when the app comes up. That is why `WorkTaskListView`'s own controls, which do render outside the readiness switch, keep using it. | Operator |
| 6 | Disabled or omitted while readiness is not `.ready`? | Neither: the state is unreachable at the new site (decision 4), so the question does not arise there. It still governs the controls that stayed in the Tasks toolbar, which keep their existing answer. | Operator |
| 7 | Does the status-bar button focus the terminal when it reveals it? | No. It calls `toggleTaskTerminal(taskId:app:)` with `focusOnReveal` left at its `false` default (`WorkTaskCoordinator+TaskTerminal.swift:13`), the same call the toolbar button makes today. ⌘J passes `true` (`ContentView.swift:115`) because a keyboard user has no other way to land there. Identical to the worktree precedent. | Spec author |
| 8 | What does the button look like in an 11pt text bar? | `Image(systemName: "rectangle.bottomhalf.inset.filled")` at `.font(.system(size: 11))` inside a `Button` with `.buttonStyle(.plain)`, tinted `.foregroundStyle(terminalVisible ? .primary : .secondary)`. The toolbar's `.opacity(… ? 1 : 0.5)` (`WorkTaskListView.swift:122`) is dropped: it was tuned for a full-contrast toolbar glyph, and stacked on this bar's already-secondary text it would read as nearly invisible. `.primary`/`.secondary` is the bar's own idiom for a state change, matching `WorktreeStatusBar` (`ContentViewHelpers.swift:114-117`). No enlarged hit frame — the bare 11pt glyph, as in the worktree bar. | Spec author |
| 9 | Does it keep its tooltip? | Yes, verbatim: `terminalVisible ? "Hide terminal" : "Show terminal"`, hoisted into a `terminalToggleLabel` computed property so `.help()` and a new `.accessibilityLabel()` cannot drift. The accessibility label is new because the control is icon-only with no text beside it; CLAUDE.md's no-helper-text rule bans copy that restates a visible label, and there is none here. | Spec author |
| 10 | Pointing-hand cursor on hover? | Yes, `.pointerCursorOnHover()` (`ContentViewHelpers.swift:228-232`, an internal `View` extension in the same module). A plain-styled `Button` on macOS otherwise shows the arrow and looks inert, and both clickable PR states in the worktree bar already use it. | Spec author |
| 11 | Does the button need a nested `HStack` like the worktree bar's? | No. `WorktreeStatusBar` needs `HStack(spacing: 12)` because three things share its trailing edge (ports, PR status, toggle). Here the toggle is the only trailing item, so it goes straight after the `Spacer()` in the existing `HStack(spacing: 0)`, which is otherwise unchanged. | Spec author |
| 12 | Do any `ToolbarGroupBreak()`s change? | No. The two breaks are at `WorkTaskListView.swift:76` and `89`; the toggle sits mid-capsule between Copy task (91-117) and the `…` menu (128-143), so removing it leaves no dangling separator and no double separator. The toolbar becomes `+ │ Start Now │ Copy · … · Picker`. | Spec author |
| 13 | What happens to `taskTerminalOpen` and `toggleTaskTerminal()` on `WorkTaskListView`? | Both are deleted (`WorkTaskListView.swift:304-312`). The removed toolbar item is their only reader. `ghosttyApp` and `workTaskCoordinator` stay declared on that view — `startNowItems` reads `ghosttyApp.readiness` and `runPlan` reads `ghosttyApp.app` and calls `workTaskCoordinator.planTask`. | Spec author |
| 14 | Does the standalone Task window's path bar get the same button? | No. `WorkTaskWindow` has its own `pathBar` (`WorkTaskWindow.swift:241`, `247`) and hosts no task terminal at all, which is why all three panel toggles already grey out on that window per CLAUDE.md. | Spec author |
| 15 | Does ⌘J, `PanelToggle`, `PanelCommands` or `AppKeyboardShortcuts` change? | No. `bottomPanel`'s `.taskTerminal` case (`ContentView.swift:112-116`) is untouched, ⌘J stays declared only on its menu item, and the button declares no key equivalent in either its old or its new home, so the `claims` table and its pins are unchanged. | Spec author |
| 16 | Does this add a test? | No. The change is view-only and introduces no decision rule. The visibility read (`terminalManager.isTaskTerminalVisible`) and the launch choice behind the toggle are already pinned by `Tests/TaskTerminalLaunchCommandTests.swift`, and `TaskDetailView` is a SwiftUI `View` with no output XCTest can inspect. There is no pure helper worth lifting out. `./scripts/ci.sh` stays the regression check; the moved control is confirmed by the operator in the running app. | Spec author |
| 17 | Are any docs stale after this? | Yes, and every one is corrected in the same change. Four sentences name the moved control by its old home — `CLAUDE.md:235` ("the copy/terminal/`…` group" becomes the copy/`…` group), `WorkTaskCoordinator+TaskTerminal.swift:10-11` and `Tests/TaskTerminalLaunchCommandTests.swift:5` (both "toolbar" become "path bar"), and `CLAUDE.md:226` with its twin at `WorkTaskListView.swift:251`, which justified the `readiness` gate as "the same reason the sibling toolbar buttons use it" — the sibling it pointed at is the button this change removes, so the reason is restated on its own terms. PR #221 touched no docs because no sentence described the toolbar it changed; these do. | Spec author |

## Assumptions

Each verified by reading the codebase at base `b4369a5`. No probe scripts or temporary files were
written, into the repo or the scratchpad.

1. **`TaskDetailView` has exactly one construction site.** `ContentView.swift:934`, in the
   `detailSelection == .tasks` branch of `detailView`, as `TaskDetailView(taskId: selectedTaskId, …)`.
   `grep -rn "TaskDetailView" Sources Tests` returns that line, the declaration
   (`TaskDetailView.swift:9`) and three comments. So the new `@EnvironmentObject` has one ancestry to
   satisfy, and the standalone window is a different type (`WorkTaskWindow`).
2. **`WorkTaskCoordinator` is in that ancestry.** `ProjectWindow.swift:113` applies
   `.environmentObject(workTaskCoordinator)` to `ContentView()` (built at line 108 from the
   `@StateObject` at line 79), and `TaskDetailView` renders inside `ContentView`'s detail column.
   `ContentView` itself already reads it as an `@EnvironmentObject` (`ContentView.swift:63`).
3. **`pathBar` never renders without a task.** `TaskDetailView.body` is `if let task { VStack { … pathBar(for: task) } }`
   (`TaskDetailView.swift:46`, `121`), so decision 4's claim that the `selectedTask == nil` half is
   structural holds.
4. **`terminalVisible` on `TaskDetailView` and `taskTerminalOpen` on `WorkTaskListView` read the
   same value.** Both call `terminalManager.isTaskTerminalVisible(_:)`
   (`TaskDetailView.swift:35-37`, `WorkTaskListView.swift:304-307`) over the `@Published`
   `taskTerminalVisible` dictionary (`TerminalManager.swift:48`), one keyed on `taskId` and one on
   `selection`. They cannot disagree in practice: `ContentView.swift:934` passes
   `taskId: selectedTaskId` — the same binding `WorkTaskListView` holds as `selection` — and pins
   identity with `.id(taskId)`. So the moved button shows the same state it showed in the toolbar.
5. **The new home is reached under a condition no narrower than the toolbar's.** The Tasks toolbar
   is declared on `WorkTaskListView`'s body, which renders whenever `detailSelection == .tasks`
   (`ContentView.swift:756-757`) — including with no task selected, which is why the item carried
   the `selectedTask == nil` half. The path bar needs a selected, still-existing task. Every state in
   which the button was *usable* (a selected task) still has a path bar, so nothing usable is lost;
   the unusable state is the one that disappears. This is the same direction as the worktree move.
6. **`pointerCursorOnHover()` is reachable.** It is an internal `extension View` method in
   `Sources/App/ContentViewHelpers.swift:228-232`, the same module and target as
   `Sources/App/TaskDetailView.swift`. Its overlay's `hitTest` returns `nil`, so the click still
   reaches the button.
7. **Nothing else reads the two members being deleted.**
   `grep -rn "taskTerminalOpen\|toggleTaskTerminal" Sources Tests` puts `taskTerminalOpen` only at
   `WorkTaskListView.swift:122`, `124` and `304`, and `WorkTaskListView.toggleTaskTerminal()` only at
   line 120 and its own declaration at 309. The unrelated `TerminalManager.toggleTaskTerminal(for:app:projectPath:)`
   and `WorkTaskCoordinator.toggleTaskTerminal(taskId:app:focusOnReveal:)` are different symbols and
   keep their callers.
8. **`toggleTaskTerminal(taskId:app:focusOnReveal:)` is callable from the new site unchanged.** It is
   a `@MainActor` method on `WorkTaskCoordinator` (`WorkTaskCoordinator+TaskTerminal.swift:13`) and
   everything here is `@MainActor` SwiftUI view code. No C or block callback is formed, so CLAUDE.md's
   `@convention(block)` trap does not apply.
9. **Both files stay well inside SwiftLint's limits and are linted.** Only `Sources/Ghostty` and
   `BuildInfo.generated.swift` are excluded (`.swiftlint.yml`). `TaskDetailView.swift` is 272 lines
   and `WorkTaskListView.swift` 384, against a 700-line `file_length` warning; `pathBar` is 28 lines
   against a 100-line `function_body_length` warning. `line_length` warns at 200 columns.
10. **No new Swift file**, so nothing new depends on `xcodegen generate` picking up a source — though
    `./scripts/ci.sh` runs it regardless.

## Objective

The Tasks toolbar carries actions on the selected task; the detail pane's panel controls belong with
the detail pane. Move the task terminal's show/hide control to the path bar's trailing edge so the
Tasks destination reads the same way the worktree destination has since PR #221, without changing
what the control does.

### Success criteria

1. With a task selected and the terminal ready, the path bar at the bottom of the task detail pane
   shows the `rectangle.bottomhalf.inset.filled` button at its trailing edge, with the file path
   still at the leading edge.
2. Clicking it shows or hides that task's bottom terminal, exactly as the toolbar button did, and
   does not move keyboard focus into the revealed terminal.
3. The button is full-contrast while the terminal is visible and dimmed while it is hidden; its
   tooltip reads "Hide terminal" or "Show terminal" to match.
4. Hovering it shows the pointing-hand cursor.
5. The button carries no readiness gate: the path bar renders only inside `readinessDetailView`'s
   `.ready` branch, so it is never on screen while the terminal is still coming up. While readiness
   is `.loading` or `.error` the detail pane shows that state instead, with no path bar.
6. Copying the path by clicking the path text, and its "Copied!" feedback, still work; clicking the
   button does not copy the path.
7. The Tasks toolbar no longer contains the button and reads `+ │ Start Now │ Copy · … · Picker`,
   with one separator between each pair and no gap where the button was.
8. View → Show/Hide Bottom Panel and its ⌘J still work on the Tasks destination, still focus the
   task terminal on reveal, and still grey out on a standalone Task/Prompt/Settings window.
9. `./scripts/ci.sh` is green and `swiftlint lint --quiet` reports zero errors for the change.

## Verification

```bash
./scripts/ci.sh
```

Regenerates the Xcode project, lints, builds and runs the test suite — the regression check for
every build task and the full gate at sign-off, per CLAUDE.md's `## Pipeline` section. Do not
hand-write an `xcodebuild` line.

The change is view-only and adds no test (decision 16), so criteria 1-8 are confirmed by the
operator in the running app (`./scripts/run.sh`), on a project with at least one backlog task. Per
memory, build agents do not launch the app or take screenshots — the operator checks by hand.

Expect the un-gitignored `default.profraw` in the repo root after any Debug launch. Run
`git status --porcelain` and report untracked files before any CI stamp or sign-off; never
`git add -A`.

## Files touched

| File | Change |
| --- | --- |
| `Sources/App/TaskDetailView.swift` | Add `@EnvironmentObject private var workTaskCoordinator: WorkTaskCoordinator`, a `terminalToggleLabel` computed property and a `toggleTerminal()` private method guarding `ghosttyApp.app`, doc-commented with why the button carries no `.disabled`; add the button after `pathBar`'s `Spacer()` with `.buttonStyle(.plain)`, `.help`, `.accessibilityLabel` and `.pointerCursorOnHover()`. |
| `Sources/App/WorkTaskListView.swift` | Delete the terminal-toggle `ToolbarItem` (lines 119-126) and the now-unread `taskTerminalOpen` and `toggleTaskTerminal()` (lines 304-312). No `ToolbarGroupBreak` changes. |
| `Sources/App/WorkTaskCoordinator+TaskTerminal.swift` | One doc-comment phrase: "the toolbar button `false`" becomes "the path bar button `false`". |
| `Tests/TaskTerminalLaunchCommandTests.swift` | One doc-comment phrase: "the toolbar toggle" becomes "the path bar toggle". No assertion changes. |
| `CLAUDE.md` | Line 235: "the copy/terminal/`…` group" becomes "the copy/`…` group". Line 226: the `readiness` gate's justification no longer points at the removed sibling toolbar button. |
| `docs/superpowers/specs/2026-09-20-move-task-terminal-toggle-to-status-bar.md` | This document. |
| `docs/superpowers/plans/2026-09-20-move-task-terminal-toggle-to-status-bar.md` | The plan, written by the next stage. |

## Out of scope

- ⌘J, `PanelToggle`, `PanelCommands` and `AppKeyboardShortcuts` (decision 15).
- Making the status-bar click focus the task terminal (decision 7).
- `WorkTaskWindow`'s path bar (decision 14), and `PromptDetailView`, which has no bottom terminal.
- Any other path-bar content — a status badge, a branch name, the live-ports row the worktree bar
  carries.
- The worktree destination's status bar and toolbar; PR #221 already settled those.
- Splitting `ContentView.swift` below SwiftLint's 1000-line error. This change neither adds to it nor
  shrinks it; the split is still owed whenever something is next added there.
