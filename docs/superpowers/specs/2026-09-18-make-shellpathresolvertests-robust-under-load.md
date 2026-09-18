# Make ShellPathResolverTests robust under load

**Date:** 2026-09-18
**Base:** 7ae81c1fca4c52beaf290a2035746c975ff95c69
**PR:** #223

`Tests/ShellPathResolverTests.swift` drives every case — including the ones that must resolve
successfully — at a 0.5 second per-attempt limit. A fake shell is a process spawn, so a stall on a
busy machine expires the interactive attempt of a shell that is perfectly healthy, the resolver
falls through to the login-only attempt, and the test reports `degraded` where it expected `full`.
This change gives every attempt that must complete the production 5 second limit and keeps the
short limit only where the test's whole point is that the limit fires, so the suite's outcome stops
depending on how busy the machine is.

## Decisions

| # | Question | Decision | Source |
| --- | --- | --- | --- |
| 1 | Inject a clock, or widen the timeout? | Widen. The task brief offers both; a clock is the wrong trade here. The wait is `DispatchSemaphore.wait(timeout:)` on a real `Process` (`ShellPathResolver.swift:87-109`), so making it deterministic means abstracting process execution itself — and the file-versus-pipe capture, the stderr flood and the "stdout is read only after exit" rule (`ShellPathResolver.swift:62-66, 83-84, 111-112`) are exactly what these tests exist to cover against a real child process. A fake process would delete the coverage the suite was written for. | Spec author |
| 2 | What limit do the tests that must resolve use? | The production one, by passing no `timeout:` at all — `ShellPathResolver(shell:)` already defaults to `attemptTimeout` (`ShellPathResolver.swift:46-52`). 5 seconds is ~1600× the measured 3 ms spawn and ~16× the worst stall measured on this machine at the same load the defect was reported at (see Assumptions 4). A test-only "generous" constant would be a second number meaning the same thing. | Spec author |
| 3 | What limit do the tests that must time out use? | An unchanged short one, `expiringTimeout = 0.5`, named for what it does. Load cannot break these: it can only delay the child further, which makes the expiry the test asserts more certain, never less. They keep the suite fast — two of them would otherwise cost 10 seconds each. | Spec author |
| 4 | Which tests are which? | Must expire: `testAShellThatPrintsABannerThenBlocksProducesNoPath`, `testATimedOutAttemptDoesNotWaitLongerThanTheLimit` — every attempt in them blocks, none completes. Everything else must complete, including `testBothAttemptsFailingGivesFailed` and `testAMissingShellGivesFailed`: they pass today whatever the timing, but at 0.5 s a stall makes them pass through the timeout path instead of the non-zero-exit and spawn-failure paths they name. | Spec author |
| 5 | What about `testATimedOutInteractiveAttemptFallsThroughToTheLoginAttempt`, where one attempt must expire and the next must complete? | It uses the production limit. The two attempts share one `timeout` value, so the only lever is the block: the interactive branch blocks far longer than 5 seconds and the login branch is one `echo`, which gets the same 5 second budget as every other completing attempt. The cost is that this one test waits out the limit, ~5 seconds per run. That is the price of covering the reported defect — a timed-out interactive attempt falling through rather than aborting resolution — and it is paid once. | Spec author |
| 6 | How long do the blocking fake shells block? | 20 seconds, from one constant, replacing today's 3. It must outlast the largest limit in use (5 s) with margin; the limit's clock starts at `process.run()` (`ShellPathResolver.swift:91-98`), before the child even reaches the `sleep`, so a slow spawn only widens the margin. | Spec author |
| 7 | The orphaned `sleep` after `process.terminate()`? | Accepted, unchanged in kind. `terminate()` signals the shell, not its `sleep` child, so an idle `sleep` outlives the test — today for 3 seconds, after this change for up to 20. Trapping `TERM` in the fake shell to kill the child is test machinery bought with no correctness gain. | Spec author |
| 8 | Does `ShellPathResolver` itself change? | No. This is a test-only change; nothing in `Sources/` moves. The `timeout:` injection point stays, now used only where expiry is the point. | Spec author |
| 9 | Does `testTheProductionTimeLimitIsFiveSecondsPerAttempt` stay? | Yes, and it gains weight: after decision 2 it is the pin that says what limit most of the suite runs at. | Spec author |
| 10 | How is the elapsed-time assertion in `testATimedOutAttemptDoesNotWaitLongerThanTheLimit` made robust? | By widening the gap rather than the slack. With a 20 second block and a 0.5 second limit, a bounded resolution takes ~1 second and an unbounded one would take ~40, so the assertion becomes `elapsed < 5`: 5× headroom over the real value and 8× below the failure it catches. Today the same assertion allows 2.5 against a 6 second failure. | Spec author |
| 11 | Are the sibling suites fixed too? | No. `Tests/ShellPathStoreTests.swift` has its own thin margins (see Out of scope); the task names one file, and the store suite's fix is a different shape — a semaphore, not a timeout. | Spec author |

## Assumptions

Each verified against the codebase at base `7ae81c1`. The timing probe (assumption 4) ran entirely
in the scratchpad: a fake shell script and two `zsh` timing loops, plus a synthetic load generator.
Nothing was written into the repository.

1. **A timed-out interactive attempt is indistinguishable from any other failed attempt, so the
   observed symptom is exactly a spurious timeout.** `resolve()` is `attempt("-lic")` then, on
   `nil`, `attempt("-lc")` marked `.degraded` (`ShellPathResolver.swift:54-60`), and the timeout
   branch returns `nil` like every other refusal (`ShellPathResolver.swift:98-109`). So a healthy
   fake shell whose first attempt is killed by the limit yields `.degraded` where the test expects
   `.full` — the reported failure, in the reported direction.
2. **Every case that expects `.full` is exposed to that.** The five are
   `testAHealthyShellGivesFullFromOneInteractiveAttempt`,
   `testExtraLinesAroundThePathDoNotBreakResolution`,
   `testATrailingPathShapedLineIsNotMistakenForThePath`,
   `testAProfileThatFloodsStderrStillResolves` and
   `testTheResolvedValueIsTheSanitizedOne`; each constructs the resolver with
   `timeout: timeout` (`Tests/ShellPathResolverTests.swift:11, 89-181`) — five candidates for the
   three-per-run failures reported.
3. **The timeout is injectable per instance and defaults to the production value.**
   `init(shell:timeout:)` defaults `timeout` to `attemptTimeout`, which is 5
   (`ShellPathResolver.swift:30, 46-52`), so dropping the argument is all decision 2 needs.
4. **A trivial shell spawn costs milliseconds but stalls into the hundreds of milliseconds on a
   loaded machine.** Probe at load average 3.39 — the same regime as the reported failure: 200
   spawns of a one-line `#!/bin/sh` script gave avg 4.5 ms, max 306.8 ms; three further runs of 300
   spawns each gave a steady ~3 ms with a 6.4 ms worst case. A single 306 ms outlier against a
   500 ms budget is 1.6× headroom, and the real attempt does more than the probe — it creates two
   temp files and opens two `FileHandle`s before spawning (`ShellPathResolver.swift:67-86`) inside a
   test host under `xcodebuild`. Against 5 seconds the same outlier is 16× headroom.
5. **Load makes an expiring attempt expire sooner, not later.** The limit is measured from after
   `process.run()` returns (`ShellPathResolver.swift:91-98`), while the fake shell's `sleep` starts
   only once the child has execed, so scheduling delay is spent inside the window. Decision 3 is
   safe in the only direction that matters.
6. **`terminate()` does not reach the `sleep`.** `process.terminate()` (`ShellPathResolver.swift:99`)
   sends `SIGTERM` to the shell's pid only — no process group, no children — which is why decision 7
   is about an orphan that already exists rather than a new one.
7. **Nothing outside the test file reads these fakes.** `ShellPathResolver(` appears only in
   `Sources/App/ShellPathStore.swift:27` (production default, no timeout) and in
   `Tests/ShellPathResolverTests.swift`; `ShellPathStoreTests` drives a `FakeResolver` closure
   instead (`Tests/ShellPathStoreTests.swift:205-222`). The change cannot reach another suite.

## Objective

`Tests/ShellPathResolverTests.swift` fails when resolution logic is wrong and at no other time.

Success criteria:

1. Every case whose expected outcome requires an attempt to complete runs at the production
   5 second limit; the short limit survives only in cases where every attempt must expire.
2. No assertion's pass/fail boundary sits within an order of magnitude of a measured stall: the
   completing cases have ~1600× headroom over a nominal spawn and ~16× over the worst stall
   measured, and the elapsed-time assertion discriminates 1 second from 40.
3. `./scripts/ci.sh` is green.
4. `./scripts/ci.sh` is green a second time while the machine is deliberately loaded — the load
   generator started and killed from the scratchpad, never the repo. This is the only direct
   evidence for the property the task asks for.

## Verification

```bash
./scripts/ci.sh
```

The project's one runner: it regenerates the Xcode project, lints, builds and runs the suite. A
hand-written `xcodebuild` line is not a substitute (`CLAUDE.md`, "Verifying a change").

Before sign-off, `git status --porcelain`, and report anything untracked — including the
un-gitignored `default.profraw` a Debug launch leaves behind.

## Files touched

- `Tests/ShellPathResolverTests.swift` — the only file this change edits.
- `docs/superpowers/specs/2026-09-18-make-shellpathresolvertests-robust-under-load.md` — this file.

## Out of scope

- **`Sources/App/ShellPathResolver.swift`.** The resolver's behaviour is not in question; only the
  limit the tests drive it at.
- **The resolver's production 5 second limit.** It is reasoned about at
  `ShellPathResolver.swift:24-30` and pinned by a test; this change consumes it, it does not revisit
  it.
- **`Tests/ShellPathStoreTests.swift`.** Two cases assert that a call returns in under 0.2 s while a
  `FakeResolver` sleeps 0.3 s on another thread
  (`Tests/ShellPathStoreTests.swift:99-103, 127-131, 219`), so the window separating correct from
  broken is 0.2 s to 0.3 s — thinner than the one this task exists to widen. The fix is a different
  shape: block `FakeResolver` on a semaphore the test signals, which makes "did not wait"
  structural and costs no wall-clock at all. Reported as a follow-up, not folded in.
- **Converting the suite to Swift Testing, or restructuring it beyond the timeout values.**
