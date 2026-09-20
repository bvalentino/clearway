# Plan: Make WorktreeConfigStore's git error logs public in release builds

Breaks down `docs/superpowers/specs/2026-09-20-worktreeconfigstore-public-git-error-logs.md`.

**Date:** 2026-09-20
**Base:** b4369a5 (`Split buttons for Run and Open in (#237)`)

## Architecture decisions carried from the spec

- `WorktreeConfigStore.log(_:_:)` is the single edit. All twelve of the store's failure reports
  funnel through it and no call site touches `Ghostty.logger` directly, so one annotation fixes
  every one of them (decision 4).
- **Both** interpolations get `privacy: .public`, not just git's message. `what` is redacted by the
  same default rule, and `worktree config: <private> failed: <git error>` would not say which key
  or which worktree lost the write (decision 2).
- `.public` is acceptable for both values because what they can carry is bounded: `what` is a key
  name, a worktree path or a git argument vector — no call site interpolates the value being
  written — and `message` is git's stderr, which at worst names a path. Paths are already published
  across this target (`GitResolver.swift:48`, `ShellPathResolver.swift:139`,
  `SavedCommandStore.swift:122`, `ShellPathStore.swift:66`,
  `WorktreeGroupManager.swift:483`), so this introduces no new category of logged data (decision 3).
- The prefix, the wording and the level do not change. The line stays a
  `Ghostty.logger.warning` reading `worktree config: <what> failed: <message>`, so the two-layer
  split — `worktree groups:` names the lost gesture, `worktree config:` names git's refusal —
  is untouched (decision 6).
- **No test.** Redaction is applied by the log reader according to its privilege, not baked into
  the stored entry, so `OSLogStore(scope: .currentProcessIdentifier)` reads the same text before
  and after the change and any such test would pass either way. Adding a seam on `log` to assert a
  format string would be indirection this change does not need. Verification is the source line
  plus a green `./scripts/ci.sh` (decision 5).
- The helper carries a short note saying why the two values are public, the same note
  `WorktreeGroupManager.logFailure` carries (`Sources/App/WorktreeGroupManager.swift:479-481`).
  It preserves the redaction decision at the site that would otherwise read as an oversight.
- Out of scope: the other unannotated `Ghostty.logger` lines in `Sources/App`, the `clearway.name`
  and `clearway.status` failures at the manager layer, and any change to what the store logs, when
  it logs, or at which level.

## Dependency graph

```
T1 (annotate log(_:_:))   — single task, no dependencies
```

## T1: Mark both of `log(_:_:)`'s interpolations public

**Files touched**

- `Sources/App/WorktreeConfigStore.swift` — the body of `log(_:_:)` (line 403-405), plus a doc
  comment on the helper.

**What it does**

Rewrite the one line in `log(_:_:)` so both interpolations carry a privacy modifier:

```swift
Ghostty.logger.warning("worktree config: \(what, privacy: .public) failed: \(message, privacy: .public)")
```

Add a doc comment above the helper stating that both values are public because a release build
would otherwise redact the whole line, and that neither parameter carries a user-authored value —
`what` is a key name, a worktree path or a git argument vector, `message` is git's stderr.

Nothing else in the file changes. No call site changes. No new file, so `project.yml` is untouched.

**Acceptance criteria**

- `log(_:_:)` interpolates `what` and `message` with `privacy: .public`, and is still the file's
  only `Ghostty.logger` reference.
- The message string is otherwise byte-identical: prefix `worktree config: `, separator ` failed: `,
  level `warning`.
- `Sources/App/WorktreeConfigStore.swift` is the only changed file; no test file is added or edited.

**Verification**

- `grep -n 'logger' Sources/App/WorktreeConfigStore.swift` returns exactly one line, and it contains
  two occurrences of `privacy: .public`.
- `git diff --name-only` lists `Sources/App/WorktreeConfigStore.swift` and nothing else.
- `swiftlint lint --quiet` reports zero errors, and the rewritten line stays under the
  200-character `line_length` warning (`.swiftlint.yml`).
- `./scripts/ci.sh` green — the regression check this project's `## Pipeline` section names.

## Build log

### T1: Mark both of `log(_:_:)`'s interpolations public

**What landed**

| File | State |
| --- | --- |
| `Sources/App/WorktreeConfigStore.swift` | Edited — `log(_:_:)` now interpolates both `what` and `message` with `privacy: .public`, and carries a doc comment saying why. Only changed file. |

The line reads:

```swift
Ghostty.logger.warning("worktree config: \(what, privacy: .public) failed: \(message, privacy: .public)")
```

113 characters, against SwiftLint's 200-character warning. `grep -n logger Sources/App/WorktreeConfigStore.swift`
returns that line and nothing else; `git diff --name-only` lists that file and nothing else.

**Evidence**

No test, per decision 5 of the spec and the plan's "No test" bullet: redaction is applied by the log
reader according to its privilege, not baked into the stored entry, so a test reading its own
process's entries sees identical text before and after and would pass either way. There is therefore
no failure to watch. Verification is the source line above plus the gate below.

**Deviations from the plan**

None.

**Gate**

`./scripts/ci.sh` — green, 676 tests, 0 failures, `==> CI passed.`

The first run of that command failed one test, `WorktreeGroupManagerNameTests`
`testReconcilePopulatesNamesFromConfigAndDropsAClearedOne`:

```
caught error: "Failure(command: "-C …/.worktrees/feature config --worktree --unset clearway.name",
status: 255, stderr: "error: could not lock config file
…/.git/worktrees/feature/config.worktree: File exists")"
```

That is the test harness's own `repo.unsetValue` losing git's config lock to the manager's write
chain on the same `config.worktree`, not a product failure, and nothing in this change touches a
write path. An immediately following run of the same command on the same bytes was green. Recorded
as a follow-up, not fixed here.
