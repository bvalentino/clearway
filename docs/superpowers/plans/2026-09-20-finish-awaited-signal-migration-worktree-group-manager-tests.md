# Finish the awaited-signal migration in the WorktreeGroupManager suites

**Date:** 2026-09-20
**Base:** b4369a5 (`Split buttons for Run and Open in (#237)`)

Breaks down `docs/superpowers/specs/2026-09-20-finish-awaited-signal-migration-worktree-group-manager-tests.md`.
Every design decision is settled there; this file only orders the work and says how each piece is
verified.

## Architecture decisions carried from the spec

1. A bare `reconcile` followed by a poll becomes `await manager.reconcile(…).value` and a plain
   `XCTAssert`. `reconcile` publishes everything before its `Task` ends — `reloadConfig` assigns
   `grouping`, `groups`, `placement`, `names` and `statuses`, then `seedPositions` mutates
   `placement` synchronously — so the value the poll waited for is correct on the next line.
2. The awaited form is **stronger** than the poll it replaces, not weaker: a poll passes the
   instant the value appears anywhere inside its 5 s window, including before the gesture; the
   awaited form asserts once, at a defined point.
3. The two cases whose assertions read git back rather than published state
   (`testTheStoredOrderSurvivesContentViewsReloadSequence`, `testRemovingAWorktreeLeavesNothingBehind`)
   follow the awaited `reconcile` with `await settle()`, the test base's one idiom for "the
   manager's in-flight writes have landed".
4. `WorktreeGroupManager` gains `private(set) var reconcileTask: Task<Void, Never>?`, assigned in
   `reconcile`, so `settle()` covers a reconcile a body dropped. That is the whole production diff.
   `reconcile` keeps `@discardableResult` and its return type, so no call site changes.
5. `settle()` awaits `loadTask`, then `reconcileTask`, then `writeChain` — **in that order**, so the
   `writeChain` it samples is the one the reconcile's seed write left behind.
6. `reconcileTask` does **not** chain on the previous reconcile the way `writeChain` chains on the
   previous write. Chaining would serialise overlapping reconciles, which is behavioural. The slot
   holds the most recent `Task`; that limit is stated in the property's doc comment rather than
   engineered around.
7. The strong `self` capture in `reconcile`'s `Task` is accepted. It is temporary, not a leak: the
   `Task` releases its captures when it completes. `[weak self]` would change what a reconcile does
   when the manager is released mid-flight, which is behavioural.
8. The three helpers that read git back — `waitForStoredValue` (`Tests/TestHelpers.swift:278`),
   `waitForRegistry` and `waitForLocalValue` (`Tests/WorktreeGroupPersistenceTests.swift:379`, `:394`)
   — each open with `await settle()`. `waitFor` itself does **not**: it is the primitive that also
   polls published state and `recordedWriteAlerts`, and settling inside it would push the whole
   write chain into waits that are not about git.
9. The poll loop stays inside those three helpers. After the settle the first read already matches,
   so the loop costs one `git config` and never sleeps; keeping it means a helper called before its
   gesture still behaves as it does today rather than failing outright.
10. `waitForPublishedName` and `waitForPublishedStatuses` are deleted once their only callers are
    converted. `waitForStoredName` and `waitForStoredStatus` keep their callers and stay — they
    delegate to `waitForStoredValue`, so they inherit the settle with no edit of their own.
11. No assertion is weakened, dropped or reordered. Each of the four suites holds the same number of
    `XCTAssert` calls before and after, plus the new case's.

## Dependency graph

```
T1  reconcileTask + settle order + waitForStoredValue settles
 ├── T2  WorktreeGroupPersistenceTests: four sites, two local helpers, the new settle case
 ├── T3  WorktreeGroupManagerStatusTests: three sites, waitForPublishedStatuses deleted
 └── T4  WorktreeGroupManagerNameTests: three sites, waitForPublishedName deleted
```

T2, T3 and T4 are independent of each other once T1 lands; each edits one file no other task
touches. T1 must land first: T2's new case cannot exist without `reconcileTask`, and all three
conversion tasks assert on a `settle()` that already covers the reconcile.

The regression check after every task is `./scripts/ci.sh` — the only runner of the test suite, and
the only thing that regenerates the Xcode project.

Every reverted-guard proof is made with `Edit` on the source file and restored with `Edit`. Never
`git checkout`, never `git stash`. After each restore, confirm `git diff --stat Sources/` matches
what the task expects before moving on.

## Task list

### T1: Store the reconcile Task and make settle await it

**Files**

- `Sources/App/WorktreeGroupManager.swift`
- `Tests/TestHelpers.swift`

**What it does**

1. Add beside `loadTask` (`WorktreeGroupManager.swift:60`):

   ```swift
   /// The most recent `reconcile`, awaited by the test base so a case that dropped the `Task`
   /// still settles. Not chained: a second `reconcile` fired before the first finished replaces
   /// this slot and leaves the first unawaited.
   private(set) var reconcileTask: Task<Void, Never>?
   ```

2. `reconcile` (`:296-301`) binds the `Task` it already creates, assigns it to `reconcileTask`, and
   returns it. `@discardableResult` and the return type stay. The body inside the `Task` is
   untouched — `await self.reloadConfig(for:)` then `self.seedPositions(for:openIds:)`, in that
   order.
3. `settle()` (`Tests/TestHelpers.swift:232`) awaits `reconcileTask` between `loadTask` and
   `writeChain`. Its doc comment loses the paragraph beginning "The chain is sampled once…" — the
   caveat about `seedPositions` enqueuing in the same continuation, which `reconcileTask` retires —
   and gains one clause naming the reconcile as the third thing awaited.
4. `waitForStoredValue` (`:278`) opens with `await settle()` before its `waitFor` call, with a one-
   line comment saying why: it reads git back, so the manager's queued writes must have landed.

**Acceptance criteria**

- `reconcileTask` is `private(set) var`, assigned on exactly one line, and reachable from the test
  target.
- `settle()` awaits three things in the order `loadTask`, `reconcileTask`, `writeChain`.
- `Sources/App/ContentView.swift:349` is unchanged and still compiles; `git diff --stat Sources/`
  shows one file and no behavioural hunk.
- No existing test case is edited in this task, and no test case is added.

**Verification**

- `./scripts/ci.sh` is green, with the same set of tests passing as before the task.
- Record the four suites' wall times from this run's `.xcresult` as the **baseline** for the final
  checkpoint (see "Recording wall times" below). This is the first run of the build phase, which
  spec criterion 8 names.
- No watched failure applies: this task adds no test and changes no behaviour. The proof that
  `reconcileTask` is load-bearing is T2's new case, which is watched failing with the property
  reverted.

### T2: Convert the four sites in WorktreeGroupPersistenceTests

**Files**

- `Tests/WorktreeGroupPersistenceTests.swift`

**What it does**

1. Converts four sites. Each `manager.reconcile(…)` becomes `await manager.reconcile(…).value`, and
   the `waitFor` that follows becomes a plain `XCTAssertEqual` on the same expression with the same
   message:

   | Case | `reconcile` | Poll replaced by | Also |
   | --- | --- | --- | --- |
   | `testMembershipAndPositionSurviveARelaunch` | `:34` | `XCTAssertEqual(renderedOrder([alpha, bravo]), [bravo.id, alpha.id], …)` | — |
   | `testTheStoredOrderSurvivesContentViewsReloadSequence` | `:58` | same shape | `await settle()` after the awaited reconcile — the case reads `clearway.position` back off git |
   | `testAMembershipNamingAnUnlistedGroupRendersUngrouped` | `:248` | `XCTAssertEqual(manager.name(for: ghosted), "Ghosted", …)` | — |
   | `testRemovingAWorktreeLeavesNothingBehind` | `:288` | `XCTAssertEqual(manager.groupNames, [staying.id: "Group"], …)` | `await settle()` — the case reads three `clearway.*` keys back off git |

   The `describing:` string each poll carried becomes the `XCTAssert`'s message, so a failure still
   names what it was waiting for.
2. `waitForRegistry` (`:379`) and `waitForLocalValue` (`:394`) each open with `await settle()`,
   matching `waitForStoredValue` (T1). Do not move either onto the base class.
3. Adds one case pinning that `settle()` covers a reconcile no test awaited. Recommended placement:
   the end of the `// MARK: - Relaunch` section, after
   `testTheStoredOrderSurvivesContentViewsReloadSequence`, since that is where `reconcile` and a
   stored position already live. The shape:

   - `let path = try repo.addWorktree(branch: "alpha")`, `let alpha = makeWorktree(...)`.
   - Fire `manager.reconcile([alpha], openIds: [])` **bare**, discarding the `Task`.
   - `await settle()` and nothing else.
   - `XCTAssertEqual(try repo.value(ofKey: WorktreeConfigStore.positionKey, atWorktree: path), "0", …)`
     read straight off git, with **no** `waitFor` and no `waitForStoredValue` — a poll would hide
     exactly the defect the case exists for.

   `seedPositions` gives a lone ungrouped worktree slot 0: `maxPosition(inSectionNamed: nil)` is
   `nil` for an empty section, so the slot is `(-1) + 1`.

**Acceptance criteria**

- The four sites await the returned `Task`; the two named above also `await settle()`.
- `waitForRegistry` and `waitForLocalValue` open with `await settle()`.
- The new case fires a bare `reconcile`, awaits only `settle()`, and reads git with no poll.
- The file's `XCTAssert` count is its pre-task count plus the new case's, and no existing assertion
  is weakened, dropped or reordered.

**Verification**

- `./scripts/ci.sh` is green.
- Five watched failures, each run alone with the rule reverted by `Edit` and restored the same way,
  each failure pasted into the build log:

  | Case | Revert |
  | --- | --- |
  | new settle case | `reconcileTask`'s assignment in `reconcile` (T1's line) — `settle()` then returns before the seed's first `git config`, so the read is `nil` |
  | `testMembershipAndPositionSurviveARelaunch` | the `mutatePlacement` block in `reloadConfig` (`WorktreeGroupManager.swift:402-405`) |
  | `testTheStoredOrderSurvivesContentViewsReloadSequence` | swap the two statements inside `reconcile`'s `Task` (`:298-299`) so the seed runs before the reload |
  | `testAMembershipNamingAnUnlistedGroupRendersUngrouped` | the `listed.contains` filter (`:400-401`) |
  | `testRemovingAWorktreeLeavesNothingBehind` | the `mutatePlacement` block (`:402-405`) |

- If a named revert leaves a case green, that is a finding, not a licence to skip the proof: find
  the rule the converted assertion actually pins, prove it, and record the deviation in the build
  log the way the prior plan's T3 proof 3 did.
- `git diff --stat Sources/` is empty after every restore.

### T3: Convert the three sites in WorktreeGroupManagerStatusTests

**Files**

- `Tests/WorktreeGroupManagerStatusTests.swift`

**What it does**

1. Converts three sites to `await manager.reconcile([alive], openIds: []).value`:

   | Case | `reconcile` | Poll replaced by |
   | --- | --- | --- |
   | `testReconcilePopulatesStatusesFromWorktreeConfig` | `:82` | `XCTAssertEqual(manager.statuses, [alive.id: .inReview], "published statuses")` |
   | `testReconcileDropsAnUnrecognisedStatusSlugAndKeepsTheName` | `:97` | `XCTAssertEqual(manager.name(for: alive), "Stored name", …)`, keeping the existing `XCTAssertTrue(manager.statuses.isEmpty)` on the line after |
   | `testReconcileDropsAnAbsentWorktree` | `:117` | `XCTAssertEqual(manager.statuses, [alive.id: .todo], "published statuses")` |

2. Deletes `waitForPublishedStatuses` (`:277`), which has no callers left. `waitForStoredStatus`
   (`:262`) stays — it still has a caller and delegates to `waitForStoredValue`.

**Acceptance criteria**

- No bare `manager.reconcile` remains in the file.
- `grep -n "waitForPublishedStatuses" Tests/` returns nothing.
- The file holds the same number of `XCTAssert` calls as before, counting each deleted poll's
  assertion as the plain assert that replaced it.

**Verification**

- `./scripts/ci.sh` is green.
- Three watched failures, each run alone, each pasted into the build log:

  | Case | Revert |
  | --- | --- |
  | `testReconcilePopulatesStatusesFromWorktreeConfig` | delete `if reloaded.statuses != statuses { statuses = reloaded.statuses }` (`WorktreeGroupManager.swift:407`) |
  | `testReconcileDropsAnUnrecognisedStatusSlugAndKeepsTheName` | in `readConfig` (`:449-452`), publish the slug regardless: `reloaded.statuses[id] = WorktreeStatus(rawValue: slug) ?? .todo`. Deleting the guard outright does not compile, since `WorktreeStatus(rawValue: "bogus")` is `nil`. The name assertion must stay green — only `statuses.isEmpty` fails |
  | `testReconcileDropsAnAbsentWorktree` | delete the same `statuses` assignment (`:407`): the published map then keeps `dead` as well as `alive` |

- `git diff --stat Sources/` is empty after every restore.

### T4: Convert the three sites in WorktreeGroupManagerNameTests

**Files**

- `Tests/WorktreeGroupManagerNameTests.swift`

**What it does**

1. Converts three sites to `await manager.reconcile([wt], openIds: []).value`:

   | Case | `reconcile` | Poll replaced by |
   | --- | --- | --- |
   | `testReconcilePopulatesNamesFromConfigAndDropsAClearedOne` | `:109` | `XCTAssertEqual(manager.name(for: wt), "Stored name", …)` |
   | (same case, second half) | `:113` | `XCTAssertNil(manager.name(for: wt), …)` |
   | `testReconcileDropsAWhitespaceOnlyStoredName` | `:130` | `XCTAssertNil(manager.name(for: wt), …)`, keeping the existing `XCTAssertTrue(manager.names.isEmpty)` after it |

   The second half of the first case is the one worth reading carefully: the poll was for `nil`
   after an external `unsetValue`, which a poll cannot distinguish from "the reload has not run
   yet". The awaited form is what makes it a real assertion.
2. Deletes `waitForPublishedName` (`:181`), which has no callers left. `waitForStoredName` (`:166`)
   stays.
3. `testReconcileRightAfterSetNameDoesNotRaceTheWrite` (`:144`) is **not** converted — it already
   binds the `Task` and awaits it. Note that its `waitForStoredName` call now settles first (T1),
   which awaits the reload before the stored-name wait rather than after it. Both waits still
   happen and the final `XCTAssertEqual(manager.name(for: wt), "Fresh name")` is unchanged; if this
   case turns flaky, that is a finding to report, not a reason to restore a sleep.

**Acceptance criteria**

- No bare `manager.reconcile` remains in the file.
- `grep -n "waitForPublishedName" Tests/` returns nothing.
- `testReconcileRightAfterSetNameDoesNotRaceTheWrite` is byte-identical to its pre-task form.
- The file holds the same number of `XCTAssert` calls as before.

**Verification**

- `./scripts/ci.sh` is green.
- Two watched failures, each run alone, each pasted into the build log:

  | Case | Revert |
  | --- | --- |
  | `testReconcilePopulatesNamesFromConfigAndDropsAClearedOne` | delete `if reloaded.names != names { names = reloaded.names }` (`WorktreeGroupManager.swift:406`) |
  | `testReconcileDropsAWhitespaceOnlyStoredName` | in `readConfig` (`:444-446`), drop the trim and the empty check: `reloaded.names[id] = values[WorktreeConfigStore.nameKey]`. The published name is then `"   "` |

- `git diff --stat Sources/` is empty after every restore.

## Checkpoint: after T1–T4

- `grep -rn "manager.reconcile" Tests/` shows no call whose result is discarded, except the one in
  T2's new case (spec criterion 1).
- `grep -rn "waitForPublishedName\|waitForPublishedStatuses" Tests/` returns nothing (criterion 7).
- All three git-reading helpers open with `await settle()` (criterion 2).
- Nine converted cases and one new case each carry a watched failure in the build log (criteria 5
  and 6).
- `./scripts/ci.sh` is green, exit 0.
- The four suites' combined wall time is recorded against the T1 baseline (criterion 8).
- `git status --porcelain` shows only this change's files, plus the un-gitignored `default.profraw`
  if the app was launched. `git diff Sources/` shows only `reconcileTask` — no reverted guard left
  behind (criterion 9).

**Recording wall times.**

`ci.sh` passes no `-resultBundlePath`, so the bundle is the newest `.xcresult` under
`~/Library/Developer/Xcode/DerivedData/Clearway-*/Logs/Test/`. Sum the case durations per suite for
`WorktreeGroupManagerTests`, `WorktreeGroupPersistenceTests`, `WorktreeGroupManagerStatusTests` and
`WorktreeGroupManagerNameTests`, and record the case count beside each. Report the combined figure
for T1's run and for the last run of the build phase.

A modest reduction is the expectation, not a target: the ten polls each cost at most one 20 ms tick
on a healthy run, so the saving is small. The point of the change is determinism, and a combined
time that moves within run-to-run variance is a pass, not a finding — say so rather than chasing it.

## Risks

| Risk | Impact | Mitigation |
| --- | --- | --- |
| A converted assertion is now evaluated at a point the poll used to slide past, and the case goes flaky | High | Each converted case is watched failing against its production rule, which proves the assertion discriminates. A case that turns flaky against correct code is a finding: report it with the failure rather than restoring the poll. |
| `settle()` inside `waitForStoredValue` changes the ordering of a case that was not converted | Medium | Only `testReconcileRightAfterSetNameDoesNotRaceTheWrite` reconciles before a stored-value wait. T4 names it, leaves it unedited, and states what the reordering means. |
| A reverted-guard proof is left in `Sources/` | High | Each proof is one `Edit` and one `Edit` back. Every task's verification ends with `git diff --stat Sources/`, and the checkpoint re-reads `git status --porcelain`. |
| `reconcileTask`'s strong `self` capture reads as a leak in review | Low | Spec decision 8 settled it; the property's doc comment carries the limit, and the `Task` releases its captures on completion. |

## Build log

Each build agent appends its entry here under a `### T<n>: <name>` heading: what changed per file,
the watched failures with their pasted output, any deviation from this plan, and the gate result.

### T1: Store the reconcile Task and make settle await it

**What landed**

| File | State |
| --- | --- |
| `Sources/App/WorktreeGroupManager.swift` | `private(set) var reconcileTask: Task<Void, Never>?` added beside `loadTask`, with the doc comment from the plan. `reconcile` binds the `Task` it already creates, assigns it to the slot, and returns it; `@discardableResult`, the return type and the `Task` body are unchanged. `+8 −1`, no behavioural hunk. |
| `Tests/TestHelpers.swift` | `settle()` awaits `loadTask`, then `reconcileTask`, then `writeChain`. Its doc comment loses the "The chain is sampled once…" paragraph and gains the clause naming the reconcile as the second thing awaited and why it precedes the chain sample. `waitForStoredValue` opens with `await settle()` and a one-line comment. |
| `Sources/App/ContentView.swift` | Unchanged. `groupManager.reconcile(…)` at `:349` still discards the result and still compiles. |

**Evidence**

No watched failure applies. This task adds no test and changes no behaviour; the plan states the
proof that `reconcileTask` is load-bearing is T2's new case, watched failing with this task's
assignment reverted.

**Deviations**

None.

**Gate**

`./scripts/ci.sh` — green. `Executed 676 tests, with 0 failures (0 unexpected) in 105.547 seconds`,
`Test Succeeded`, `==> CI passed.`

**Baseline wall times** (first run of the build phase), summed per case from
`Test-ClearwayTests-2026.09.20_18-56-01--0300.xcresult`. The suite nodes carry no duration of their
own, so these are per-case sums and exclude per-suite fixture overhead; the final checkpoint must
be measured the same way to compare.

| Suite | Cases | Wall time |
| --- | --- | --- |
| `WorktreeGroupManagerTests` | 33 | 15.810s |
| `WorktreeGroupPersistenceTests` | 17 | 15.820s |
| `WorktreeGroupManagerStatusTests` | 14 | 8.900s |
| `WorktreeGroupManagerNameTests` | 11 | 8.830s |
| **Combined** | **75** | **49.360s** |

### T2: Convert the four sites in WorktreeGroupPersistenceTests

**What landed**

| File | State |
| --- | --- |
| `Tests/WorktreeGroupPersistenceTests.swift` | Four sites now `await manager.reconcile(…).value` and assert once. `testTheStoredOrderSurvivesContentViewsReloadSequence` and `testRemovingAWorktreeLeavesNothingBehind` follow the awaited reconcile with `await settle()`. Each poll's `describing:` string became the plain assert's message. `waitForRegistry` and `waitForLocalValue` each open with `await settle()` and the same one-line comment `waitForStoredValue` carries. One new case, `testSettleCoversAReconcileNoBodyAwaited`, at the end of the Relaunch section. |
| `Sources/` | Unchanged. `git diff --stat Sources/` is empty. |

`XCTAssert` count 35 → 40: the four converted polls each moved their assertion out of `waitFor`'s
body into the file, plus the new case's one. Nothing weakened, dropped or reordered. The only bare
`manager.reconcile` left in the file is the new case's (`:82`); the three remaining `waitFor` calls
are the write-alert wait and the two helpers, none paired with a reconcile.

**Evidence** — five watched failures, each run alone with
`xcodebuild … -only-testing:ClearwayTests/WorktreeGroupPersistenceTests/<case> test`, the revert made
with `Edit` and restored with `Edit`, `git diff --stat Sources/` empty after each restore.

1. New settle case, `reconcileTask = task` removed from `reconcile`:

```
WorktreeGroupPersistenceTests.swift:85: error: testSettleCoversAReconcileNoBodyAwaited :
XCTAssertEqual failed: ("nil") is not equal to ("Optional("0")") -
the reconcile's seed write must have landed by the time settle() returns
```

2. `testMembershipAndPositionSurviveARelaunch`, `mutatePlacement` block in `reloadConfig` removed:

```
WorktreeGroupPersistenceTests.swift:36: error: XCTAssertEqual failed:
("[…/alpha", "…/bravo"]") is not equal to ("[…/bravo", "…/alpha"]") - rendered order after a relaunch
```

3. `testTheStoredOrderSurvivesContentViewsReloadSequence`, the two statements inside `reconcile`'s
   `Task` swapped so the seed runs first:

```
WorktreeGroupPersistenceTests.swift:63: error: XCTAssertEqual failed:
("[…/alpha", "…/bravo"]") is not equal to ("[…/bravo", "…/alpha"]") - rendered order after a relaunch
WorktreeGroupPersistenceTests.swift:68: error: XCTAssertEqual failed:
("Optional("1")") is not equal to ("Optional("0")") -
the seed must not renumber a worktree git already holds a position for
```

4. `testAMembershipNamingAnUnlistedGroupRendersUngrouped`, the `listed.contains` filter removed:

```
WorktreeGroupPersistenceTests.swift:273: error: XCTAssertNil failed: "Ghost" -
the membership names no listed group
WorktreeGroupPersistenceTests.swift:275: error: XCTAssertEqual failed: ("[]") is not equal to ("[…/ghosted"]")
```

5. `testRemovingAWorktreeLeavesNothingBehind`, `mutatePlacement` block removed:

```
WorktreeGroupPersistenceTests.swift:311: error: XCTAssertEqual failed:
("[…/staying": "Group", "…/going": "Group"]") is not equal to ("[…/staying": "Group"]") - published memberships
WorktreeGroupPersistenceTests.swift:312: error: XCTAssertEqual failed:
("[…/going": 0, "…/staying": 1]") is not equal to ("[…/staying": 1]")
```

**Deviations**

One addition, no departure. Proof 4's named revert turns the case red at `:273`/`:275` but leaves
the **converted** assertion at `:272` green — the `listed.contains` filter is not the rule that
assertion pins. A sixth run was made to prove the converted line discriminates, reverting
`if reloaded.names != names { names = reloaded.names }` (`WorktreeGroupManager.swift:406`, T4's
revert, restored immediately):

```
WorktreeGroupPersistenceTests.swift:272: error: XCTAssertEqual failed:
("nil") is not equal to ("Optional("Ghosted")") - published name for …/ghosted
```

The new case is placed directly after `testTheStoredOrderSurvivesContentViewsReloadSequence` rather
than after the Relaunch section's last case, which is where the plan's two phrasings differ; this is
the more specific of the two and keeps it beside the other reconcile-and-position cases.

**Gate**

`./scripts/ci.sh` — green, exit 0. `Executed 677 tests, with 0 failures (0 unexpected) in 109.953
seconds`, `Test Succeeded`, `==> CI passed.` (676 before this task; the new case is the 677th.)
