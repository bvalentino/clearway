# Plan: Remove all use of the task status

Breaks down `docs/superpowers/specs/2026-10-03-remove-all-use-of-the-task-status.md`.

**Date:** 2026-10-03
**Base:** 31293f2 (Release v2.0.1)

## Architecture decisions carried from the spec

- `WorkTask.status`, `WorkTask.ReservedStatus`, `WorkTask.migrateStatus` and the `status:`
  parameter of `WorkTask.init` are deleted (D1).
- `WorkTask.attempt` is deleted, with the bump in `confirmCreate`, `TaskLink.priorAttempt` and its
  restore in `abandonPendingCreate` (D2).
- `Sources/App/WorkTaskAgentMetadata.swift` is deleted with its three call sites in
  `WorkTaskWindow`, `TaskDetailView` and `TaskAsideView`. No replacement view (D3).
- `parse` requires frontmatter and `title`, nothing else. `status`/`attempt` keys are ignored like
  any unknown key (D4).
- `frontmatterLines` writes `id`, `title`, then `worktree` and `hidden` when set (D5).
- No new code stops a rewrite of old files or keeps a typed `status:` line out of the file. The
  existing write paths already do it; tests pin it (D6, D7).
- `resolveStart`: re-read the task with `freshTask(id:)`. Linked → `.reuse(wt)` when a live worktree
  has that branch, else `.ignored`. Unlinked → `.prefill` with a `deriveBranchName` branch. The
  status guard and the `current.worktree ??` fallback go (D8).
- Start Now in the task window shows when `task` is non-nil and `task.worktree == nil`; nil `task`
  shows no button. The Tasks list is unchanged (D9).
- `resolveSidePanelTab(stored:linkedTask:current:isMain:)` takes `linkedTask: WorkTask?`. Stored
  available tab wins; else `.task` when available and `linkedTask` is non-nil and not `hidden`;
  else current, with `.task` demoted to `.todos`. `ContentView.restoreSidePanelTab` passes
  `worktree.branch.flatMap { workTaskManager.task(forWorktree: $0) }` (D10, D11).
- `PendingCreate.TaskLink` keeps `id` and `priorWorktree`. `abandonPendingCreate` restores
  `worktree` only (D12).
- Comments in `Sources/App` that mention the task status are reworded or removed (D13). README
  §Tasks and `Sources/App/CLAUDE.md` stop describing either field (D14).
- No migration and no strip on launch (D15). Tests mention `status`/`attempt` only as raw
  frontmatter text in the tests that prove old lines are ignored and dropped (D16).

## Sequencing

The operator wants one coherent change, and every task below must leave `./scripts/ci.sh`
passing. Swift will not compile a reference to a deleted member, so the order is: first move every
reader off the status (T1, T2), drop the attempt label and field (T3, T4), stop every writer and
detach every test from the field (T5, T6, T7), then delete the field itself (T8). Between T5 and
T8 the model still has `status` and new tasks get its `"new"` default; nothing reads it by then,
so that interim state has no visible effect and is gone at T8.

## Dependency graph

```
T1 (side panel) ──────────────────────────────┐
T2 (Start gate) ──┬─ T3 (label) ── T4 (attempt field) ── T5 (coordinator writes) ──┐
                  │                                                                 ├── T8 (delete field) ── T9 (docs + grep)
                  └─ T6 (manager writes) ───────────────────────────────────────────┤
T7 (test decoupling) ───────────────────────────────────────────────────────────────┘
```

T1, T2 and T7 have no prerequisites. T3 follows T2 (both edit `WorkTaskWindow.swift`). T4 follows
T3 (the label reads `attempt`). T5 follows T4 (both edit `WorkTaskCoordinator.swift` and its tests).
T6 follows T2. T8 needs T1, T5, T6 and T7. Run them in numeric order unless parallelizing.

## Tasks

Every task's last acceptance criterion is that `./scripts/ci.sh` exits 0 after the task's final
edit. Each task also keeps `swiftlint lint` at zero new warnings. Build agents do not launch the
app or take screenshots.

### T1: Side panel selects Task for a visible linked task

**Files:** `Sources/App/ContentViewHelpers.swift`, `Sources/App/ContentView.swift`,
`Tests/SidePanelTabTests.swift`

**What:** Change `resolveSidePanelTab(stored:taskStatus:current:isMain:)` to
`resolveSidePanelTab(stored:linkedTask:current:isMain:)` with `linkedTask: WorkTask?` (D10). The
`.task` rule becomes `available.contains(.task), let linkedTask, !linkedTask.hidden`. Reword its
doc comment (`ContentViewHelpers.swift:43-46`) to describe the new rule with no mention of a
status. In `ContentView.restoreSidePanelTab` (around `:670-684`), drop the status lookup and pass
`linkedTask: worktree.branch.flatMap { workTaskManager.task(forWorktree: $0) }`. Rewrite
`SidePanelTabTests` against the new signature with no `taskStatus`/`ReservedStatus` reference;
build `WorkTask(title:worktree:)` values, setting `hidden = true` for the shadow case.

**Acceptance criteria:**
- A stored available tab wins over everything; an unknown stored string falls through.
- With no stored tab, a non-hidden linked task selects `.task`; a hidden linked task and `nil`
  keep the current tab, with `.task` demoted to `.todos`.
- On main, no input yields `.task`.
- `./scripts/ci.sh` exits 0.

**Verify:** the rewritten `SidePanelTabTests` cover each bullet above (spec T6);
`grep -n "taskStatus" Sources/App Tests -r` returns nothing; `./scripts/ci.sh`.

### T2: Start gate uses the worktree link

**Files:** `Sources/App/WorkTaskCoordinator.swift`, `Sources/App/WorkTaskWindow.swift`,
`Tests/WorkTaskCoordinatorTests.swift`

**What:** In `resolveStart` (D8), delete the status guard (`:68-69`) and the
`current.worktree ??` fallback (`:78`). With a link: `.reuse(wt)` if a worktree in
`worktreeManager.worktrees` has that branch, else `.ignored`. Without a link: `.prefill` with
`deriveBranchName(from:existingBranches:)`. Reword the doc/inline comments at `:62-63` so they
mention no status ("leaves the task on its backlog marker" goes). In `WorkTaskWindow.primaryActionButton`
(`:286-294`), gate on `if let task, task.worktree == nil` (D9; not `task?.worktree == nil`).
In `WorkTaskCoordinatorTests`, replace the `resolveStart` tests: delete
`testResolveStartPrefersTheTasksSavedBranchOverADerivedOne`, and add tests that (a) an unlinked
task whose central file says `status: in_progress` returns `.prefill` with the derived branch —
write that file as raw frontmatter text so the test survives T8; (b) a linked task with a live
worktree returns `.reuse`; (c) a linked task with no live worktree returns `.ignored`. Leave the
`confirmCreate`/`abandonPendingCreate` tests for T4/T5.

**Acceptance criteria:**
- `resolveStart` reads no status; tests (a)–(c) pass (crit. 8, 9).
- The task window's Start Now condition is exactly `task != nil && task.worktree == nil`.
- `./scripts/ci.sh` exits 0.

**Verify:** new coordinator tests; read the `primaryActionButton` diff against D9 (no test seam,
spec §Testing); `./scripts/ci.sh`.

### T3: Remove the "Attempt N" label

**Files:** `Sources/App/WorkTaskAgentMetadata.swift` (delete), `Sources/App/WorkTaskWindow.swift`,
`Sources/App/TaskDetailView.swift`, `Sources/App/TaskAsideView.swift`

**What:** Delete `WorkTaskAgentMetadata.swift` and its call sites (`WorkTaskWindow.swift:226-230`,
`TaskDetailView.swift:77-81`, `TaskAsideView.swift:40-42`; line numbers are at base and may have
shifted). Remove any container, divider or spacing that existed only to hold the label, so no
empty gap is left. Reword or remove the status comment at `TaskAsideView.swift:24-25` (D13). No
`project.yml` edit; `ci.sh` regenerates the project.

**Acceptance criteria:**
- `grep -rn "WorkTaskAgentMetadata\|Attempt " Sources/App` returns nothing (crit. 12).
- `./scripts/ci.sh` exits 0.

**Verify:** the grep above; `./scripts/ci.sh`.

### T4: Delete the attempt field and counter

**Files:** `Sources/App/WorkTask.swift`, `Sources/App/WorkTaskCoordinator.swift`,
`Tests/WorkTaskCoordinatorTests.swift`, `Tests/WorkTaskTests.swift`

**What:** Remove `var attempt`, the `attempt:` line in `frontmatterLines`, and any `attempt`
parsing in `parse` (D2). In `confirmCreate` remove the `canceled` bump; remove
`TaskLink.priorAttempt` and its restore in `abandonPendingCreate`. Keep `priorStatus` for now (T5
removes it). In `WorkTaskCoordinatorTests`, delete the two attempt tests (around `:139-153` and
`:225-245`) and drop `priorAttempt:` from every `TaskLink` construction. In `WorkTaskTests`, drop
the `attempt` assertions from the round-trip test (around `:100-131`) but keep its raw
`attempt: 2` input line, which now proves an `attempt:` key is ignored.

**Acceptance criteria:**
- No Swift reference to `attempt`/`priorAttempt` on `WorkTask` or `TaskLink` remains in
  `Sources/App` or `Tests` (raw frontmatter text in `WorkTaskTests` excepted).
- A file carrying `attempt: 2` still parses, and `serialized()` of the result has no `attempt:` line.
- `./scripts/ci.sh` exits 0.

**Verify:** `grep -rnE "\.attempt\b|priorAttempt|attempt:" Sources/App Tests` (only raw
frontmatter hits in `WorkTaskTests`); `./scripts/ci.sh`.

### T5: Create writes only the worktree link

**Files:** `Sources/App/WorkTaskCoordinator.swift`, `Tests/WorkTaskCoordinatorTests.swift`

**What:** `confirmCreate` sets only `updated.worktree = branch` (D2, D8). `TaskLink` keeps `id` and
`priorWorktree` (D12); `abandonPendingCreate` restores `worktree` alone. Reword the `TaskLink` doc
comment (`:22-24`, "three system-managed fields") and the `abandonPendingCreate` doc comment
(`:121-124`, "on `in_progress`", "a state `resolveStart` refuses") so they describe the link alone
(D13). In `WorkTaskCoordinatorTests`, remove every remaining `status`/`ReservedStatus`/`priorStatus`
reference (including the Plan test around `:526-541` and the stale-snapshot test around
`:620-662`): `confirmCreate` tests assert the link is written; `abandonPendingCreate` tests assert
the prior link is restored and `resolveStart` then returns `.prefill` (crit. 10); where a test
asserted the file kept or gained a status, assert on `worktree` or `title`/`body` instead. The
`status: in_progress` raw text in T2's test (a) stays.

**Acceptance criteria:**
- `WorkTaskCoordinator.swift` contains no `status`/`ReservedStatus` reference.
- After `confirmCreate`, the task's `worktree` is the confirmed branch (crit. 2); after
  `abandonPendingCreate`, it is the prior value and the task is startable (crit. 10).
- `WorkTaskCoordinatorTests` references the status only as raw frontmatter text.
- `./scripts/ci.sh` exits 0.

**Verify:** `grep -nE "status|Status" Sources/App/WorkTaskCoordinator.swift Tests/WorkTaskCoordinatorTests.swift`
shows only the raw-text fixture and unrelated worktree-status hits; `./scripts/ci.sh`.

### T6: Shadow and exposed tasks stop passing a status

**Files:** `Sources/App/WorkTaskManager.swift`, `Tests/WorkTaskManagerTests.swift`

**What:** Drop the `status: WorkTask.ReservedStatus.inProgress` argument from `createShadowTask`
and `createExposedTask` (around `:144-170`). Reword or remove the status comments at `:141-142`,
`:169`, `:190`, `:202-207` and `:358` (D13). In `WorkTaskManagerTests`, remove every Swift
reference to `status`/`ReservedStatus`: drop `status:` init arguments; delete the assertions that
shadow/exposed tasks start `in_progress` (`:84`, `:182`); where a test uses `status` as the field a
disk write advances, follow T7's rule. Raw frontmatter fixtures that contain a `status:` line
(around `:159`, `:390`) stay for now; `parse` still requires it until T8.

**Acceptance criteria:**
- `WorkTaskManager.swift` contains no `status`/`ReservedStatus` reference.
- `WorkTaskManagerTests` references the status only inside raw frontmatter strings.
- `./scripts/ci.sh` exits 0.

**Verify:** `grep -nE "\.status\b|status:|ReservedStatus" Sources/App/WorkTaskManager.swift Tests/WorkTaskManagerTests.swift`
shows only raw fixture lines; `./scripts/ci.sh`.

### T7: Detach the remaining tests from the status field

**Files:** `Tests/WorkTaskManagerWatcherTests.swift`, `Tests/TaskEditorBuffersTests.swift`,
`Tests/WorkTaskRelocationSafetyTests.swift`

**What:** Test-only. Remove every Swift reference to `status`/`ReservedStatus` while keeping what
each test proves. Rule: where a test proves an external edit is adopted (the watcher tests),
advance `title` or `body` instead of `status`. Where a test proves a disk-only field survives a
buffer save (the `TaskEditorBuffersTests` "body save must not clobber status" and "status from
disk must survive body save" tests), use `worktree`, since `applyEditorBuffer` copies only
`title` and `body` from the buffer (spec D7, Files touched). Drop `status:` init arguments
everywhere. The raw `status: in_progress` fixture in `WorkTaskRelocationSafetyTests` (around `:22`)
stays until T8.

**Acceptance criteria:**
- These three files reference the status only inside raw frontmatter strings.
- Each rewritten test still fails if its guarded behavior breaks (e.g. the editor test fails if a
  body save overwrites `worktree` from the buffer).
- `./scripts/ci.sh` exits 0.

**Verify:** `grep -nE "\.status\b|status:|ReservedStatus" <the three files>`; `./scripts/ci.sh`.

### T8: Delete the status field and pin old-line handling

**Files:** `Sources/App/WorkTask.swift`, `Tests/WorkTaskTests.swift`,
`Tests/WorkTaskManagerTests.swift`, `Tests/WorkTaskRelocationSafetyTests.swift`

**What:** In `WorkTask.swift`, delete `status`, `ReservedStatus`, `migrateStatus`, the `status:`
`init` parameter, the `status:` line in `frontmatterLines`, and the `status` requirement in
`parse` (D1, D4, D5). Reword the comments at `:9-11` and the `parse` doc comment ("required
fields (`title`, `status`)"). Remove the `status:` line from the raw fixtures in
`WorkTaskManagerTests` and `WorkTaskRelocationSafetyTests` that do not test old-line handling. In
`WorkTaskTests`, delete the `migrateStatus` and arbitrary-slug tests and add:
- spec T1: `serialized()` of a new task, a shadow-shaped task (`hidden`, linked) and a linked task
  has no `status:` or `attempt:` line (crit. 1);
- spec T2: a file with only `title` parses; each of `new`, `in_progress`, `canceled`, `open`,
  `started`, `stopped`, `ready_to_start`, an arbitrary slug, and `attempt: 3` parses equal to the
  bare file (same `id`/`createdAt` passed in); a file with no `title` returns nil (crit. 3, 4).
In `WorkTaskManagerTests` add:
- spec T3: a central file with `status: in_progress` and `attempt: 2` is byte-identical after
  `reload` and after an `updateFields` that changes nothing; after a title change neither line is
  in the file (crit. 5);
- spec T4: `applyEditorBuffer` with `status:`/`attempt:` lines added to the buffer leaves the
  file with neither line (crit. 6).

**Acceptance criteria:**
- `WorkTask` has no `status` or `attempt` member, and `ReservedStatus`/`migrateStatus` do not exist.
- The four new test groups above pass.
- `./scripts/ci.sh` exits 0.

**Verify:** the spec's criterion-14 grep
(`grep -rnE "ReservedStatus|migrateStatus|taskStatus|priorStatus|priorAttempt|WorkTaskAgentMetadata|\.attempt\b|task\.status|status: WorkTask|\"status\"|status:" Sources/App Tests`)
returns only old-line test fixtures and unrelated hits (worktree status, `Todo.Status`, git exit
status, agent hook JSON); `./scripts/ci.sh`.

### T9: Docs drop the task status and attempt

**Files:** `README.md`, `Sources/App/CLAUDE.md`

**What:** README §Tasks (around `:58`): remove the `status` sentences, keep the Start Now
description, and state that Start Now is offered for a task with no worktree. `Sources/App/CLAUDE.md`:
in the `WorkTaskCoordinator` bullet (around `:175-198`) say `confirmCreate` writes
`worktree = <branch as confirmed>` only, `resolveStart` derives the branch, and a linked task with
no live worktree is ignored; at `:279` drop "no status"; at `:289-292` drop the two sentences about
`status`. Remove any mention of `attempt`, `ReservedStatus`, `migrateStatus` or
`WorkTaskAgentMetadata`. Also describe the new side-panel rule wherever the file states the old
`in_progress` one.

**Acceptance criteria:**
- `grep -nE "status|attempt|Attempt" README.md Sources/App/CLAUDE.md` has no hit about a task's
  status or attempt (worktree status and todo status hits remain) (crit. 13).
- `./scripts/ci.sh` exits 0.

**Verify:** the grep above, reading each hit; `./scripts/ci.sh`.

## Build log

### T1: Side panel selects Task for a visible linked task

| File | State |
| --- | --- |
| `Sources/App/ContentViewHelpers.swift` | `resolveSidePanelTab(stored:linkedTask:current:isMain:)`; `.task` rule is `available.contains(.task), let linkedTask, !linkedTask.hidden`; doc comment reworded with no status |
| `Sources/App/ContentView.swift` | `restoreSidePanelTab` passes `linkedTask: worktree.branch.flatMap { workTaskManager.task(forWorktree: $0) }` |
| `Tests/SidePanelTabTests.swift` | Rewritten on `WorkTask(title:worktree:)` values (one with `hidden = true`); no `taskStatus`/`ReservedStatus` reference |

Coverage against the acceptance criteria: stored tab wins (`testStoredTabBeatsAVisibleLinkedTask`,
`testMainKeepsStoredNonTaskTab`); unknown stored string falls through (`testInvalidStoredRawValueFallsThrough`,
`testPersistedNotesTabFallsBackToValidTab`); visible linked task selects `.task`
(`testVisibleLinkedTaskSelectsTask`); hidden linked task and `nil` keep current with `.task` demoted
(`testHiddenLinkedTaskPreservesCurrentDemotingTask`, `testNoLinkedTaskPreservesCurrentDemotingTask`);
main never yields `.task` (`testMainClampsAVisibleLinkedTaskToTodos`, `testMainDropsStoredTaskFallingBackToCurrent`,
`testMainClampsStoredAndCurrentTaskToTodos`, `testMainPreservesCurrentNonTaskTab`).

**Watched failure (RED).** Tests written first against the old function; `./scripts/ci.sh` exited 65:

```
Tests/SidePanelTabTests.swift:15:32: incorrect argument label in call (have 'stored:linkedTask:current:isMain:', expected 'stored:taskStatus:current:isMain:')
```

The failure is a compile error, not an assertion: the change is a signature change, so no test
against the new signature can run on the unfixed code.

**Deviations:** none. `Sources/App/CLAUDE.md` still describes no side-panel rule change here; T9 owns docs.

**Gate:** `./scripts/ci.sh` exit 0 after the last edit (883 tests, 0 failures).
`grep -rn "taskStatus" Sources/App Tests` returns nothing. `swiftlint lint --quiet` on the touched
files: no output.

### T2: Start gate uses the worktree link

| File | State |
| --- | --- |
| `Sources/App/WorkTaskCoordinator.swift` | `resolveStart` reads no status: linked → `.reuse(wt)` for a live worktree with that branch, else `.ignored`; unlinked → `.prefill` with `deriveBranchName`. The `current.worktree ??` fallback is gone. Doc comment reworded; it now states why a linked, not-live task is ignored |
| `Sources/App/WorkTaskWindow.swift` | `primaryActionButton` gates on `if let task, task.worktree == nil` |
| `Tests/WorkTaskCoordinatorTests.swift` | Deleted `testResolveStartPrefersTheTasksSavedBranchOverADerivedOne` and `testResolveStartIgnoresATaskThatIsNeitherNewNorCanceled` (it asserted the old status gate). Added (a) `testResolveStartPrefillsAnUnlinkedTaskWhoseFileSaysInProgress`, written as raw frontmatter text so it survives T8, and (c) `testResolveStartIgnoresALinkedTaskWithNoLiveWorktree`. (b) is the existing `testResolveStartReusesALiveWorktree` |

**Watched failure (RED).** New tests run against the unchanged `resolveStart`; `./scripts/ci.sh` exited 65:

```
✖ testResolveStartIgnoresALinkedTaskWithNoLiveWorktree, failed - expected ignored
✖ testResolveStartPrefillsAnUnlinkedTaskWhoseFileSaysInProgress, failed - expected prefill
Executed 883 tests, with 2 failures (0 unexpected)
```

**Deviations:** `testResolveStartIgnoresATaskThatIsNeitherNewNorCanceled` was deleted as well as the
saved-branch test. The plan did not name it, but it pins the status gate this task removes, and test
(a) is its replacement. The `status:` assertion in `testResolveStartWritesNothing` and the remaining
status references in the confirm/abandon/stale-snapshot tests are left for T4/T5 as planned; they still pass.

**Gate:** `./scripts/ci.sh` exit 0 after the last edit (883 tests, 0 failures). `swiftlint lint --quiet`
on the three touched files: no output.

### T3: Remove the "Attempt N" label

| File | State |
| --- | --- |
| `Sources/App/WorkTaskAgentMetadata.swift` | Deleted |
| `Sources/App/WorkTaskWindow.swift` | Metadata block and its comment removed; the `Divider()` under the title stays, it separates title from body |
| `Sources/App/TaskDetailView.swift` | Metadata block removed; `Divider()` stays for the same reason |
| `Sources/App/TaskAsideView.swift` | Metadata row removed; the `VStack` drops `spacing: 16`, which only separated the card from the row. The `createShadowTask` comment no longer mentions status changes |

**Evidence.** No test: the change deletes a view, and the suite has no view tests to pin its
absence. Acceptance is the grep: `grep -rn "WorkTaskAgentMetadata\|Attempt " Sources/App` returns
nothing (exit 1).

**Deviations:** none.

**Gate:** `./scripts/ci.sh` exit 0 after the last code edit (883 tests, 0 failures).

### T4: Delete the attempt field and counter

| File | State |
| --- | --- |
| `Sources/App/WorkTask.swift` | `var attempt`, its `frontmatterLines` line and its `parse` read removed |
| `Sources/App/WorkTaskCoordinator.swift` | `TaskLink.priorAttempt` removed; `confirmCreate` drops the `canceled` bump; `abandonPendingCreate` no longer restores `attempt`. `priorStatus` stays for T5. The `TaskLink` doc comment's "three system-managed fields" now reads "two"; T5 rewords it fully |
| `Sources/App/WorkTaskManager.swift` | `applyEditorBuffer` doc comment drops `attempt` from its system-managed field list (rest of that comment is T6's) |
| `Tests/WorkTaskCoordinatorTests.swift` | Deleted `testConfirmCreateCountsTheAttemptWhenRestartingACanceledTask` and `testAbandonPendingCreateRestoresABumpedAttempt`; `priorAttempt:` dropped from both `TaskLink` constructions |
| `Tests/WorkTaskTests.swift` | `testRetiredFieldsAreDroppedOnReserialize` keeps the raw `attempt: 2` input, drops `parsed.attempt`, and now asserts the reserialized text has no `attempt` |

**Watched failure (RED).** The test edit ran first against the unchanged model; `./scripts/ci.sh` exited 65:

```
✖ testRetiredFieldsAreDroppedOnReserialize, XCTAssertFalse failed - attempt must not be re-emitted
Executed 883 tests, with 1 failure (0 unexpected)
```

**Deviations:** the one-word comment fixes in `WorkTaskCoordinator.swift` and `WorkTaskManager.swift`
were not in the plan's T4 text; both comments would otherwise name a field that no longer exists.

**Gate:** `./scripts/ci.sh` exit 0 after the last edit (881 tests, 0 failures; the two deleted
attempt tests account for the drop from 883). `swiftlint lint --quiet` on the five touched files:
no output. `grep -rnE "\.attempt\b|priorAttempt|attempt:" Sources/App Tests` returns only the raw
`attempt: 2` fixture line in `Tests/WorkTaskTests.swift`.

### T5: Create writes only the worktree link

| File | State |
| --- | --- |
| `Sources/App/WorkTaskCoordinator.swift` | `confirmCreate` sets only `worktree`; `TaskLink` is `id` + `priorWorktree`; `abandonPendingCreate` restores `worktree` alone. `TaskLink` and `abandonPendingCreate` doc comments describe the link only; the abandon log line says "its worktree link stands" instead of "its start marker stands" |
| `Tests/WorkTaskCoordinatorTests.swift` | Class doc comment drops the `in_progress` sentence. `testResolveStartWritesNothing` asserts the file is byte-identical instead of checking a `status:` line. `testConfirmCreateWritesTheStatusAndTheConfirmedBranch` renamed `testConfirmCreateWritesTheConfirmedBranch` and asserts `worktree` only. New `testConfirmCreateWritesOnlyTheWorktreeLink`: the file after Create, minus its `worktree: "ship-it"` line, equals the file before. Abandon test drops its status assertion (it still asserts byte-identical restore, nil `worktree`, and `.prefill`). Plan and stale-snapshot tests no longer set or assert `status`. `priorStatus:` dropped from both `TaskLink` constructions |

**Watched failure (RED).** Tests edited first. To get an assertion rather than a compile error,
`priorStatus` was removed from `TaskLink` while `confirmCreate` still wrote `in_progress`;
`./scripts/ci.sh` exited 65:

```
✖ testAbandonPendingCreateRestoresTheTaskExactlyAsItWas, XCTAssertEqual failed: ("---
✖ testConfirmCreateWritesOnlyTheWorktreeLink, XCTAssertEqual failed: ("---
Executed 882 tests, with 2 failures (0 unexpected)
```

Both fail on the status line: Create still rewrote `status: new` to `in_progress`, and the
abandon (no longer restoring the status) left it there. Removing the status write made both pass.

**Deviations:** the abandon log message wording (`start marker` → `worktree link`) was not named in
the plan; it described the status. The new test is durable past T8: it compares whole files, so it
holds once the `status:` line is gone from both.

**Gate:** `./scripts/ci.sh` exit 0 after the last edit (882 tests, 0 failures). `swiftlint lint --quiet`
on both touched files: no output. `grep -nE "status|Status"` on both files returns only the raw
`status: in_progress` fixture and its doc comment in T2's test (a).

### T6: Shadow and exposed tasks stop passing a status

| File | State |
| --- | --- |
| `Sources/App/WorkTaskManager.swift` | `createShadowTask` and `createExposedTask` build `WorkTask(title: "", worktree: branch)`. Status comments reworded: the `createShadowTask` doc drops the `.inProgress`/`.new` sentence; the `createExposedTask` inline comment names only the empty title; `updateFields` says "fresher fields"; `applyEditorBuffer` lists `worktree`, `hidden`, timestamps as never taken from the buffer and drops "state commands" and "pre-agent status"; the watcher doc says "stale content" |
| `Tests/WorkTaskManagerTests.swift` | Every `status:` init argument dropped. The shadow/exposed `in_progress` assertions deleted. `testStatusWriteOnHiddenTaskPreservesHiddenFlag` renamed `testFieldWriteOnHiddenTaskPreservesHiddenFlag` and writes `title`. `testExternalWorktreeStatusRewriteUpdatesPool` renamed `testExternalWorktreeRewriteUpdatesPool`, advances `title` + `body` (T7's rule), branch `feature/inflight`. `testApplyEditorBufferRebasesSystemFieldsFromDisk` uses `worktree` as the disk-only field. `testApplyEditorBufferPreservesSystemFields`, the novel-insert and central-rewrite tests drop their status writes and assertions. The two raw fixtures (`status: new`, `status: in_progress`) stay until T8 |

**Watched failure (RED).** The two rewritten editor-buffer tests now guard `worktree` instead of
`status`. To prove they still bite, `applyEditorBuffer` was mutated to also copy
`parsed.worktree` from the buffer; `./scripts/ci.sh` exited 65:

```
✖ testApplyEditorBufferPreservesSystemFields, XCTAssertEqual failed: ("nil") is not equal to ("Optional("some-branch")") - worktree must be preserved by applyEditorBuffer
✖ testApplyEditorBufferRebasesSystemFieldsFromDisk, XCTAssertEqual failed: ("nil") is not equal to ("Optional("feature/disk")") - worktree must come from disk, not the stale pool/buffer
Executed 882 tests, with 3 failures (0 unexpected)
```

The source was restored from a scratchpad copy before the green run.

**Deviations:** the plan named the status-driven tests by line only; the T7 rule (advance `title`
or `body`; use `worktree` for a disk-only field) was applied to the three tests here that used
`status` that way. In the `applyEditorBuffer` doc, `hidden` replaces `status` in the field list,
since it is the other system-managed field the buffer never sets.

**Gate:** `./scripts/ci.sh` exit 0 after the last code edit (882 tests, 0 failures).
`swiftlint lint --quiet` on both touched files: no output.
`grep -nE "\.status\b|status:|ReservedStatus"` on both files returns only the two raw fixture lines.

### T7: Detach the remaining tests from the status field

| File | State |
| --- | --- |
| `Tests/WorkTaskManagerWatcherTests.swift` | Central-rewrite test drops its status writes and assertion (title + body still advance). `testWatcherAdoptsAtomicWorktreeStatusRewrite` renamed `testWatcherAdoptsAtomicWorktreeRewrite`, advances `title` + `body`. Re-arm test advances `title` on the first write and `title` + `body` on the second. No `status:` init arguments |
| `Tests/TaskEditorBuffersTests.swift` | `status:` init arguments dropped. `testSaveBodyModeWritesTitleAndBodyViaRebase` guards `worktree` ("body save must not clobber worktree"). `testSaveBodyModeAllowsWriteWhenOnlyStatusMovedOnDisk` renamed `...WhenOnlyWorktreeMovedOnDisk`, advances `worktree` on disk and asserts it survives. Both CAS-abort tests drop their status writes and assertions; title/body still prove the abort |
| `Tests/WorkTaskRelocationSafetyTests.swift` | `status:` init arguments dropped from the real and shadow tasks. The raw `status: in_progress` fixture stays for T8 |

`Tests/WorkTaskManagerTests.swift` needed nothing: T6 had already applied this rule there.

**Watched failure (RED).** To prove the two rewritten editor tests still bite, the body-mode write
in `TaskEditorBuffers.save` was mutated to build a fresh `WorkTask(id:title:body:)` instead of
setting `title`/`body` on the disk re-base; `./scripts/ci.sh` exited 65:

```
✖ testSaveBodyModeAllowsWriteWhenOnlyWorktreeMovedOnDisk, XCTAssertEqual failed: ("nil") is not equal to ("Optional("feature/disk")") - worktree from disk must survive body save
✖ testSaveBodyModeWritesTitleAndBodyViaRebase, XCTAssertEqual failed: ("nil") is not equal to ("Optional("feature/disk")") - body save must not clobber worktree
Executed 882 tests, with 2 failures (0 unexpected)
```

The source was restored from a scratchpad copy before the green run.

**Deviations:** none.

**Gate:** `./scripts/ci.sh` exit 0 after the last code edit (882 tests, 0 failures).
`swiftlint lint --quiet` on the three touched files: no output.
`grep -nE "\.status\b|status:|ReservedStatus"` on the three files returns only the raw fixture in
`WorkTaskRelocationSafetyTests.swift:22`.

### T8: Delete the status field and pin old-line handling

| File | State |
| --- | --- |
| `Sources/App/WorkTask.swift` | `status`, `ReservedStatus`, `migrateStatus`, the `status:` `init` parameter and the `status:` line in `frontmatterLines` deleted. `parse` requires only `title`; its doc comment says so. The `:9-11` status doc comment went with the property |
| `Tests/WorkTaskTests.swift` | `testArbitrarySlugRoundTrips`, `testLegacyStatusValuesMigrate` and `testRetiredReadyToStartMigratesToNew` deleted. Added `testSerializedTasksCarryNoStatusOrAttemptLine` (spec T1: new, hidden linked shadow, linked), `testFileWithOnlyTitleParses`, `testFileWithoutTitleIsRejected` and `testOldStatusAndAttemptLinesParseLikeTheBareFile` (spec T2: the eight status values plus `attempt: 3`, each equal to the bare file with the same `id`/`createdAt`). `testRetiredFieldsAreDroppedOnReserialize` now counts `status` among the retired fields and asserts it is not re-emitted. `status:` dropped from the two non-old-line fixtures and the init arguments |
| `Tests/WorkTaskManagerTests.swift` | `status:` dropped from the two non-old-line raw fixtures. Added `testOldStatusAndAttemptLinesSurviveUntilTheNextRealSave` (spec T3) and `testApplyEditorBufferDropsTypedStatusAndAttemptLines` (spec T4) |
| `Tests/WorkTaskRelocationSafetyTests.swift` | `status: in_progress` dropped from the legacy fixture |

**Watched failure (RED).** The new tests were written against the finished model, so to prove they
bite, three mutations were applied together: `frontmatterLines` appended `status: new`, `parse`
required a `status` key (and rejected `canceled`), and `updateFields` lost its no-change guard.
`./scripts/ci.sh` exited 65:

```
✖ testSerializedTasksCarryNoStatusOrAttemptLine, XCTAssertFalse failed - no status line in:
✖ testFileWithOnlyTitleParses, XCTAssertEqual failed: ("nil") is not equal to ("Optional("Bare")")
✖ testOldStatusAndAttemptLinesParseLikeTheBareFile, XCTUnwrap failed: expected non-nil value of type "WorkTask"
✖ testOldStatusAndAttemptLinesSurviveUntilTheNextRealSave, XCTAssertEqual failed: ("---
✖ testApplyEditorBufferDropsTypedStatusAndAttemptLines, XCTAssertFalse failed - a typed status line must not be persisted
✖ testRetiredFieldsAreDroppedOnReserialize, XCTAssertFalse failed - status must not be re-emitted
Executed 885 tests, with 17 failures (0 unexpected)
```

The other failures were existing parse tests on status-less fixtures, as expected under a
required-status mutation. Both sources were restored from a scratchpad copy before the green run.

**Deviations:** `testFileWithoutTitleIsRejected` is its own test rather than a case inside the
parse-equality test, so the rejection reads separately from the acceptance. The spec T4 test went
in `WorkTaskManagerTests`, one of the two files the spec allows.

**Gate:** `./scripts/ci.sh` exit 0 after the last code edit (885 tests, 0 failures).
`swiftlint lint --quiet` on the four touched files: no output. The criterion-14 grep over
`Sources/App` returns only worktree status, `Todo.Status`, git exit status and agent hook JSON;
over `Tests` it returns those plus the old-line fixtures in `WorkTaskTests`, `WorkTaskManagerTests`
and T2's `WorkTaskCoordinatorTests` test (a).

### T9: Docs drop the task status and attempt

| File | State |
| --- | --- |
| `README.md` | §Tasks: the `status`/`in_progress` sentences are gone; Start Now is described as offered for a task with no worktree |
| `Sources/App/CLAUDE.md` | `WorkTaskCoordinator` bullet: `resolveStart` derives the branch for an unlinked task, focuses a linked task's live worktree, ignores a linked task with no live worktree (and why); `confirmCreate` writes `worktree = <branch as confirmed>` and nothing else. Plan bullet drops "no status". The two sentences on advancing and round-tripping `status` are gone |

**Evidence:** docs-only task, no behavioral test. `grep -nE "status|attempt|Attempt" README.md Sources/App/CLAUDE.md`
now returns seven hits, each read: worktree status tint (`:171`), background-task `status` in hook JSON (`:559`),
Claude Code's status line (`:567`), the agent status section headers (`:571`), the hook listener's last enable
attempt (`:602`), the yellow status badge colour (`:645`), a shell's exit status (`:690`). None is about a task.
No `ReservedStatus`, `migrateStatus`, `WorkTaskAgentMetadata` or `in_progress` remains in either file.

**Deviations:** `Sources/App/CLAUDE.md` never stated the old `in_progress` side-panel rule, so there was no
sentence to replace and none was added; the rule lives in `resolveSidePanelTab`'s doc comment and
`SidePanelTabTests` (T1).

**Gate:** `./scripts/ci.sh` exit 0 after the last edit (885 tests, 0 failures).
