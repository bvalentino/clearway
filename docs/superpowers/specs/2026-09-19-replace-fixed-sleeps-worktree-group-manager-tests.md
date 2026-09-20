# Replace fixed sleeps and close the named coverage gaps in the WorktreeGroupManager suites

**Date:** 2026-09-19
**Base:** 1206708 (`Keep worktree groups, order and grouping mode in git config (#230)`)

The three `WorktreeGroupManager` suites carry 59 fixed `Task.sleep` calls totalling 8.4 seconds per
run. Almost all of them wait for a git-config write that the assertion beside them never reads —
every gesture on the manager publishes synchronously, and the paths being written to are synthetic
`/tmp` directories where the write can only fail. This change deletes the waiting that buys nothing,
replaces the handful that guard a real race with an awaited signal, and adds the six cases the
PR #230 test review named as missing.

## Decisions

| # | Question | Decision | Source |
| --- | --- | --- | --- |
| 1 | The branch was two commits behind `origin/main`, and #230 — the code this task is about — was one of them. | Fast-forwarded the worktree to `1206708` before writing this spec. The branch held no commits of its own, so it was a pure fast-forward with nothing to lose, and a spec written against `484482d` would have cited a `WorktreeGroupManager` that #230 deleted (it still had `WorktreeGroupStore`, `groups.json` and `defaultOrder`). Reported to the operator. | Spec author |
| 2 | Replace each sleep with a poll, or delete it? | Delete it, wherever the assertion reads only published state. A poll is still a loop with a deadline; the correct replacement for "wait for something nobody looks at" is nothing at all. Every mutating method publishes before it enqueues its write (`WorktreeGroupManager.swift:82-287`), so `manager.groups`, `groupNames`, `positions`, `statuses`, `names` and `sidebarOrderedWorktrees` are all correct on the line after the gesture. This covers all 44 sleeps in `WorktreeGroupManagerTests` and 11 of the 12 in `WorktreeGroupManagerStatusTests`. | Spec author |
| 3 | What replaces the sleeps that do guard something? | An awaited signal. Four cases assert that a gesture wrote *nothing* (assumption 5), and absence cannot be polled — `waitFor` returns the moment the expected value is already there, which for "nothing happened" is immediately, so a poll would pass against a broken manager. These await the manager's in-flight work and then assert. | Spec author |
| 4 | What is that signal? | Widen `writeChain` to `private(set) var` and have `reconcile` return its `Task` as `@discardableResult`. `loadTask` is already `private(set) var` for exactly this reason, and its doc comment already names the test base as a client (`WorktreeGroupManager.swift:50-52`), so this is the established shape rather than a new seam. Returning the reconcile task rather than storing it avoids adding a second `self`-retaining stored property for a handle only tests read. Alternatives lose: a test-only `settled()` method on the manager is the same exposure with more surface; a `Clock` injection would have to reach `WorktreeConfigStore`'s subprocesses, which is what these suites exist to exercise. | Spec author |
| 5 | Can the "wrote nothing" cases instead queue an observable write behind the gesture, the way `WorktreeGroupPersistenceTests.swift:114-117` does? | No. Three of the four assert that `extensions.worktreeConfig` was never enabled, and any probe write enables it (`WorktreeConfigStore.swift:217, 240`) — the probe would destroy the assertion. The trick works only where the thing being proved absent is not the bootstrap itself. | Spec author |
| 6 | Do the failing background writes get awaited before teardown? | Yes — `WorktreeGroupManagerGitTestCase.tearDown` awaits `writeChain` before it removes the scratch root. Without the sleeps, a test body now ends while its `git config` subprocesses are still queued, and leaving them to run against a directory being deleted leaks work across the test boundary. This costs the real git time the sleeps were only approximating, never more. | Spec author |
| 7 | Is `WorktreeGroupPersistenceTests` in scope? The task names three suites. | Yes, for its single sleep (`:248`). It is the same defect of the same kind, the mechanism decision 4 introduces fixes it in one line, and leaving it would make the rule "no fixed sleeps in the manager suites" untrue the moment it was written. Nothing else in that suite changes. | Spec author |
| 8 | Where do the six new cases go? | Three by behaviour, three by evidence. `addWorktree` re-add and the `removeWorktreeFromGroup` position go to `WorktreeGroupManagerTests` beside the gestures they extend; main's status on the read path goes to `WorktreeGroupManagerStatusTests`. The repo-level re-read, the non-integer position and the no-op `setGrouping` go to `WorktreeGroupPersistenceTests`, whose doc comment already scopes it to stored state read back through `GitRepoFixture` (`WorktreeGroupPersistenceTests.swift:4-6`) — all three are about config the app did not write, or config it must not write. | Spec author |
| 9 | Does production behaviour change? | No. The two visibility changes in decision 4 are the only edits under `Sources/`, and neither alters a code path. Everything else is test-side. | Spec author |
| 10 | How is main's status on the read path driven, now that `readConfig` cannot put main's id into `statuses`? | Through two `Worktree` values over one path. `Worktree.id` is the path (`Worktree.swift:19`), so `setStatus` against a non-main worktree at that path seeds `statuses[path]`, and `status(for:)` against an `isMain: true` worktree at the same path must still answer `nil`. The case also asserts the consequence the doc comment names — main stays first under `.status` grouping — rather than the accessor alone. | Spec author |
| 11 | Does the non-integer position case assert the row is dropped or tolerated? | Tolerated: the worktree renders, unpositioned, and the name stored beside it still lands. `readConfig` drops only the unparseable value (`WorktreeGroupManager.swift:446`), which is the same rule the unrecognised status slug already has a case for (`WorktreeGroupManagerStatusTests.swift:65-81`). | Spec author |

## Assumptions

Each verified against the codebase at base `1206708`. No probe scripts or temporary files were
written into the repository; the sleep census below was taken with a read-only shell pipeline.

1. **Every mutating method on `WorktreeGroupManager` publishes synchronously and only then enqueues
   a write.** `createGroup` appends to `groups` and calls `writeRegistry()`
   (`WorktreeGroupManager.swift:82-86`); `addWorktree`, `removeWorktreeFromGroup`, `deleteGroup`,
   `setUngroupedOrder`, `setGroupOrder` and `seedPositions` all go through `mutatePlacement`, a
   synchronous single assignment (`:570-575`), before `enqueueWrite`; `setStatus`, `setName` and
   `setGrouping` assign the published property first (`:230-274`). So an assertion on published
   state needs no wait.

2. **The sleeps in `WorktreeGroupManagerTests` guard nothing, because that file never reads stored
   state.** It contains no reference to `repo.` at all and never calls `restartManager()` or
   `reconcile` — every assertion is on `manager.groups`, `manager.groupName`, `manager.positions`,
   `renderedOrder`, or the two pure statics. Nothing in it can observe a write landing.

3. **The census is 59 sleeps / 8,400 ms across the three named suites**, 44 / 5,550 ms in
   `WorktreeGroupManagerTests`, 12 / 1,950 ms in `WorktreeGroupManagerStatusTests`, 3 / 900 ms in
   `WorktreeGroupManagerNameTests`, plus 1 / 300 ms in `WorktreeGroupPersistenceTests:248`.

4. **The polling helpers this change leans on already exist.** `waitFor(_:describing:timeout:reading:)`
   and `waitForStoredValue(_:ofKey:at:)` are on `WorktreeGroupManagerGitTestCase`
   (`TestHelpers.swift:219-247`), as are `restartManager()` (`:212-215`) and `renderedOrder`
   (`:250-257`). No new polling machinery is needed — only the awaited signal in decision 4.

5. **Exactly four cases assert that a gesture wrote nothing, and each has a sleep as its only
   guard.** `WorktreeGroupManagerNameTests.testSetNameEmptyOnAWorktreeWithNoStoredNameChangesNothing`
   (`:75-84`) and `testSetNameIgnoresTheMainWorktree` (`:86-98`),
   `WorktreeGroupManagerStatusTests.testSetStatusIgnoresTheMainWorktree` (`:34-45`), and
   `WorktreeGroupPersistenceTests.testAProjectWhereTheExtensionCannotBeEnabledShowsNoGroups`
   (`:238-260`). The first three assert `extensions.worktreeConfig` is still absent; the fourth
   asserts a second manager over the same root sees nothing.

6. **`WorktreeGroupManagerNameTests.testReconcileRightAfterSetNameDoesNotRaceTheWrite` (`:139-149`)
   is a fifth case whose sleep guards a real thing** — it waits for the reload `reconcile` fired to
   finish and prove it did not publish an empty name over "Fresh name". It is the one case decision
   4's returned reconcile `Task` exists for.

7. **`reconcile` does re-read both repo-level keys, and nothing today covers it.**
   `reloadConfig` issues `localValue(groupingKey)` and `localValues(groupOrderKey)` as `async let`
   and applies both (`WorktreeGroupManager.swift:374-386`). Every existing test that observes either
   key does so through `restartManager()`, which goes via `loadTask` (`:57-72`) — a different code
   path. `testAMembershipNamingAnUnlistedGroupRendersUngrouped` calls `reconcile` but the registry
   it checks against was written by the manager itself, so it would pass with the re-read removed.

8. **`addWorktree`'s re-add guard is a bare `return` before any publish**
   (`WorktreeGroupManager.swift:135`), so "no publish" is observable as zero `objectWillChange`
   emissions — the counter `testAddWorktreePublishesOnce` already uses
   (`WorktreeGroupManagerTests.swift:134-146`). No existing case drives the guard.

9. **`removeWorktreeFromGroup` assigns a position as well as clearing the membership**
   (`WorktreeGroupManager.swift:152-166`), and `testRemoveWorktreeFromGroup`
   (`WorktreeGroupManagerTests.swift:114-126`) asserts only `groupName(for:)` is nil. The sibling
   rule for `deleteGroup` does have a case
   (`testDeleteGroupAppendsItsMembersToTheUngroupedSection`, `:55-68`); this half does not.

10. **A no-op `setGrouping` returns before `enqueueWrite`** (`WorktreeGroupManager.swift:268-274`),
    and the manager's default grouping is `.group` (`:40`), so `setGrouping(.group)` on a fresh
    manager is the no-op. The case #230 deleted for this rule asserted through `groups.json`
    (`docs/superpowers/plans/2026-09-19-retire-groups-json.md:743-746`), so it has no replacement.

11. **`WorktreeConfigStore` memoises its extension probe**, so a test that enables
    `extensions.worktreeConfig` behind the manager's back must `restartManager()` to be seen —
    stated in `restartManager`'s own doc comment (`TestHelpers.swift:206-211`). The new cases that
    seed config externally have to follow that order: enable, restart, edit, then act.

## Objective

Make the four `WorktreeGroupManager` test suites wait on signals rather than on the clock, and
close the six coverage gaps the PR #230 review named.

### Success criteria

1. `grep -c "Task.sleep" Tests/WorktreeGroupManager*.swift Tests/WorktreeGroupPersistenceTests.swift`
   reports zero for all four files.
2. Every case that asserted on published state asserts it on the line after the gesture, with no
   intervening wait.
3. Every case that asserts a gesture wrote nothing awaits the manager's in-flight work first, and
   would fail if the gesture enqueued a write.
4. The six new cases exist, each watched failing against a deliberately reverted rule before it is
   accepted, with the failure pasted into the build log:
   - `reconcile` re-reads `clearway.grouping` and `clearway.groupOrder` — an external edit to both
     is picked up without a relaunch.
   - `addWorktree` into the group the worktree already holds publishes nothing: zero
     `objectWillChange` emissions, membership and position unchanged.
   - `removeWorktreeFromGroup` appends the worktree to the ungrouped section at one above that
     section's maximum position, and the rendered order shows it last.
   - A status stored against main's id is ignored by `status(for:)` and main stays first under
     `.status` grouping.
   - A non-integer `clearway.position` is dropped, the worktree renders unpositioned, and the
     `clearway.name` stored beside it still lands.
   - `setGrouping` to the value already held enqueues no write and does not enable
     `extensions.worktreeConfig`.
5. `./scripts/ci.sh` is green, and the four suites' combined wall time is below their current one.
6. `git status --porcelain` is clean apart from this change's files.

## Verification

```bash
./scripts/ci.sh
```

The only runner of the test suite; it regenerates the Xcode project, lints, builds and tests. It is
both the regression check after each build step and the full gate at sign-off, per the project's
`## Pipeline` section. `swiftlint lint --quiet` runs inside it as a post-build phase.

## Files this change touches

| File | Change |
| --- | --- |
| `Sources/App/WorktreeGroupManager.swift` | `writeChain` becomes `private(set) var`; `reconcile(_:openIds:)` becomes `@discardableResult` returning its `Task<Void, Never>`. No behavioural edit. |
| `Tests/TestHelpers.swift` | `WorktreeGroupManagerGitTestCase` gains a helper that awaits `loadTask` then `writeChain`, and a `tearDown` that awaits the chain before the scratch root is removed. |
| `Tests/WorktreeGroupManagerTests.swift` | All 44 sleeps deleted. Two new cases (re-add no-op, `removeWorktreeFromGroup` position). |
| `Tests/WorktreeGroupManagerStatusTests.swift` | 11 sleeps deleted, 1 replaced by the awaited signal. One new case (main's status on the read path). |
| `Tests/WorktreeGroupManagerNameTests.swift` | Two sleeps replaced by the awaited signal, one by the returned reconcile `Task`. |
| `Tests/WorktreeGroupPersistenceTests.swift` | One sleep replaced by an awaited `writeChain`. Three new cases (repo-level re-read, non-integer position, no-op `setGrouping`). |

## Out of scope

- **The synthetic `/tmp` paths in `WorktreeGroupManagerTests`.** Those gestures still spawn `git
  config` writes that can only fail. Rehoming them onto the `GitRepoFixture` would make the suite
  slower, not faster, and none of its assertions read stored state. Left as is.
- **`Task.sleep` elsewhere in `Tests/`.** `WorkTaskManagerWatcherTests`, `PromptManagerTests`,
  `SavedCommandManagerTests` and `ShellPathStoreTests` also sleep; they are different subsystems
  with different signals and are not named by this task.
- **The 20 ms poll interval inside `waitFor`.** It is a poll granularity, not a fixed wait, and
  nothing in the task asks for it to change.
- **Any change to what `WorktreeGroupManager` does.** Decision 9: the two visibility widenings are
  the whole production diff.
