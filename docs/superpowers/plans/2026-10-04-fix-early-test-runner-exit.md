# Plan: Fix the early test-runner exit in WorktreeGroupPersistenceTests

Breaks down `docs/superpowers/specs/2026-10-04-fix-early-test-runner-exit.md`.

**Date:** 2026-10-04
**Base:** 3fe622b (Bundle THIRD-PARTY-LICENSES in the app, #271)

The spec's Decisions (D1-D10), Assumptions (A1-A6), Evidence (E1-E8), Hypotheses (H1-H3) and
Investigation procedure are the source of truth. Read the spec before starting T2; this plan only
orders the work and says how each piece is verified.

## Architecture decisions carried from the spec

- D1: two independent tasks. T1 is the import removal, T2 the investigation. T1 runs first so T2
  starts from a known-green baseline.
- D2: evidence comes from the macOS unified log via `/usr/bin/log show` (never bare `log`, a zsh
  builtin). No `.xcresult` of the failing run exists.
- D3: `testAHandEditedRegistryDropsBlanksAndRepeats` is the test that happened to be running, not
  the suspect. Do not edit `Tests/WorktreeGroupPersistenceTests.swift` unless the investigation
  implicates it.
- D4: test H1 (concurrent hosts), then H2 (non-first-party `exit()` caller), then H3 (the test
  itself), using reproductions R1 and R2.
- D5: at most about 60 minutes of wall-clock repro runs across R1 and R2, each step under the
  10-minute tool limit. No recurrence inside that budget means the outcome is "unreproducible".
- D6: a cause in app or test code is fixed at its source with a regression test that fails on
  3fe622b. A cause in concurrent-host interference (H1) is **not** fixed here: no change to
  `scripts/ci.sh`, `.github/workflows/ci.yml`, `project.yml` test settings, or the test host's
  defaults domain or home. Return to the orchestrator with the evidence and a recommended fix.
- D7: on "unreproducible", write (a) the build log under T2 in this plan (hypotheses, every repro
  command with duration and result, E1-E8) and (b) three or four lines in the project `CLAUDE.md`
  `## Pipeline` section: an early "test runner exited with code 0" is investigated through the
  unified log, not the xcresult; the `/usr/bin/log show` query from the spec's procedure step 1;
  a pointer to the spec.
- D8: delete line 2 of `Tests/BundledResourcesTests.swift`. If it fails to compile, restore it and
  record the compiler error as the reason it stays.
- D9: temporary diagnostics (for example an `atexit` handler logging `Thread.callStackSymbols`) live
  only in the working tree and are removed before commit, unless one becomes the fix's regression
  test. The build log records their use.
- D10: CPU load is allowed for R2 only under `CLAUDE.md` "Background load generators": every
  generator bounded by `timeout <secs>` or `trap 'kill $LOADPIDS' EXIT`, every step shorter than
  the tool timeout.

Standing rules from the project `CLAUDE.md` that bind T2's repro commands: never pass
`PRODUCT_NAME` or `APP_PRODUCT_NAME` to `xcodebuild`; never launch the app outside a test run; never
`git stash` or `git checkout <path>`. Repro loops are probes and never stand in for `./scripts/ci.sh`.

## Dependency graph

```
T1 (import removal, ci.sh green)
 └── T2 (investigation; fix, return, or write-up)
```

T2 depends on T1 only for the green baseline. Neither task depends on anything else.

## Tasks

### T1: Remove the unused `@testable import Clearway` from BundledResourcesTests

**Files:** `Tests/BundledResourcesTests.swift`; this plan (build log).

**What:** Delete line 2 (`@testable import Clearway`). The file uses only `XCTest`, `Bundle.main`,
`String`, `Set` and `XCTUnwrap`; `Bundle.main` is the app because the test bundle is app-hosted
(`TEST_HOST`), independent of the import. Leave the blank line structure otherwise unchanged.
If the build fails without the import, put it back and record the compiler error in the build log
as the reason it stays (D8).

**Acceptance criteria:**
- `Tests/BundledResourcesTests.swift` has no `import Clearway` line, or the build log quotes the
  compiler error that requires it.
- `testThirdPartyLicensesShipsWithEveryNotice` passes.
- `./scripts/ci.sh` exits 0 after the last edit.

**Verification:** `./scripts/ci.sh` after the edit; record exit status, test count and failures in
the build log under this task. Confirm the named test passed (xcbeautify output or `xcresulttool`
on the run's `.xcresult`). If the run exits 65 with "test runner exited with code 0 before finishing
running tests", that is a recurrence of the T2 incident: capture it right away with the spec's
procedure step 1 query, record the host pid and its last log lines in the build log for T2, then
rerun `ci.sh` for T1's own verdict.

### T2: Investigate the early test-host exit and resolve it per D6 or D7

**Files:** this plan (build log, always). Depending on the outcome: `CLAUDE.md` (unreproducible
outcome only); or the offending source file plus one test file (H2/H3 fix only). Never
`scripts/ci.sh`, `.github/workflows/ci.yml` or `project.yml`.

**What:** Follow the spec's "Investigation procedure" steps 1-5 in order. Concretely:

1. Re-run the spec's step 1 query over `--last 1h` before and after each repro step to detect a
   recurrence. Use the `testmanagerd` pid query and `processID == <pid>` with `--debug --info` to
   pull the host's last lines.
2. R1 (H3): with T1's build in place, loop only the suite using `ci.sh`'s `xcodebuild` flags
   (`-project Clearway.xcodeproj -scheme ClearwayTests -configuration Debug -destination
   "platform=macOS,arch=$(uname -m)" test`) plus
   `-only-testing:ClearwayTests/WorktreeGroupPersistenceTests -test-iterations <n>`, with `n` sized
   so each step ends under 10 minutes.
3. R2 (H1): run two or three `xcodebuild … test` invocations concurrently with the same flags, each
   with its own `-derivedDataPath` under the scratchpad (same bundle id, separate build products).
   Stagger them so at least one full-suite run ends while another is inside
   `WorktreeGroupPersistenceTests`, reproducing the E5 timing. Background every concurrent run with
   a bound (`timeout <secs>`) and keep each step under the tool timeout. Optional load per D10.
4. On a hit: add D9's temporary `atexit` stack logging to name the `exit()` caller, reproduce once
   more, then apply D6:
   - caller in app or test code (H2 in first-party wrappers, or H3): fix at the source, add a
     regression test that fails on 3fe622b (record the red run), remove the diagnostic;
   - caller is interference between concurrent hosts (H1), or in libghostty/Sparkle/XCTest where
     the only remedy is environmental: stop, remove the diagnostic, and return to the orchestrator
     with the evidence and one recommended fix. Do not edit the pipeline.
5. No hit within the D5 budget (about 60 minutes of repro wall-clock): write the D7 build log and
   the `CLAUDE.md` `## Pipeline` note.

**Acceptance criteria:**
- The build log under T2 lists every repro command with its duration and result, and the total
  repro wall-clock spent against D5's budget.
- Exactly one outcome holds, and the build log says which:
  - the `exit()` caller is named by a stack or a reproduction and fixed, with a regression test
    whose failure on 3fe622b is quoted; or
  - H1 is shown, and the report back to the orchestrator carries the evidence and a recommended fix
    with no pipeline file changed; or
  - no recurrence: the build log carries H1-H3, the attempts and E1-E8 (by reference to the spec),
    and `CLAUDE.md` `## Pipeline` has the three or four D7 lines.
- No diagnostic code, scratch file, or orphaned background process remains (`git status --porcelain`
  lists only intended changes plus a reported `default.profraw`; `pgrep -fl 'xcodebuild|yes'`
  shows nothing this task started).
- `./scripts/ci.sh` exits 0 after the last edit.

**Verification:** `./scripts/ci.sh` after the last edit, exit status recorded. `git status
--porcelain` and `pgrep` output recorded in the build log. For the fix outcome, the red run on the
base (test added, fix absent) and the green run are both quoted. For the `CLAUDE.md` outcome,
`git diff CLAUDE.md` shows only the added lines inside `## Pipeline`.

## Risks

| Risk | Impact | Mitigation |
| --- | --- | --- |
| Concurrent repro runs overwrite the shared `~/.clearway/hook.sock` and the real `~/.claude/settings.json` hook block (A2, `CLAUDE.md` Pipeline) | Low: the same happens on every `ci.sh` run | Expected; no cleanup needed beyond what a normal `ci.sh` run leaves. |
| Other pipelines on the machine run `ci.sh` during T2 and add hosts to the log | Medium: muddies which host is which | Identify hosts by pid via `testmanagerd` lines, not by timestamps alone. |
| A background `xcodebuild` or load generator outlives the step | High (see `CLAUDE.md` incident) | Every background process bounded by `timeout`; `pgrep` check in T2's acceptance. |
| The incident never recurs | Expected | D5 budget and D7 write-up make that a complete outcome. |

## Build log

Each build agent appends its evidence here under a bold `**T1**` or `**T2**` label (not a `###`
heading, which the orchestrator reserves for tasks).

**T1**

| File | State |
| --- | --- |
| `Tests/BundledResourcesTests.swift` | Line 2 (`@testable import Clearway`) deleted; the file imports only `XCTest`. |

Evidence: the file compiles without the import, so no compiler error to record (D8). No RED step:
this is a dead-import removal with no behavior change; the existing
`testThirdPartyLicensesShipsWithEveryNotice` is the check, and it still resolves `Bundle.main` to the
app because the bundle is app-hosted.

Deviations: none.

Gate: `./scripts/ci.sh` after the edit, exit 0 in 181 s. "Executed 956 tests, with 0 failures
(0 unexpected)", "==> CI passed." `xcrun xcresulttool get test-results tests` on
`Test-ClearwayTests-2026.10.04_18-44-12--0400.xcresult` reports
`testThirdPartyLicensesShipsWithEveryNotice() Passed`. No "test runner exited with code 0" recurrence
in this run.
