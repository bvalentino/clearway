Breaks down `docs/superpowers/specs/2026-09-22-close-task-terminal-on-standalone-delete.md`.

# Plan: Close the task terminal when a task is deleted from the standalone task window

**Date:** 2026-09-22
**Base:** 66145eb (Release v2.0.0)

## Architecture decisions carried from the spec

- The standalone Delete (`WorkTaskWindow`) closes the task's terminal before `deleteTask`, in the same order as the list's two doors (`WorkTaskListView.swift:156-157`, `:174-175`). (Spec D1)
- When the task's terminal has a running foreground process, Delete shows a `confirmationDialog` titled `Delete "<title>"?`, `titleVisibility: .visible`, message "There are processes still running in this task's terminal.", one destructive Delete button. Otherwise it shows the existing alert, "This action cannot be undone." Same text as the list. (Spec D2)
- The window reaches terminals through two new `static` members on `TerminalManager`, keyed only on the task id, that fan out over `TerminalManager.allInstances`, shaped like `needsConfirmQuit` / `closeAllManagers` (`TerminalManager.swift:558-567`). (Spec D3)
- No notification, observer, or project-path registry. (Spec D4, D5, Boundaries)
- The running-process check is read once, when "Delete Task" is clicked, as `confirmDeleteTask` does (`WorkTaskListView.swift:314-320`). (Spec D6)
- The standalone window keeps its own `WorkTaskManager`; the project window learns of the delete through its watcher. (Spec D7)
- The list's delete path and `closeTaskTerminal` itself are unchanged. (Spec D8, Boundaries)

## Dependency graph

```
T1 (static fan-out on TerminalManager + unit test)
 └── T2 (WorkTaskWindow Delete wiring + Sources/App/CLAUDE.md note)
```

T2 calls the members T1 adds, so T1 lands first.

## Tasks

### T1: Static task-terminal fan-out on TerminalManager

**Files:**
- `Sources/App/TerminalManager+TaskTerminals.swift`
- `Tests/TerminalManagerTests.swift`

**What it does:** Adds two `static` members to the `TerminalManager` extension in
`TerminalManager+TaskTerminals.swift`, next to the instance members they wrap:

- `static func anyTaskHasActiveProcess(_ taskId: UUID) -> Bool`: `true` when any manager in
  `allInstances.allObjects` returns `true` from `taskHasActiveProcess(taskId)`.
- `static func closeTaskTerminalInAllManagers(_ taskId: UUID)`: calls `closeTaskTerminal(taskId)`
  on every manager in `allInstances.allObjects`.

The names are a suggestion; any name that reads as the all-managers counterpart of the instance
member is fine. Keep the doc comments to one line each, or drop them if the name says it.

Adds tests to `Tests/TerminalManagerTests.swift`:

- Two live `TerminalManager`s. Seed bookkeeping for task A in the first manager and for task B in
  the second (`openTaskIds`, `taskTerminalVisible`, `taskTerminalHeights` are writable from tests,
  as `Tests/WorkTaskCoordinatorTests.swift:186` does). Call the static close for A. Assert A has no
  entry in any of the three collections (nor in `taskSurfaces`) of either manager, and B's entries
  in the second manager are intact. Then call it for B and assert the second manager's B entries
  are gone. This proves the fan-out reaches a manager other than the first.
- The static running-process query returns `false` for a task id with no surface in any manager
  (the `true` path needs a `Ghostty.SurfaceView`, which needs a `ghostty_app_t`; it is covered by
  the operator's manual check in T2).

Hold both managers in local constants for the whole test so the weak `allInstances` table keeps
them.

**Acceptance criteria:**
- Both static members exist and delegate to the existing instance members; `closeTaskTerminal` and
  `taskHasActiveProcess` are unchanged.
- The new tests pass and fail if the static close only reaches one manager.
- `./scripts/ci.sh` exits 0.

**Verification:** Run `./scripts/ci.sh` and report its exit status. Confirm the new test methods
appear as passed in its output.

### T2: Standalone Delete closes the terminal and confirms on a running process

**Files:**
- `Sources/App/WorkTaskWindow.swift`
- `Sources/App/CLAUDE.md`

**What it does:** In `WorkTaskWindow`:

- Add `@State private var showForceDeleteConfirmation = false`.
- The "Delete Task" menu button (`WorkTaskWindow.swift:98-104`) reads
  `TerminalManager.anyTaskHasActiveProcess(taskId)` (T1's name) at click time and sets
  `showForceDeleteConfirmation = true` when it is `true`, else `showDeleteConfirmation = true`.
- Extract one private `deleteTask()` used by both prompts. It runs, in order:
  `deleted = true`; if `task` exists, `TerminalManager.closeTaskTerminalInAllManagers(task.id)` then
  `workTaskManager.deleteTask(task)`; then the existing
  `DispatchQueue.main.async { NSApplication.shared.keyWindow?.close() }` unchanged.
- The existing `.alert` (`:120-134`) keeps its title, Cancel button, and message; its Delete button
  calls `deleteTask()`.
- Add a `.confirmationDialog("Delete \"\(title)\"?", isPresented: $showForceDeleteConfirmation,
  titleVisibility: .visible)` with one `Button("Delete", role: .destructive)` calling `deleteTask()`,
  and message `Text("There are processes still running in this task's terminal.")`. Text matches
  `WorkTaskListView.swift:163-181` exactly. The dialog's system Cancel dismisses without side effects.

In `Sources/App/CLAUDE.md:206-209`: the sentence ending "so the standalone task window's door
still reaches the project window behind that watcher" stays true for the task pool. Add, in one
clause, that the standalone door closes the task terminal directly through
`TerminalManager`'s static fan-out over `allInstances`, so only the pool, not the terminal, waits on
the watcher. Do not rewrite the surrounding paragraph.

**Acceptance criteria:**
- Both Delete buttons in `WorkTaskWindow` close the task terminal before `deleteTask`.
- With a running process, the window shows the confirmation dialog, not the alert; without one it
  shows the alert unchanged (spec success criteria 2 and 3).
- Cancelling either prompt calls neither the close nor `deleteTask` (spec criterion 4).
- `WorkTaskListView.swift` is not modified.
- `./scripts/ci.sh` exits 0, including SwiftLint with no new warnings.

**Verification:** Run `./scripts/ci.sh` and report its exit status. Read the diff of
`WorkTaskWindow.swift` against the acceptance criteria. Agents do not launch the app (memory); leave
this manual check for the operator: open a standalone task window for a backlog task with no
worktree, start a long-running process in that task's terminal in the project window, choose
Delete Task, confirm the "processes still running" dialog appears, Delete, and confirm the terminal
closes and the row disappears. Repeat with no process and see the "cannot be undone" alert.

## Risks

| Risk | Impact | Mitigation |
| --- | --- | --- |
| A test's manager is released early and drops out of the weak `allInstances` table, so the fan-out test passes vacuously | Med | T1 holds both managers in locals and asserts the seeded entries exist before the close |
| Other tests leave live managers in `allInstances` | Low | Task ids are fresh UUIDs, so stray managers have no entry and are unaffected |
| A launch awaiting PATH in the project window mints a surface after the close (spec Out of scope) | Low | Accepted by the spec; not addressed here |

## Open questions

None.

## Build log

### T1: Static task-terminal fan-out on TerminalManager

| File | State |
| --- | --- |
| `Sources/App/TerminalManager+TaskTerminals.swift` | Adds `static func anyTaskHasActiveProcess(_:)` (next to `taskHasActiveProcess`) and `static func closeTaskTerminalInAllManagers(_:)` (next to `closeTaskTerminal`), both over `allInstances.allObjects`. The instance members are unchanged. |
| `Tests/TerminalManagerTests.swift` | Adds `test_closeTaskTerminalInAllManagers_clearsTheTaskInEveryManager` and `test_anyTaskHasActiveProcess_isFalseWithoutASurface`, plus two private helpers that seed and check task bookkeeping. |

**Watched failure.** With `closeTaskTerminalInAllManagers` temporarily written as
`allInstances.allObjects.first?.closeTaskTerminal(taskId)` (reaches one manager only), running
`xcodebuild ... test -only-testing:ClearwayTests/TerminalManagerTests` failed:

```
TerminalManagerTests.swift:577: error: -[ClearwayTests.TerminalManagerTests test_closeTaskTerminalInAllManagers_clearsTheTaskInEveryManager] : XCTAssertFalse failed
TerminalManagerTests.swift:577: error: ... : XCTAssertNil failed: "true"
TerminalManagerTests.swift:577: error: ... : XCTAssertNil failed: "320.0"
Executed 48 tests, with 3 failures (0 unexpected)
** TEST FAILED **
```

Line 577 is the `assertNoTaskTerminal(taskA, in:)` loop over both managers. Restoring the `for`
loop over every manager turned it green.

**Deviations.** No doc comments on the two static members; the names say what they do. The test
asserts the seeded entries exist before the close (plan risk row 1) through `openTaskIds` only,
which is enough to show both managers are live in `allInstances`.

**Gate.** `./scripts/ci.sh` exit 0: 842 tests, 0 failures. Both new tests listed as Passed in the
xcresult. `swiftlint lint --quiet` on the two touched files reports nothing.

### T2: Standalone Delete closes the terminal and confirms on a running process

| File | State |
| --- | --- |
| `Sources/App/WorkTaskWindow.swift` | Adds `showForceDeleteConfirmation`. "Delete Task" reads `TerminalManager.anyTaskHasActiveProcess(task.id)` at click time and raises the new `confirmationDialog` (title `Delete "<title>"?`, `titleVisibility: .visible`, message "There are processes still running in this task's terminal.", one destructive Delete) or the existing alert, which is unchanged apart from its Delete button. Both Delete buttons call a new private `deleteTask()`: `deleted = true`, then `closeTaskTerminalInAllManagers(task.id)` before `workTaskManager.deleteTask(task)`, then the existing async key-window close. Cancel on either prompt runs nothing. |
| `Sources/App/CLAUDE.md` | One clause added to the Delete note: the standalone door closes the task terminal directly through the static fan-out over `allInstances`, so only the pool waits on the watcher. |

**Watched failure.** None for this task. The change is SwiftUI prompt wiring, which XCTest cannot
reach (spec success criterion 5); the fan-out it calls is covered by T1's tests, whose failure is
quoted above. The prompt choice and the close are left to the operator's manual check.

**Deviations.** None. `WorkTaskListView.swift` is untouched.

**Gate.** `./scripts/ci.sh` exit 0: 842 tests, 0 failures, "CI passed." `swiftlint lint --quiet
Sources/App/WorkTaskWindow.swift` reports nothing.

### Simplify

Rewrapped `assertNoTaskTerminal`'s signature in `Tests/TerminalManagerTests.swift` onto one
parameter per line, matching the project's existing `file:`/`line:` default-parameter style
(`Tests/SavedCommandTests.swift:63-66`) instead of the ad hoc hanging indent it landed with. No
other simplification found; T1/T2's production and test code were already minimal.
