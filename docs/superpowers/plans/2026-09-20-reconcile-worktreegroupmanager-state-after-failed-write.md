# Plan: Reconcile WorktreeGroupManager state after a failed git-config write

Breaks down `docs/superpowers/specs/2026-09-20-reconcile-worktreegroupmanager-state-after-failed-write.md`.

**Date:** 2026-09-20
**Base:** b4369a5 (`Split buttons for Run and Open in (#237)`)

## Architecture decisions carried from the spec

- After a refused `git config` write the manager **re-reads what git holds** for the affected
  worktrees and publishes that. It never reverts the optimistic mutation in memory: a gesture is
  several independent writes, so a half-applied gesture can only be described by reading git
  (decision 1).
- The reconcile runs in **its own `Task`, outside the write chain**, and reaches git through the
  existing `reloadConfig`, including its `guard writeChain == chain else { continue }` race guard.
  Running it inside the chain would publish git's older value over a gesture that has already
  published and is still queued (decision 2).
- It re-reads **both repo-level keys plus every worktree the manager has published any `clearway.*`
  value for, unioned with the paths the failed writes named**. The union is load-bearing: a refused
  `setName(nil, …)` on a worktree with no group and no position names an id no published map holds
  (decision 3).
- A failed write reaches the manager **through `enqueueWrite`**, the one door every config write
  already goes through. Its `work` closure comes to *return* what it could not land, and
  `enqueueWrite`'s own `Task` starts the reconcile when that is non-empty. Making it the closure's
  return type rather than an opt-in helper is what stops a future write site forgetting. The write
  body still captures no manager; the one `[weak self]` lives in `enqueueWrite` (decision 4).
- **Every write on the chain triggers it**, `clearway.name` and `clearway.status` included. No new
  log line is added for those two — decision 13 of the #236 spec still stands (decision 5).
- The reconcile **does not seed positions** afterwards: it has neither the live worktree list nor
  the open ids, and the next `reconcile(_:openIds:)` seeds on the usual terms (decision 6).
- **The alert and log copy from #236 do not change.** Two doc comments that promise the opposite of
  this change are corrected (decision 8).
- The reconcile is exposed as a `private(set) var` handle beside `writeChain` and `loadTask`, and
  `WorktreeGroupManagerGitTestCase.settle()` awaits it after the chain. Nothing in production reads
  it (decision 9).
- The reconcile lives **in `WorktreeGroupManager.swift`** — it publishes `private(set)` state an
  extension in another file cannot set. Room is made by moving the two pure ordering statics out
  (decision 10).
- A reconcile whose own read fails **keeps what is published**, which is `readConfig`'s and
  `reloadConfig`'s existing policy. A repo-wide git outage therefore reads as "holds nothing";
  pre-existing, accepted, not fixed here (decision 11).
- The optimistic publish is unchanged: the sidebar still shows a gesture the instant it is made
  (decision 12). A refused write is **not retried** (decision 13).
- Out of scope: retrying a refused write, any change to `WorktreeConfigStore`, the #236 log and
  alert strings, and pessimistic publishing.

## Dependency graph

```
T1 (move the two ordering statics into their own file)
      │
      v
T2 (refusals returned through enqueueWrite; the reconcile task; settle())
      │
      v
T3 (persistence cases for the four behaviours)
```

Strictly sequential. T1 and T2 edit the same file and T1 is what keeps it under the `file_length`
warning; T3 asserts on the API T2 adds.

### T1: Move the ordering statics into their own file

**Files**

- `Sources/App/WorktreeGroupManager+Ordering.swift` (new)
- `Sources/App/WorktreeGroupManager.swift`

**What it does**

Moves `repositioned(_:with:)` and `reassignedPositions(section:newOrder:)` — the `// MARK: -
Ordering` block at `Sources/App/WorktreeGroupManager.swift:538-585` — verbatim, with their
documentation comments intact, into a new `extension WorktreeGroupManager` in
`Sources/App/WorktreeGroupManager+Ordering.swift`. Both stay `static` and internal; neither touches
anything private, so no access level changes and no call site changes. The `// MARK: - Ordering`
heading goes with them.

Nothing else moves and no behaviour changes. `Tests/WorktreeGroupManagerTests.swift:468-506` calls
both by type name and must stay untouched.

**Acceptance criteria**

- `WorktreeGroupManager.repositioned` and `WorktreeGroupManager.reassignedPositions` are declared
  only in the new file, with their doc comments and bodies byte-identical to what was removed.
- `Sources/App/WorktreeGroupManager.swift` is at or below 620 lines.
- No call site anywhere in `Sources/` or `Tests/` changed.

**Verification**

- `./scripts/ci.sh` green — it runs `xcodegen generate`, without which the new file is invisible to
  the build; both targets glob their directory, so `project.yml` needs no edit.
- `swiftlint lint --quiet` reports zero errors and no new warnings.
- `git diff --stat` shows the manager shrinking by the number of lines the new file gained.

### T2: Report refused writes through `enqueueWrite` and reconcile from git

**Files**

- `Sources/App/WorktreeGroupManager.swift`
- `Sources/App/WorktreeGroupWriteAlert.swift`
- `Tests/TestHelpers.swift`

**What it does**

**1. A refusal value.** Adds a small `Sendable` type naming what one write body could not land —
the worktree paths git refused, and whether a repo-level key was refused. Declare it at **file
scope** in `WorktreeGroupManager.swift`, not nested inside the `@MainActor` class, so the
nonisolated write bodies can construct it with no isolation question. Shape:

```swift
struct WorktreeConfigWriteRefusals: Sendable, Equatable {
    /// The worktrees whose own `clearway.*` write git refused, by path.
    var paths: Set<String> = []
    /// A repo-level key — `clearway.grouping` or `clearway.groupOrder` — that was refused. It
    /// names no worktree, so this is the only way such a refusal can reach the reconcile.
    var repoLevel = false

    var isEmpty: Bool { paths.isEmpty && !repoLevel }
}
```

**2. `enqueueWrite`'s contract.** Its closure becomes
`@escaping @Sendable (WorktreeConfigStore) async -> WorktreeConfigWriteRefusals`, and its `Task`
gains the one `[weak self]`:

```swift
writeChain = Task { [weak self] in
    await previous?.value
    let refusals = await work(configStore)
    guard !refusals.isEmpty, let self else { return }
    self.reconcileAfterRefusedWrite(refusals)
}
```

The `guard` before touching `self` is what makes "a gesture whose writes all land triggers no
reconcile and no extra `git config` read" true. The body still captures no manager.

**3. The seven write bodies report.** `Self.write(_:forKey:worktreeAt:in:)` returns the `Bool` it
already computes (it keeps its existing log line, unchanged), and every site carries the result
out:

- `addWorktree` (`:149`) and `removeWorktreeFromGroup` (`:168`) — both writes are still attempted;
  the path is reported if either is refused.
- `setStatus` (`:244`) and `setName` (`:273`) — the `configStore.set` result is no longer dropped.
  It reports the path. **No log line is added** for these two.
- `setGrouping` (`:281`) — keeps its log line and reports `repoLevel = true`.
- `writeRegistry` (`:514`) — the member abandon reports that member's path (after its existing log
  line and its awaited alert, still in that order, still returning at the first failure); the
  `replaceLocalValues` failure reports `repoLevel = true` after its existing log line and alert.
- `writePositions` (`:643`) — reports every refused path; the loop still continues to the rest.

**4. `reloadConfig` takes its targets.** Its signature becomes
`private func reloadConfig(for targets: [(id: String, path: String)]) async`; the `compactMap` that
built them from worktrees (`:377-380`) moves into `reconcile(_:openIds:)`'s `Task`, which is its
only production caller. Nothing else about the method changes.

**5. The reconcile and its handle.** A `private(set) var reconcileTask: Task<Void, Never>?` beside
`writeChain` and `loadTask`, and:

```swift
private func reconcileAfterRefusedWrite(_ refusals: WorktreeConfigWriteRefusals) {
    let ids = Set(groupNames.keys)
        .union(positions.keys)
        .union(names.keys)
        .union(statuses.keys)
        .union(refusals.paths)
    let targets = ids.map { (id: $0, path: $0) }
    let previous = reconcileTask
    reconcileTask = Task {
        await previous?.value
        await self.reloadConfig(for: targets)
    }
}
```

A member's id **is** its path (`Worktree.id` is `path ?? branch ?? ""`, and every writer of those
four maps refuses a worktree with no path), so the targets need no lookup, and main is never a key
in any of them.

Two properties the build must preserve:

- **The chain task must never await the reconcile task.** It creates the handle and returns; the
  reconcile then awaits `writeChain?.value` — the chain task that created it — from the outside and
  proceeds once it completes. Awaiting in the other direction deadlocks.
- **The handle is assigned inside the chain task before it returns**, which is what makes awaiting
  the chain first, then the handle, enough for a test to see it. Chaining each reconcile on the
  previous one keeps a single handle covering every in-flight reconcile, so nothing is left running
  behind `settle()`.

**6. The two doc comments.** `reloadConfig`'s "Nothing re-reads until the worktree list changes
again, so a lost gesture would stay lost for the session" (`:374-375`) and
`WorktreeGroupWriteAlert.informativeText`'s "which only runs when the worktree list changes"
(`Sources/App/WorktreeGroupWriteAlert.swift:25-27`) now describe the opposite of what happens.
Restate each in one line: a refused write reconciles against git at once, with no worktree-list
change. **No user-visible string changes** — `messageText` and `informativeText` are byte-identical
to what #236 shipped.

**7. `settle()`.** `WorktreeGroupManagerGitTestCase.settle()` (`Tests/TestHelpers.swift:232-235`)
awaits `manager?.reconcileTask?.value` after the write chain, and its doc comment says why the
chain comes first. Without this, a case whose write fails leaves `git config` subprocesses running
against a scratch root `tearDown` is removing.

**Acceptance criteria**

- Every `enqueueWrite` call site returns a `WorktreeConfigWriteRefusals`; no `configStore.set`,
  `setLocal` or `replaceLocalValues` result inside the manager is discarded.
- A refused write starts exactly one reconcile task, which publishes only after the write chain is
  quiet and restarts if a gesture was enqueued while its reads were in flight.
- A gesture whose writes all land leaves `reconcileTask` `nil` and performs no extra `git config`
  read.
- `WorktreeGroupWriteAlert.messageText` and `informativeText` are unchanged character for
  character; the only edit to that file is the doc comment above `informativeText`.
- `WorktreeConfigStore` is unchanged.
- The existing suite passes unchanged, including
  `testARenameWhoseMemberWritesFailLeavesTheRegistryUntouched`,
  `testADeleteWhoseMemberWritesFailLeavesTheRegistryUntouched` and
  `testAFailedRegistryRewriteTellsTheUser`.

**Verification**

- `./scripts/ci.sh` green, with the suite **completing** — a run that hangs is this task's failure
  mode (a chain/reconcile await cycle, or a `settle()` that returns before the reconcile is done),
  so confirm it finished rather than only that nothing reported a failure.
- `swiftlint lint --quiet`: zero errors, no new warnings. `Sources/App/WorktreeGroupManager.swift`
  stays under the 700-line `file_length` warning and the class body under the 500-line
  `type_body_length` warning.
- `git diff Sources/App/WorktreeGroupWriteAlert.swift` shows comment lines only.

### T3: Cases for what the reconcile publishes

**Files**

- `Tests/WorktreeGroupPersistenceTests.swift`
- `Tests/TestHelpers.swift`

**What it does**

Extends the two existing abandoned-registry cases and adds four. Every case runs under
`WorktreeGroupManagerGitTestCase`, whose recording presenter keeps the run off a modal, and waits
with `settle()` or `waitFor`, never a fixed sleep.

**A lever that fails a write but not a read.** Three of these cases need git to refuse a write
while the matching read still succeeds; removing the worktree directory — the lever the two
existing cases use — breaks both, and then the reconcile keeps what is published and there is
nothing to assert. Make the directory holding the target config file non-writable instead
(`0o555` via `FileManager.setAttributes`), so git cannot create its lock file while every read
still works:

- a worktree's own config: `.git/worktrees/<name>/`, found with
  `git -C <worktree path> rev-parse --git-dir`;
- the repo-level config: the project's `.git/`.

Add it to `GitRepoFixture` as a helper that returns the mode it replaced, or a pair of
lock/unlock helpers. **The permissions must be restored before `tearDown`**, or removing the
scratch root fails; restore in a `defer` in each case that uses it. If this lever proves unreliable
on the build machine, report it rather than weakening the assertions — the alternative levers
cannot observe these criteria at all.

**The cases**

1. `testARenameWhoseMemberWritesFailLeavesTheRegistryUntouched` — after the existing assertions and
   a `settle()`, add: `manager.groups.map(\.name) == ["Old"]` **in the same manager, before the
   `restartManager()` line**. The registry read is repo-level and succeeds, so the reconcile
   republishes the old name with no relaunch.
2. `testADeleteWhoseMemberWritesFailLeavesTheRegistryUntouched` — the same addition:
   `manager.groups.map(\.name) == ["Doomed"]` after `settle()`, with no relaunch.
3. A new half-applied rename, which is what "each member's stored membership" in the spec's success
   criteria actually needs: group `Old` with **two** members, `alpha` (position 0, left alive) and
   `beta` (position 1, its directory then removed). `members(ofGroupNamed:)` orders by position, so
   `alpha`'s `clearway.group = "New"` lands and `beta`'s is refused, abandoning the registry.
   After `settle()`, with no relaunch: `manager.groups.map(\.name) == ["Old"]`, and
   `manager.groupName(for: alpha.id) == nil` — git holds `New` for `alpha`, the reloaded registry
   does not list it, and `reloadConfig` drops a membership naming an unlisted group rather than
   rendering a phantom section.
4. A new refused position write: two ungrouped worktrees `alpha` and `beta` with positions landed;
   lock `alpha`'s worktree git dir; `setUngroupedOrder` reordering the two so `alpha`'s position
   write is the refused one. After `settle()`, `manager.positions[alpha.id]` equals what git holds
   for `alpha`, not the value the drag published — so the next drag that assigns that value is a
   real change.
5. A new refused `clearway.grouping` write: `repo.setLocalValue("status", …)` behind the manager's
   back and `restartManager()` so memory and git agree on `.status`; lock the project's `.git`;
   `manager.setGrouping(.none)`. After `settle()`, `manager.grouping == .status`.
6. A new landed-gesture case: a gesture whose writes all land (e.g. `createGroup` plus an
   `addWorktree` on a live worktree), `settle()`, then `XCTAssertNil(manager.reconcileTask)` — a
   success starts nothing.

**Acceptance criteria**

- All six cases pass, and each fails for the right reason on a build without T2 (check at least
  cases 4 and 5 that way, by reverting the reconcile call locally and watching them fail — do not
  leave that state behind).
- No test opens a modal, and no case sleeps for a fixed span.
- Every case that changes a directory's permissions restores them, and
  `WorktreeGroupPersistenceTests` leaves nothing behind in `NSTemporaryDirectory()`.
- `Tests/TestHelpers.swift` changes are the permission helper only — `settle()` was already done in
  T2.

**Verification**

- `./scripts/ci.sh` green, the suite completing.
- Run the suite twice; the new cases involve real subprocesses and must not be flaky.
- `swiftlint lint --quiet`: zero errors, no new warnings.
- `git status --porcelain` shows no stray files beyond the un-gitignored `default.profraw` a Debug
  launch leaves.

## Build log

### T1: Move the ordering statics into their own file

**What landed**

| File | State |
| --- | --- |
| `Sources/App/WorktreeGroupManager+Ordering.swift` | New. `extension WorktreeGroupManager` holding `repositioned(_:with:)` and `reassignedPositions(section:newOrder:)`, bodies and doc comments byte-identical to what was removed. 55 lines. |
| `Sources/App/WorktreeGroupManager.swift` | 667 → 618 lines; the `// MARK: - Ordering` block deleted, nothing else touched. |
| `Clearway.xcodeproj/project.pbxproj` | Regenerated by `xcodegen generate` inside `ci.sh`; four added lines, all naming the new file. |

No call site changed. `Tests/WorktreeGroupManagerTests.swift` is untouched and still reaches both
by type name.

**Evidence**

The move is verbatim, checked rather than eyeballed:

```
$ git show HEAD:Sources/App/WorktreeGroupManager.swift | sed -n '540,585p' > old.txt
$ sed -n '9,54p' Sources/App/WorktreeGroupManager+Ordering.swift > new.txt
$ diff old.txt new.txt && echo "BYTE IDENTICAL"
BYTE IDENTICAL
```

`git diff --stat` on the tracked source shows the one-sided deletion the move implies:
`Sources/App/WorktreeGroupManager.swift | 49 ----------------------------------`.

No regression test is owed: this task changes no behaviour, and the existing
`WorktreeGroupManagerTests` cases for both statics pass unchanged.

**Deviations**

- The `// MARK: - Ordering` heading did **not** come across. In a file named
  `WorktreeGroupManager+Ordering.swift` whose extension already carries a doc comment saying what
  the two statics are, a lone section marker for the file's only section restates the filename. The
  plan asked for it; the heading is the only thing in the block that was not moved.

**Gate**

`./scripts/ci.sh` — passed. 676 tests executed, 0 failures, suite completed
(`Test Suite 'All tests' passed`), ending `==> CI passed.`

`swiftlint lint --quiet` — exit 0, no output, so zero errors and zero warnings.

`git status --porcelain` after the run: only the files listed above; no `default.profraw`, since
nothing launched the Debug app.

### T2: Report refused writes through `enqueueWrite` and reconcile from git

**What landed**

| File | State |
| --- | --- |
| `Sources/App/WorktreeGroupManager.swift` | 618 → 694 lines. File-scope `WorktreeConfigWriteRefusals`; `enqueueWrite`'s closure returns one and its task starts the reconcile behind `guard !refusals.isEmpty, let self`; `Self.write` answers `Bool`; all seven write bodies report; `reloadConfig` takes `[(id: String, path: String)]`; `reconcileTask` handle and `reconcileAfterRefusedWrite`; the corrected `reloadConfig` doc comment. |
| `Sources/App/WorktreeGroupWriteAlert.swift` | The `informativeText` doc comment only — `git diff` on the file is three comment lines. `messageText` and `informativeText` byte-identical to #236. |
| `Tests/TestHelpers.swift` | `settle()` awaits `reconcileTask` after the write chain, with the doc line saying why the chain comes first. |
| `Sources/App/WorktreeConfigStore.swift` | Unchanged. |

The `compactMap` that built `reloadConfig`'s targets moved into `reconcile(_:openIds:)`'s `Task`;
`reconcile` remains the only production caller of `reloadConfig`.

**Evidence**

No case in the suite can yet observe what the reconcile publishes — that is T3's whole subject.
Both existing levers (removing the worktree directory) fail the read as well as the write, so the
reconcile keeps what is published and there is nothing to assert. No regression test is claimed
here.

What this run does prove is the failure mode the plan names: a chain/reconcile await cycle, or a
`settle()` that returns before the reconcile is done. Three cases —
`testARenameWhoseMemberWritesFailLeavesTheRegistryUntouched`,
`testADeleteWhoseMemberWritesFailLeavesTheRegistryUntouched` and
`testAFailedRegistryRewriteTellsTheUser` — drive a refused write, so each one now starts a
reconcile that awaits `writeChain` from outside while `settle()` awaits both. The suite
**completed** rather than timing out:

```
Executed 676 tests, with 0 failures (0 unexpected) in 116.070 (116.282) seconds
Test Suite 'All tests' passed at 2026-09-20 19:09:04.367.
```

676 is the same count T1 recorded, so nothing was skipped.

No `configStore.set`, `setLocal` or `replaceLocalValues` result in the manager is discarded —
every one of the eleven call sites binds its `Bool` and carries it out. `Self.write` is deliberately
not `@discardableResult`, so a future site that drops it is a compiler warning.

**Deviations**

None.

**Gate**

`./scripts/ci.sh` — passed, ending `==> CI passed.`, with the suite completing as quoted above.

`swiftlint lint --quiet` — exit 0, no output: zero errors, zero warnings.
`Sources/App/WorktreeGroupManager.swift` is 694 lines against the 700-line `file_length` warning —
6 lines of headroom, which is why two of the new doc comments were tightened before the gate ran.
T3 does not touch this file.

`git status --porcelain` after the run: the three files above and nothing else. No
`default.profraw`, since nothing launched the Debug app.

### T3: Cases for what the reconcile publishes

**What landed**

| File | State |
| --- | --- |
| `Tests/TestHelpers.swift` | `GitRepoFixture.gitDir(ofWorktreeAt:)` and `GitRepoFixture.setPermissions(_:of:)`, the lever and the way to find its target. Nothing else; `settle()` was done in T2. |
| `Tests/WorktreeGroupPersistenceTests.swift` | A `// MARK: - Reconciling a refused write` section with the four new cases, plus the `settle()` + republish assertion added to each of the two existing abandoned-registry cases. 17 → 21 cases. |
| `Sources/App/` | Unchanged. |

The six cases: `testARenameWhoseMemberWritesFailLeavesTheRegistryUntouched` and
`testADeleteWhoseMemberWritesFailLeavesTheRegistryUntouched` now assert the republished registry in
the same manager before any relaunch; `testAHalfAppliedRenameRepublishesWhatGitHolds`,
`testARefusedPositionWriteRepublishesTheStoredPosition`,
`testARefusedGroupingWriteRepublishesTheStoredMode` and
`testAGestureWhoseWritesLandStartsNoReconcile` are new.

**Evidence**

The lever was checked against real git in the scratchpad before a line of test code ran — a
read-only directory refuses the write and answers every read:

```
$ chmod 555 .git/worktrees/alpha
$ git -C .worktrees/alpha config --worktree clearway.position 1
error: could not lock config file .../worktrees/alpha/config.worktree: Permission denied
write exit=255
$ git -C .worktrees/alpha config --worktree --get clearway.position
0
$ chmod 555 .git && git config --local clearway.grouping none
error: could not lock config file .git/config: Permission denied
```

Each of the five cases that observe the reconcile was then watched failing against the unfixed
code: `WorktreeGroupManager.swift` was copied to the scratchpad, `enqueueWrite`'s
`self.reconcileAfterRefusedWrite(refusals)` replaced with `_ = self`, the six cases run, and the
file restored from the copy (`git diff Sources/` empty afterwards).

```
testARenameWhoseMemberWritesFailLeavesTheRegistryUntouched: XCTAssertEqual failed: ("["New"]") is not equal to ("["Old"]") - the refusal reconciles against git at once, so the old name is back with no relaunch
testADeleteWhoseMemberWritesFailLeavesTheRegistryUntouched: XCTAssertEqual failed: ("[]") is not equal to ("["Doomed"]") - the refusal reconciles against git at once, so the group is back with no relaunch
testAHalfAppliedRenameRepublishesWhatGitHolds: XCTAssertEqual failed: ("["New"]") is not equal to ("["Old"]") - the registry git holds, with no relaunch
testAHalfAppliedRenameRepublishesWhatGitHolds: XCTAssertNil failed: "New" - git holds New for alpha and the reloaded registry does not list it, so it renders ungrouped rather than as a phantom section
testARefusedGroupingWriteRepublishesTheStoredMode: XCTAssertEqual failed: ("none") is not equal to ("status") - memory holds git's value, with no relaunch
testARefusedPositionWriteRepublishesTheStoredPosition: XCTAssertEqual failed: ("Optional(1)") is not equal to ("Optional(0)") - memory holds git's value, not the drag's
```

The two refused-write log lines in that run prove the lever fired rather than something else
failing: `set clearway.grouping failed: error: could not lock config file .git/config: Permission
denied`, and `set clearway.position at …/.worktrees/alpha failed: error: could not lock config file
…/.git/worktrees/alpha/config.worktree: Permission denied`.

`testAGestureWhoseWritesLandStartsNoReconcile` **passed** on that neutralised build, as it must:
it asserts the absence of a reconcile, so removing the reconcile cannot make it fail. It is a pin
against a future trigger that fires on a gesture that landed, not a regression test for this
defect.

Nothing is left behind. The suite was run on its own with the leftover roots in
`NSTemporaryDirectory()` recorded before and after:

```
$ xcodebuild … -only-testing:ClearwayTests/WorktreeGroupPersistenceTests
Executed 21 tests, with 0 failures (0 unexpected) in 22.422 seconds
$ comm -13 before.txt after.txt   # new clearway-manager-tests-* roots
(nothing)
$ find /var/folders/…/T/clearway-manager-tests-* -type d ! -perm -u+w | wc -l
0
```

The 27 roots already in `NSTemporaryDirectory()` date from 17–20 Sep and predate this branch; none
holds a non-writable directory, so the `defer` restores hold.

**Deviations**

- Case 4 reorders **twice** rather than seeding first: one `setUngroupedOrder` to land alpha 0 /
  beta 1, then the lock, then the reverse order. `reassignedPositions` assigns 0 and 1 from an
  unpositioned section anyway, so the seed adds nothing, and starting from an explicit order makes
  the refused value (alpha keeps 0 while the drag published 1) readable in the assertion.
- Case 3 also pins the recorded alert. The abandon is what puts git into the half-applied state the
  case is about, and the alert is the only other observable that it happened.

**Gate**

`./scripts/ci.sh` — passed twice, both ending `==> CI passed.`, the suite completing both times:

```
Executed 680 tests, with 0 failures (0 unexpected) in 114.904 (115.149) seconds
Executed 680 tests, with 0 failures (0 unexpected) in 117.132 (117.370) seconds
Test Suite 'All tests' passed
```

676 + 4 new cases = 680, so nothing was skipped. `swiftlint lint --quiet` — exit 0, no output.

`git status --porcelain` after the runs: `Tests/TestHelpers.swift` and
`Tests/WorktreeGroupPersistenceTests.swift` only. No `default.profraw`, since nothing launched the
Debug app.

### Simplify

`WorktreeConfigWriteRefusals` is gone. It held two bits — some path was refused, or a repo-level
key was — and the reconcile read only the first, because `reloadConfig` re-reads both repo-level
keys unconditionally. So the trigger is now the `Bool` the body already computes and the extra
paths to re-read are stated by the door: `enqueueWrite(touching:_:)` takes the worktrees the
gesture writes, which every call site knows before the write runs, and `work` answers whether
everything landed. That deletes the struct and the nine hand-assembled literals.

Also: `addWorktree` and `removeWorktreeFromGroup`'s identical write bodies collapsed into
`writeMembership`; `reloadConfig`/`readConfig` take `[String]` rather than `[(id:path:)]`, since a
worktree's id *is* its path; `reconcile`'s target derivation hoisted out of its `Task`; the
reconcile task takes `[weak self]`, matching `enqueueWrite`; the tests reach the project's `.git`
through the `gitDir` helper added in T3 rather than building the path by hand.

`./scripts/ci.sh` — passed, `==> CI passed.`, `Executed 680 tests, with 0 failures (0 unexpected)`,
`Test Suite 'All tests' passed`. `swiftlint lint --quiet` — exit 0. `WorktreeGroupManager.swift`
694 → 677 lines. `git status --porcelain` — the three files above, nothing else.

## Changelog

### Review fixes: targets resolved inside the reload, the `reconcileTask` doc, spec drift

Three items from the review step, landed on this branch after T3 and the simplify pass.

| File | State |
| --- | --- |
| `Sources/App/WorktreeGroupManager.swift` | `ReloadTargets` + `resolvedPaths(_:)` added; `reloadConfig` takes the enum and resolves its paths inside the retry loop; `reconcileAfterRefusedWrite` no longer snapshots targets; `reconcileTask`'s doc comment made true. 677 → 689 lines. |
| `Tests/WorktreeGroupPersistenceTests.swift` | `testAFirstGestureMadeDuringTheReconcileSurvivesIt` added. |
| `docs/superpowers/specs/2026-09-20-reconcile-worktreegroupmanager-state-after-failed-write.md` | Decisions 3 and 4 restated as the code landed. |

**1. The reconcile's targets were fixed at refusal time.** `reconcileAfterRefusedWrite` unioned the
published map keys with the gesture's paths and handed `reloadConfig` a list. But `reloadConfig`
can retry on `guard writeChain == chain else { continue }`, and it publishes `names`, `statuses`
and `placement` wholesale — so a worktree the manager had published nothing for that took its
*first* gesture while the reads were in flight sat outside that list, and its landed value was
erased from memory although git held it.

The targets are now a `ReloadTargets` value — `.worktrees([String])` for a worktree-list change,
`.refusedWrite(Set<String>)` for a refusal — resolved by `resolvedPaths(_:)` **inside** the loop,
after the chain await, so every iteration unions the gesture's paths with the map keys as they
stand then.

Watched fail first, with the fix temporarily reverted to the old snapshot
(`reloadConfig(for: .worktrees(resolvedPaths(.refusedWrite(paths))))`):

```
Test Case '-[ClearwayTests.WorktreeGroupPersistenceTests testAFirstGestureMadeDuringTheReconcileSurvivesIt]' started.
Tests/WorktreeGroupPersistenceTests.swift:352: error: XCTAssertEqual failed: ("nil") is not equal
to ("Optional("Beta")") - memory holds what git holds for beta
Test Case '...testAFirstGestureMadeDuringTheReconcileSurvivesIt]' failed (1.065 seconds).
```

Beta's own assertion — that git holds `Beta` — passed in the same run, so the failure is the
publish erasing memory, not the write. With the fix restored the whole suite runs green:
`Executed 22 tests, with 0 failures (0 unexpected)`.

**2. The `reconcileTask` doc comment.** It said "or `nil` while every write has landed", and
nothing ever reassigns `nil`. The doc was made true rather than the code: clearing the handle when
a reconcile finishes would race the next refusal's chaining, which is what keeps one handle
covering every in-flight reconcile. It now says the handle stays non-`nil` once set, which is also
what `testAGestureWhoseWritesLandStartsNoReconcile` asserts about the state before the first one.

**3. Spec drift.** Decisions 3 and 4 still described `work` returning worktree paths plus a
repo-level flag, and the reconcile firing when that was non-empty — the shape the simplify pass
replaced with `enqueueWrite(touching:)` plus a `Bool`. Both are restated as landed, and decision 3
now carries the resolution timing item 1 fixed.

**Deviation from the plan.** None of this was planned work; it is review feedback. The one shape
choice worth naming is the enum over a closure parameter or a `unioningPublished: Bool` flag: the
two callers want different target sets and the enum names both at the call site, where a flag would
not say what it unions. `Sources/App/WorktreeGroupManager.swift` is at 689 lines against
SwiftLint's 700-line `file_length` warning — the next addition to it needs a split first.

**Gate.** `./scripts/ci.sh` — passed.

### Rebase onto `origin/main`, round one: #240 and #241

PR #246 went conflicting against `origin/main`. Two files conflicted; only
`Sources/App/WorktreeGroupManager.swift` needed a hand resolution. This round was first taken as a
merge commit; round two below replaced it with a rebase, and the resolution described here survives
in the squashed commit.

| File | State |
| --- | --- |
| `Sources/App/WorktreeGroupManager.swift` | `setName` and `setStatus` resolved to `enqueueWrite(touching: [path])` around `Self.write(…, in: configStore)` — this branch's trigger with main's helper. 689 → 692 lines. |
| `Tests/WorktreeGroupPersistenceTests.swift` | Auto-merged; PR #241's case joins this branch's. Restated as `testAFailedNameOrStatusWriteIsReconciledAgainstGitAndRaisesNoAlert` — see below. |
| `docs/superpowers/specs/2026-09-20-reconcile-worktreegroupmanager-state-after-failed-write.md` | Decision 5 restated; the `WorktreeConfigStore` success criterion and the matching out-of-scope bullet qualified. |

**The conflict.** Both sides edited the same two `enqueueWrite` bodies. This branch had added
`touching: [path]` so a refusal starts the reconcile; PR #241 (`9615e29`) had replaced the bare
`configStore.set` with `Self.write`, which logs `clearway.<key> for <path> was not saved` and
returns whether the write landed. The two wants are the same expression — `Self.write`'s `Bool` is
exactly what `enqueueWrite` now consumes — so the resolution keeps both and duplicates no log line:
`write` is the only thing that logs, and each body calls it once per key. Every worktree-scoped
write site is now uniform, which is why decision 5's carve-out wording went.

**PR #240 (`3ed10b7`).** It changed only `Sources/App/WorktreeConfigStore.swift`, making the store's
own `worktree config:` line public in release builds. No conflict, and nothing here depends on it
beyond the spec criterion that said the store is unchanged, which now names the merge.

**The one semantic collision, and the test that caught it.** PR #241 pinned that a refused name or
status write *stays published* — true on main, where nothing re-read until the worktree list
changed, and its comment said so: "the next launch corrects it". On this branch the refusal starts
the reconcile at once, so it was merged and run as written and it failed, which is the collision
surfacing rather than a regression:

```
Test Case '-[ClearwayTests.WorktreeGroupPersistenceTests testAFailedNameOrStatusWriteStaysPublishedAndRaisesNoAlert]' started.
Tests/WorktreeGroupPersistenceTests.swift:213: error: XCTAssertEqual failed: ("nil") is not equal
to ("Optional("Renamed")") - the publish stands when the write fails
Tests/WorktreeGroupPersistenceTests.swift:214: error: XCTAssertEqual failed: ("nil") is not equal
to ("Optional(Clearway.WorktreeStatus.inReview)") - the publish stands when the write fails
```

The removal that refuses the write also makes `git config --worktree --list` refuse, and a refusal
reads as "stores nothing" rather than "could not say" (`WorktreeConfigStore.values(forWorktreeAt:)`
answers `[:]` for `.refused` and `nil` only when git could not run at all). So the reconcile
correctly publishes nothing — the same "what git holds" this branch's rename and delete cases
already assert, and what #241's own decision 4 anticipated: "the next `reconcile` republishes what
git holds".

Both halves of #241's subject are kept, split around the settle: the gesture still publishes before
its write runs, asserted synchronously, and the alert is still absent. What changed is the third
assertion, which now pins the reconcile. Renamed to
`testAFailedNameOrStatusWriteIsReconciledAgainstGitAndRaisesNoAlert` so the name states it.

**File length.** `Sources/App/WorktreeGroupManager.swift` came out of the merge at 692 lines,
still under SwiftLint's 700-line `file_length` warning, so nothing was split out. The next addition
to it still needs a split first.

**Gate.** `./scripts/ci.sh` — passed.

### Rebase onto `origin/main`, round two: #243, #244 and #245

`origin/main` moved again and PR #246 went conflicting a second time. The operator asked for a
rebase, so the branch was squashed onto `origin/main` as one commit rather than replayed: the
branch carried the round-one merge commit, a plain rebase drops it and with it the resolution
above, and the six own commits all touch the same two regions of
`Sources/App/WorktreeGroupManager.swift` that #245 touches, so replaying would have meant the same
resolution five times over. The resolution itself was taken as a real `git merge origin/main`, and
the result was then re-parented onto `origin/main` with `git reset --soft`, so every conflict was
resolved with full three-way context.

| File | State |
| --- | --- |
| `Sources/App/WorktreeGroupManager.swift` | Two conflicts, both the `reconcileTask` slot #245 added independently — see below. 698 lines. |
| `Tests/TestHelpers.swift` | One conflict, `settle()`'s doc comment; git had already merged its body to the four-await form. |
| `Tests/WorktreeGroupPersistenceTests.swift` | Auto-merged. |
| `Clearway.xcodeproj/project.pbxproj` | Auto-merged, then confirmed by `xcodegen generate`, which produced no further change. |
| `docs/superpowers/specs/2026-09-20-reconcile-worktreegroupmanager-state-after-failed-write.md` | Decision 9 restated; the `settle()` success criterion and the `Tests/TestHelpers.swift` file entry widened. |

**The collision: two `reconcileTask` slots.** #245 added a `private(set) var reconcileTask` for the
reconcile a worktree-list change starts, so `settle()` covers one a test body dropped. This branch
had added a `private(set) var reconcileTask` for the reconcile a refused write starts. Same name,
same purpose, opposite ordering constraints: #245 awaits it *before* the chain, because
`reconcile(_:openIds:)`'s `seedPositions` enqueues a write that has to be in the chain when the
chain is sampled; this branch awaits it *after*, because a refused write creates its handle inside
the chain task and there is nothing to await until the chain has run.

Resolved as one slot with both orders. `settle()` is load, reconcile, chain, reconcile — the second
read picks up whatever the chain left behind — and both writers chain on the previous reconcile,
which is what makes the second read sufficient. Chaining supersedes #245's decision 7, which
declined it to keep that task's production diff non-behavioural; that was #245's constraint, and an
unchained slot makes this branch's stated invariant false, since a worktree-list change fired while
a refused write's reconcile is still running would replace the handle and leave that reconcile
running against a scratch root `tearDown` is removing. It also stops two wholesale publishes
landing out of order.

**#244 (`60f501f`) and #243 (`efc7040`).** Neither touches anything this branch does. #244's
`project.pbxproj` entry for `Sources/App/FullWidthPicker.swift` merged with this branch's entry for
`Sources/App/WorktreeGroupManager+Ordering.swift` without a conflict.

**File length.** `Sources/App/WorktreeGroupManager.swift` came out of the rebase at 698 lines,
under SwiftLint's 700-line `file_length` warning, so nothing further was split out. The next
addition to it needs a split first — `WorktreeGroupManager+Ordering.swift` is where T1 put the
first one.
