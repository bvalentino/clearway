# Close the task terminal when a task is deleted from the standalone task window

**Date:** 2026-09-22
**Base:** 66145eb (Release v2.0.0)

Deleting a task from its standalone window (`WorkTaskWindow`) removes the task file but leaves its
task terminal running. The two Delete doors in the project window's backlog (`WorkTaskListView`)
both call `TerminalManager.closeTaskTerminal` first, and both ask a stronger question when a process
is still running in that terminal. The standalone door does neither, so a task deleted there while
an agent runs in its bottom terminal leaves a live surface under `.task(id)` with no row to show it
and no control to close it. This is the stranded-agent state that Decisions 19 and 22 of the
PR #257 spec exist to prevent. This change routes the standalone door through the same close and
the same running-process confirmation, so all three Delete doors behave alike.

## Decisions

| # | Question | Answer | Source |
| --- | --- | --- | --- |
| 1 | Should the standalone Delete close the task's terminal? | Yes. It closes it before deleting the file, in the same order as the list's doors (`WorkTaskListView.swift:156-157`, `:174-175`). | Task brief |
| 2 | Should it match the list's "processes still running" confirmation? | Yes. When the task's terminal has a running foreground process, Delete shows a `confirmationDialog` titled `Delete "<title>"?` with the message "There are processes still running in this task's terminal." and one destructive Delete button. Otherwise it shows the existing alert, "This action cannot be undone." This is the same pair of prompts the list shows (`WorkTaskListView.swift:150-181`). | Task brief |
| 3 | How does the standalone window reach the terminal, given that it owns no `TerminalManager`? | Through two new `static` members on `TerminalManager`, keyed only on the task id, that fan out over `TerminalManager.allInstances`: one asks whether any manager's terminal for that task has a running process, the other closes that task's terminal in every manager. This is the same shape as the existing `needsConfirmQuit` and `closeAllManagers` (`TerminalManager.swift:558-567`). Task ids are UUIDs, so only the manager that owns the task has an entry, and the others do nothing. | Spec |
| 4 | Why not post a notification that the project window handles? | A notification cannot answer the running-process question synchronously, and the confirmation needs that answer before it can choose which prompt to show. It would also add an observer to `ProjectWindow` for a job that a direct static call already does. Rejected. | Spec |
| 5 | Why not look up the project's `TerminalManager` by project path and inject it? | `TerminalManager` does not know its project path (`ProjectWindow.swift:132` builds it with `TerminalManager()`), so this would add a path field and a registry only to find the manager that the task id already selects. Rejected. | Spec |
| 6 | When is the running-process check read? | When the operator clicks "Delete Task" in the window's ellipsis menu, as `confirmDeleteTask` does in the list (`WorkTaskListView.swift:314-320`). A process that starts or exits while a prompt is open does not switch the prompt. Both prompts close the terminal on Delete, so the outcome is the same either way. | Spec |
| 7 | Does the project window's task list need to see the delete immediately? | No. The standalone window owns its own `WorkTaskManager` (`WorkTaskWindow.swift:47-56`), so the project window sees the delete through its file watcher, about 0.3s later. That is acceptable because the close is keyed on the task id, not on either manager's task pool. | Task brief |
| 8 | Does the list's own delete path change? | No. It keeps calling its injected `terminalManager` instance. Only the standalone window, which has no instance to call, uses the static fan-out. | Spec |

## Assumptions

Each assumption below was checked against the code at `66145eb`.

- The standalone Delete currently deletes without closing the terminal: `WorkTaskWindow.swift:125-131` calls only `workTaskManager.deleteTask(task)`, then closes the key window.
- The standalone window has no `TerminalManager` in its environment: `ClearwayApp.swift:258-263` builds `WorkTaskWindow(identifier:)` with only `.clearwayChrome(settings)`, and `WorkTaskWindow` declares no `terminalManager` property (`WorkTaskWindow.swift:25-41`). `TerminalManager` is created per project window (`ProjectWindow.swift:132`) and injected at `ProjectWindow.swift:155`.
- Every `TerminalManager` registers itself in the weak `allInstances` table at `init` (`TerminalManager.swift:12`, `:79`), so a static fan-out reaches every open project window.
- `closeTaskTerminal` removes the task's bookkeeping even when it has no surface, and it retires and closes the surface when there is one (`TerminalManager+TaskTerminals.swift:57-65`). Calling it on a manager that does not own the task does nothing.
- `taskHasActiveProcess` reads `needsConfirmQuit` on the task's surface and returns `false` when there is none (`TerminalManager+TaskTerminals.swift:11-13`).
- The standalone Delete is only offered for tasks with no worktree (`WorkTaskWindow.swift:98`), which are the tasks whose terminal lives under `.task(id)`.
- `WorkTaskManager.deleteTask` removes the file and reloads only its own pool (`WorkTaskManager.swift:258-261`). `Sources/App/CLAUDE.md:206-209` already records that the standalone door reaches the project window only through the watcher.

No empirical probes were run for this spec.

## Objective and success criteria

Deleting a task from the standalone window closes its task terminal in whichever project window
holds it, and confirms first in the same way the backlog does.

1. After Delete in the standalone window, no `TerminalManager` has an entry for the task id in
   `taskSurfaces`, `openTaskIds`, `taskTerminalVisible` or `taskTerminalHeights`, and any surface it
   had is retired and closed.
2. When the task's terminal has a running foreground process, the standalone Delete shows the
   "There are processes still running in this task's terminal." dialog, not the "cannot be undone"
   alert.
3. When it has none, or has no terminal at all, the standalone Delete shows the existing alert
   unchanged.
4. Cancelling either prompt leaves the task and its terminal untouched.
5. A unit test in `Tests/TerminalManagerTests.swift` shows that the static close clears a task's
   bookkeeping in every live manager and leaves other task ids alone. The SwiftUI prompt wiring
   cannot be tested with XCTest (a `Ghostty.SurfaceView` needs a `ghostty_app_t`), so the operator
   checks it by hand. Per memory, agents do not launch the app.

## Commands

From the project's `## Pipeline` section:

| Step | Command |
| --- | --- |
| Every build task, and simplify (regression check) | `./scripts/ci.sh` |
| Sign-off, once (full gate) | `./scripts/ci.sh` |

Before sign-off, run `git status --porcelain` and report any untracked or ignored files.

## Files touched

- `Sources/App/TerminalManager+TaskTerminals.swift`: two `static` members that fan out over
  `allInstances` (the running-process query and the close).
- `Sources/App/WorkTaskWindow.swift`: the Delete menu item chooses between the alert and the new
  running-process `confirmationDialog`, and both Delete buttons close the terminal before deleting.
- `Tests/TerminalManagerTests.swift`: a test of the static close across two managers.
- `Sources/App/CLAUDE.md`: update the note at `:206-209` if its wording about the standalone door
  no longer holds.

## Boundaries

- Always: close before `deleteTask`, as the list does. Reuse the list's exact prompt titles and
  message text.
- Ask first: any change to the list's delete path, or to `closeTaskTerminal` itself.
- Never: add a notification, observer or project-path registry for this. Never change the
  standalone window's `WorkTaskManager` ownership.

## Out of scope

- The watcher lag described in Decision 7. A task-terminal launch that is already awaiting PATH in
  the project window (PR #257 Decision 22) re-reads that window's own pool, which learns about a
  standalone delete only about 0.3s later through the watcher. A launch that resumes inside that
  window could still mint a surface after the close. This change does not make the project
  window's pool reload synchronously.
- Extracting a shared delete-confirmation component for the list and the window. The two views
  hold their prompt state differently: the list tracks a selected or pending task, while the window
  has exactly one task.
- The window-close call `NSApplication.shared.keyWindow?.close()` after Delete, which is
  pre-existing and unchanged.
