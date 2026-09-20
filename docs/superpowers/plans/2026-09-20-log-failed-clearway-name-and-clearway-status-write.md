# Plan: Log failed clearway.name and clearway.status writes

Breaks down `docs/superpowers/specs/2026-09-20-log-failed-clearway-name-and-clearway-status-write.md`.

**Date:** 2026-09-20
**Base:** b4369a5 (`Split buttons for Run and Open in (#237)`)

## Architecture decisions carried from the spec

- `setName` and `setStatus` each drop the `Bool` their `configStore.set` answers. Routing both
  through the existing `Self.write(_:forKey:worktreeAt:in:)` is the whole change: the helper already
  does the `set`, tests the result and logs `worktree groups: <key> for <path> was not saved`
  (decisions 1, 3).
- Nothing new is written. No new log string at either call site — the key comes from the helper's
  `key` parameter, so the copy exists once (decision 3).
- No alert. A name or status is one value the next gesture overwrites and the next reload corrects,
  unlike the half-applied registry rewrite that owns `presentWriteAlert`. `presentWriteAlert` is not
  touched (decision 2).
- The optimistic publish stands on failure and nothing is retried; the next `reconcile` republishes
  what git holds (decision 4).
- The two `enqueueWrite` bodies stay plain `@Sendable` closures handed the store, capturing no
  manager — which is why `write` is `nonisolated static` (decision 6).
- `WorktreeConfigStore` does not change, including its own `worktree config:` lines and their
  redaction (decision 10).
- Clearing a value in a project with the extension off still logs nothing: `set` returns `true` for
  a `nil`/empty value when `extensionState()` is `.off`, because no `clearway.*` value can exist
  there (decision 5). Do not "fix" this.
- One test, in `Tests/WorktreeGroupPersistenceTests.swift`, covering both keys in one case. The log
  line itself has no seam — `Ghostty.logger` is not observable and PR #236 pinned none of its four
  log-only sites either. What is observable, and what the change could get wrong, is that a refused
  name or status write still publishes and raises no alert (decisions 7, 8).

## Dependency graph

One task. Nothing unblocks anything else.

```
T1 (source edit + test)
```

## Task list

### T1: Route setName and setStatus through Self.write, and pin that they stay silent to the user

**Files touched**

- `Sources/App/WorktreeGroupManager.swift`
- `Tests/WorktreeGroupPersistenceTests.swift`

**What it does**

In `setStatus` (`Sources/App/WorktreeGroupManager.swift:240-251`), replace the `enqueueWrite`
body's bare call:

```swift
await configStore.set(
    status?.rawValue,
    forKey: WorktreeConfigStore.statusKey,
    worktreeAt: path
)
```

with the helper, passing the store through:

```swift
await Self.write(
    status?.rawValue,
    forKey: WorktreeConfigStore.statusKey,
    worktreeAt: path,
    in: configStore
)
```

In `setName` (`:263-276`), the same substitution on the one-line call
`await configStore.set(stored, forKey: WorktreeConfigStore.nameKey, worktreeAt: path)` →
`await Self.write(stored, forKey: WorktreeConfigStore.nameKey, worktreeAt: path, in: configStore)`.

Both values are already `String?`, which is the helper's first parameter type, so nothing is
converted. Nothing else in either method moves: the guards, the optimistic publish and the
`enqueueWrite` wrapper are untouched, and the closures keep capturing only `path` and the value.

Then add one case to `Tests/WorktreeGroupPersistenceTests.swift`, beside the other failing-write
cases (`:107-182`). It creates a worktree, removes it with `repo.removeWorktree(at:)` so
`git -C <gone path> config --worktree` can only fail, sets a name and a status on it, drains the
write chain with `await settle()`, and asserts both values are still published and no alert was
recorded:

```swift
/// A name or status git refused is log-only: `WorktreeGroupManager` names the lost gesture in the
/// log and tells the user nothing, because the value is one the next gesture overwrites and the
/// next reload corrects — unlike the half-applied registry rewrite that owns the alert. Here the
/// worktree's directory is gone, so its `git config --worktree` writes can only fail.
func testAFailedNameOrStatusWriteStaysPublishedAndRaisesNoAlert() async throws {
    let path = try repo.addWorktree(branch: "member")
    let member = makeWorktree(branch: "member", path: path)
    manager.setName("Named", for: member)
    try await waitForStoredValue("Named", ofKey: WorktreeConfigStore.nameKey, at: path)
    try repo.removeWorktree(at: path)

    manager.setName("Renamed", for: member)
    manager.setStatus(.inReview, for: member)
    await settle()

    XCTAssertEqual(manager.name(for: member), "Renamed", "the publish stands when the write fails")
    XCTAssertEqual(manager.status(for: member), .inReview, "the publish stands when the write fails")
    XCTAssertTrue(recordedWriteAlerts.isEmpty, "a lost name or status is log-only")
}
```

The first `setName` before the removal is what gets the repo-level extension bootstrapped while the
worktree still exists, so the two failing writes fail on the worktree's own config and not on
`enableExtension`. Both gestures enqueue synchronously before `settle()` is called, so the one
sample covers both. Keep it as one case, not two — it is the pair the change could get wrong.

**Acceptance criteria**

- Neither `enqueueWrite` body in `setName` / `setStatus` calls `configStore.set` directly; both call
  `Self.write(…, in: configStore)`.
- No new `Ghostty.logger` call and no new string literal is added anywhere.
- `presentWriteAlert`, `WorktreeConfigStore` and every other method in `WorktreeGroupManager` are
  unchanged.
- The new test exists in `Tests/WorktreeGroupPersistenceTests.swift` and passes.
- Every existing name, status and persistence test passes untouched.

**Verification**

- `./scripts/ci.sh` — regenerates the project, lints, builds and runs the suite; green.
- `swiftlint lint --quiet` — zero errors. (`Sources/App/WorktreeGroupManager.swift` is 667 lines
  against a 700-line `file_length` warning; the edit is roughly net-neutral there.)
- `git diff --stat` shows exactly the two files above.

**Estimated scope:** XS — two call sites and one test case.

## Risks

| Risk | Impact | Mitigation |
| --- | --- | --- |
| The new test's writes succeed instead of failing, so it pins nothing | Med | The first `setName` is asserted to have landed via `waitForStoredValue` before `removeWorktree`, which is the same shape `testARenameWhoseMemberWritesFailLeavesTheRegistryUntouched` uses to force this failure. |
| `settle()` samples the write chain before both gestures are enqueued | Low | `setName` and `setStatus` enqueue synchronously on the main actor; the test body calls both before `settle()` with no `await` between them. |

## Open questions

None. The spec carries no open decisions.

## Build log

### T1: Route setName and setStatus through Self.write, and pin that they stay silent to the user

**What landed**

| File | State |
| --- | --- |
| `Sources/App/WorktreeGroupManager.swift` | Edited. `setStatus`'s `enqueueWrite` body (`:244-250`) and `setName`'s (`:275`) call `await Self.write(…, in: configStore)` instead of `await configStore.set(…)`. No other change; no new `Ghostty.logger` call and no new string literal. File is 668 lines, against SwiftLint's 700-line `file_length` warning. |
| `Tests/WorktreeGroupPersistenceTests.swift` | Edited. One case added after `testAFailedRegistryRewriteTellsTheUser`: `testAFailedNameOrStatusWriteStaysPublishedAndRaisesNoAlert`. |

**Evidence**

The change's only output is a log line, and `Ghostty.logger` has no test seam, so the watched
failure is the log the test run itself emits rather than an assertion. The same single test was run
against the unfixed code and against the fixed code, and the unified log is the before/after.

Unfixed (`-only-testing:…/testAFailedNameOrStatusWriteStaysPublishedAndRaisesNoAlert`, passing): both
writes genuinely fail, and `WorktreeGroupManager` says nothing about either —

```
[ghostty] worktree config: set clearway.name at /var/folders/…/.worktrees/member failed: fatal: cannot change to '/var/folders/…/.worktrees/member': No such file or directory
[ghostty] worktree config: set clearway.status at /var/folders/…/.worktrees/member failed: fatal: cannot change to '/var/folders/…/.worktrees/member': No such file or directory
Test Case '-[ClearwayTests.WorktreeGroupPersistenceTests testAFailedNameOrStatusWriteStaysPublishedAndRaisesNoAlert]' passed (1.508 seconds).
```

There is no `worktree groups:` line in that run. This is also what proves the test's premise: the
two `worktree config: … failed` lines are the store refusing both writes, so the case exercises the
path the change is about rather than a pair of writes that quietly succeeded (the plan's first
risk).

Fixed, same test, same command: each refusal is now named once, in the wording success criterion 1
asks for —

```
[ghostty] worktree config: set clearway.name at /var/folders/…/.worktrees/member failed: fatal: cannot change to …
[ghostty] worktree groups: clearway.name for /var/folders/…/.worktrees/member was not saved
[ghostty] worktree config: set clearway.status at /var/folders/…/.worktrees/member failed: fatal: cannot change to …
[ghostty] worktree groups: clearway.status for /var/folders/…/.worktrees/member was not saved
Test Case '-[ClearwayTests.WorktreeGroupPersistenceTests testAFailedNameOrStatusWriteStaysPublishedAndRaisesNoAlert]' passed (0.807 seconds).
```

The test case itself pins what stays observable across that change and is what the edit could get
wrong: both values are still published after a refused write, and `recordedWriteAlerts` is empty. It
passes before and after — decision 7 said so in advance, and that is recorded here rather than
dressed up as a regression test.

**Deviations from the plan**

None. The two substitutions and the one test case are exactly as written; the case's wording is the
plan's, reflowed to the file's 110-column comment width.

**Gate**

`./scripts/ci.sh` — green. `Executed 677 tests, with 0 failures (0 unexpected)`, `==> CI passed.`
SwiftLint runs inside it and reported nothing.

## Simplify pass

Nothing simplified: the change is two call-site substitutions onto an existing helper, which is
itself the reuse a simplify pass would have asked for, and `setStatus`'s multi-line call matches
the `positionKey` sites of the same width. `@discardableResult` on `WorktreeConfigStore.set` is now
unused by `Sources/` but still needed by `Tests/WorktreeConfigStoreTests.swift`, so it stays.

Coverage was re-checked rather than extended. The success path of both keys is pinned by the
round-trips in `WorktreeGroupManagerNameTests` and `WorktreeGroupManagerStatusTests`, which read
back through `git config --worktree --get`, so a wrong key or a lost write on the new route fails
them; `testTwoNamesInOneTurnLandInTheOrderTheyWereMade` pins the chain order through the helper and
`testSetNameEmptyOnAWorktreeWithNoStoredNameChangesNothing` pins the silent extension-off clear.
The failure path of both keys is the one new case. `Self.write` adds only the log to the `set` those
cover, so it carries no untested behaviour this route change relies on.

Both refusals were re-observed on the built binary, one line each, confirming the new case is not
vacuous:

```
[ghostty] worktree config: set clearway.name at <tmp>/.worktrees/member failed: fatal: cannot change to …
[ghostty] worktree groups: clearway.name for <tmp>/.worktrees/member was not saved
[ghostty] worktree config: set clearway.status at <tmp>/.worktrees/member failed: fatal: cannot change to …
[ghostty] worktree groups: clearway.status for <tmp>/.worktrees/member was not saved
```

`./scripts/ci.sh` — green, exit 0. `Executed 677 tests, with 0 failures (0 unexpected)`,
`==> CI passed.` `git status --porcelain` clean; only ignored `.clearway/`, `.work/` and
`Sources/App/BuildInfo.generated.swift`.

## PR review pass

Four agents read `git diff main...HEAD` from a fresh context: general code review against
`CLAUDE.md`, test coverage, error handling, and type design. The code review and the type-design
review returned nothing to change. Two findings were applied, both in the new test.

**The premise was unasserted.** The case relies on `repo.removeWorktree(at:)` making every
`git -C <path> config --worktree` fail, but asserted nothing that could only hold if it had. A
fixture or store change that let those writes succeed would have left the only failure-path case
for these two keys passing while covering nothing. One line, using a helper that already exists:

```swift
XCTAssertFalse(try repo.statusSucceeds(in: path), "git can no longer run in the worktree")
```

**"The next reload corrects" was wrong**, and the doc comment also read as though it checked the
log. `reloadConfig` has one non-test caller, `reconcile`, whose own single non-test caller is
`ContentView.swift:349` inside `.onChange(of: worktreeManager.worktrees)`; `Worktree` is `Hashable`
over `branch`, `path`, `isMain` and `headStatus` alone, so a refresh that returns the same worktree
set reconciles nothing — the sidebar's refresh button included. `reloadConfig`'s own doc comment
already says the accurate version: "a lost gesture would stay lost for the session." The comment now
says the next *launch* corrects it, and says outright that the log line has no test seam, so a
reader debugging a failure does not go looking for an assertion that was never there.

Neither touches the production diff, which stands as T1 left it.

### Findings not acted on

- **`@discardableResult` on `WorktreeConfigStore.set` / `setLocal` / `replaceLocalValues` is now
  load-bearing for tests only.** No `Sources/` caller discards any of the three after this change,
  so the attribute's only remaining production effect is to keep the compiler quiet the next time
  someone drops the `Bool` — the exact defect this change repairs. Dropping it and writing `_ =` at
  the dozen-odd test sites would buy back that static check. Out of scope: "any change to
  `WorktreeConfigStore`", and the simplify pass already recorded keeping it.
- **`WorktreeConfigStore`'s own failure line redacts in a release build.** `worktree config:
  \(what) failed: \(message)` carries no `privacy:` annotation, and non-annotated `String`
  interpolation in unified logging defaults to private, which is why `logFailure` carries
  `privacy: .public` and says so. So in a shipped build the operator sees `worktree config:
  <private> failed: <private>` above the new public line. This makes the new line strictly more
  valuable than the spec claimed — it is the only one naming the key and the path — but it also
  means `logFailure`'s doc comment ("`WorktreeConfigStore` has already logged why git refused … so
  this line cannot repeat it") is true in source and false in a shipped log. The line and its
  comment are both pre-existing, and its redaction is named in Out of scope.
- **Re-applying the same value after a failed write is a fully silent no-op.** `setName` and
  `setStatus` guard on `names[wt.id] != stored` / `statuses[wt.id] != status`, and the publish is
  optimistic, so a user who suspects a rename did not take and re-confirms the same name enqueues
  no write and logs nothing. Decision 2's "the next gesture overwrites it" holds for a *different*
  value, not a repeat. The guard predates this change and reverting the optimistic publish is named
  in Out of scope, but the rationale is weaker than the decision it supports.
- **Decision 2's "the next reload corrects" carries the same inaccuracy** the test comment did.
  The decision itself — log-only, no alert — is unaffected: a lost single value is still not the
  half-applied multi-step write that earns a modal. Only the sentence justifying it needs the
  narrower wording, and the Decisions table is not reopened at review.
- **No seam for the log line.** `presentWriteAlert` is precedent for one: a sibling injectable
  `reportWriteFailure` closure would make all six log-only sites in the file assertable for about
  four lines. Decision 7 settled that the line is unpinned, and PR #236 left its four sites the
  same way.
