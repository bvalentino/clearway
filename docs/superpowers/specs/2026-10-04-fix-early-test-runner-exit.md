# Fix the early test-runner exit in WorktreeGroupPersistenceTests

**Date:** 2026-10-04
**Base:** 3fe622b (Bundle THIRD-PARTY-LICENSES in the app, #271)

While PR #271 was being built, one `./scripts/ci.sh` run exited 65 because the test host (the
built `Clearway.app`) exited with status 0 during
`WorktreeGroupPersistenceTests.testAHandEditedRegistryDropsBlanksAndRepeats`. This change finds
out why and fixes it. If the cause cannot be reproduced, the change records the evidence and the
investigation instead. It also removes the unused `@testable import Clearway` from
`Tests/BundledResourcesTests.swift`. The spec stage already pulled the incident out of the macOS
unified log (see "Evidence gathered at spec time"). That evidence changes the starting point: the
host did not quit through AppKit, and two other test hosts with the same bundle id were running
alongside it.

## Decisions

| # | Question | Decision | Why |
| --- | --- | --- | --- |
| D1 | One spec for both items? | Yes. Two independent tasks in the plan: the import removal (T-import) and the investigation (T-exit). | The brief bundles them. The import removal is one line, and putting it first gives the investigation a known-green baseline. |
| D2 | Where does the evidence for the exit come from? | The macOS unified log, read with `/usr/bin/log show`. The `.xcresult` is not a source. | No `.xcresult` for the failing run survives. `Clearway-dhvfbjezcccjkagulhjgkogmvfhr/Logs/Test/` (the #271 worktree's DerivedData) holds only the three later 951-test runs. The log still holds the incident, and it records the host's own last lines, which an xcresult never does. Always call it as `/usr/bin/log`: in zsh, bare `log` is a builtin and fails with "too many arguments". |
| D3 | Is `testAHandEditedRegistryDropsBlanksAndRepeats` treated as the suspect? | No. It is treated as the test that happened to be running, and its file is not edited unless the investigation implicates it. | The host ran its `atexit` handlers on its main thread, and no `-[NSApplication terminate:]` line came first (E3). The test runs `git config` subprocesses and builds a `WorktreeGroupManager` (`Tests/WorktreeGroupPersistenceTests.swift:547-556`, `Tests/TestHelpers.swift:322-336`), and no code on that path calls `exit` (A4). |
| D4 | Which hypotheses does the investigation test, and in what order? | H1, then H2, then H3, as defined under "Hypotheses". Each one gets a bounded reproduction attempt as described under "Investigation procedure". | Ordered by how strongly the evidence points at each one. |
| D5 | How much effort goes into reproducing it? | At most about 60 minutes of wall-clock repro runs across R1 and R2, in steps that each finish inside the 10-minute tool limit. If nothing recurs, the outcome is "unreproducible" with the write-up from D7. | It happened once in at least two weeks of logged runs (E8), so an open-ended loop could run forever. The brief explicitly accepts an evidenced "unreproducible". |
| D6 | What counts as a fix, and who decides on one that changes the pipeline? | If the cause is in app or test code (a path that ends the process), fix it at that source and add a regression test that fails on 3fe622b. If the cause is interference between concurrently running test hosts (H1), **do not change `scripts/ci.sh` or the pipeline on your own**: return to the orchestrator with the evidence and a recommended fix. That is a scope change the operator owns. | Under H1, a fix means serialising `ci.sh` runs, isolating the test host's defaults domain or home, or similar. Each of those changes how every pipeline in this repo runs, not just this task. |
| D7 | If it is unreproducible, where does the write-up go? | Two places. (a) The plan's build log for T-exit: the hypotheses, each repro attempt with its command, duration and result, and the E1-E8 evidence. (b) Three or four lines in the project `CLAUDE.md` `## Pipeline` section. They say that an early "test runner exited with code 0" is investigated through the unified log and not the xcresult, give the `/usr/bin/log show` query from "Investigation procedure" step 1, and point to this spec. | The spec is frozen after merge, and the plan's build log is where run evidence lives in this repo (see `docs/superpowers/plans/2026-10-04-bundle-third-party-licenses-in-the-app.md:211-214`). The `CLAUDE.md` lines matter because the only surviving evidence was the unified log, which keeps roughly two weeks. The next agent who sees this error needs to capture it before it rotates out. |
| D8 | How is the import removal verified? | Delete line 2 of `Tests/BundledResourcesTests.swift`, then run `./scripts/ci.sh`. A clean compile plus `testThirdPartyLicensesShipsWithEveryNotice` passing is the proof. If it fails to compile, put the import back and record the compiler error as the reason it stays. | The file uses only `XCTest`, `Bundle.main`, `String`, `Set` and `XCTUnwrap` (`Tests/BundledResourcesTests.swift:1-17`). `Bundle.main` is the app because the bundle is app-hosted (`TEST_HOST`), whether or not the module is imported. |
| D9 | May the investigation add diagnostic code? | Only temporarily and only in the working tree: for example, an `atexit` handler in a test file that logs `Thread.callStackSymbols`. It is removed before commit, and the build log records that it was used. No diagnostic is committed unless it becomes the fix's regression test. | A stack at the moment of `exit` is the only thing that would directly name the caller. The sign-off gate refuses stray files. |
| D10 | May the investigation run under CPU load? | Yes, if it helps R2, under the `CLAUDE.md` "Background load generators" rule: every generator is bounded by `timeout <secs>` or `trap 'kill $LOADPIDS' EXIT`, and every step stays shorter than the tool timeout. | Brief, Pointers. That rule exists because a load loop once outlived its shell. |

## Assumptions

Each assumption below was checked against the code or the machine.

- **A1.** The test host is the built app, and it launches with the user's real defaults and home.
  `scripts/ci.sh:19-23` runs `-scheme ClearwayTests` with no `APP_PRODUCT_NAME`. The built
  `Info.plist` gives `CFBundleIdentifier` = `app.getclearway.mac.debug` (read from
  `Clearway-dhvfbjezcccjkagulhjgkogmvfhr/Build/Products/Debug/Clearway.app`). Every Debug test
  host on this machine therefore shares one bundle id and one defaults domain. `ClearwayApp.init`
  (`Sources/App/ClearwayApp.swift:149-186`) runs inside the host. It starts `ghostty_init`, the
  agent-hook monitor and Sparkle's `SPUStandardUpdaterController(startingUpdater: true)`.
- **A2.** Concurrent `ci.sh` runs share `~/.clearway/hook.sock`. The log shows host 30841 at
  17:10:40.630: "A process is already listening at /Users/bvalentino/.clearway/hook.sock — most
  likely a second Clearway".
- **A3.** Every AppKit quit path goes through `-[NSApplication terminate:]` and logs it at the
  default level: Cmd+Q, last window closed (`applicationShouldTerminateAfterLastWindowClosed`
  returns `true`, `ClearwayApp.swift:57-59`), a quit Apple Event, and libghostty's
  `GHOSTTY_ACTION_QUIT` (`Sources/Ghostty/Ghostty.App.swift:232-234`, which calls
  `NSApp.terminate`). The normally finishing host 33479 logs
  `[com.apple.AppKit:Application] terminate:` at 17:14:02.157 before it exits.
- **A4.** No first-party code in the app calls `exit`. `grep -rnE '\bexit\(|_exit\(' Sources Tests`
  matches only `Sources/CLI/main.swift:10`, which is the `cway` tool, a separate executable that is
  not part of the `Clearway` target.
- **A5.** No crash report exists. `~/.local/state/ghostty/crash/` has no entry after Sep 17, and the
  exit status was 0, not 6 (`CLAUDE.md`, Concurrency: libghostty's crash handler exits 6).
- **A6.** The app has no `NSSupportsAutomaticTermination` key in its `Info.plist` (checked in the
  built plist), so AppKit automatic termination does not apply even though AppKit logs
  `AutomaticTermination` lines.

## Evidence gathered at spec time

All of this comes from `/usr/bin/log show` on 2026-10-04. No files were written to the repo. The
queries ran from the shell only, with no probe scripts.

- **E1.** The failure: `xcodebuild[32531]` at 2026-10-04 17:14:02.419 logged "Test runner for
  (null) will finish with error: The test runner exited with code 0 before finishing running
  tests. This may be due to your code calling 'exit'…". Its host was pid 32226, launched at
  17:11:17.54. xcodebuild then relaunched a host (pid 42822) for "Selected tests" starting at
  `WorktreeGroupPersistenceTests`, and the rerun passed. That is the retry that turned the run into
  exit 65 and not a hang.
- **E2.** Three `ci.sh` test runs overlapped. Hosts 30841 (xcodebuild 30723, ended normally
  17:13:20), 32226 (xcodebuild 32531, the #271 run) and 33479 (xcodebuild 32009, ended normally
  at 17:14:02.30) were alive together. Judging only by timestamps, the other two runs belong to the
  `show-skill-install-failures-in-settings` and `setup-script-with-long-command` worktrees, whose
  xcresults start at 17:10:35 and 17:11:06.
- **E3.** How 32226 died: its main thread (`2d0326e`) logged `CoreAnalytics … Entering exit
  handler` at 17:14:02.040. No `terminate:`, `_setShouldRestoreStateOnNextLaunch` or
  `discardAllPersistentStateAndClose` line came before it, although 33479's ordinary end logs all
  three. So the process called `exit()` directly. It did not go through AppKit termination (A3),
  and it did not take a signal, because `atexit` handlers ran.
- **E4.** Between 17:13:51.009 and 17:14:01.869, 32226 logged nothing. At 17:14:01.869 and .875 its
  main thread logged "Loading Preferences From User CFPrefsD" twice. Those two moments match, to
  the millisecond, 33479's runner closing two suites (17:14:01.869 and 17:14:01.876, the end of
  `WorktreeGroupWriteAlertTests` and `WorktreeHooksTests`). The process exited 165 ms later.
- **E5.** 32226 exited within 0.12 s of 33479's own end: 33479's last suite, `WorktreeTests`,
  started at 17:14:01.902, and 33479 logged `terminate:` at 17:14:02.157.
- **E6.** The operator was clicking 33479's window (`a084`, added at 17:11:46.259, the moment host
  33479 started). WindowManager logged "began drag of window a084" at 17:13:59.936 and
  17:14:01.950, and an "activation ordering click on window a084" at 17:14:02.033, 7 ms before
  32226 exited. The first click at 17:13:59.9 did not end any host.
- **E7.** The earlier normal end of host 30841 at 17:13:20 did not end 32226 or 33479. So if one
  host's ending can take another down, it does not happen every time.
- **E8.** `/usr/bin/log show --last 14d` (the log reaches back to 2026-09-20) has exactly one
  "before finishing running tests" line: E1.

## Hypotheses

- **H1. Interference between concurrent test hosts.** All three hosts share the same bundle id,
  defaults domain, `~/.clearway`, `~/.claude/settings.json` and test-temp naming (A1, A2). E4 and
  E5 tie 32226's last moments to 33479's run ending. If this holds, the fault is in the shared
  environment, not in any one test.
- **H2. An in-process caller of `exit()` that is not first-party Swift.** Candidates are libghostty
  (Zig `std.process.exit`), Sparkle, and XCTest itself. E3 rules out every AppKit path but not
  these. A4 rules out first-party code.
- **H3. The test, or a test before it in the same host.** No evidence supports it. It stays in
  scope so that R1 can rule it out cheaply.

## Investigation procedure

T-exit follows these steps. Record every command, its duration and its result in the build log.

1. **Capture recipe.** On any recurrence, find the run with
   `/usr/bin/log show --last 1h --predicate 'process == "xcodebuild" AND eventMessage CONTAINS "before finishing running tests"' --style compact`,
   then the host pid from
   `/usr/bin/log show … --predicate 'process == "testmanagerd" AND eventMessage CONTAINS "pid"'`,
   then the host's last lines with
   `/usr/bin/log show … --predicate 'processID == <pid>' --debug --info`.
2. **R1, the test alone (H3).** Run `./scripts/ci.sh` once to build. Then run only the suite in a
   loop with the same flags `ci.sh` passes, plus
   `-only-testing:ClearwayTests/WorktreeGroupPersistenceTests -test-iterations <n>` (no
   `PRODUCT_NAME`, no `APP_PRODUCT_NAME`; see `CLAUDE.md` "Verifying a change"). Pick `n` so each
   step finishes under 10 minutes.
3. **R2, concurrent hosts (H1).** Run two or three `xcodebuild … test` invocations at the same
   time with the `ci.sh` flags, each with its own `-derivedDataPath` under the scratchpad, so they
   do not fight over one DerivedData but still share the bundle id. At least one runs the full
   suite to its end while another is mid-`WorktreeGroupPersistenceTests`, which repeats the E5
   timing. Load, if used, follows D10.
4. **On a hit**, use D9's temporary `atexit` stack logging to name the caller, then apply D6.
5. **With no hit** inside D5's budget, write up per D7.

## Objective and success criteria

- `Tests/BundledResourcesTests.swift` no longer has `@testable import Clearway`, or the import stays
  with the compiler error that requires it written down (D8).
- One of these holds:
  - the caller of `exit()` is identified with a stack or a reproduction, and the cause is fixed with
    a regression test that fails on 3fe622b; or
  - the cause is shown to be concurrent-host interference, and the evidence plus a recommended fix
    go back to the orchestrator (D6); or
  - it did not recur within the D5 budget, and the build log plus the `CLAUDE.md` note record the
    investigation (D7).
- `./scripts/ci.sh` exits 0 after the last edit.
- `git status --porcelain` shows no untracked or ignored leftovers before sign-off, apart from a
  reported `default.profraw`, if any.

## Commands

From the project `CLAUDE.md` `## Pipeline` section:

| Step | Command |
| --- | --- |
| Regression check (every build task, simplify) | `./scripts/ci.sh` |
| Full gate (sign-off, once) | `./scripts/ci.sh` |
| Pre-sign-off tree check | `git status --porcelain` |

The repro loops in R1 and R2 are probes, not verification. They never stand in for `ci.sh`.

## Files touched

| File | Change |
| --- | --- |
| `Tests/BundledResourcesTests.swift` | Line 2 deleted (D8). |
| `docs/superpowers/plans/2026-10-04-fix-early-test-runner-exit.md` | Build log carries the investigation (D7a). |
| `CLAUDE.md` | Three or four lines in `## Pipeline`, only on the unreproducible outcome (D7b). |
| To be determined | Only if a source is found under H2 or H3: the offending file plus a regression test. |

## Boundaries

- Always: run `./scripts/ci.sh` after the last edit, bound every background process, and remove
  temporary diagnostics before committing.
- Ask first (return to the orchestrator): any change to `scripts/ci.sh`, `.github/workflows/ci.yml`,
  `project.yml` test settings, or how the test host picks its defaults domain or home (D6).
- Never: `git stash` or `git checkout <path>`, `PRODUCT_NAME` passed to `xcodebuild`, or launching
  the app outside a test run (see memory: no screenshot verification by agents).

## Out of scope

- Other flakes the repro loops may surface, such as the `ShellPathResolverTests` wall-clock flake
  mentioned in older plans. Report them as follow-ups.
- Isolating the test host from the developer's real `~/.claude/settings.json` and defaults in
  general. It is relevant to H1 but is a separate decision (D6).
- Removing `@testable import Clearway` from any other test file.
