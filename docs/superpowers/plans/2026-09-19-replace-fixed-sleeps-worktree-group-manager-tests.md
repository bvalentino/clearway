# Replace fixed sleeps and close the named coverage gaps in the WorktreeGroupManager suites

**Date:** 2026-09-19
**Base:** 1206708 (`Keep worktree groups, order and grouping mode in git config (#230)`)

Breaks down `docs/superpowers/specs/2026-09-19-replace-fixed-sleeps-worktree-group-manager-tests.md`.
Every design decision is settled there; this file only orders the work and says how each piece is
verified.

## Architecture decisions carried from the spec

1. A sleep whose assertion reads only published state is **deleted, not replaced by a poll** — every
   mutating method publishes synchronously before it enqueues its write, so the assertion on the
   next line is already correct.
2. A sleep whose assertion is that a gesture wrote **nothing** is replaced by an **awaited signal**,
   never a poll: `waitFor` returns the instant the expected value is already there, so a poll for
   absence passes against a broken manager.
3. That signal is the manager's own in-flight work: `writeChain` widens to `private(set) var` and
   `reconcile` becomes `@discardableResult`, returning its `Task`. `loadTask` is already
   `private(set)` for the same reason, so this is the established seam, not a new one.
4. `WorktreeGroupManagerGitTestCase.tearDown` awaits the write chain before the scratch root is
   removed. Without the sleeps a body ends with `git config` subprocesses still queued, and they
   must not run against a directory being deleted.
5. `WorktreeGroupPersistenceTests` is in scope for its single sleep and for three of the six new
   cases, because its doc comment already scopes it to stored state read back through
   `GitRepoFixture`.
6. Production behaviour does not change. The two visibility widenings in decision 3 are the whole
   `Sources/` diff.
7. The synthetic `/tmp` paths in `WorktreeGroupManagerTests` stay. Their writes can only fail, and
   nothing in that file reads stored state.
8. A test body that, after its sleep is deleted, neither awaits nor throws loses `async throws` from
   its signature. Both shapes already exist side by side in these files; a signature that promises
   waiting where none happens is exactly what this change is removing.
9. `WorktreeConfigStore` memoises its extension probe, so any new case that seeds worktree config
   behind the manager's back runs in this order: `repo.enableWorktreeConfig()`, `restartManager()`,
   seed the values, then act.

## Dependency graph

```
T1  seam + test-base settle/tearDown
 ├── T2  delete the 44 sleeps in WorktreeGroupManagerTests
 │    └── T4  two new cases in WorktreeGroupManagerTests
 └── T3  replace the sleeps in the Status, Name and Persistence suites
      ├── T5  new case: main's status on the read path (Status suite)
      └── T6  three new cases in WorktreeGroupPersistenceTests
```

T2 and T3 are independent of each other once T1 lands. T4, T5 and T6 each edit a file an earlier
task rewrote, so each waits on that task; they are independent of one another.

The regression check after every task is `./scripts/ci.sh` — the only runner of the test suite, and
the only thing that regenerates the Xcode project so a new or deleted Swift file is visible to the
build.

## Task list

### T1: Expose the settle seam and await it at teardown

**Files**

- `Sources/App/WorktreeGroupManager.swift`
- `Tests/TestHelpers.swift`

**What it does**

1. `private var writeChain: Task<Void, Never>?` becomes `private(set) var writeChain`. Extend its
   existing doc comment by one clause naming the test base as the second client, the way
   `loadTask`'s comment already does.
2. `func reconcile(_ worktrees: [Worktree], openIds: [String])` becomes
   `@discardableResult func reconcile(_ worktrees: [Worktree], openIds: [String]) -> Task<Void, Never>`,
   binding the `Task` it already creates and returning it. The body is otherwise untouched.
   `ContentView.swift:333` is the only production call site and must keep compiling unchanged —
   that is what `@discardableResult` is for.
3. Add to `WorktreeGroupManagerGitTestCase` (`Tests/TestHelpers.swift`) a settle helper:

   ```swift
   /// Awaits the manager's in-flight work — the load, then the write chain as it stands now — so a
   /// case asserting a gesture wrote *nothing* has something to wait on. Absence cannot be polled:
   /// `waitFor` returns the moment the expected value is already there.
   func settle(_ target: WorktreeGroupManager? = nil) async {
       let manager = target ?? self.manager
       await manager?.loadTask?.value
       await manager?.writeChain?.value
   }
   ```

   The parameter exists for `WorktreeGroupPersistenceTests`, which builds its own managers over a
   second root rather than using `self.manager`.
4. Override `tearDown` in `WorktreeGroupManagerGitTestCase` to `await settle()` before it drops
   `manager` and lets `TempRootTestCase.tearDown` remove the scratch root. Carry one comment saying
   why: a sleep-free body can end with `git config` subprocesses still queued.

**Acceptance criteria**

- `writeChain` and `reconcile`'s returned `Task` are reachable from the test target; no other line
  under `Sources/` changes.
- `settle()` and the new `tearDown` exist on `WorktreeGroupManagerGitTestCase`.
- No existing test is edited in this task.

**Verification**

- `./scripts/ci.sh` is green, with the same set of tests passing as before the task.
- `git diff --stat Sources/` shows exactly one file and no behavioural hunk.

### T2: Delete the 44 sleeps in WorktreeGroupManagerTests

**Files**

- `Tests/WorktreeGroupManagerTests.swift`

**What it does**

Deletes every `try await Task.sleep(...)` in the file. The file never reads stored state — it
contains no reference to `repo.`, never calls `restartManager()` and never calls `reconcile` — so
every assertion in it is on published state that is correct on the line after the gesture.

Where a body then neither awaits nor throws, drop `async throws` from its signature (decision 8).
Where it still calls a `try` or `await` helper, keep what it needs and nothing more. Leave blank
lines tidy: a gesture and its assertion separated only by the deleted sleep should read as one
paragraph, not two.

**Acceptance criteria**

- `grep -c "Task.sleep" Tests/WorktreeGroupManagerTests.swift` reports 0.
- Every case in the file still asserts what it asserted before; no assertion is weakened, added or
  reordered.
- No test function is left `async` or `throws` without an `await` or `try` in its body.

**Verification**

- `./scripts/ci.sh` is green.
- The suite's wall time, read from the `xcodebuild` output for
  `WorktreeGroupManagerTests`, is below its pre-task value; record both numbers in the build report.

### T3: Replace the sleeps in the Status, Name and Persistence suites

**Files**

- `Tests/WorktreeGroupManagerStatusTests.swift`
- `Tests/WorktreeGroupManagerNameTests.swift`
- `Tests/WorktreeGroupPersistenceTests.swift`

**What it does**

Deletes the 11 sleeps in `WorktreeGroupManagerStatusTests` that guard nothing — the ordering and
`matches` cases, which run on synthetic paths and assert only on published state — under the same
rule and with the same signature cleanup as T2.

Replaces the five sleeps that guard something:

| Case | Replacement |
| --- | --- |
| `WorktreeGroupManagerStatusTests.testSetStatusIgnoresTheMainWorktree` | `await settle()` |
| `WorktreeGroupManagerNameTests.testSetNameEmptyOnAWorktreeWithNoStoredNameChangesNothing` | `await settle()` |
| `WorktreeGroupManagerNameTests.testSetNameIgnoresTheMainWorktree` | `await settle()` |
| `WorktreeGroupManagerNameTests.testReconcileRightAfterSetNameDoesNotRaceTheWrite` | bind the `Task` `reconcile` returns and `await` its `.value` after the stored-name wait, in place of the trailing sleep |
| `WorktreeGroupPersistenceTests.testAProjectWhereTheExtensionCannotBeEnabledShowsNoGroups` | `await settle(first)` — the manager there is a local, not `self.manager` |

Nothing else in `WorktreeGroupPersistenceTests` changes in this task.

**Acceptance criteria**

- `grep -c "Task.sleep"` reports 0 for all three files.
- The four "wrote nothing" cases each await the manager's in-flight work before asserting, and each
  would fail if the gesture enqueued a write.
- `testReconcileRightAfterSetNameDoesNotRaceTheWrite` still proves the reload did not publish an
  empty name over "Fresh name", now by awaiting the reload rather than outlasting it.

**Verification**

- `./scripts/ci.sh` is green.
- Prove criterion 3 of the spec for each of the four "wrote nothing" cases: temporarily delete the
  guard the case exists for (`guard !wt.isMain` in `setStatus`, then in `setName`; the
  `stored == nil` early path for the empty-name case; the store's failure path for the
  extension-cannot-be-enabled case), run the single case, watch it fail, restore the guard. Paste
  each failure into the build report. Do this with `Edit` on the source file and restore it the same
  way — never `git checkout`.

### T4: Two new cases in WorktreeGroupManagerTests

**Files**

- `Tests/WorktreeGroupManagerTests.swift`

**What it does**

Adds the two cases the PR #230 review named for this file, beside the gestures they extend.

1. **`addWorktree` into the group the worktree already holds publishes nothing.** The guard is a
   bare `return` before any publish (`WorktreeGroupManager.swift:135`), so "no publish" is zero
   `objectWillChange` emissions — the `countingEmissions` helper already in the file
   (`:164`). Place the worktree in the group, note its membership and position, then count the
   emissions of a second `addWorktree` into the same group: 0, with membership and position
   unchanged. Goes beside `testAddWorktreePublishesOnce`.
2. **`removeWorktreeFromGroup` appends to the ungrouped section.** The sibling of
   `testDeleteGroupAppendsItsMembersToTheUngroupedSection` (`:55-68`), which is the shape to copy:
   two ungrouped worktrees seeded at 0 and 1, a third added to a group (position 0 of its own
   section), then `removeWorktreeFromGroup` on the third. Assert its position is 2 — one above the
   ungrouped section's maximum — and that `renderedOrder` shows it last.

**Acceptance criteria**

- Both cases exist, named for the rule they pin, and pass.
- Case 1 asserts emissions, membership and position; case 2 asserts both the position and the
  rendered order.
- No sleep is introduced.

**Verification**

- `./scripts/ci.sh` is green.
- Each case watched failing against its rule reverted, with the failure pasted into the build
  report: for case 1 delete `guard groupNames[wt.id] != name else { return }`
  (`WorktreeGroupManager.swift:135`); for case 2 delete the
  `placement.positions[wt.id] = position` line in `removeWorktreeFromGroup` (`:158`). Restore both
  with `Edit`.

### T5: New case — a status stored against main's id is ignored on the read path

**Files**

- `Tests/WorktreeGroupManagerStatusTests.swift`

**What it does**

`readConfig` never puts main's id into `statuses`, so the rule is driven through two `Worktree`
values over one path: `Worktree.id` is the path, so `setStatus` against a **non-main** worktree at
that path seeds `statuses[path]`, and `status(for:)` against an `isMain: true` worktree at the same
path must still answer `nil`.

The case asserts the accessor **and** the consequence its doc comment names
(`WorktreeGroupManager.swift:219-222`, `:320-323`): under `.status` grouping main stays first.
Give a second, non-main worktree a status that sorts **before** the one seeded against main's path —
`WorktreeStatus.allCases` is `todo, inProgress, inReview, done, onHold`, so e.g. `.todo` on the
other worktree against `.done` on main's path — so the ordering assertion actually discriminates:
if `status(for:)` honoured main's stored status, `partitionedByStatus` would drop main below the
other worktree. Synthetic `/tmp` paths, like the other ordering cases in this file.

**Acceptance criteria**

- `manager.statuses` holds an entry under main's id (proving the seed landed), `status(for: main)`
  is `nil`, and the rendered order under `.status` grouping is main first.
- No sleep is introduced; every assertion is on published state.

**Verification**

- `./scripts/ci.sh` is green.
- Watched failing with `status(for:)` reverted to `statuses[wt.id]`
  (`WorktreeGroupManager.swift:223-225`), with the failure pasted into the build report. Both the
  accessor assertion and the ordering assertion must fail; if only one does, the case is not yet
  pinning the consequence.

### T6: Three new cases in WorktreeGroupPersistenceTests

**Files**

- `Tests/WorktreeGroupPersistenceTests.swift`
- `Tests/TestHelpers.swift` (only if a `GitRepoFixture` setter for repo-level keys is needed)

**What it does**

Adds the three cases that are about config the app did not write, or config it must not write. They
belong here because this suite is already scoped to stored state read back through `GitRepoFixture`.

1. **`reconcile` re-reads both repo-level keys.** `reloadConfig` issues `localValue(groupingKey)`
   and `localValues(groupOrderKey)` as `async let` and applies both
   (`WorktreeGroupManager.swift:374-386`); every existing case that observes either key does so
   through `restartManager()`, a different code path. Seed both keys externally on the fixture
   repo — `clearway.grouping` set to a non-default value and `clearway.groupOrder` given a group
   name — then call `reconcile` on the **existing** manager (no relaunch) and wait for `grouping`
   and `groups` to pick both up. Do not restart the manager: the relaunch is the path this case
   exists to avoid. Repo-level keys are `--local`, so no extension bootstrap is involved and
   decision 9's ordering does not apply. Pass a worktree list that keeps the case honest — an empty
   list, or one real worktree from `repo.addWorktree` — rather than synthetic paths whose seed
   writes can only fail. `GitRepoFixture` today has readers for local keys but no setter; add
   `setLocalValue(_:ofKey:)` and an `--add` form for the multivar beside `setValue(_:ofKey:atWorktree:)`
   if needed.
2. **A non-integer `clearway.position` is tolerated, not fatal.** `readConfig` drops only the
   unparseable value (`WorktreeGroupManager.swift:446`) — the same rule the unrecognised status slug
   already has a case for (`WorktreeGroupManagerStatusTests.swift:65-81`). Following decision 9:
   `repo.enableWorktreeConfig()`, `restartManager()`, store a non-integer `clearway.position` and a
   `clearway.name` against one worktree, then `reconcile`. Assert the name lands, the worktree has no
   position, and it still renders in `renderedOrder`.
3. **A no-op `setGrouping` enqueues no write.** The manager's default grouping is `.group`
   (`WorktreeGroupManager.swift:40`) and `setGrouping` returns before `enqueueWrite` when the value
   is unchanged (`:268-274`). Call `setGrouping(.group)` on the fresh manager, `await settle()`, and
   assert that `extensions.worktreeConfig` is still absent and `clearway.grouping` was never
   written. The case #230 deleted for this rule asserted through `groups.json`, so it has no
   replacement.

**Acceptance criteria**

- All three cases exist, pass, and introduce no sleep.
- Case 1 asserts both repo-level keys, on a manager that was never relaunched.
- Case 3 asserts absence after an awaited signal, never after a poll.

**Verification**

- `./scripts/ci.sh` is green.
- Each case watched failing against its rule reverted, with the three failures pasted into the build
  report: case 1 by removing the `mode`/`registry` reads and their application from `reloadConfig`;
  case 2 by making the position parse force-unwrap or by dropping the whole worktree when the
  position does not parse; case 3 by deleting `guard grouping != self.grouping else { return }`.
  Restore each with `Edit`.

## Checkpoint: after T1–T3

- `grep -c "Task.sleep" Tests/WorktreeGroupManager*.swift Tests/WorktreeGroupPersistenceTests.swift`
  reports 0 for all four files (spec success criterion 1).
- `./scripts/ci.sh` is green.
- The four suites' combined wall time is below the pre-change value; record both numbers.

## Checkpoint: after T4–T6

- The six new cases exist, each with its watched failure in the build report (spec success
  criterion 4).
- `./scripts/ci.sh` is green.
- `git status --porcelain` shows only this change's files, plus the un-gitignored `default.profraw`
  if the app was launched. No probe file, no reverted-guard edit left behind.

## Risks

| Risk | Impact | Mitigation |
| --- | --- | --- |
| A deleted sleep was load-bearing after all, and the case goes flaky rather than failing | High | T2 and T3 leave every `waitFor`/`waitForStoredValue` call in place; only fixed sleeps go. Any case that turns flaky is a finding: report it with the failure rather than restoring the sleep. |
| The reverted-guard proofs leave an edit in `Sources/` | High | Each proof is one `Edit` and one `Edit` back, never `git checkout`. The checkpoint after T4–T6 re-reads `git status --porcelain`. |
| `settle()` awaits a chain captured before the gesture enqueued its write | Medium | `settle()` reads `writeChain` after the gesture has returned, and every gesture assigns the chain synchronously inside `enqueueWrite` before it returns. Call it only after the gesture. |

## Build log

### T1: Expose the settle seam and await it at teardown

| File | State |
| --- | --- |
| `Sources/App/WorktreeGroupManager.swift` | `writeChain` is `private(set) var`, doc comment extended by one clause naming the test base. `reconcile(_:openIds:)` is `@discardableResult` and returns the `Task` it already created. No behavioural hunk: `git diff --stat Sources/` is one file, 6 insertions / 3 deletions, and the only production call site (`ContentView.swift:333`) is unchanged. |
| `Tests/TestHelpers.swift` | `WorktreeGroupManagerGitTestCase` gains `settle(_:)` — awaits `loadTask` then `writeChain`, with an optional target for the suites that build their own managers — and a `tearDown` override that awaits it before dropping `manager` and letting `TempRootTestCase` remove the scratch root. |

The `settle` local binds as `let manager: WorktreeGroupManager? = target ?? self.manager`. Without
the annotation, `??` against the implicitly-unwrapped `self.manager` force-unwraps, which would trap
in `tearDown` after a failed `setUp`.

**Evidence.** No watched failure applies: this task adds no test and changes no behaviour. The seam
it exposes is what T3–T6 prove their rules with; those tasks own the reverted-guard proofs. What is
verified here is that nothing regressed and that the seam is reachable from the test target — both
covered by the gate below, which compiles `settle()` against the widened `writeChain` and runs the
new `tearDown` on every case in the four suites.

**Deviations from the plan.** None.

**Gate.** `./scripts/ci.sh` — passed. 556 tests, 0 failures, 101.6s. `git status --porcelain` shows
only this change's two source files plus the untracked spec and plan, which this commit carries.

**Baseline suite wall times**, for T2's and the T1–T3 checkpoint's comparison (summed case durations
from the T1 `.xcresult`):

| Suite | Before |
| --- | --- |
| `WorktreeGroupManagerTests` | 19.44s |
| `WorktreeGroupPersistenceTests` | 14.58s |
| `WorktreeGroupManagerStatusTests` | 10.20s |
| `WorktreeGroupManagerNameTests` | 10.14s |
| Combined | 54.36s |

### T2: Delete the 44 sleeps in WorktreeGroupManagerTests

| File | State |
| --- | --- |
| `Tests/WorktreeGroupManagerTests.swift` | All 44 `try await Task.sleep` calls deleted. 26 insertions / 78 deletions, and the only two non-signature, non-blank insertions are the `addWorktree` gestures in `testAddWorktreeToGroupPlacesItInGroup` and `testAddMainWorktreeIsNoOp`, relocated below their `let` so the gesture sits next to its assertion. 31 test functions and 56 `XCTAssert` calls before and after; no assertion added, weakened or reordered. |

Every test function in the file is now plain `func test…()`: `grep -n "async\|throws"` returns
nothing, and the only remaining `await` is the word inside `countingEmissions`' doc comment. Five
bodies that already had no `await` or `try` before this task
(`testDeleteGroupAppendsItsMembersToTheUngroupedSection`, `testAddWorktreePublishesOnce`,
`testReorderPublishesOnce`, `testSidebarOrderStableAcrossOpenStateChanges`,
`testADragKeepsTheSlotOfAnUnpositionedRowTheFilterHid`) lost `async throws` too, because the
acceptance criterion is absolute rather than scoped to the bodies a sleep was deleted from.

**Evidence.** No watched failure applies: this task deletes waiting and adds no test. The proof that
each deleted sleep guarded nothing is assumption 2 of the spec — the file never references `repo.`,
`restartManager()` or `reconcile`, so no assertion in it can observe a write landing — plus the gate
below, which runs all 31 cases against the sleep-free bodies. The reverted-guard proofs belong to
T3–T6.

**Deviations from the plan.** None.

**Gate.** `./scripts/ci.sh` — passed. 556 tests, 0 failures, 97.1s. `git status --porcelain` showed
only `Tests/WorktreeGroupManagerTests.swift` before this log was written; no `default.profraw`, as
the app was never launched.

**Suite wall time** (summed case durations from the T2 `.xcresult`):

| Suite | Before | After |
| --- | --- | --- |
| `WorktreeGroupManagerTests` | 19.44s | 17.96s |

5.55s of sleeps came out but the suite dropped only 1.48s, which is decision 6 working as the spec
predicted: the `git config` subprocesses the sleeps used to overlap are now paid at `tearDown`,
where `settle()` awaits the write chain. The remaining time is real git, not waiting. The other
three suites moved too (Persistence 14.58→11.36, Status 10.20→10.07, Name 10.14→9.61) although T2
did not touch them; that is run-to-run variance, and the T1–T3 checkpoint should re-read all four.

### T3: Replace the sleeps in the Status, Name and Persistence suites

| File | State |
| --- | --- |
| `Tests/WorktreeGroupManagerStatusTests.swift` | 11 sleeps deleted, 1 replaced by `await settle()` (`testSetStatusIgnoresTheMainWorktree`). Four cases lost `async throws` — `testNoneGroupingReturnsTheSameOrderAsGroup`, `testStatusGroupingStablyPartitionsTheBaseOrder`, `testStatusGroupingAppliesVisibilityFirst`, `testMatchesContainingGroupName` — plus `testMatchesStatusDisplayName`, which had no sleep but was already `async throws` with neither in its body. 13 cases and every assertion unchanged. |
| `Tests/WorktreeGroupManagerNameTests.swift` | 2 sleeps replaced by `await settle()`, 1 by `await reload.value` on the `Task` `reconcile` now returns. `testMatchesStoredName` drops `async` (it still `try`s `repo.addWorktree`). 11 cases and every assertion unchanged. |
| `Tests/WorktreeGroupPersistenceTests.swift` | The one sleep in `testAProjectWhereTheExtensionCannotBeEnabledShowsNoGroups` replaced by `await settle(first)` — the manager there is a local. Nothing else in the file changed. |

`grep -c "Task.sleep"` is 0 for all four suites, so the T1–T3 checkpoint's first criterion holds.
`git diff Sources/` is empty: T3 is test-side only.

The signature cleanup was applied absolutely per file, as T2 read it — "no test function left `async`
or `throws` without an `await` or `try`" — rather than only to the bodies a sleep came out of. That
is the one reason `testMatchesStatusDisplayName` and `testMatchesStoredName` appear in the diff.

**Evidence.** Each "wrote nothing" case run alone with its rule reverted by `Edit` and restored the
same way. `git diff --stat Sources/` is empty after all four.

1. `testSetStatusIgnoresTheMainWorktree`, with `guard !wt.isMain, let path = wt.path` in `setStatus`
   cut to `guard let path = wt.path`:

   ```
   WorktreeGroupManagerStatusTests.swift:40: error: … testSetStatusIgnoresTheMainWorktree : XCTAssertTrue failed
   WorktreeGroupManagerStatusTests.swift:41: error: … testSetStatusIgnoresTheMainWorktree : XCTAssertNil failed: "true" - a main-worktree status must not even bootstrap the extension
   Executed 1 test, with 2 failures (0 unexpected) in 0.349 seconds
   ```

2. `testSetNameIgnoresTheMainWorktree`, with the same guard cut from `setName`:

   ```
   WorktreeGroupManagerNameTests.swift:92: error: … testSetNameIgnoresTheMainWorktree : XCTAssertTrue failed
   WorktreeGroupManagerNameTests.swift:94: error: … testSetNameIgnoresTheMainWorktree : XCTAssertNil failed: "true" - a main-worktree name must not even bootstrap the extension
   Executed 1 test, with 2 failures (0 unexpected) in 0.352 seconds
   ```

3. `testSetNameEmptyOnAWorktreeWithNoStoredNameChangesNothing`. The plan named one guard here — the
   `stored == nil` early path. **Deleting it alone leaves the case green**:

   ```
   Test Case '…testSetNameEmptyOnAWorktreeWithNoStoredNameChangesNothing' passed (0.262 seconds).
   ```

   The rule is two guards in series: `WorktreeGroupManager.setName`'s
   `guard names[wt.id] != stored else { return }` stops the write being enqueued, and
   `WorktreeConfigStore.set`'s nil branch returns `true` on `case .off` without bootstrapping, so
   even an enqueued clear writes nothing. Reverting both — the manager guard deleted and the store's
   nil branch replaced by `guard await enableExtension() else { return false }` — is red, on both
   assertions, `core.bare` relocation included:

   ```
   WorktreeGroupManagerNameTests.swift:82: error: … : XCTAssertNil failed: "true"
   WorktreeGroupManagerNameTests.swift:83: error: … : XCTAssertEqual failed: ("nil") is not equal to ("Optional("false")")
   Executed 1 test, with 2 failures (0 unexpected) in 0.647 seconds
   ```

4. `testAProjectWhereTheExtensionCannotBeEnabledShowsNoGroups` **has no reverted-guard proof, and
   cannot have one.** Its root is a bare `NSTemporaryDirectory()` folder that is not a repository and
   is not inside one, so no `git config --local` write can ever land there whatever guard is removed.
   The revert the plan named — `replaceLocalValues`' `guard await enableExtension()` and the
   `unsetAllLocal` guard behind it, both reduced to discarded calls — is green:

   ```
   Test Case '…testAProjectWhereTheExtensionCannotBeEnabledShowsNoGroups' passed (0.254 seconds).
   ```

   `enableExtension` cannot get past `git rev-parse --git-common-dir` there
   (`WorktreeConfigStore.swift:321`), and neither `--unset-all` nor `--add` can either, so the case's
   `second.groups.isEmpty` is unfalsifiable by construction rather than under-guarded. What
   `settle(first)` buys is spec decision 6: the `defer` that removes `plainRoot` no longer races the
   queued subprocesses. That `settle` genuinely waits for an enqueued write is proved by proofs 1–3,
   which are the same method: each read `extensions.worktreeConfig` back as `"true"` on the line
   after `settle()`, which only a completed `git config` subprocess can produce.

`testReconcileRightAfterSetNameDoesNotRaceTheWrite` needs no revert of its own — it already had a
watched failure when it was written, and `await reload.value` is strictly stronger than the 300 ms it
replaces: `waitForStoredName` returns the moment the write lands, which can be before `reloadConfig`
has published, and the reload `Task` is awaited to completion rather than outlasted.

**Deviations from the plan.** Two, both in the verification step rather than the change:
proof 3 needs a second revert in `WorktreeConfigStore` because the rule is two guards in series, and
proof 4 does not exist because the case is unfalsifiable. Neither changes what T3 edits.

**Gate.** `./scripts/ci.sh` — passed. 556 tests, 0 failures, 92.6s. `git status --porcelain` shows
only this change's three test files plus the plan; no `default.profraw`, as the app was never
launched, and `git diff Sources/` is empty.

**Checkpoint: after T1–T3.**

| Suite | Baseline (T1) | After T3 |
| --- | --- | --- |
| `WorktreeGroupManagerTests` | 19.44s | 15.61s |
| `WorktreeGroupPersistenceTests` | 14.58s | 11.49s |
| `WorktreeGroupManagerStatusTests` | 10.20s | 8.87s |
| `WorktreeGroupManagerNameTests` | 10.14s | 9.19s |
| Combined | 54.36s | 45.16s |

Below the recorded baseline, and by less than the 8.4 s sleep census, for the reason T2 recorded: the
git-config subprocesses the sleeps used to overlap are now paid at the awaited teardown.
