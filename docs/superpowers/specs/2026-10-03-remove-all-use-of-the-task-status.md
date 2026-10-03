# Remove all use of the task status

**Date:** 2026-10-03
**Base:** 31293f2 (Release v2.0.1)

A task's `status:` frontmatter line and the `attempt:` counter that depends on it stop meaning
anything to Clearway. The app no longer reads or writes either line. Since a task moves into its
worktree on Start, and a worktree's state lives in git config (`clearway.status`), the task's own
status line is a leftover. Today it drives three behaviors: it gates Start Now, it counts restarts
of a canceled task, and it picks the default side-panel tab. Each now uses a fact the app already
holds. Start Now is gated on the task's `worktree` link. The attempt counter and its "Attempt N"
label are deleted, since nothing in the UI can cancel a task. The side panel opens on the Task tab
when the worktree has a visible linked task. Old task files keep their lines until the app next
saves them for some other reason. This change unblocks the Clearway CLI task, which should not have
to know about a status field.

## Decisions

| # | Question | Decision | Why |
| --- | --- | --- | --- |
| D1 | What happens to `WorkTask.status`, `ReservedStatus`, `migrateStatus`? | All three are deleted. `WorkTask.init` loses its `status:` parameter. | Task brief, In scope. |
| D2 | What happens to `WorkTask.attempt`? | The field is deleted, along with the bump in `confirmCreate`, `PendingCreate.TaskLink.priorAttempt`, and its restore in `abandonPendingCreate`. | Task brief, In scope. The bump only fires for `canceled`, which nothing in the UI can set (brief, Background). |
| D3 | What happens to `WorkTaskAgentMetadata`? | `Sources/App/WorkTaskAgentMetadata.swift` is deleted, along with its three call sites in `WorkTaskWindow.swift:226-230`, `TaskDetailView.swift:77-81` and `TaskAsideView.swift:40-42`. | Its only content is the "Attempt N" label (`WorkTaskAgentMetadata.swift:7-17`). Without `attempt` it renders nothing, so an empty view would be dead code. `project.yml` globs `Sources`, so no project-file edit is needed beyond `xcodegen generate`, which `ci.sh` runs. |
| D4 | What does `parse` require? | A file needs frontmatter and a `title` key, and nothing else. A `status` or `attempt` key is ignored like any other unknown key. | Criteria 3 and 4. `YAML.parseFrontmatter` returns a plain `[String: String]` (`YAMLHelpers.swift:78`), so unknown keys need no special handling. |
| D5 | What does `frontmatterLines` write? | `id`, `title`, then `worktree` and `hidden` when set. No `status` or `attempt` line. | Criteria 1, 2 and 5. |
| D6 | How is a file stopped from being rewritten only to drop the lines? | No new code. The existing paths already write only on a real change. `updateFields` writes only when `base != before` (`WorkTaskManager.swift:192-199`), and with neither field on the model, an old line cannot make two values differ. `reload` never writes (`WorkTaskManager.swift:317-349`). Relocation is a `moveItem` plus an id-only insert (`:80-98`). The editor's save returns early when the buffer equals `existing.serialized()` (`TaskEditorBuffers.swift:115`). | Criterion 5. A test pins it (Testing). |
| D7 | How is a `status:` or `attempt:` line typed into the frontmatter editor kept out of the file? | No new code. `applyEditorBuffer` copies only `title` and `body` onto an existing task (`WorkTaskManager.swift:209-223`). The editor then resets its buffer to `updated.serialized()` (`TaskEditorBuffers.swift:124-129`), which no longer carries either line. The novel-id branch (`:225`) persists a parsed `WorkTask`, which has neither field after D1/D2. | Criterion 6. A test pins it. |
| D8 | What is the new `resolveStart` rule? | Re-read the task fresh, as today. If it has a `worktree` link: return `.reuse(wt)` when a live worktree has that branch, else `.ignored`. With no link, return `.prefill` with a branch from `deriveBranchName`. The status guard (`WorkTaskCoordinator.swift:68-69`) and the `current.worktree ??` fallback (`:78`) go. | Brief, In scope: "Replace the Start gate with the worktree link". Criterion 9 keeps `.reuse`. A linked task with no live worktree is exactly the state between `confirmCreate` and `completePendingCreate`. Today `in_progress` makes `resolveStart` ignore it, which stops a second Start Now from opening another sheet for a branch already being created. The link carries that guard now. The saved-branch prefill only existed to restart a `canceled` task on its old branch (`WorkTaskCoordinatorTests.swift:37-55`), and restarting is out of scope. Rejected: prefilling the saved branch for a linked, not-live task. That would reopen the double-create window that `in_progress` closes today. |
| D9 | Where is Start Now offered? | The Tasks list keeps its current gate, `worktree == nil` (`WorkTaskListView.swift:38-48`), so it needs no change. In the task window, `primaryActionButton` (`WorkTaskWindow.swift:286-294`) shows the button when `task` is non-nil and `task.worktree == nil`. | Criterion 7. A nil `task` must still draw no button, so the check is not `task?.worktree == nil`. |
| D10 | What is the new side-panel rule? | `resolveSidePanelTab(stored:linkedTask:current:isMain:)` takes `linkedTask: WorkTask?` in place of `taskStatus: String?`. The order is: a stored available tab wins. Otherwise, if `.task` is available and `linkedTask` is non-nil and not `hidden`, select `.task`. Otherwise keep the current tab, demoting `.task` to `.todos`. `ContentView.restoreSidePanelTab` passes `worktree.branch.flatMap { workTaskManager.task(forWorktree: $0) }`. | Criterion 11. Passing the task rather than a `Bool` puts the hidden-shadow rule inside the pure, tested function, not in an untested line in a view. `task(forWorktree:)` returns the first pool task linked to the branch (`WorkTaskManager.swift:110-112`). `createShadowTask` and `createExposedTask` both return any existing link instead of adding a second one (`:144,166-168`). |
| D11 | Is the side-panel change a regression for hand-made worktrees? | No. It is the behavior the brief asks for: a worktree with only its hidden shadow task keeps the current tab. | Brief, Constraints: "a deliberate behavior change". |
| D12 | What happens to `PendingCreate.TaskLink`? | It keeps `id` and `priorWorktree` only. `abandonPendingCreate` restores `worktree` alone. | Criterion 10: the link unwind still leaves the task startable. Its doc comments are reworded so they no longer mention a status (`WorkTaskCoordinator.swift:22-24,121-124`). |
| D13 | Comments in `Sources/App` that mention the task status | They are reworded or removed: `WorkTask.swift:9-11`, `WorkTaskManager.swift:141-142,169,190,202-207,358`, `TaskAsideView.swift:24-25`, `ContentViewHelpers.swift:43-46`, `WorkTaskCoordinator.swift:62-63,121-124`. | Criterion 14. Global CLAUDE.md: a comment that no longer holds is removed, not kept. |
| D14 | Docs | README §Tasks (`README.md:58`): drop the `status` sentences and keep the Start Now description. `Sources/App/CLAUDE.md`: in the `WorkTaskCoordinator` bullet (`:175-198`), `confirmCreate` writes `worktree = <branch as confirmed>` only, `resolveStart` derives the branch, and a linked task with no live worktree is ignored. At `:279`, drop "no status". At `:289-292`, drop the two sentences about `status`. | Criterion 13. |
| D15 | Is there a migration or a strip on launch? | No. | Brief, Out of scope. |
| D16 | Does a test keep any reference to `status`/`attempt`? | Yes, only as raw frontmatter text in the tests proving that old lines are ignored and dropped on the next save (Testing T2-T4). | Criterion 14 allows exactly this. |

## Assumptions

Each was checked against the tree at `31293f2`. No probes were needed and none were written.

| # | Assumption | Evidence |
| --- | --- | --- |
| A1 | Every read and write of the task status and attempt in `Sources/App` is in the files listed under Files touched. | `grep -rnE "ReservedStatus|migrateStatus|\.status|attempt|taskStatus|AgentMetadata" Sources/App`. The remaining hits are `WorktreeStatus`, `Todo.Status`, git exit statuses, `AgentHookEvent`, and the "enable attempt" and `ShellPathResolver` attempts, all unrelated. |
| A2 | The Tasks list already offers Start Now only for unlinked tasks. | `WorkTaskListView.swift:38-41` (`startableTask` requires `task.worktree == nil`) and `:46-48` (rows come from `backlogTasks`, filtered on `worktree == nil`). |
| A3 | The task window shows Start Now only for `status == new` today. | `WorkTaskWindow.swift:288`. |
| A4 | Both Start Now doors reach `resolveStart` through the `WorkTaskNotification.start` notification. | Posted by `WorkTaskWindow.swift:315` and `WorkTaskListView.swift:336`, handled by `ContentView.swift:470` → `startWorkTask` (`:771-773`). |
| A5 | `resolveStart` re-reads the task from disk, so a stale snapshot that shows no link still sees a link written by another window. | `WorkTaskCoordinator.swift:67` (`freshTask(id:)`). |
| A6 | Between `confirmCreate` and `completePendingCreate`, the central task file carries the link while no worktree has that branch yet. | `confirmCreate` writes `worktree = branch` (`WorkTaskCoordinator.swift:105`) before the create runs. `completePendingCreate` runs once the worktree is live (`:150-157`). |
| A7 | Nothing in the UI sets `canceled`. | `ReservedStatus.canceled` doc comment: "Read-only: nothing writes it any more" (`WorkTask.swift:33-35`). Grep finds no writer in `Sources/App`. |
| A8 | No file is rewritten on load. | `reload` and `loadTask` only read (`WorkTaskManager.swift:317-349`, `loadTask` at `:420`). `write` is reached only through `createTask`, `createShadowTask`, `createExposedTask` and `persist` (`:130-174,232`). |
| A9 | The editor buffer is the serialized task, so once `status` is gone from `serialized()`, opening an old file does not count as an edit. | `WorkTaskWindow.swift:154`, `TaskDetailView.swift:144` (`editorText = task.serialized()`). Save guard: `TaskEditorBuffers.swift:115`. |
| A10 | Shadow tasks are `hidden: true`. Backlog and exposed tasks are not. | `WorkTaskManager.swift:148-149` (shadow), `:132` and `:170` (no `hidden` set; the default is `false`, `WorkTask.swift:21`). |
| A11 | `/work` and `/plan-task` do not read the task status. | Task brief, Constraints (checked by the operator). |
| A12 | New or deleted Swift files are picked up only after `xcodegen generate`, which `ci.sh` runs. | `CLAUDE.md` §Verifying a change. `project.yml:25-30` globs `Sources`. |

## Objective and success criteria

A task file is `id`, `title`, an optional `worktree` link, an optional `hidden` flag, and a body.
The work is done when every acceptance criterion in `.clearway/TASK.md` holds:

1. New backlog, shadow and exposed tasks are written with no `status:` line (D5).
2. Create writes the `worktree` link and nothing about status or attempt (D2, D8).
3. A file with no `status:` loads. Only a missing `title` rejects a file (D4).
4. A file with `status:`/`attempt:` set to any value loads the same as one without (D4).
5. No file is rewritten only to drop those lines. The next real save drops them (D6).
6. A `status:`/`attempt:` line typed in the frontmatter editor is not persisted (D7).
7. Start Now is offered exactly when the task has no link, in the Tasks list and the task window (D9).
8. An unlinked task whose old file says `in_progress` (or any status) can be started (D8).
9. A linked task whose worktree is live is focused with no sheet (D8).
10. A cancelled sheet, and a failed create, leave the task startable with its prior link restored (D12).
11. Side panel: a stored tab wins; otherwise a visible linked task selects Task; otherwise the current tab is kept with Task demoted; main never lands on Task (D10).
12. No "Attempt N" label anywhere (D3).
13. README and `Sources/App/CLAUDE.md` describe neither field (D14).
14. No reference to either field remains in `Sources/App` or `Tests`, except the old-line tests (D13, D16).
15. `./scripts/ci.sh` passes.

## Commands

From the project's `## Pipeline` section:

| Step | Command |
| --- | --- |
| Regression check (every build task, simplify) | `./scripts/ci.sh` |
| Full gate (sign-off, once) | `./scripts/ci.sh` |

Criterion 14 also has a grep check. Its hits must be limited to the old-line tests:
`grep -rnE "ReservedStatus|migrateStatus|taskStatus|priorStatus|priorAttempt|WorkTaskAgentMetadata|\.attempt\b|task\.status|status: WorkTask|\"status\"|status:" Sources/App Tests`,
then read each hit and set aside the worktree status, `Todo.Status` and git exit status ones.

## Files touched

Source:
- `Sources/App/WorkTask.swift`: remove `status`, `attempt`, `ReservedStatus` and `migrateStatus`, the `init` parameter, the serialization lines and the parse requirement.
- `Sources/App/WorkTaskCoordinator.swift`: `resolveStart` (D8), `confirmCreate` and `abandonPendingCreate` (D2, D12), `TaskLink`, comments.
- `Sources/App/WorkTaskManager.swift`: `createShadowTask` and `createExposedTask` initializers, comments (D13).
- `Sources/App/WorkTaskWindow.swift`: Start Now gate (D9), metadata call site (D3).
- `Sources/App/TaskDetailView.swift`, `Sources/App/TaskAsideView.swift`: metadata call sites (D3), aside comment.
- `Sources/App/ContentViewHelpers.swift`, `Sources/App/ContentView.swift`: side-panel rule (D10).
- `Sources/App/WorkTaskAgentMetadata.swift`: deleted.

Docs: `README.md`, `Sources/App/CLAUDE.md` (D14).

Tests, updated so they neither set nor assert either field: `Tests/WorkTaskTests.swift`,
`Tests/WorkTaskManagerTests.swift`, `Tests/WorkTaskCoordinatorTests.swift`,
`Tests/WorkTaskManagerWatcherTests.swift` (the external-edit tests switch to asserting `title` or
`body` adoption), `Tests/TaskEditorBuffersTests.swift` (the "body save must not clobber status"
test now checks that a body save does not clobber `worktree`), `Tests/WorkTaskRelocationSafetyTests.swift`,
`Tests/SidePanelTabTests.swift`.

## Testing

XCTest, through `./scripts/ci.sh`. New or rewritten tests:

- T1 `WorkTaskTests`: `serialized()` of a new, a shadow-shaped (`hidden`, linked) and a linked task has no `status:`/`attempt:` line (crit. 1).
- T2 `WorkTaskTests`: `parse` of a file with only `title` succeeds. Each of `new`, `in_progress`, `canceled`, `open`, `started`, `stopped`, `ready_to_start`, an arbitrary slug, and `attempt: 3` parses to the same `WorkTask` as the bare file. A file with no `title` returns nil (crit. 3, 4).
- T3 `WorkTaskManagerTests`: a central file with `status: in_progress` and `attempt: 2` survives reload and a no-op `updateFields` byte-for-byte. After a title change, the file has neither line (crit. 5).
- T4 `TaskEditorBuffersTests` or `WorkTaskManagerTests`: `applyEditorBuffer` with a `status:`/`attempt:` line added leaves the file without either line (crit. 6).
- T5 `WorkTaskCoordinatorTests`: `resolveStart` prefills an unlinked task whose file says `in_progress` (crit. 8). It returns `.reuse` for a linked live task (crit. 9) and `.ignored` for a linked task with no live worktree (D8). It always derives the branch, replacing `testResolveStartPrefersTheTasksSavedBranchOverADerivedOne`. `confirmCreate` writes the link alone (crit. 2), and `abandonPendingCreate` restores the prior link (crit. 10). The two attempt tests are deleted.
- T6 `SidePanelTabTests`: stored wins; a visible linked task selects `.task`; a hidden linked task and `nil` keep current with `.task` → `.todos`; main never yields `.task` (crit. 11).
- The task window's Start Now (crit. 7) is a view condition with no test seam. Review checks it against D9, and the operator checks it by hand. Build agents do not launch the app (memory).

## Boundaries

- Always: run `./scripts/ci.sh` after the last edit; keep `swiftlint lint` at zero new warnings.
- Ask first: any change to worktree status, `Todo.Status`, the CLI or skills, or any file migration.
- Never: rewrite existing task files on launch; add a cancel/restart flow; launch the app or take screenshots from a build agent.

## Out of scope

- The worktree status (`clearway.status`, `WorktreeStatus`, sidebar Status grouping and badges).
- `Todo.Status`.
- Rewriting existing task files. The `.clearway/tasks` files in this repo keep `status: new` until the next save.
- The Clearway CLI and skills.
- Any new way to cancel, restart or track a task's lifecycle.
- Older builds rejecting status-less files on rollback (open risk, accepted by the operator).
