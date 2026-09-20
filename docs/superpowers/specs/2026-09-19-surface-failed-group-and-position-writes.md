# Surface failed group and position writes

**Date:** 2026-09-19
**Base:** 1206708 (`Keep worktree groups, order and grouping mode in git config (#230)`)

Every sidebar gesture that writes git config publishes optimistically and queues the write behind
`WorktreeGroupManager`'s write chain. When the write fails, the manager notices — `set`, `setLocal`
and `replaceLocalValues` all answer `Bool` — and does nothing with the answer, except in
`writeRegistry`, which abandons the registry write silently. The next reload republishes what git
holds and the sidebar snaps back with no explanation. This change makes every one of those failures
say so: a `Ghostty.logger` line naming the gesture that was lost and the worktree it was lost on,
plus, for the two cases that leave the user's change half-applied on disk, an `NSAlert`.

## Decisions

| # | Question | Decision | Source |
| --- | --- | --- | --- |
| 1 | Does the abandoned-registry case get a user-visible alert? | Yes. When a member's `clearway.group` write fails during a group rename or delete, `writeRegistry` skips the registry write, and the user sees an `NSAlert` naming the group and the worktree whose write failed — `.warning` style, one OK button, `runModal()`, the shape `OpenInMenu.presentFailure` uses (`Sources/App/OpenInMenu.swift:41-48`). | Operator |
| 2 | Does any other failed write alert? | **Amended 2026-09-20.** Yes, one: a failed `replaceLocalValues` on `clearway.groupOrder`. It is unset-all-then-add-each, so a refusal mid-loop leaves the registry truncated or empty and every group is gone on the next launch — half-applied exactly like the abandoned registry, not a single value the next gesture overwrites. It raises the same alert through the same presenter seam, naming the group the gesture acted on, alongside its existing log line. Individual `clearway.group`, `clearway.position` and `clearway.grouping` writes stay log-only. The alert's `path` becomes `String?` rather than the type gaining a second field or a case: `clearway.groupOrder` is repo-level and names no worktree, so a path there could only be invented, and `informativeText` says `the group list` where a member's says `the group for <path>`. *(Was: No. Individual `clearway.group`, `clearway.position` and `clearway.grouping` writes, and the `replaceLocalValues` registry write when it fails on its own, are log-only.)* | Operator |
| 3 | How is double-logging avoided while still naming the worktree? | The two layers log different facts and neither can repeat the other. `WorktreeConfigStore` logs *why git refused* and already names the key and the worktree path (`Sources/App/WorktreeConfigStore.swift:213`, `221`). The manager logs *which gesture was lost*, and structurally cannot repeat the git error: `set`, `setLocal` and `replaceLocalValues` return `Bool` and keep the message inside the store. One failed write therefore produces exactly two lines — `worktree config: set clearway.group at <path> failed: <git stderr>` and `worktree groups: clearway.group for <path> was not saved`. | Spec author |
| 4 | What distinguishes the manager's lines? | The prefix `worktree groups:`, against the store's `worktree config:`. Both are `Ghostty.logger.warning`. | Spec author |
| 5 | Are the interpolated paths and keys marked public? | Yes, `privacy: .public`, following `SavedCommandStore.swift:74`. Apple, *Generating Log Messages from Your Code* (fetched 2026-09-19): "By default, the system doesn't redact integer, floating-point and Boolean values, but it does redact the contents of dynamic strings and complex dynamic objects." Without the modifier a release build logs `<private>` where the worktree should be, which is the whole point of the line. The store's existing lines are left as they are — changing them is not this task. | Spec author |
| 6 | Where does the `NSAlert` live? | A new `Sources/App/WorktreeGroupWriteAlert.swift`: a small `Sendable` value carrying the group name and the worktree path — optional, by amended decision 2 — with pure `messageText` / `informativeText` and a `@MainActor present()` that runs the alert. The copy is then pinned by tests, and AppKit stays out of the manager — the same split `OpenInAppLauncher.failureMessage` makes (`Sources/App/OpenInAppLauncher.swift:31-42`). | Spec author |
| 7 | How do tests avoid opening a modal nothing can dismiss? | The manager holds the presenter as an instance closure defaulting to the real one — the shape `TerminalManager.mainCommandProvider` uses (`Sources/App/TerminalManager.swift:168`) — and `WorktreeGroupManagerGitTestCase` installs a recorder in both places it builds a manager (`Tests/TestHelpers.swift:194`, `213`). This is not optional: `testARenameWhoseMemberWritesFailLeavesTheRegistryUntouched` (`Tests/WorktreeGroupPersistenceTests.swift:106-125`) drives exactly the abandoned-registry path, and a modal on the write chain would stall the chain the rest of that test waits on. | Spec author |
| 8 | Is the alert awaited on the write chain? | Yes, inline where the abandon happens. `writeRegistry` returns at the first failed member, so one gesture raises at most one alert, and a chain held while the user reads it is correct: nothing should keep writing behind a message saying a write failed. | Spec author |
| 9 | Does the manager revert its optimistic state on failure? | No. The next reload already restores what git holds; the task is to explain the snap-back, not to change it. | Spec author |
| 10 | How does `writeRegistry` learn the group to name? | A new parameter. The value it writes to members is not it: a delete passes `nil` there, and the alert must still name the deleted group. All three callers know it — `createGroup` the new name, `renameGroup` the trimmed new name, `deleteGroup` the name being removed — so it is non-optional. `createGroup` passes no members, so the only alert it can reach is the registry rewrite's — amended decision 2. | Spec author |
| 11 | How is the worktree named in the alert? | By its full path, the way `OpenInAppLauncher.spawnFailureMessage` names the folder (`Sources/App/OpenInAppLauncher.swift:40-42`). A member is identified by its path and nothing else here (`Sources/App/WorktreeGroupManager.swift:540-546`); the manager's `names` map holds only worktrees the user has renamed, so a friendlier label would be absent exactly when it is needed. | Spec author |
| 12 | What does the alert say? | **Amended 2026-09-20.** Title `Couldn't save the group "<group>"`, unchanged. Body promises no revert: `Clearway couldn't write the group for <path>. The sidebar will show what git holds.` — and, where the registry itself failed and there is no path, `Clearway couldn't write the group list. The sidebar will show what git holds.` A multi-member rename where one write lands and another fails leaves the landed member naming a group the registry does not list, so it renders ungrouped on the next reload rather than as it was; and a reload only runs when the worktree list changes. *(Was: body `Clearway couldn't write the group for <path>, so the sidebar will go back to how it was.`)* | Operator |
| 13 | Which writes are in scope? | `clearway.group`, `clearway.position`, `clearway.grouping` and `clearway.groupOrder`. `clearway.name` and `clearway.status` are not — the task names four keys and `setName`/`setStatus` are a separate gesture path. Recorded as a follow-up, not done here. | Spec author |

## Assumptions

Each verified against the codebase at `1206708`. No probe was needed and none was written; the one
external claim (decision 5) is quoted from Apple's documentation with its fetch date.

1. **The store already names the key and the worktree in its own log.** `log("set \(key) at \(path)", message)` and the `--unset` counterpart (`Sources/App/WorktreeConfigStore.swift:213`, `221`). So the manager's job is the gesture, not the key-and-path pair — decision 3.
2. **No `false` the store returns is silent at the git level.** `set` and `setLocal` return `false` either from a logged refusal (`WorktreeConfigStore.swift:212-214`, `220-222`, `243-245`), from `extensionState() == .unknown` (logged by `probeExtension`, `:302`), or from `enableExtension()` (logged through `reportingFailure: true`, `:321-347`). `replaceLocalValues` adds `add \(key)` and `unsetAllLocal`'s `unset \(key)` (`:261-262`, `273-274`). The manager adding the raw error again would be the duplicate; adding the gesture is not.
3. **The manager sees a `Bool` and nothing else.** `set`, `setLocal` and `replaceLocalValues` are `@discardableResult ... -> Bool` (`Sources/App/WorktreeConfigStore.swift:201`, `230`, `253`), and every manager call site discards it today except the `guard` in `writeRegistry` (`Sources/App/WorktreeGroupManager.swift:474`).
4. **The write-chain body is a plain Swift closure, not a block.** `enqueueWrite` takes `@escaping @Sendable (WorktreeConfigStore) async -> Void` (`Sources/App/WorktreeGroupManager.swift:457`), so a literal written inside a `@MainActor` method infers `nonisolated` and is checked statically — the exception CLAUDE.md draws against `@convention(c)` / `@convention(block)`. Reaching the presenter through a captured `@MainActor @Sendable` closure value keeps that property and captures no manager, preserving the note at `:454-456`.
5. **`Ghostty.logger` is reachable from a nonisolated `@Sendable` body.** `Sources/Ghostty/Ghostty.swift:7`, already called that way from the `Sendable` `WorktreeConfigStore` (`:396`).
6. **The abandoned-registry path is already under test.** `testARenameWhoseMemberWritesFailLeavesTheRegistryUntouched` deletes the member's directory so `git -C <path> config --worktree` can only fail (`Tests/WorktreeGroupPersistenceTests.swift:106-125`). This is the test that would meet the modal — decision 7.
7. **The one test that builds a manager outside the base installs its own presenter.** `testAProjectWhereTheExtensionCannotBeEnabledShowsNoGroups` (`Tests/WorktreeGroupPersistenceTests.swift`) calls only `createGroup`, which passes no members to `writeRegistry` (`Sources/App/WorktreeGroupManager.swift:82-86`) — so under amended decision 2 the registry failure it reaches is now the alerting one, and both managers it builds carry a presenter of their own rather than the live one.
8. **A member's ID is its path**, so a log line and an alert can name the worktree without a lookup (`Sources/App/WorktreeGroupManager.swift:540-546`; `writePositions` is keyed the same way, `:584-595`).
9. **Production builds the manager in one place**, `Sources/App/ProjectWindow.swift:92`, and never touches the presenter, so the default is the real alert and no wiring is added.
10. **An instance closure defaulting to real behaviour is the established seam.** `TerminalManager.mainCommandProvider: () -> String? = { nil }` (`Sources/App/TerminalManager.swift:168`), wired at `ContentView.swift:384`. Here the default is the live presenter rather than a stub, so only tests replace it.
11. **New files need no `project.yml` edit but do need `ci.sh`.** Both targets glob a directory — `Sources` (`project.yml:25-26`) and `Tests` (`project.yml:303-304`) — and `xcodegen generate` runs inside `ci.sh`.
12. **The manager stays inside SwiftLint's limits.** `Sources/App/WorktreeGroupManager.swift` is 609 lines against a 700-line warning and 1000-line error (`.swiftlint.yml`), and the change adds roughly 25 lines there; the alert type's own file keeps the rest out.

## Objective

A failed git-config write from the sidebar is never silent. The developer reading the log learns
which gesture was lost and on which worktree, in addition to the git error the store already
records; the user whose rename or delete left members naming a group the registry does not list is
told, with the group and the worktree named, instead of watching the sidebar revert for no visible
reason.

### Success criteria

- A rename or delete whose member write fails raises exactly one alert, naming the group and the
  failing worktree's path, and still leaves the registry untouched.
- A failed `clearway.groupOrder` rewrite raises one alert naming the group and no path.
- The alert's title and body are pinned by unit tests against a group name and a path.
- A failed `clearway.group`, `clearway.position`, `clearway.grouping` or `clearway.groupOrder`
  write logs one `worktree groups:` warning naming the gesture and, where there is one, the
  worktree path — and the manager logs no git error text, so nothing is logged twice.
- Interpolated paths and keys survive a release build's redaction (`privacy: .public`).
- No test opens a modal: the git-backed test base replaces the presenter everywhere it builds a
  manager, including `restartManager()`.
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

**New**

- `Sources/App/WorktreeGroupWriteAlert.swift` — the group name and worktree path the alert names,
  its two pure copy properties, and the `@MainActor present()` that runs the `NSAlert`.
- `Tests/WorktreeGroupWriteAlertTests.swift` — pins the copy.

**Edited**

- `Sources/App/WorktreeGroupManager.swift` — the presenter seam and its default; a private
  `nonisolated static` log helper; failure handling at the six write sites (`addWorktree`,
  `removeWorktreeFromGroup`, `setGrouping`, `writePositions`, and both halves of `writeRegistry`);
  `writeRegistry` gains the affected group's name, passed by `createGroup`, `renameGroup` and
  `deleteGroup`.
- `Tests/TestHelpers.swift` — `WorktreeGroupManagerGitTestCase` installs a recording presenter at
  both manager-construction sites and exposes what it recorded.
- `Tests/WorktreeGroupPersistenceTests.swift` — `testARenameWhoseMemberWritesFailLeavesTheRegistryUntouched`
  additionally asserts the one recorded failure names the group and the removed worktree's path.

## Log and alert text

Manager lines, all `Ghostty.logger.warning`, all prefixed `worktree groups:`:

- `clearway.group for <path> was not saved`
- `clearway.position for <path> was not saved`
- `clearway.grouping was not saved`
- `clearway.groupOrder was not saved`
- `clearway.groupOrder was not rewritten: clearway.group for <path> was not saved` — the abandoned
  registry, which also raises the alert.

- `clearway.groupOrder was not saved` — the failed registry rewrite, which also raises the alert.

Alert:

- Title: `Couldn't save the group "<group>"`
- Body, a member write: `Clearway couldn't write the group for <path>. The sidebar will show what git holds.`
- Body, the registry rewrite: `Clearway couldn't write the group list. The sidebar will show what git holds.`

## Out of scope

- `clearway.name` and `clearway.status` write failures (`setName`, `setStatus`). The same manager
  layer is silent for them; the task names four keys and this change does not widen to a fifth and
  sixth. Follow-up.
- Reverting the optimistic publish at the moment a write fails, or retrying it. The reload already
  restores what git holds — decision 9.
- Any change to `WorktreeConfigStore`, including making its existing log lines `privacy: .public`.
- Anything about *why* a write failed: this change reports failure, it does not diagnose it.
