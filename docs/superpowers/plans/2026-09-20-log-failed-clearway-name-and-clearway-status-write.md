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
