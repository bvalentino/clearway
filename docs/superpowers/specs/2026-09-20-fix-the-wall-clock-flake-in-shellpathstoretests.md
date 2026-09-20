# Fix the wall-clock flake in ShellPathStoreTests

**Date:** 2026-09-20
**Base:** b4369a5 (`Split buttons for Run and Open in (#237)`)

`ShellPathStoreTests` proves two rules — a degraded `PATH` is never awaited, and a failed
resolution is not awaited a second time — by measuring how long `awaitPath()` took against a fake
resolver that sleeps 0.3 s. A machine under load can spend more than the 0.2 s bound inside a call
that awaited nothing, which is what failed once during PR #232 and passed on the unloaded re-run.
This change replaces both timing bounds with a resolver call the test holds open, so each rule is
proved by what the store did rather than by how fast it did it, and deletes the 0.6 s of sleeping
the bounds needed.

## Decisions

| # | Question | Decision | Source |
| --- | --- | --- | --- |
| 1 | What deterministic signal replaces the elapsed-time bound? | A held resolver call. `FakeResolver` gains an optional 1-based `holdingCall:` index; the call at that index blocks on a semaphore until the test releases it, and the fake counts finished calls as well as started ones. The rule "the caller did not await this resolution" then reads as `resolver.finishedCount == 1` on the line after `awaitPath()` returns — a fact the machine's speed cannot change, because a held call cannot finish. | Spec author |
| 2 | Why not simply delete the timing assertion and keep the value assertion? | Because in the degraded case the value assertion is itself racing the refresh, and the 0.3 s delay is the only thing hiding it. With no delay, the refresh's `.full` value can land in `knownPath` before the second `awaitPath()` reads `currentPath` (assumption 3), and the test fails for the opposite reason. Holding the second call fixes both assertions at once; deleting the bound alone would trade a rare flake for a frequent one. | Spec author |
| 3 | Why not a fake clock, or an injected `Clock` on the store? | The store measures no time — it has no deadline, no timeout and no sleep (`ShellPathStore.swift:1-113`); the only duration in the test is the fake's own. There is nothing to inject a clock into, and adding one to production code to serve a test would be the larger change. | Spec author |
| 4 | Why a `DispatchSemaphore` rather than an `async` gate? | The fake runs on `DispatchQueue.global(qos: .userInitiated)`, off the cooperative pool, deliberately (`ShellPathStore.swift:84-87`), and it already blocks that thread with `Thread.sleep`. A semaphore is the same thread-blocking shape; an `async` gate would need the resolver closure to be async, which it is not (`ShellPathStore.swift:20`). | Spec author |
| 5 | Does the held call wait forever? | No — it waits with a bounded timeout, so a store that wrongly awaits the resolution fails an assertion instead of hanging the suite. The bound is only ever paid on the broken path: a passing run releases the gate on the line after the assertions and never waits. The bound may be generous (5 s) precisely because load cannot reach it in the passing case, which is the property the current 0.2 s bound lacks. | Spec author |
| 6 | Is `testAFailedResolutionIsNotAwaitedASecondTime` (`:93-104`) in scope? The task names only the degraded case. | Yes. It is the same assertion shape, the same 0.3 s sleep and the same defect, two cases above the one named, and decision 1's mechanism fixes it in the same edit. This follows the precedent in `docs/superpowers/specs/2026-09-19-replace-fixed-sleeps-worktree-group-manager-tests.md` decision 7, which pulled a fourth suite in for its single sleep rather than leave the stated rule untrue on the day it was written. It is also the only one of the two whose value assertion cannot distinguish the failure, so it depends on the new signal entirely. | Spec author |
| 7 | Does `FakeResolver.delay` go away? | No. Two cases keep it — `testTwoConcurrentCallsStartOneResolution` (`:106-117`) and `testAnEagerResolutionIsJoinedRatherThanDuplicated` (`:169-176`) — where the delay widens the window for a second caller to arrive while the first resolution is in flight. Neither asserts on elapsed time, and neither can fail under load (assumption 5): load only makes them exercise less. Making the overlap *guaranteed* would need the store to expose the moment a caller joins an in-flight task, which it does not and should not; a held call cannot serve there, because the joining caller would be waiting on the gate the test has not yet released. So the fake carries two knobs and the doc comment says which is for what. | Spec author |
| 8 | Does anything under `Sources/` change? | No. The rules being proved are unchanged and correct; only the proof changes. | Spec author |
| 9 | How is each rewritten case shown to still be a test? | By reverting the rule and watching it fail. `ShellPathStore.swift:57` — `return hasCompletedAResolution ? nil : task` — is the whole rule behind both cases; with it changed to `return task` both must fail, naming the finished-call count. The failures go in the plan's build log, and the line is restored before the build step ends. | Spec author |

## Assumptions

Each verified against the code at base `b4369a5`. No probe scripts or temporary files were written
into the repository; the reasoning below is read off the two files cited.

1. **The 0.2 s bound is the only thing either case asserts about not waiting.**
   `testADegradedValueIsReturnedWithoutWaiting` (`Tests/ShellPathStoreTests.swift:120-132`) and
   `testAFailedResolutionIsNotAwaitedASecondTime` (`:93-104`) each take `Date()` before the second
   `awaitPath()` and assert `XCTAssertLessThan(Date().timeIntervalSince(started), 0.2, …)` after it,
   against a `FakeResolver(delay: 0.3)`. Nothing else in either case distinguishes an awaited
   resolution from one running behind the caller.

2. **A second `awaitPath()` does start a fresh resolution in both cases, so there is a call to
   hold.** `awaitPath` returns early only when `knownIsFull` (`ShellPathStore.swift:55`); a degraded
   value leaves it false (`:93`) and a failure leaves `knownPath` nil (`:94-97`), so
   `startResolutionLocked()` runs and `inFlight` is nil by then, because the first `awaitPath()`
   awaited the task that cleared it (`:100`, `:59`). The second call is therefore always the
   resolver's call 2.

3. **The degraded case's value assertion races the refresh once the delay is gone.** `awaitPath`
   returns `currentPath` (`:60`), read after `pending?.value`, and `pending` is nil on this path
   (`:57`, `hasCompletedAResolution` was set at `:99`). The refresh runs concurrently on a global
   queue (`:84-87`) and assigns `knownPath` under the lock (`:92`), so with no delay it can publish
   `/opt/homebrew/bin` before that read and the assertion on the degraded value fails. This is
   decision 2's reason for holding the call rather than deleting the bound.

4. **Blocking inside the fake blocks a `DispatchQueue.global` thread, not the cooperative pool.**
   The resolution is hopped off the pool on purpose and the comment at `ShellPathStore.swift:84`
   says so; `FakeResolver.next()` already sleeps that thread (`Tests/ShellPathStoreTests.swift:219`).
   One further held thread per case, released by the test, adds no new hazard.

5. **The two cases that keep `delay` cannot fail under load.**
   `testTwoConcurrentCallsStartOneResolution` asserts `callCount == 1` (`:115`): the second caller
   either joins the in-flight task (`ShellPathStore.swift:78`) or finds `knownIsFull` and starts
   nothing (`ShellPathStore.swift:55`), so the count is 1 on both interleavings.
   `testAnEagerResolutionIsJoinedRatherThanDuplicated` asserts the same count (`:177`) after
   `startResolution()` (`ShellPathStore.swift:40-45`), with the same two interleavings. Load changes
   which interleaving is taken, never the assertion.

6. **`waitUntil` already exists on the suite** (`Tests/ShellPathStoreTests.swift:182-196`), polling
   a condition with a 2 s deadline. The cases that need to observe a background resolution landing
   already use it (`:85`, `:142`, `:153`, `:165`); this change adds no polling machinery and removes
   none.

7. **No other test reads `FakeResolver`'s call accounting in a way a second counter would disturb.**
   `callCount` is read at `:23`, `:74`, `:86`, `:115`, `:143`, `:153`, `:166` and `:177`, and
   `calls` is incremented before the delay (`:214-219`); a `finishedCount` incremented after the
   delay is additive and leaves every existing reading unchanged.

## Objective

Make both "was not awaited" rules in `ShellPathStoreTests` provable from the resolver's state rather
than from elapsed time, so neither case can fail on a loaded machine.

### Success criteria

1. `grep -n "Date()" Tests/ShellPathStoreTests.swift` matches only inside `waitUntil`'s deadline
   loop — no case measures its own elapsed time.
2. `testADegradedValueIsReturnedWithoutWaiting` holds the refresh open and asserts both that the
   value returned is the degraded one and that the refresh had not finished when it returned.
3. `testAFailedResolutionIsNotAwaitedASecondTime` does the same for the retry.
4. Both cases were watched failing against `ShellPathStore.swift:57` reverted to `return task`, with
   the failure text pasted into the plan's build log, and the line restored afterwards.
5. No `Thread.sleep` runs on the passing path of either case; the suite's wall time drops by roughly
   0.6 s.
6. `Sources/` is unchanged by the merged diff.
7. `./scripts/ci.sh` is green, and `git status --porcelain` is clean apart from this change's files.

## Verification

```bash
./scripts/ci.sh
```

The only runner of the test suite: it regenerates the Xcode project, lints, builds and tests. It is
both the regression check after each build step and the full gate at sign-off, per the project's
`## Pipeline` section. `swiftlint lint --quiet` runs inside it as a post-build phase.

Repeat runs under load are a useful spot check of the criterion this change exists for, but the
proof is the assertion shape, not a sample of green runs.

## Files this change touches

| File | Change |
| --- | --- |
| `Tests/ShellPathStoreTests.swift` | `FakeResolver` gains an optional held-call index, a semaphore with a bounded wait, a `release()` and a finished-call counter. The two cases drop their `Date()` bounds and their `delay:`, and assert on the held call instead. |
| `docs/superpowers/plans/2026-09-20-fix-the-wall-clock-flake-in-shellpathstoretests.md` | The plan and its build log. |

## Out of scope

- **Any change to `ShellPathStore`.** Decision 8: the rules are correct; only their proof is being
  replaced. The temporary revert in criterion 4 is restored within the build step.
- **`FakeResolver.delay` and the two cases that use it.** Decision 7 and assumption 5: they carry no
  timing assertion and cannot fail under load.
- **`Task.sleep` in the other suites.** `WorkTaskManagerWatcherTests` (5), `PromptManagerTests` (1)
  and `SavedCommandManagerTests` (2) sleep for reasons of their own — file-system watchers and debounce
  windows — and none of them asserts an elapsed-time bound. Different subsystems, different signals,
  not named by this task.
- **`waitUntil`'s 5 ms poll interval and 2 s deadline.** A poll granularity and a failure deadline,
  neither of which is an assertion about speed.
