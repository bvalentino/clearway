# Plan: Make ShellPathResolverTests robust under load

**Date:** 2026-09-18
**Base:** 7ae81c1fca4c52beaf290a2035746c975ff95c69
**PR:** #223

Breaks down `docs/superpowers/specs/2026-09-18-make-shellpathresolvertests-robust-under-load.md`.

## Architecture decisions carried from the spec

1. Widen the timeouts; do not inject a clock. The wait is `DispatchSemaphore.wait(timeout:)` on a
   real `Process` (`Sources/App/ShellPathResolver.swift:87-109`), and the real child process is
   precisely what this suite exists to cover — file-versus-pipe capture, the stderr flood, and
   "stdout is read only after exit". A fake process deletes that coverage.
2. Every case whose expected outcome needs an attempt to **complete** runs at the production limit,
   obtained by passing **no** `timeout:` argument. `ShellPathResolver(shell:timeout:)` already
   defaults `timeout` to `attemptTimeout` = 5 (`ShellPathResolver.swift:30, 46-52`). No test-only
   "generous" constant is introduced — it would be a second number meaning the same thing.
3. Only cases where **every** attempt must expire keep a short limit, renamed `expiringTimeout` and
   left at `0.5`. Load can only delay a blocked child further, which makes the asserted expiry more
   certain, never less.
4. The blocking fake shells sleep `20` seconds, from one constant, replacing today's literal `3`.
   It must outlast the largest limit in use (5 s) with margin; the limit's clock starts after
   `process.run()` returns, before the child reaches its `sleep`, so a slow spawn only widens the
   margin.
5. `testATimedOutInteractiveAttemptFallsThroughToTheLoginAttempt` uses the **production** limit. Both
   its attempts share one `timeout` value, so the only lever is the block: the interactive branch
   blocks 20 s and the login branch is one `echo`. The test therefore costs ~5 s per run. That is the
   price of covering the reported defect and it is paid once.
6. The elapsed-time assertion in `testATimedOutAttemptDoesNotWaitLongerThanTheLimit` becomes
   `elapsed < 5`, a literal, not an expression over the timeout. With a 20 s block and a 0.5 s limit
   a bounded resolution takes ~1 s and an unbounded one ~40 s, so the bound has 5× headroom over the
   real value and sits 8× below the failure it catches.
7. The orphaned `sleep` that outlives `process.terminate()` is accepted unchanged in kind.
   `terminate()` signals the shell's pid only, not its children, so an idle `sleep` outlives the
   test — today 3 s, after this change up to 20 s. Trapping `TERM` in the fake shell is test
   machinery bought with no correctness gain.
8. **Nothing in `Sources/` changes.** The `timeout:` injection point stays, now used only where
   expiry is the point. `testTheProductionTimeLimitIsFiveSecondsPerAttempt` stays and gains weight:
   it is the pin that says what limit most of the suite runs at.
9. `Tests/ShellPathStoreTests.swift` is **not** touched. Its thin margins need a different fix (a
   semaphore, not a timeout) and are a follow-up.

## Dependency graph

```
T1 (the only task)
```

One file, one interlocking edit: the block length, the renamed short limit and the elapsed bound
only make sense together. Nothing unblocks anything else.

## Task list

### T1: Drive the completing cases at the production limit and widen the blocking shells

**Files touched**

- `Tests/ShellPathResolverTests.swift`

**What it does**

Three mechanical changes across the one file.

*Constants* (currently `Tests/ShellPathResolverTests.swift:8-10`). Rename the stored property
`timeout` to `expiringTimeout`, keep the value `0.5`, and rewrite its doc comment to say what it is
now for — the limit used only where the test's point is that the limit fires. Add a sibling constant
for the block length, e.g. `private let blockingSeconds = 20`, interpolated into the fake shell
bodies as `sleep \(blockingSeconds)`.

*The two cases that must expire* keep `timeout: expiringTimeout`:

- `testAShellThatPrintsABannerThenBlocksProducesNoPath` (line 31)
- `testATimedOutAttemptDoesNotWaitLongerThanTheLimit` (line 187)

*Every other case that constructs a resolver* drops the `timeout:` argument entirely, so it runs at
`ShellPathResolver.attemptTimeout`. All twelve:

- `testATimedOutInteractiveAttemptFallsThroughToTheLoginAttempt` (line 41 — see decision 5)
- `testAnInteractiveValueThatIsNotAPathFallsThroughToTheLoginAttempt` (line 54)
- `testANonZeroExitFallsThroughToTheLoginAttemptEvenWhenTheOutputLooksLikeAPath` (line 65)
- `testBothAttemptsFailingGivesFailed` (line 76)
- `testAMissingShellGivesFailed` (line 82)
- `testAHealthyShellGivesFullFromOneInteractiveAttempt` (line 90)
- `testExtraLinesAroundThePathDoNotBreakResolution` (line 103)
- `testATrailingPathShapedLineIsNotMistakenForThePath` (line 121)
- `testAProfileThatFloodsStderrStillResolves` (line 137)
- `testAMarkedLineOnStderrIsNotAPath` (line 158)
- `testOutputWithNoMarkedLineGivesFailed` (line 167)
- `testTheResolvedValueIsTheSanitizedOne` (line 173)

`testTheProductionTimeLimitIsFiveSecondsPerAttempt` (line 183) constructs no resolver and is
unchanged.

*The three `sleep 3` fake shells* become `sleep \(blockingSeconds)`:

- `testAShellThatPrintsABannerThenBlocksProducesNoPath` (line 34)
- `testATimedOutInteractiveAttemptFallsThroughToTheLoginAttempt` (line 44, the `*i*` branch)
- `testATimedOutAttemptDoesNotWaitLongerThanTheLimit` (line 188)

*The elapsed bound* (line 194) becomes `XCTAssertLessThan(elapsed, 5, ...)`. Keep the message's
meaning — both attempts must be bounded by the limit.

Line numbers are from base `7ae81c1` and will drift as the edit proceeds; match on the test names.
Edit surgically — do not rewrite the file. Per `CLAUDE.md`, do not add explanatory comments beyond
the two constants' own doc comments; the test names carry the intent.

**Acceptance criteria**

1. `Tests/ShellPathResolverTests.swift` contains exactly two `timeout:` arguments, both
   `timeout: expiringTimeout`, in `testAShellThatPrintsABannerThenBlocksProducesNoPath` and
   `testATimedOutAttemptDoesNotWaitLongerThanTheLimit`. No other `ShellPathResolver(` call site
   passes a `timeout:`.
2. No `sleep 3` remains; the three blocking shells sleep `blockingSeconds` = 20.
3. The elapsed assertion is `elapsed < 5` as a literal, not derived from a timeout constant.
4. `Sources/` is untouched — `git diff --name-only` names only
   `Tests/ShellPathResolverTests.swift` plus the docs added by this pipeline.
5. `./scripts/ci.sh` is green.
6. `./scripts/ci.sh` is green a second time with the machine deliberately loaded.

**How the criteria are verified**

Criteria 1-4 by reading the diff and:

```bash
grep -n 'timeout:\|sleep \|XCTAssertLessThan' Tests/ShellPathResolverTests.swift
git diff --name-only
```

Criterion 5 by one clean run of the project's regression command:

```bash
./scripts/ci.sh
```

Criterion 6 is the direct evidence for the property this task exists to deliver, so it is not
optional. Build the load generator **in the session scratchpad, never in the repo** — the sign-off
gate refuses on stray untracked files. One workable shape:

```bash
# $SCRATCH is the session scratchpad directory
cat > "$SCRATCH/load.sh" <<'EOF'
#!/bin/sh
: > "$1"
n=$(sysctl -n hw.ncpu)
i=0
while [ "$i" -lt "$n" ]; do
  ( while : ; do : ; done ) &
  echo $! >> "$1"
  i=$((i + 1))
done
EOF
chmod +x "$SCRATCH/load.sh"
"$SCRATCH/load.sh" "$SCRATCH/load.pids"
uptime                    # record the load average actually reached
./scripts/ci.sh; echo "exit=$?"
xargs kill < "$SCRATCH/load.pids"
uptime                    # confirm the load is gone
```

Record in the build log: the load average reached, the exit status of each `./scripts/ci.sh` run,
and the wall-clock duration of the suite under load. Report the loaded run's exit status explicitly
— a green claim without it does not satisfy criterion 4. Finish by killing every load process and
confirming `git status --porcelain` shows nothing from the scratchpad work.

**Estimated scope:** S — one file, one interlocking edit, two full runs of the regression command.

## Build log

### T1: Drive the completing cases at the production limit and widen the blocking shells

**What landed**

| File | State |
| --- | --- |
| `Tests/ShellPathResolverTests.swift` | Edited. `timeout` renamed to `expiringTimeout` (still `0.5`), new `blockingSeconds = 20`, twelve call sites drop the `timeout:` argument, three fake shells sleep `blockingSeconds`, the elapsed bound is the literal `5`. |
| `Sources/` | Untouched. `git diff --name-only` names only the test file and this pipeline's two docs. |

Acceptance criteria 1-4 verified by reading the file: two `timeout:` arguments remain, both
`timeout: expiringTimeout`, in `testAShellThatPrintsABannerThenBlocksProducesNoPath` and
`testATimedOutAttemptDoesNotWaitLongerThanTheLimit`; no `sleep 3` remains; the assertion is
`XCTAssertLessThan(elapsed, 5, ...)`.

**Evidence**

This change adds no regression test, so there is no new assertion to watch fail. The property it
delivers — that the suite's outcome stops depending on machine load — was probed directly instead.

A scratchpad probe spawned a one-line `#!/bin/sh` fake shell 200 times and recorded the worst
latency, at three load levels on this machine (18 cores):

| Load average (1 min) | avg | max |
| --- | --- | --- |
| ~3 (baseline) | 4.3 ms | 307.5 ms |
| 11.8 (18 busy loops) | 9.2 ms | 760.7 ms |
| 23.5 (54 busy loops) | 23.7 ms | 765.5 ms |

A 765 ms stall on a spawn that nominally costs 4 ms is 1.5x **over** the old 0.5 s per-attempt
budget and 6.5x under the 5 s production limit. That is the margin this change buys, measured
rather than argued.

An attempt to watch the pre-fix file fail was made and did **not** reproduce. The test file was
reverted to its `7ae81c1` content (the edited version was copied to the session scratchpad first and
restored from there byte-identically afterwards, which is the restore route `CLAUDE.md`'s git
hygiene rule requires) and `./scripts/ci.sh` was run twice under load, at load averages 18.1 and
23.9. Both were green (exit 0, 457 tests, 0 failures). So the reported three-per-run failure is
probabilistic and was not triggered synthetically here; the case for the change rests on the
measured stall above, not on a watched failure, and that is stated rather than papered over.

**Deviations from the plan**

None. The load generator lived in the session scratchpad and every process it started was killed;
`ps` confirms no busy loop survives and the load average returned to baseline.

**The gate**

| Run | Load average at start | Result | Wall clock |
| --- | --- | --- | --- |
| `./scripts/ci.sh` clean | 2.96 | **exit 0** — 457 tests, 0 failures | 70 s |
| `./scripts/ci.sh` under deliberate load | 13.04 (17.21 at finish) | **exit 0** — 457 tests, 0 failures | 65 s |
| `./scripts/ci.sh` final, after restoring the edited file | 13.07 (decaying) | **exit 0** — 457 tests, 0 failures | 69 s |

`ShellPathResolverTests` costs ~6 s per run, dominated by
`testATimedOutInteractiveAttemptFallsThroughToTheLoginAttempt` waiting out the production limit —
the cost decision 5 of the spec accepted.

### Simplify

Dropped the first sentence of `blockingSeconds`' doc comment — it restated the identifier; only the
"longer than the largest limit in use" rationale remains. Three review findings were skipped as
already-settled spec decisions: shortening
`testATimedOutInteractiveAttemptFallsThroughToTheLoginAttempt` back to `expiringTimeout` (decision 5
— both attempts share one limit, so the login branch's spawn would get a 0.5 s budget against a
measured 765 ms stall, reintroducing the flake), the longer orphaned `sleep` (decision 7), and
deriving the `elapsed < 5` bound from `ShellPathResolver.attemptTimeout` (decision 10 — the bound
comes from `expiringTimeout` and `blockingSeconds`, and the shared digit is a coincidence).
`./scripts/ci.sh` exit 0 — 457 tests, 0 failures.
