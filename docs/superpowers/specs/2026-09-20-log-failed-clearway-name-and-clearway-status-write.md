# Log failed clearway.name and clearway.status writes

**Date:** 2026-09-20
**Base:** b4369a5 (`Split buttons for Run and Open in (#237)`)

`WorktreeGroupManager.setName` and `setStatus` publish optimistically and queue a
`WorktreeConfigStore.set` behind the write chain, discarding the `Bool` it answers. When git
refuses, the store logs why under `worktree config:` and the manager says nothing, so the log never
names the gesture that was lost. PR #236 gave the other four `clearway.*` keys exactly that line
through `Self.write(_:forKey:worktreeAt:in:)`; this change routes these two through the same helper.
Log-only, no alert, no other behaviour change.

## Decisions

| # | Question | Decision | Source |
| --- | --- | --- | --- |
| 1 | What is the mechanism? | Replace the bare `await configStore.set(…)` in each of the two `enqueueWrite` bodies with `await Self.write(…, forKey:worktreeAt:in:)` (`Sources/App/WorktreeGroupManager.swift:490-500`). Nothing new is written: the helper already does the `set`, tests the `Bool` and logs. | Task brief |
| 2 | Is there an alert? | No. Log-only, as the brief states and as decision 2 of `2026-09-19-surface-failed-group-and-position-writes.md` settled for every single-value write: a name or status is one value the next gesture overwrites and the next reload corrects, not a half-applied multi-step write like the registry. `presentWriteAlert` is not touched. | Task brief / prior spec |
| 3 | What do the lines say? | Whatever the helper already emits: `worktree groups: clearway.name for <path> was not saved` and `worktree groups: clearway.status for <path> was not saved`. The key comes from the `key` parameter, so the copy is not written twice. | Spec author |
| 4 | Does the manager revert the optimistic publish on failure? | No, unchanged. The next `reconcile` republishes what git holds — prior spec decision 9. | Prior spec |
| 5 | Does a clearing write log when the extension is off? | It cannot, and that is correct. `set` with a `nil` or empty value returns `true` when `extensionState()` is `.off` (`Sources/App/WorktreeConfigStore.swift:216-218`), because with the extension off no `clearway.*` value can exist. So clearing a name in a project that never stored one stays silent instead of logging a failure that did not happen. | Spec author |
| 6 | Do the two `enqueueWrite` bodies stay as they are otherwise? | Yes. They remain plain `@Sendable` closures handed the store, capturing no manager — the property the prior spec's assumption 4 records and the reason `write` is `nonisolated static`. | Spec author |
| 7 | Is anything tested, given a log line has no seam? | One test, and only one. There is no way to observe `Ghostty.logger`, so the line itself cannot be pinned — PR #236 pinned none of its four log-only sites either. What *is* observable is the pair the change could get wrong: a failed name or status write must still publish, and must raise no alert. One case in `Tests/WorktreeGroupPersistenceTests.swift` drives both keys against a removed worktree and asserts `recordedWriteAlerts` is empty. | Spec author |
| 8 | Where does that test live? | `Tests/WorktreeGroupPersistenceTests.swift`, beside the other failing-write cases (`:107-182`), not in `WorktreeGroupManagerNameTests` / `…StatusTests`. It is about what a refused write does, which is that file's subject, and `recordedWriteAlerts` is the base class's seam those two files never touch. One case covers both keys rather than two near-identical ones. | Spec author |
| 9 | How is the failing write produced in the test? | `repo.removeWorktree(at: path)` after the worktree exists (`Tests/TestHelpers.swift:89`), the way `testARenameWhoseMemberWritesFailLeavesTheRegistryUntouched` does (`Tests/WorktreeGroupPersistenceTests.swift:107-136`): `git -C <gone path> config --worktree` can then only fail, while the repo-level `enableExtension()` ahead of it still succeeds. `await settle()` drains the write chain (`Tests/TestHelpers.swift:232-235`); both gestures enqueue synchronously before it is called, so the single sample covers them. | Spec author |
| 10 | Does `WorktreeConfigStore` change? | No. Its own lines, and their redaction, stay exactly as they are — same boundary the prior spec drew. | Prior spec |

## Assumptions

Each verified against the working tree at `b4369a5`. No probe was written and none was needed; the
external claim this change rests on (`privacy: .public`) was quoted and dated in the prior spec and
is not re-litigated, because this change adds no new `logger` call.

1. **The helper exists and is reachable from both call sites.** `private nonisolated static func write(_:forKey:worktreeAt:in:) async` (`Sources/App/WorktreeGroupManager.swift:490-500`), on the same type as `setStatus` (`:240-251`) and `setName` (`:263-276`), which are members of the same class in the same file.
2. **The helper's behaviour is exactly today's plus the log.** It calls `configStore.set(value, forKey:worktreeAt:)` and, only on `false`, calls `logFailure("\(key) for \(path) was not saved")` (`:498-499`). `logFailure` is the `worktree groups:` prefix with `privacy: .public` (`:483`).
3. **Both call sites discard the `Bool` today.** `setStatus` at `Sources/App/WorktreeGroupManager.swift:244-250` and `setName` at `:273-275` call `configStore.set` as a statement; `set` is `@discardableResult` (`Sources/App/WorktreeConfigStore.swift:209-210`), so no warning marks the discard.
4. **The values passed are already `String?`.** `status?.rawValue` and `stored` — the helper's first parameter is `String?` (`:491`), so no conversion is introduced.
5. **The keys are the two the task names.** `nameKey = "clearway.name"`, `statusKey = "clearway.status"` (`Sources/App/WorktreeConfigStore.swift:12-13`), and the manager is their only writer (`grep nameKey|statusKey Sources/` returns only the store's declarations, these two write sites and the two read sites at `:444`, `:449`).
6. **No `false` the store returns on this path is otherwise silent at the git level.** A refused `set`/`unset` logs (`Sources/App/WorktreeConfigStore.swift:212-214`, `:220-222`), `.unknown` extension state logs through `probeExtension`, and `enableExtension()` logs through `reportingFailure: true`. So the new line adds the gesture and never repeats the git error — prior spec decision 3 and assumption 2 still hold with two more keys under them.
7. **The test base already records alerts and keeps every manager off the real presenter.** `recordedWriteAlerts` plus `makeRecordingManager()` (`Tests/TestHelpers.swift:203`, `:250-256`), used by both `setUp` and `restartManager()`. Nothing new is wired for the test in decision 7.
8. **`GitRepoFixture.removeWorktree(at:)` exists** (`Tests/TestHelpers.swift:89`) and is already used to force this class of failure (`Tests/WorktreeGroupPersistenceTests.swift:113`, `:144`).
9. **The file stays inside SwiftLint's limits.** `Sources/App/WorktreeGroupManager.swift` is 667 lines against a 700-line warning and 1000-line error (`.swiftlint.yml:26-28`); the edit is net-negative there (the multi-line `set` call in `setStatus` becomes a `write` call of the same shape, and `setName`'s stays one line).
10. **No new file, so no `project.yml` edit.** Both targets glob their directories; `ci.sh` runs `xcodegen generate` regardless.

## Objective

A refused `clearway.name` or `clearway.status` write names itself in the log, under the same prefix
and in the same wording as the four keys PR #236 covered, so a developer reading the log after a
rename or status change that snapped back learns which gesture was lost and on which worktree.

### Success criteria

- A failed `clearway.name` write logs `worktree groups: clearway.name for <path> was not saved`, and
  a failed `clearway.status` write the same with `clearway.status`, each exactly once.
- Neither raises an `NSAlert`, and no test records one for them.
- A successful write logs nothing, and clearing a value in a project with the extension off logs
  nothing.
- The optimistic publish and the write chain's ordering are unchanged; every existing name, status
  and persistence test passes untouched.
- `./scripts/ci.sh` green, `swiftlint lint --quiet` with zero errors.

## Commands

Regression check for every build step, and the full gate at sign-off, are the same command:

```bash
./scripts/ci.sh
```

It regenerates the Xcode project, lints, builds and runs the test suite. Lint alone:

```bash
swiftlint lint --quiet
```

`ci.sh` does not refuse on a dirty tree, so run `git status --porcelain` before any CI stamp and
report untracked or ignored files — expect the un-gitignored `default.profraw` after any Debug
launch.

## Files this change touches

**Edited**

- `Sources/App/WorktreeGroupManager.swift` — the `enqueueWrite` bodies of `setStatus` (`:244-250`)
  and `setName` (`:273-275`) call `Self.write(…)` instead of `configStore.set(…)`.
- `Tests/WorktreeGroupPersistenceTests.swift` — one case: a name and a status written to a removed
  worktree stay published and raise no alert.

**New**

- None.

## Log text

Both `Ghostty.logger.warning`, both prefixed `worktree groups:`, both produced by the existing
helper rather than written at the call site:

- `clearway.name for <path> was not saved`
- `clearway.status for <path> was not saved`

## Out of scope

- Any alert for these two keys — decision 2.
- Reverting or retrying the optimistic publish when a write fails.
- Any change to `WorktreeConfigStore`, including its existing log lines and their redaction.
- Widening `Self.write` to the repo-level keys (`clearway.grouping`, `clearway.groupOrder`), which
  are not worktree-scoped and log at their own call sites today.
- Diagnosing *why* a write failed.
