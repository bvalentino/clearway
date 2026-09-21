# Make WorktreeConfigStore's git error logs public in release builds

**Date:** 2026-09-20
**Base:** b4369a5 (`Split buttons for Run and Open in (#237)`)

`WorktreeConfigStore.log(_:_:)` interpolates two dynamic strings into a `Ghostty.logger.warning`
without a privacy modifier, so a release build redacts both: the line reads
`worktree config: <private> failed: <private>` and carries no information at all. Every one of the
store's twelve failure reports goes through that one helper. `WorktreeGroupManager` (PR #236)
already marks its own line `privacy: .public` and logs *which gesture was lost*, which is why a
release log today says a gesture failed but never why git refused. This change annotates both
interpolations in the store's helper so the key, the path, the git command and git's stderr survive
redaction.

## Decisions

| # | Question | Decision | Source |
| --- | --- | --- | --- |
| 1 | Is this the follow-up the reference PR deferred? | Yes. `2026-09-19-surface-failed-group-and-position-writes.md` puts it in Out of scope verbatim — "Any change to `WorktreeConfigStore`, including making its existing log lines `privacy: .public`" — and decision 5 there says "The store's existing lines are left as they are — changing them is not this task." So nothing here re-litigates that spec; it discharges it. | Reference spec |
| 2 | Which interpolations become public — `message` only, or `what` as well? | Both. The brief names the reason, but `what` is redacted by the same rule, and `worktree config: <private> failed: <git error>` would not say which key or which worktree lost the write. `WorktreeGroupManager.logFailure` publishes its whole message for exactly this reason (`Sources/App/WorktreeGroupManager.swift:483`), as do `GitResolver`, `ShellPathResolver` and `ShellPathStore` for paths. | Spec author |
| 3 | Is `.public` acceptable for git's stderr? | Yes. What the two parameters can carry is bounded: `what` is a key name, a worktree path, or a git argument vector, and no call site interpolates a user-authored value — `set`/`setLocal`/`replaceLocalValues` log `set \(key) at \(path)`, `unset \(key)`, `add \(key)`, never the value being written (`Sources/App/WorktreeConfigStore.swift:221`, `229`, `252`, `269`, `281`). `message` is git's stderr, which can name a path. Filesystem paths are already published across this codebase — `GitResolver.swift:48`, `ShellPathResolver.swift:139` publishes the entire resolved `PATH`, `SavedCommandStore.swift:122` publishes a project path — so a git path in a warning introduces no category of data the log does not already carry. | Spec author |
| 4 | Is the fix one edit to the helper, or per call site? | One edit to the helper. All twelve reports already funnel through `log(_:_:)`; no call site touches `Ghostty.logger` directly (verified: `Sources/App/WorktreeConfigStore.swift:404` is the file's only `logger` reference). | Spec author |
| 5 | Does this get a unit test? | No, and that is deliberate rather than an omission. Redaction is applied by the log *reader* according to its privilege, not baked into the stored entry, so a test reading its own process's entries through `OSLogStore(scope: .currentProcessIdentifier)` sees the unredacted text either way and would pass identically before and after the change. Adding a seam on `log` purely to assert a format string would be indirection the change does not need. PR #236 set the same precedent: its success criteria list the `privacy: .public` requirement and its tests pin only the alert copy. Verification is the source line plus a green `./scripts/ci.sh`. | Spec author |
| 6 | Does the message text, prefix or log level change? | No. The line stays `Ghostty.logger.warning("worktree config: <what> failed: <message>")` — same prefix, same level, same wording, so the two-layer split decision 3 of the reference spec established (`worktree config:` = why git refused, `worktree groups:` = which gesture was lost) is untouched. | Spec author |

## Assumptions

Each verified against the working tree at `b4369a5`. No probe was written; the one external claim is
quoted below with its fetch date.

1. **A `String` interpolated into an `os.Logger` message is redacted by default.** Apple,
   *Generating Log Messages from Your Code* (fetched 2026-09-20): "By default, the system doesn't
   redact integer, floating-point and Boolean values, but it does redact the contents of dynamic
   strings and complex dynamic objects. To make a private value public again, configure the privacy
   of the variable using appropriate modifiers in your message string or interpolated variable."
   Both of `log`'s parameters are `String`.
2. **`log(_:_:)` carries no privacy modifier today.** `Ghostty.logger.warning("worktree config: \(what) failed: \(message)")`
   (`Sources/App/WorktreeConfigStore.swift:404`).
3. **It is the file's only logging call.** Grep for `logger` across
   `Sources/App/WorktreeConfigStore.swift` returns line 404 and nothing else.
4. **Twelve call sites feed it**, covering every failure the store reports: lines 142, 149, 181,
   193, 221, 229, 252, 269, 281, 310, 335 and 397 (`Sources/App/WorktreeConfigStore.swift`). One
   edit therefore fixes all of them.
5. **No call site interpolates a user-authored value into `what`.** The write helpers log the key
   and the path only (lines 221, 229, 252, 269, 281); the `reportingFailure: true` path logs
   `args.joined(separator: " ")` (line 397), whose only callers are `enableExtension`'s
   `git rev-parse`, `git config --file … core.bare <path>`, `git config --local extensions.worktreeConfig true`
   and `git config --local --unset <key>` (lines 329-361) — paths and fixed keys. Supports decision 3.
6. **`privacy: .public` is the established annotation in this target**, used at
   `Sources/App/GitResolver.swift:48`, `Sources/App/ShellPathResolver.swift:139`,
   `Sources/App/SavedCommandStore.swift:122`, `Sources/App/ShellPathStore.swift:66` and
   `Sources/App/WorktreeGroupManager.swift:483`.
7. **The annotated line stays inside SwiftLint's limits.** The rewritten line is ~110 characters
   against a 200-character warning, and the file is 417 lines against a 700-line warning
   (`.swiftlint.yml:20-30`).
8. **Nothing else observes this text.** No test asserts on the log output — `Tests/WorktreeConfigStoreTests.swift`
   exercises the pure argument builders and parsers only — so the change cannot break a test.
9. **`WorktreeConfigStore` is `Sendable` and nonisolated, and `Ghostty.logger` is reachable from it**
   (`Sources/App/WorktreeConfigStore.swift:10`; `Sources/Ghostty/Ghostty.swift:7`). A privacy
   modifier changes neither, so no concurrency consideration arises.
10. **No new file, so no `project.yml` edit is needed**, and `./scripts/ci.sh` runs `xcodegen generate`
    regardless (`CLAUDE.md`, "Verifying a change").

## Objective

A developer reading a release build's log learns why a `clearway.*` git-config read or write failed,
not just that one did. The two-layer story the sidebar's write failures already tell —
`worktree groups:` naming the lost gesture, `worktree config:` naming git's refusal — becomes
legible in release, where today only the first half is.

### Success criteria

- `WorktreeConfigStore.log(_:_:)` marks both interpolations `privacy: .public`.
- The line's prefix, wording and level are unchanged, so it still reads
  `worktree config: set clearway.group at <path> failed: <git stderr>`.
- No other file changes, and no test changes.
- `./scripts/ci.sh` green; `swiftlint lint --quiet` with zero errors; `git status --porcelain`
  clean apart from the un-gitignored `default.profraw` a Debug launch drops.

## Commands

The regression check for the build step and the full gate at sign-off are the same command:

```bash
./scripts/ci.sh
```

It regenerates the Xcode project, lints, builds and runs the test suite. Lint alone:

```bash
swiftlint lint --quiet
```

`ci.sh` does not refuse on a dirty tree, so run `git status --porcelain` before any CI stamp and
report untracked or ignored files.

## Files this change touches

**Edited**

- `Sources/App/WorktreeConfigStore.swift` — the body of `log(_:_:)` (line 404), plus a short note on
  the helper saying why the two values are public.

No new files. No test files.

## Out of scope

- The other unannotated `Ghostty.logger` lines in `Sources/App` — `SavedCommandStore.swift:86`,
  `104`, `124`, `138`, `OpenInAppLauncher.swift:67`, `80`, `SavedCommandManager.swift:151`,
  `SettingsManager.swift:173`, `179`, `Worktree.swift:217`, `AgentLaunch.swift:85` and others. The
  task names this one helper. A sweep is a separate task; recorded as a follow-up.
- `clearway.name` and `clearway.status` write failures at the manager layer — still the open
  follow-up from the reference spec, and unrelated to redaction.
- Any change to what the store logs, when it logs, or at which level.
- Anything about the alert or the `worktree groups:` layer added by PR #236.
