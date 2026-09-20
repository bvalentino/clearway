# Plan: Surface failed group and position writes

Breaks down `docs/superpowers/specs/2026-09-19-surface-failed-group-and-position-writes.md`.

**Date:** 2026-09-19
**Base:** 1206708 (`Keep worktree groups, order and grouping mode in git config (#230)`)

## Architecture decisions carried from the spec

- Every failed `clearway.group` / `clearway.position` / `clearway.grouping` / `clearway.groupOrder`
  write logs one `Ghostty.logger.warning` from `WorktreeGroupManager`, prefixed `worktree groups:`,
  naming the gesture that was lost and the worktree path where there is one (decisions 3, 4, 13).
- The manager never logs git's error text. `WorktreeConfigStore` already logs *why* git refused,
  with its own `worktree config:` prefix, and only hands the manager a `Bool` (decision 3). Nothing
  in `WorktreeConfigStore` changes, including its existing log lines.
- Interpolated paths and keys carry `privacy: .public`, or a release build logs `<private>` where
  the worktree should be (decision 5).
- Only one failure is user-visible: `writeRegistry` abandoning the registry write because a
  member's `clearway.group` write failed, which leaves a rename or delete half-applied. That raises
  an `NSAlert` — `.warning`, one OK button, `runModal()` — in addition to its log line. Every other
  failure is log-only (decisions 1, 2).
- The alert is a value type in its own file, `WorktreeGroupWriteAlert`: group name + worktree path,
  pure `messageText` / `informativeText`, and a `@MainActor present()`. AppKit stays out of the
  manager and the copy is unit-testable (decision 6).
- The manager reaches the alert through an instance closure defaulting to the real presenter, the
  shape `TerminalManager.mainCommandProvider` uses, so tests can swap in a recorder (decisions 7,
  10). Production never touches it (`Sources/App/ProjectWindow.swift:92`).
- The alert is awaited inline on the write chain where the abandon happens. `writeRegistry` returns
  at the first failed member, so one gesture raises at most one alert (decision 8).
- `writeRegistry` gains a non-optional affected-group-name parameter: the value it writes to
  members is `nil` on a delete, and the alert must still name the deleted group (decision 10).
- No optimistic state is reverted and nothing is retried. The next reload already restores what git
  holds; this change explains the snap-back (decision 9).
- Exact strings, to be reproduced verbatim:
  - `worktree groups: clearway.group for <path> was not saved`
  - `worktree groups: clearway.position for <path> was not saved`
  - `worktree groups: clearway.grouping was not saved`
  - `worktree groups: clearway.groupOrder was not saved`
  - `worktree groups: clearway.groupOrder was not rewritten: clearway.group for <path> was not saved`
  - Alert title: `Couldn't save the group "<group>"`
  - Alert body: `Clearway couldn't write the group for <path>, so the sidebar will go back to how it was.`
- Out of scope: `setName` / `setStatus` failures, reverting or retrying a write, any edit to
  `WorktreeConfigStore`, and diagnosing *why* a write failed.

## Dependency graph

```
T1 (WorktreeGroupWriteAlert + copy tests)  ──┐
                                             ├──> T3 (presenter seam, alert on abandon, test base recorder)
T2 (manager failure logging, six sites)   ───┘
```

T1 and T2 touch disjoint files and can run in either order or in parallel. T3 needs the alert type
from T1 and edits the same `writeRegistry` body T2 rewrites, so it runs last.

## T1: The alert value type and its copy tests

**Files**

- `Sources/App/WorktreeGroupWriteAlert.swift` (new)
- `Tests/WorktreeGroupWriteAlertTests.swift` (new)

**What it does**

Adds a `struct WorktreeGroupWriteAlert: Sendable, Equatable` holding `group: String` and
`path: String`, with:

- `var messageText: String` → `Couldn't save the group "\(group)"`
- `var informativeText: String` → `Clearway couldn't write the group for \(path), so the sidebar
  will go back to how it was.`
- `@MainActor func present()` → builds an `NSAlert`, sets `messageText`, `informativeText`,
  `alertStyle = .warning`, `addButton(withTitle: "OK")`, `runModal()`. Same shape as
  `OpenInMenu.presentFailure` (`Sources/App/OpenInMenu.swift:41-48`).

`import AppKit` (or `SwiftUI`, matching the file's needs) lives here and nowhere else for this
change. No other file references the type yet — T3 wires it in.

The tests pin both copy properties against a concrete group name and a concrete path, so a later
reword has to be deliberate. `present()` is not tested: it opens a modal.

**Acceptance criteria**

- `WorktreeGroupWriteAlert(group:path:)` exists, is `Sendable`, and its two copy properties are
  pure and callable off the main actor.
- `messageText` and `informativeText` match the spec strings character for character, including
  the straight double quotes around the group name and the trailing period.
- `present()` is `@MainActor` and is the only place AppKit is touched.

**Verification**

- `./scripts/ci.sh` green; the new tests run and pass.
- `swiftlint lint --quiet` reports zero errors.

## T2: Log every failed write in the manager

**Files**

- `Sources/App/WorktreeGroupManager.swift`

**What it does**

Adds a `private nonisolated static func logFailure(_ message: String)` (or equivalently named
helper) that emits `Ghostty.logger.warning("worktree groups: \(message, privacy: .public)")`, and
stops discarding the `Bool` at every write site in the manager that writes one of the four keys in
scope:

1. `addWorktree` — `clearway.group` then `clearway.position` for one path. A failed group write
   logs `clearway.group for <path> was not saved`; a failed position write logs
   `clearway.position for <path> was not saved`. Both writes are still attempted; the group
   failing does not skip the position.
2. `removeWorktreeFromGroup` — same two lines, same rule.
3. `setGrouping` — a failed `setLocal` logs `clearway.grouping was not saved`.
4. `writePositions` — a failed `set` logs `clearway.position for <path> was not saved` per path,
   and the loop continues to the remaining paths.
5. `writeRegistry`, member half — the `guard ... else { return }` that abandons the registry logs
   `clearway.groupOrder was not rewritten: clearway.group for <path> was not saved` before
   returning. (T3 adds the alert beside this line.)
6. `writeRegistry`, registry half — a failed `replaceLocalValues` logs
   `clearway.groupOrder was not saved`.

Paths are interpolated with `privacy: .public`. The manager logs no git error text anywhere — it
has none. Behaviour is otherwise unchanged: nothing new returns early, nothing is reverted.

**Acceptance criteria**

- No call to `configStore.set`, `configStore.setLocal` or `configStore.replaceLocalValues` inside
  `WorktreeGroupManager.swift` discards its result any more, for the four keys in scope.
  `setName` and `setStatus` are deliberately untouched.
- Each of the five log lines in the spec's "Log and alert text" section is produced at exactly one
  site, worded as written, prefixed `worktree groups:`.
- Every interpolated path is marked `privacy: .public`.
- The existing suites, including `testARenameWhoseMemberWritesFailLeavesTheRegistryUntouched`,
  still pass unchanged — the abandon still returns before the registry write.

**Verification**

- `./scripts/ci.sh` green.
- `swiftlint lint --quiet` reports zero errors; the file stays under the 700-line warning.
- `grep -n "await configStore\." Sources/App/WorktreeGroupManager.swift` shows every group,
  position, grouping and groupOrder call under a `guard`/`if` that handles `false`.

## T3: Alert on the abandoned registry, and keep tests out of the modal

**Files**

- `Sources/App/WorktreeGroupManager.swift`
- `Tests/TestHelpers.swift`
- `Tests/WorktreeGroupPersistenceTests.swift`

**What it does**

Adds the presenter seam and raises the alert:

- A stored instance closure on the manager, `var presentWriteAlert: @MainActor @Sendable
  (WorktreeGroupWriteAlert) -> Void = { $0.present() }` — internal, not private, so the test base
  can replace it; the default is the live presenter, so `ProjectWindow` needs no wiring. It is a
  plain Swift closure type, never `@convention(block)`, so the literal is checked statically.
- `writeRegistry` gains the affected group's name as a non-optional parameter, distinct from the
  value written to members: `createGroup` passes the new name, `renameGroup` the trimmed new name,
  `deleteGroup` the name being removed. `createGroup` passes no members, so it can never reach the
  alert.
- The `enqueueWrite` body captures the presenter closure value (not `self`, preserving the
  no-manager-capture note at `WorktreeGroupManager.swift:454-456`) and, at the member-write abandon
  added in T2, `await presenter(WorktreeGroupWriteAlert(group: group, path: path))` before
  returning. The chain is held while the modal is up, which is correct: nothing should keep writing
  behind a message saying a write failed. The registry-half failure raises nothing.

Keeps the suite out of the modal:

- `WorktreeGroupManagerGitTestCase` installs a recording presenter at **both** places it builds a
  manager — `setUp` and `restartManager()` — and exposes what was recorded, e.g. a
  `private(set) var recordedWriteAlerts: [WorktreeGroupWriteAlert]` appended to by the installed
  closure. Both sites matter: `restartManager()` otherwise hands back a manager with the live
  presenter. Reset the recording when a manager is replaced or in `tearDown`, whichever keeps the
  existing assertions honest.
- `testARenameWhoseMemberWritesFailLeavesTheRegistryUntouched` additionally asserts exactly one
  alert was recorded and that it names the new group (`"New"`) and the removed worktree's path.

**Acceptance criteria**

- A rename or delete whose member write fails raises exactly one alert, carrying the group name and
  the failing worktree's path, and still leaves `clearway.groupOrder` untouched.
- No test opens a modal: every manager built by `WorktreeGroupManagerGitTestCase`, including the
  one from `restartManager()`, carries the recorder.
- `testAProjectWhereTheExtensionCannotBeEnabledShowsNoGroups` still passes — it only calls
  `createGroup`, which passes no members and so never reaches the presenter.
- The manager still contains no AppKit import and no `NSAlert`.

**Verification**

- `./scripts/ci.sh` green, with the whole suite completing — a stalled run is the failure mode this
  task exists to prevent, so confirm the suite finishes rather than only that it did not report a
  failure.
- `swiftlint lint --quiet` reports zero errors.
- `git status --porcelain` shows no stray files beyond the un-gitignored `default.profraw` a Debug
  launch leaves.

## Risks

| Risk | Impact | Mitigation |
| --- | --- | --- |
| A manager built in a test without the recorder opens a modal and stalls CI | High | T3's acceptance criteria name both construction sites in `TestHelpers.swift`; verification requires the suite to finish, not merely to report no failure |
| The presenter closure captures the manager and reintroduces a retain path into the write chain | Medium | Capture the closure value in the `enqueueWrite` body, as the store is captured today |
| A path logged without `privacy: .public` reads `<private>` in a release build | Medium | Acceptance criterion on T2; the whole point of the line is the worktree it names |

## Build log

### T1: The alert value type and its copy tests

| File | State |
| --- | --- |
| `Sources/App/WorktreeGroupWriteAlert.swift` | New. `struct WorktreeGroupWriteAlert: Sendable, Equatable` with `group` / `path`, the two pure copy properties, and `@MainActor present()`. The only `import AppKit` this change adds. |
| `Tests/WorktreeGroupWriteAlertTests.swift` | New. Three tests: the title, the body, and both read from a `Task.detached` body. |
| `Clearway.xcodeproj/project.pbxproj` | Regenerated by `xcodegen generate` inside `ci.sh`; both targets glob their directory, so `project.yml` needed no edit. |

**Evidence.** T1 adds a type rather than fixing a bug, so there is no unfixed code to watch fail;
the pins were proved instead by perturbing the copy (`the group` → `group`, `path),` → `path);`)
and running the class on its own. All three went red:

```
Tests/WorktreeGroupWriteAlertTests.swift:20: error: -[ClearwayTests.WorktreeGroupWriteAlertTests testTitleNamesTheGroupInStraightQuotes] : XCTAssertEqual failed: ("Couldn't save group "Review"") is not equal to ("Couldn't save the group "Review"")
Tests/WorktreeGroupWriteAlertTests.swift:24: error: -[ClearwayTests.WorktreeGroupWriteAlertTests testBodyNamesTheWorktreePathAndTheRevert] : XCTAssertEqual failed: ("Clearway couldn't write the group for /Users/dev/project/.worktrees/fix-crash; so the sidebar will go back to how it was.") is not equal to ("Clearway couldn't write the group for /Users/dev/project/.worktrees/fix-crash, so the sidebar will go back to how it was.")
Tests/WorktreeGroupWriteAlertTests.swift:32: error: -[ClearwayTests.WorktreeGroupWriteAlertTests testCopyIsReadableOffTheMainActor] : XCTAssertEqual failed: ("Couldn't save group "Review"") is not equal to ("Couldn't save the group "Review"")
	 Executed 3 tests, with 4 failures (0 unexpected) in 0.087 seconds
** TEST FAILED **
```

The copy was then restored character for character and the gate re-run.

**Deviations from the plan.** None. The plan left the import open (`AppKit` or `SwiftUI`); `AppKit`
is what `NSAlert` needs and nothing here draws a view.

**Gate.** `./scripts/ci.sh` — exit 0, `Executed 559 tests, with 0 failures (0 unexpected)`, run
after the last source edit. `swiftlint lint --quiet` — exit 0, zero errors; the two warnings it
prints are pre-existing (`WorktreeDraft.swift:17`, `WorktreeConfigStore.swift:406`). The three new
tests are confirmed present in the result bundle as
`ClearwayTests/WorktreeGroupWriteAlertTests/*`. `git status --porcelain` shows only the two new
files and the regenerated `project.pbxproj`; no `default.profraw`, since the app was never launched.
