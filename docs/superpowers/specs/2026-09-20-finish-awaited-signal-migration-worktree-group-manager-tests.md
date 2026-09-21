# Finish the awaited-signal migration in the WorktreeGroupManager suites

**Date:** 2026-09-20
**Base:** b4369a5 (`Split buttons for Run and Open in (#237)`)

PR #233 gave the `WorktreeGroupManager` suites a signal to await instead of a clock to outlast:
`writeChain` became `private(set)`, `reconcile` returns its `Task`, and the test base grew
`settle()`. Two gaps on that seam remain. Ten cases still fire a bare `reconcile` and then poll
`git config` subprocesses every 20 ms until the value appears, and `settle()` cannot see a
`reconcile` `Task` a body dropped — it is covered today only by an accident of where `reconcile`
suspends. This change awaits the returned `Task` at every remaining site, opens the stored-value
wait helpers with `await settle()`, and stores the reconcile `Task` on the manager so `settle()`
awaits it.

## Decisions

| # | Question | Decision | Source |
| --- | --- | --- | --- |
| 1 | The task brief says "eleven pre-existing sites". The census finds ten. | Ten. The brief's own list is 4 + 3 + 3, and the file at `b4369a5` holds exactly ten bare `reconcile` calls paired with a poll (assumption 1). The brief's `WorktreeGroupPersistenceTests` line numbers (~193, ~233) are stale by +55 because #236 landed after #233 and added the write-alert cases above them; the real lines are 248 and 288. The rule the brief states — "each pairs a bare `manager.reconcile(...)` with a `waitFor` loop" — is unambiguous, so it is applied to the ten sites that match and nothing else is invented to reach eleven. | Spec author |
| 2 | What replaces each polling site? | `await manager.reconcile(…).value`, then the poll's expectation as a plain `XCTAssert`. The `Task` ends after `seedPositions`, which publishes synchronously, so every published value the poll was waiting for is correct on the next line. This is stronger than the poll, not weaker: a poll passes the instant the value appears at any point inside its 5 s window, including before the gesture; the awaited form asserts once, at a defined point. | Spec author |
| 3 | The two sites whose assertions read git back rather than published state. | Follow the awaited `reconcile` with `await settle()`. `reconcile` can enqueue a seed write, and `settle()` is the test base's one idiom for "the manager's in-flight writes have landed". This applies to `testTheStoredOrderSurvivesContentViewsReloadSequence` and `testRemovingAWorktreeLeavesNothingBehind`, which are exactly the two cases whose point is what git holds afterwards. | Spec author |
| 4 | The brief puts `waitForRegistry` in `Tests/TestHelpers.swift`. It is not there. | It is a `private` helper on `WorktreeGroupPersistenceTests` (`:379`). Add the `await settle()` where it lives rather than moving it up to the base: nothing else calls it, and relocating a helper is a change this task does not ask for. `waitForStoredValue` is on the base (`TestHelpers.swift:278`) and is changed there. | Spec author |
| 5 | `waitForLocalValue` (`WorktreeGroupPersistenceTests.swift:394`) is the third helper of the same shape and the brief does not name it. | Include it. It reads a repo-level `clearway.*` key back through `GitRepoFixture` after a `setGrouping` write — the same defect of the same kind — and leaving it out would make the rule untrue the moment it was written. This is the same call the prior spec made for `WorktreeGroupPersistenceTests`' single sleep (decision 7 there). | Spec author |
| 6 | Revisit prior decision 4: the returned `Task` was chosen over a stored property to keep the production diff minimal. | Add the stored property as well. The brief settles this and gives the reason: the returned `Task` cannot cover a body that drops it, which is precisely `tearDown`'s problem. `reconcileTask` is one `private(set) var` assigned on one line, the shape `loadTask` and `writeChain` already have, and `reconcile` keeps `@discardableResult` and its return so no call site changes. | Task brief |
| 7 | Should `reconcileTask` chain on the previous reconcile the way `writeChain` chains on the previous write? | No. Chaining would serialise overlapping reconciles, which is a behavioural change, and this task's production diff must stay non-behavioural (decision 9 of the prior spec). The slot holds the most recent `Task`; a second `reconcile` fired before the first finished would leave the first unawaited by `settle()`. After this change no test drops a reconcile at all, so the case is theoretical, and it is stated in the property's doc comment rather than engineered around. | Spec author |
| 8 | `reconcile`'s `Task` captures `self` strongly, so storing it makes a cycle. | Accepted, and it is temporary rather than a leak: the `Task` releases its captures when it completes, and `reloadConfig`'s retry loop terminates because it only repeats while a write lands mid-read. Using `[weak self]` the way `loadTask` does would change what a reconcile does when the manager is released mid-flight, which is a behavioural change. | Spec author |
| 9 | How is "`settle()` does not return before a reconcile's write is enqueued" pinned? | One new case in `WorktreeGroupPersistenceTests`: fire a bare `reconcile` over one real worktree that has no stored position, `await settle()`, then read `clearway.position` straight off git with no poll. It must read `"0"`. With `reconcileTask` removed, `settle()` awaits only a completed `loadTask` and a `nil` `writeChain` and returns before the `Task` has spawned its first `git config`, so the read is `nil`. | Spec author |
| 10 | `waitForPublishedName` and `waitForPublishedStatuses` lose every caller once the ten sites are converted. | Delete both. They exist only to poll published state after a reconcile, which is the thing being removed. `waitForStoredName` and `waitForStoredStatus` keep their callers and stay. | Spec author |
| 11 | Should `waitFor` itself open with `await settle()`? | No. It is the primitive the three stored-value helpers are built on, and it is also what polls published state and `recordedWriteAlerts`. Settling inside it would push the manager's whole write chain into waits that are not about git at all. The settle belongs on the three helpers that read git back. | Spec author |
| 12 | Does the poll loop stay inside the three helpers once they settle first? | Yes. After `settle()` the first read already matches, so the loop costs one `git config` and never sleeps; keeping it means a helper called before its gesture has been made still behaves as it does today rather than failing outright. | Spec author |

## Assumptions

Each verified against the codebase at base `b4369a5`. No probe scripts or temporary files were
written into the repository; the census below was taken with read-only `grep`/`sed` over the
working tree.

1. **The census is ten bare `reconcile` calls, each followed by one poll**, and no other site in
   the four suites pairs the two:

   | File | `reconcile` | Poll | Case |
   | --- | --- | --- | --- |
   | `WorktreeGroupPersistenceTests.swift` | 34 | 36 | `testMembershipAndPositionSurviveARelaunch` |
   | | 58 | 60 | `testTheStoredOrderSurvivesContentViewsReloadSequence` |
   | | 248 | 250 | `testAMembershipNamingAnUnlistedGroupRendersUngrouped` |
   | | 288 | 290 | `testRemovingAWorktreeLeavesNothingBehind` |
   | `WorktreeGroupManagerStatusTests.swift` | 82 | 84 | `testReconcilePopulatesStatusesFromWorktreeConfig` |
   | | 97 | 99 | `testReconcileDropsAnUnrecognisedStatusSlugAndKeepsTheName` |
   | | 117 | 119 | `testReconcileDropsAnAbsentWorktree` |
   | `WorktreeGroupManagerNameTests.swift` | 109 | 110 | `testReconcilePopulatesNamesFromConfigAndDropsAClearedOne` |
   | | 113 | 114 | (same case, second half) |
   | | 130 | 132 | `testReconcileDropsAWhitespaceOnlyStoredName` |

   That is nine cases over ten sites. The two `reconcile` calls that already await
   (`WorktreeGroupPersistenceTests.swift:210`, `:230`) and the one that binds the `Task`
   (`WorktreeGroupManagerNameTests.swift:144`) are #233's work and are left alone.

2. **`reconcile` publishes everything before its `Task` ends.** `Sources/App/WorktreeGroupManager.swift:296-301`
   is `await reloadConfig(for:)` then `seedPositions(for:openIds:)`; `reloadConfig` assigns
   `grouping`, `groups`, `placement`, `names` and `statuses` and returns (`:393-407`), and
   `seedPositions` (`:211-222`) calls `applyPositions` (`:634`), which mutates `placement` before
   `writePositions` (`:641`) enqueues. So awaiting the `Task` is sufficient for every published
   assertion the ten polls make.

3. **The seed write is enqueued with no suspension after the reload's publish**, which is why
   `settle()` is safe today and why nothing pins that: `seedPositions` → `applyPositions` →
   `writePositions` → `enqueueWrite` (`:641-652`) is a synchronous chain, and `enqueueWrite`
   (`:469-476`) assigns `writeChain` before it returns. The first `await` added anywhere in that
   chain ends the guarantee, exactly as the brief states. The caveat is already written down in
   `settle()`'s own doc comment (`Tests/TestHelpers.swift:227-231`), which this change deletes.

4. **`settle()` today awaits two things and is the tearDown path.** `Tests/TestHelpers.swift:232-235`
   awaits `manager?.loadTask?.value` then `manager?.writeChain?.value`; `tearDown` (`:214-221`)
   calls it before dropping `manager` and letting `TempRootTestCase` remove the scratch root. It
   takes no parameter — the prior plan proposed one and the implementation did not need it, so
   `WorktreeGroupPersistenceTests.swift:362` awaits its local manager's `writeChain` directly.

5. **`reconcile`'s only production call site discards the result.** `Sources/App/ContentView.swift:349`.
   Adding a stored assignment inside `reconcile` changes nothing there, and `@discardableResult`
   (`WorktreeGroupManager.swift:295`) already keeps it compiling.

6. **The three helpers that read git back are `waitForStoredValue` (`Tests/TestHelpers.swift:278`),
   `waitForRegistry` (`Tests/WorktreeGroupPersistenceTests.swift:379`) and `waitForLocalValue`
   (`:394`).** `waitForStoredName` (`WorktreeGroupManagerNameTests.swift:166`) and
   `waitForStoredStatus` (`WorktreeGroupManagerStatusTests.swift:262`) delegate to
   `waitForStoredValue`, so they inherit the settle and need no edit of their own.

7. **`waitForPublishedName` (`WorktreeGroupManagerNameTests.swift:181`) and
   `waitForPublishedStatuses` (`WorktreeGroupManagerStatusTests.swift:277`) are called only from
   the sites in assumption 1** — lines 110, 114, 132 and 84, 119 respectively — so both are dead
   once the conversion lands.

8. **`seedPositions` gives a lone ungrouped worktree position 0**, which is what the new case in
   decision 9 reads back: `maxPosition(inSectionNamed: nil)` is `nil` for an empty section, so the
   slot is `(-1) + 1` (`WorktreeGroupManager.swift:216-219`).

9. **Every converted case still has a production rule that makes it go red**, so the conversion can
   be proved not to have hollowed anything out. The reverts, all inside
   `Sources/App/WorktreeGroupManager.swift`: the `placement` assignment in `reloadConfig` (`:402-405`)
   for the two relaunch cases; the order of the two statements in `reconcile` (`:297-298`) for the
   seed-after-reload case; the `listed.contains` filter (`:400-401`) for the unlisted-group case;
   the `names` and `statuses` assignments (`:406-407`) for the populate and absent-worktree cases;
   and the whitespace and slug drops in `readConfig` (`:444-446`, `:449-452`) for the two hand-edited-config
   cases.

10. **`git status --porcelain` is clean at base**, and `.clearway/TASK.md` is committed, so the
    only untracked files at sign-off will be this change's own.

## Objective

Leave no case in the four `WorktreeGroupManager` suites polling for a value a `reconcile` already
hands it, and make `settle()` cover a `reconcile` no test awaited, so the guarantee `tearDown`
depends on is a property of the manager rather than of where `reconcile` happens to suspend.

### Success criteria

1. Every bare `manager.reconcile(…)` followed by a poll in the four suites is gone: the ten sites
   in assumption 1 await the returned `Task` and assert once. `grep -n "manager.reconcile" Tests/`
   shows no call whose result is discarded, except the one in the new case of criterion 5.
2. `waitForStoredValue`, `waitForRegistry` and `waitForLocalValue` each open with `await settle()`.
3. `WorktreeGroupManager` has a `private(set) var reconcileTask: Task<Void, Never>?`, assigned in
   `reconcile`, and `settle()` awaits it between `loadTask` and `writeChain` — in that order, so the
   `writeChain` the helper samples is the one the reconcile's seed write left behind.
4. `reconcile` keeps `@discardableResult` and its return type; `Sources/App/ContentView.swift:349`
   is unchanged; no other line under `Sources/` changes.
5. A new case in `WorktreeGroupPersistenceTests` fires a bare `reconcile`, awaits only `settle()`,
   and reads the seeded `clearway.position` straight off git with no poll. It is watched failing
   with `reconcileTask` reverted, and the failure is pasted into the build log.
6. Each of the nine converted cases is watched failing against the rule it pins (assumption 9),
   with each failure pasted into the build log. No assertion is weakened, dropped or reordered;
   the four suites hold the same number of `XCTAssert` calls before and after, minus none.
7. `waitForPublishedName` and `waitForPublishedStatuses` are deleted, having no callers left.
8. `./scripts/ci.sh` is green, and the four suites' combined wall time is recorded before and
   after, from the `.xcresult` of the first and last runs of the build phase.
9. `git status --porcelain` shows only this change's files. No reverted-guard edit survives in
   `Sources/`.

## Verification

```bash
./scripts/ci.sh
```

The only runner of the test suite; it regenerates the Xcode project, lints, builds and tests. It is
both the regression check after each build step and the full gate at sign-off, per the project's
`## Pipeline` section. `swiftlint lint --quiet` runs inside it as a post-build phase.

Reverted-guard proofs are made with `Edit` on the source file and restored with `Edit`, never with
`git checkout` or `git stash`.

## Files this change touches

| File | Change |
| --- | --- |
| `Sources/App/WorktreeGroupManager.swift` | Adds `private(set) var reconcileTask: Task<Void, Never>?` beside `loadTask`, with a doc comment naming the test base as its client and stating decision 7's limit. `reconcile` binds the `Task` it already creates, assigns it, and returns it. No behavioural hunk. |
| `Tests/TestHelpers.swift` | `settle()` awaits `reconcileTask` between `loadTask` and `writeChain`; its doc comment loses the caveat about where `reconcile` suspends. `waitForStoredValue` opens with `await settle()`. |
| `Tests/WorktreeGroupPersistenceTests.swift` | Four sites converted; two of them (`:58`, `:288`) also take `await settle()` because they read git back. `waitForRegistry` and `waitForLocalValue` open with `await settle()`. One new case for `settle()`'s reconcile coverage. |
| `Tests/WorktreeGroupManagerStatusTests.swift` | Three sites converted. `waitForPublishedStatuses` deleted. |
| `Tests/WorktreeGroupManagerNameTests.swift` | Three sites converted. `waitForPublishedName` deleted. |

## Out of scope

- **`Task.sleep` elsewhere in `Tests/`.** `WorkTaskManagerWatcherTests`, `PromptManagerTests`,
  `SavedCommandManagerTests` and `ShellPathStoreTests` still sleep. They are different subsystems
  with different signals, and the prior spec already put them out of scope.
- **The 20 ms poll interval and the 5 s timeout inside `waitFor`.** Decision 12 keeps the loop as
  the backstop behind the settle; nothing asks for its granularity to change.
- **Moving `waitForRegistry` or `waitForLocalValue` onto `WorktreeGroupManagerGitTestCase`**
  (decision 4). Nothing outside `WorktreeGroupPersistenceTests` calls either.
- **Serialising overlapping reconciles** (decision 7), and any other change to what
  `WorktreeGroupManager` does. The stored property is the whole production diff.
- **The polls that are not paired with a `reconcile`** — the `recordedWriteAlerts` wait
  (`WorktreeGroupPersistenceTests.swift:176`) and the stored-value waits that follow an ordinary
  gesture. They gain the settle through decision 5 and criterion 2, and are not otherwise rewritten.
