# Plan: cway explicit error messages

Breaks down `docs/superpowers/specs/2026-10-03-cway-explicit-error-messages.md`.

**Date:** 2026-10-03
**Base:** 8a11de5 (Add cway CLI: create, list, and show tasks, #265)

The spec's message catalogue (U1-U8, R1-R13) is the source of truth for every message's wording.
Copy the wording from there exactly; this plan only orders the work.

## Architecture decisions carried from the spec

- Every message lives in `Sources/Shared/TaskCommand.swift` and prints as `cway: <message>\n` on
  stderr with empty stdout, through the existing `catch` in `TaskCommand.run`.
- Message form (D6): lower-case after `cway: `, ends with a period, paths and user-supplied
  arguments in single quotes, task ids unquoted in uppercase `uuidString` form. A message ending in
  a Foundation `localizedDescription` (R4, R12, R13) takes no added period.
- Usage errors (D7) exit 2. `Failure.usage` appends ` Run 'cway help' for usage.` in one place,
  so every usage message ends `. Run 'cway help' for usage.` Usage text is never printed on error.
- Exactly one git failure is recognised (D1, D2): git exits 128 **and** the first stderr line starts
  with `fatal: not a git repository (or any `. That prints R2. `fatal: not a git repository: <path>`
  (no parenthesis, broken gitfile or bad `GIT_DIR`) must not match.
- git runs with its inherited environment plus `LC_ALL=C` (D3).
- Any other non-zero git exit prints R6 (D4): the framing sentence, then git's whole stderr with
  blank lines dropped and each remaining line indented by two spaces; or the "printed nothing"
  form when git's stderr has no non-blank line. Exit 1. Only R6 is multi-line (D5).
- Before starting git, `cway` checks the working directory exists and is a directory (D8). If not,
  R1 (the empty-string form when the path is `""`), exit 1. This replaces today's uncaught
  `NSInvalidArgumentException` from `Process.currentDirectoryURL`.
- Exit codes unchanged: 2 for U1-U8, 1 for R1-R13; malformed id and stdin not UTF-8 stay 1 (D9).
- Argument errors are still reported before any git or filesystem check (D10), so the D8 check sits
  on the git path, not at the top of `run`.
- `TaskCommand.run`'s signature does not change. Env-dependent cases (git not on `PATH`, dubious
  ownership) are tested by running the embedded `Contents/MacOS/cway` with a set `environment`
  (D11).
- No change to `Sources/CLI/main.swift`, `project.yml`, success output, or any doc.

## Dependency graph

```
T1 git path (R1, R2, R3, R4-R8, D3, assertFailed takes stderr)
 ├── T2 usage and remaining runtime messages (U1-U8, R9-R13)
 └── T3 embedded-binary environment cases (R5, dubious ownership)
```

All three tasks edit the same two files, so they run in order T1, T2, T3. T2 and T3 do not depend
on each other's code, only on T1.

Every task must leave `./scripts/ci.sh` passing, and the test file must assert exactly what the
code prints at that point. When T1 changes `assertFailed` to take the expected stderr, the usage
and `show` call sites assert today's text; T2 replaces them with the catalogue text.

### T1: Explicit messages on the git path

**Files:** `Sources/Shared/TaskCommand.swift`, `Tests/TaskCommandTests.swift`

**What it does**

- Before `process.run()`, check the working directory with
  `FileManager.default.fileExists(atPath:isDirectory:)`; throw R1 if missing or not a directory, the
  empty-path form when it is `""`.
- Set `process.environment` to `ProcessInfo.processInfo.environment` with `LC_ALL` set to `C`.
- On non-zero exit: 127 → R5; 128 with the D2 first-line prefix → R2; otherwise R6 built from the
  rendered git command (`'git worktree list --porcelain'`), the status, and git's stderr per D4.
- Reword R3 (with the path from the first porcelain block's `worktree` line), R4, R7, R8 to the
  catalogue.
- In the tests, change `assertFailed` to take the expected stderr (exact string) and keep its exit
  code and empty-stdout checks. Update every call site: catalogue text for messages this task
  changes, today's exact text for usage errors and `show`'s id errors (T2 changes those).
- Add tests: spec T1 (outside a repo, `create`/`list`/`show`, exact R2 with the directory exactly
  as passed to `run`), spec T3 (a fixture repo whose `.git` is replaced by a file containing
  `gitdir: /nonexistent/x`: stderr starts with R6's framing sentence for that directory, contains
  `  fatal: not a git repository:`, and does not contain `is not inside a git repository`), spec T4
  (bare main worktree, all three commands, exact R3 with the bare path as git prints it), spec T6
  (`workingDirectory: ""` and a nonexistent path under `tempRoot`: exact R1 forms, exit 1, no
  crash).

**Acceptance criteria**

- Outside a repo every command prints exactly R2, exit 1, empty stdout, and the message contains
  neither `.git` nor `parent directories`.
- A broken gitfile prints R6 with git's line, never R2.
- `""` and a nonexistent working directory print R1 and exit 1 instead of raising an Objective-C
  exception.
- `process.environment` carries `LC_ALL=C` (no test can observe it on this machine, see spec D3;
  verified by reading the diff).
- Existing success tests pass unchanged.

**Verification:** `./scripts/ci.sh` exits 0 after the last edit; `swiftlint lint --quiet` reports
no new warnings in the two files.

### T2: Usage and remaining runtime messages

**Files:** `Sources/Shared/TaskCommand.swift`, `Tests/TaskCommandTests.swift`

**What it does**

- `Failure.usage` appends ` Run 'cway help' for usage.` to every usage message (D7).
- Reword U1-U8 per the catalogue. `parseOptions`, `list` and `show` need the subcommand name
  (`task create`, `task list`, `task show`) for U2/U3; pass it in.
- Reword R9, R11, R12, R13. R10 needs the main worktree path, so `loadPool` also returns the
  project's main path (or the `Project`).
- Tests (spec T2, T5, T7, T8):
  - Every existing usage-error call site asserts the exact U message with the suffix, including
    `testUnknownCommandExitsTwoWithEmptyStdout`. Cover all of U1-U8; add a `task create --title x
    --force` (U2), `stray` (U3, create), `list extra` and `show <id> extra` (U3), `--title` and
    `--body` without value (U4), repeated `--title` (U5), no `--title` (U6), blank title (U7),
    `show` without id (U8). Keep the existing "writes nothing" checks.
  - R9 for `show not-a-uuid`; R10 for an unknown UUID, with `<main>` taken from the first
    `worktree` line of `GitRepoFixture.git(["worktree", "list", "--porcelain"], in: repo.root)`
    so the test uses the path form git reports.
  - R11: `--body -` with stdin `Data([0xFF, 0xFE])`, exit 1, nothing written.
  - R12: create `.clearway/tasks` under the repo, set it to `0o500`, run `create`; stderr starts
    with `cway: could not write the task file '` and the quoted path contains `/.clearway/tasks/`;
    exit 1. Restore `0o700` in a `defer` so `tempRoot` cleanup succeeds.

**Acceptance criteria**

- Each of U1-U8 is asserted exactly, exit 2, empty stdout.
- R9, R10, R11 asserted exactly; R12 by its prefix and path; all exit 1.
- R13 is reworded but untested (spec: cannot be provoked without faking `JSONEncoder`).

**Verification:** `./scripts/ci.sh` exits 0 after the last edit; no new SwiftLint warnings.

### T3: Embedded-binary environment cases

**Files:** `Tests/TaskCommandTests.swift`

**What it does**

- `runHelper` gains an `environment: [String: String] = [:]` parameter merged over
  `ProcessInfo.processInfo.environment`, and returns stderr alongside stdout and status. Existing
  callers keep working.
- Spec T9: in a fixture repo with `PATH=/nonexistent`, the helper prints exactly R5, exit 1, empty
  stdout.
- Spec T10: in a fixture repo with `GIT_TEST_ASSUME_DIFFERENT_OWNER=1`, stderr starts with
  `cway: could not find the project for '`, contains `'git worktree list --porcelain' exited with
  status 128. git said:\n`, a line starting `  fatal: detected dubious ownership`, and a line
  containing `safe.directory`; it does not contain `is not inside a git repository`; exit 1, empty
  stdout. Do not assert the `<wd>` text exactly: the helper's working directory comes from
  `FileManager.currentDirectoryPath` in the child, whose form (`/private/var` vs `/var`) the test
  does not control.

**Acceptance criteria**

- Spec criteria 4 and 5 hold through the shipped binary.
- No production code changes in this task.

**Verification:** `./scripts/ci.sh` exits 0 after the last edit; no new SwiftLint warnings.

## Risks

| Risk | Mitigation |
| --- | --- |
| A test asserts a path in a different form than `cway` prints (`/var` vs `/private/var`). | R2/R1 tests pass the directory to `run` and expect it verbatim; R3/R10 take the path from git's own porcelain output. |
| The R12 test leaves a `0o500` directory that breaks `tempRoot` cleanup. | Restore the mode in `defer`. |
| `GIT_TEST_ASSUME_DIFFERENT_OWNER` stops working in a future git. | Out of our control; the test would fail loudly with git's actual stderr in the assertion message, not pass silently. |

## Changelog

- **Review fix: git's stderr is decoded lossily.** `gitFailure` decodes stderr with `String(decoding:as: UTF8.self)` under a one-line `swiftlint:disable:next optional_data_string_conversion`. This reverses T1's choice of `String(bytes:encoding: .utf8) ?? ""`, which dropped all of git's stderr when any byte was invalid UTF-8 and reported "printed nothing", hiding the cause (against the spec's "so the cause is never hidden"). Reachable with real git: a `.git/config` value git echoes verbatim, such as `repositoryformatversion = \xFF`. Do not revert to the failable decode. The stdout decode in `git` stays failable on purpose, because that output is parsed. Guarded by `testGitStderrThatIsNotUTF8StillShowsGitsReason`. No message wording changed.

## Build log

### T1: Explicit messages on the git path

| File | State |
| --- | --- |
| `Sources/Shared/TaskCommand.swift` | `git` checks the working directory first (R1, both forms), runs git with `LC_ALL=C`, and hands non-zero exits to `gitFailure`: 127 → R5, 128 + `fatal: not a git repository (or any ` → R2, anything else → R6 with git's non-blank stderr lines indented two spaces (or the "printed nothing" form). R3, R4, R7, R8 reworded; R3 names the first porcelain entry's path. |
| `Tests/TaskCommandTests.swift` | `assertFailed` takes the exact expected stderr; every call site updated (today's text for usage errors and `show`'s id errors, which T2 rewrites). New: broken gitfile (R6, never R2), missing and `""` working directory (R1). Outside-repo tests assert exact R2 and the absence of `.git` / `parent directories`; bare test asserts exact R3 with the path from git's own porcelain. |

Evidence: `./scripts/ci.sh` with the new tests and the old code, exit 65, `Executed 917 tests, with 12 failures`. Failures, quoted from the xcresult:

- `XCTAssertTrue failed - cway: fatal: not a git repository: (null)` (broken gitfile, no R6 framing)
- `("cway: the main worktree is a bare repository, which has no task backlog\n") is not equal to ("cway: the main worktree of this repository, '…/bare.git', is a bare repository …")` (×3)
- `("cway: fatal: not a git repository (or any of the parent directories): .git\n") is not equal to ("cway: the current directory '…/not-a-repo' is not inside a git repository. …")` (×3), plus the two `XCTAssertFalse` on `.git` / `parent directories`
- `("cway: cannot run git in …/gone: The file “gone” doesn’t exist.\n") is not equal to ("cway: the current directory '…/gone' does not exist. …")`
- `("cway: fatal: not a git repository (or any of the parent directories): .git\n") is not equal to ("cway: the current directory no longer exists. …")` — in-process, `URL(fileURLWithPath: "")` resolved to the test host's cwd rather than raising; the built binary's crash (spec P4) is not reproducible through `TaskCommand.run`, so this test pins the message, not the crash.

Deviations:

- The bare-repo test first expected `canonical(tempRoot)/bare.git`; the plan says to use the path as git prints it, so it now reads it from `git worktree list --porcelain` (the `/private/var` form).
- `resolveProject` now checks "no worktrees" (R8) before "bare" (R3), since R3 needs the main path. Behaviour is the same for every reachable input: a bare main entry still carries a `worktree` line.
- git's stderr is decoded with `String(bytes:encoding: .utf8) ?? ""`, not the lossy `String(decoding:as:)`: SwiftLint's `optional_data_string_conversion` flags the latter. Non-UTF-8 stderr would read as "printed nothing"; on APFS every path is UTF-8 and git's own text is ASCII under `LC_ALL=C`, so this is not expected in practice.
- `LC_ALL=C` is not observable in a test here (spec D3); verified by reading the diff.

Gate: `./scripts/ci.sh` after the last code edit: exit 0, `Executed 917 tests, with 0 failures`, no SwiftLint warnings.

### T2: Usage and remaining runtime messages

| File | State |
| --- | --- |
| `Sources/Shared/TaskCommand.swift` | `Failure.usage` appends ` Run 'cway help' for usage.`; `Failure.strayArgument(_:to:)` builds U3 for `parseOptions`, `list` and `show`. `parseOptions` takes the subcommand name for U2/U3. U1, U4-U8 reworded. R9, R11, R12, R13 reworded; `loadPool` also returns the main path, which R10 names. |
| `Tests/TaskCommandTests.swift` | `usageError(_:)` builds the expected U text. Every usage call site asserts the exact catalogue text, U1-U8 all covered (added: two-word unknown command, `create --body x` without `--title`). R9 and R10 asserted exactly, R10's path taken from git's porcelain. New: non-UTF-8 stdin (R11, nothing written); `.clearway/tasks` at `0o500` (R12 prefix, quoted path under `/.clearway/tasks/`, mode restored in `defer`). |

Evidence: `./scripts/ci.sh` with the new tests and the T1 code, exit 65, `Executed 919 tests, with 18 failures`. Every failure was an old message, e.g.:

- `testUnknownCommandExitsTwoWithEmptyStdout, XCTAssertEqual failed: ("cway: unknown command 'frobnicate'` (and `'task frob'`)
- `testMalformedCreateArgumentsAreUsageErrorsAndWriteNothing`: `unknown option '--force'`, `--title needs a value`, `--body needs a value`, `--title given more than once`, `unexpected argument 'stray'`
- `testMissingOrBlankTitleIsUsageErrorAndWritesNothing`: `missing --title` (×2), `--title is empty` (×2)
- `testListAndShowArgumentErrorsExitTwo`: `missing task id`, `unexpected argument 'extra'` (×2)
- `testShowUnknownOrMalformedIdExitsOne`: `no task 08F13391-…`, `malformed task id 'not-a-uuid'`
- `testBodyDashWithNonUTF8StdinExitsOneAndWritesNothing`: `cway: stdin is not valid UTF-8`
- `testUnwritableTasksDirectoryNamesTheTaskFile, XCTAssertTrue failed - cway: cannot write /private/var/…/.clearway/tasks/CFBB32B2-….md: The file “CFBB32B2-…`

Deviations: none. R13 is reworded and untested, as the spec says.

Gate: `./scripts/ci.sh` after the last code edit: exit 0, `Executed 919 tests, with 0 failures`; `swiftlint lint --quiet` on both files reports nothing.

### T3: Embedded-binary environment cases

| File | State |
| --- | --- |
| `Tests/TaskCommandTests.swift` | `runHelper` takes `environment: [String: String] = [:]`, merged over the inherited environment, and returns stderr with stdout and status; existing callers unchanged. New: `PATH=/nonexistent` asserts exact R5, exit 1, empty stdout (spec T9); `GIT_TEST_ASSUME_DIFFERENT_OWNER=1` asserts R6's framing prefix, `exited with status 128. git said:\n`, a `  fatal: detected dubious ownership` line, a `safe.directory` line, no R2, exit 1, empty stdout (spec T10). |

Evidence: the two new tests run (via `xcodebuild … -only-testing`) against `Sources/Shared/TaskCommand.swift` from `8a11de5`, copied in from `git show` and restored from a scratchpad copy afterwards: exit 65, `Executed 2 tests, with 5 failures`.

- `testEmbeddedHelperWithoutGitOnPathSaysGitWasNotFound, XCTAssertEqual failed: ("cway: git not found…`
- `testEmbeddedHelperShowsGitsDubiousOwnershipReasonNotOutsideRepository, XCTAssertTrue failed - cway: fatal: detected dubious ownership in repository at '/private/var/…'` (×4: no R6 framing, no `git said:`, no indented line, no `safe.directory` line, since `8a11de5` printed only git's first `fatal:` line)

Deviations: none. No production code changed.

Gate: `./scripts/ci.sh` after the last code edit: exit 0, `Executed 921 tests, with 0 failures`; `swiftlint lint --quiet Tests/TaskCommandTests.swift` reports nothing.

### Simplify

Reviewed the three commits for reuse, simplification and altitude; nothing worth changing, so no code was touched. `./scripts/ci.sh` after the review: exit 0, 921 tests, 0 failures.

### Review fix: non-UTF-8 git stderr

| File | State |
| --- | --- |
| `Sources/Shared/TaskCommand.swift` | `gitFailure` decodes stderr with `String(decoding: stderr, as: UTF8.self)`, invalid bytes becoming U+FFFD, under `// swiftlint:disable:next optional_data_string_conversion` with the reason on the decode line. The stdout decode stays `String(bytes:encoding:)`. |
| `Tests/TaskCommandTests.swift` | `testGitStderrThatIsNotUTF8StillShowsGitsReason` (written by the review step, kept unchanged): appends `repositoryformatversion = \xFF` to `.git/config`, expects exit 1, no "printed nothing", and an indented `fatal: bad numeric config value` line. |

Evidence: the test run alone (`xcodebuild … -only-testing:ClearwayTests/TaskCommandTests/testGitStderrThatIsNotUTF8StillShowsGitsReason`) against `TaskCommand.swift` from `HEAD`, restored from a scratchpad copy afterwards (`cmp` identical): exit 65, 2 failures:

- `XCTAssertFalse failed - cway: could not find the project for '/var/folders/…/clearway-tests-…': 'git worktree list --porcelain' exited with status 128 and printed nothing.`
- `XCTAssertTrue failed - cway: could not find the project for '/var/folders/…/clearway-tests-…': 'git worktree list --porcelain' exited with status 128 and printed nothing.`

Deviations: I looked for a lossy decode that needs no suppression. SwiftLint 0.63.2 matches the rule on spelling only: `String(decoding: d, as: Unicode.UTF8.self)` is not flagged, while `as: UTF8.self` is flagged even on `Array(d)`. Changing the spelling avoids the warning without fixing anything and gives the reader no reason, so the code uses the explicit suppression. A lint probe in the scratchpad confirmed this.

Gate: `./scripts/ci.sh` after the last code edit: exit 0, `Executed 922 tests, with 0 failures`; `swiftlint lint --quiet` on both files reports nothing.
