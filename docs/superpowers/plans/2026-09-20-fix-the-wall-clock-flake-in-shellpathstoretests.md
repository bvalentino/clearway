# Fix the wall-clock flake in ShellPathStoreTests

**Date:** 2026-09-20
**Base:** b4369a5 (`Split buttons for Run and Open in (#237)`)

Breaks down `docs/superpowers/specs/2026-09-20-fix-the-wall-clock-flake-in-shellpathstoretests.md`.
Every design decision is settled there; this file only orders the work and says how each piece is
verified.

## Architecture decisions carried from the spec

1. The elapsed-time bound is replaced by a **held resolver call**: `FakeResolver` gains an optional
   1-based `holdingCall:` index, and the call at that index blocks until the test calls `release()`.
2. The rule "the caller did not await this resolution" is read off a **second counter**,
   `finishedCount`, asserted on the line after `awaitPath()` returns. A held call cannot finish, so
   `finishedCount == 1` is a fact about what the store did, not about how fast it did it.
3. The gate is a `DispatchSemaphore` with a **bounded 5 s wait**, so a store that wrongly awaits the
   resolution fails an assertion instead of hanging the suite. The bound is only ever paid on the
   broken path: a passing run releases the gate on the line after its assertions and never waits.
4. A semaphore, not an `async` gate: the resolver closure is synchronous
   (`ShellPathStore.swift:20`) and already runs on `DispatchQueue.global(qos: .userInitiated)` off
   the cooperative pool, where it already blocks the thread with `Thread.sleep`.
5. No fake clock and no injected `Clock`. The store measures no time — no deadline, no timeout, no
   sleep — so there is nothing to inject one into.
6. `FakeResolver.delay` **stays**, for `testTwoConcurrentCallsStartOneResolution` and
   `testAnEagerResolutionIsJoinedRatherThanDuplicated`, where it widens the window for a second
   caller to arrive mid-flight. Neither asserts on elapsed time. The fake therefore carries two
   knobs and its doc comment says which is for what.
7. `testAFailedResolutionIsNotAwaitedASecondTime` is in scope alongside
   `testADegradedValueIsReturnedWithoutWaiting`: same assertion shape, same defect, same fix.
8. Nothing under `Sources/` changes. The rules being proved are correct; only the proof changes. The
   one touch of `Sources/App/ShellPathStore.swift` is T3's temporary revert, restored inside T3.
9. Deleting the bound without holding the call is not an option: in the degraded case the value
   assertion is itself racing the refresh, and the 0.3 s delay is the only thing hiding that race.
   Holding the call fixes both assertions at once.

## Dependency graph

```
T1  FakeResolver held-call mechanism + rewrite testADegradedValueIsReturnedWithoutWaiting
 └── T2  rewrite testAFailedResolutionIsNotAwaitedASecondTime on the same mechanism
      └── T3  negative control: revert ShellPathStore.swift:57, watch both cases fail, restore
```

Strictly sequential. T2 uses the mechanism T1 introduces; T3 needs both rewritten cases to exist at
once, because criterion 4 of the spec is that *both* were watched failing against the same reverted
line.

The regression check after every task is `./scripts/ci.sh` — the only runner of the test suite, and
the only thing that regenerates the Xcode project so an added or deleted Swift file is visible to
the build.

## Task list

### T1: Hold the refresh open in the degraded case

**Files**

| File | Change |
| --- | --- |
| `Tests/ShellPathStoreTests.swift` | `FakeResolver` gains `holdingCall:`, a semaphore, `release()` and `finishedCount`; `testADegradedValueIsReturnedWithoutWaiting` drops its `Date()` bound and its `delay:` and asserts on the held call. |

**What it does**

Extend `FakeResolver` (currently `Tests/ShellPathStoreTests.swift:199-222`) with the held-call
mechanism, then rewrite the degraded case (`:120-132`) to use it.

The fake's new shape — the existing `outcomes`, `delay` and `calls` members are unchanged:

```swift
private let holdingCall: Int?
private let gate = DispatchSemaphore(value: 0)
private var finished = 0

init(outcomes: [ShellPathResolver.Outcome], delay: TimeInterval = 0, holdingCall: Int? = nil)

/// Calls that have returned an outcome. A held call counts only once `release()` lets it go.
var finishedCount: Int { lock.withLock { finished } }

/// Lets the held call return.
func release() { gate.signal() }
```

`next()` keeps its existing locked `calls += 1` / `outcomes.removeFirst()` body, and also carries
the new call's index out of the lock. Then, outside the lock: if that index equals `holdingCall`,
wait on the gate with a bounded timeout — `_ = gate.wait(timeout: .now() + 5)` — instead of
sleeping; otherwise sleep `delay` as it does today. A held call does not also pay `delay`; no case
passes both. Finally, still outside the lock, increment `finished` under the lock and return the
outcome. `callCount` must keep counting **started** calls, incremented before the wait, because
eight existing readings depend on that (`:23`, `:74`, `:86`, `:115`, `:143`, `:153`, `:166`, `:177`).

Replace the fake's doc comment so it names both knobs and what each is for: `delay` sleeps every
call and widens the window for a second caller to arrive mid-flight; `holdingCall` blocks one call
so a case can prove the caller did not await that resolution.

The rewritten case:

```swift
func testADegradedValueIsReturnedWithoutWaiting() async {
    let resolver = FakeResolver(
        outcomes: [.degraded("/usr/local/bin"), .full("/opt/homebrew/bin")],
        holdingCall: 2
    )
    let store = ShellPathStore(resolve: { resolver.next() })

    let first = await store.awaitPath()
    XCTAssertEqual(first, "/usr/local/bin:\(baseline)")

    let second = await store.awaitPath()

    XCTAssertEqual(second, "/usr/local/bin:\(baseline)")
    XCTAssertEqual(resolver.finishedCount, 1, "A degraded value must never be awaited")
    resolver.release()
}
```

`holdingCall: 2` is the refresh: the first `awaitPath()` is the resolver's call 1 and it awaits that
call, which clears `inFlight`, so the second `awaitPath()` always starts call 2. `release()` goes
**after** the assertions — the passing path never waits on the gate, and the released call finishes
behind the test the way the old delayed call did.

**Acceptance criteria**

1. `testADegradedValueIsReturnedWithoutWaiting` contains no `Date()` and no `delay:`, and asserts
   both that the value returned is the degraded one and that `resolver.finishedCount == 1`.
2. `FakeResolver` exposes `holdingCall:`, `finishedCount` and `release()`, and its doc comment says
   which knob serves which job.
3. `testTwoConcurrentCallsStartOneResolution` and `testAnEagerResolutionIsJoinedRatherThanDuplicated`
   are untouched and still pass with `delay:`.
4. Nothing under `Sources/` changed.

**Verification**

- `./scripts/ci.sh` — green, zero SwiftLint errors.
- `grep -n "Date()\|delay:" Tests/ShellPathStoreTests.swift` — the surviving `delay:` call sites are
  `testTwoConcurrentCallsStartOneResolution`, `testAnEagerResolutionIsJoinedRatherThanDuplicated` and
  the initializer, and nothing else. The remaining `Date()` matches are `waitUntil` plus the
  `testAFailedResolutionIsNotAwaitedASecondTime` bound T2 removes.
- `git diff --stat Sources/` is empty.
- Record the suite's wall time from the `.xcresult` in the build log, for the drop criterion 5 of
  the spec asks about.

### T2: Hold the retry open in the failed-resolution case

**Files**

| File | Change |
| --- | --- |
| `Tests/ShellPathStoreTests.swift` | `testAFailedResolutionIsNotAwaitedASecondTime` drops its `Date()` bound and its `delay:` and asserts on the held call. |

**What it does**

Rewrite `testAFailedResolutionIsNotAwaitedASecondTime` (`Tests/ShellPathStoreTests.swift:93-104`)
on the mechanism T1 added. Its doc comment above the case is correct and stays as it is.

```swift
func testAFailedResolutionIsNotAwaitedASecondTime() async {
    let resolver = FakeResolver(outcomes: [.failed, .failed], holdingCall: 2)
    let store = ShellPathStore(resolve: { resolver.next() })

    _ = await store.awaitPath()

    let second = await store.awaitPath()

    XCTAssertEqual(second, baseline)
    XCTAssertEqual(resolver.finishedCount, 1, "a retry must run behind the caller")
    resolver.release()
}
```

The value assertion here cannot distinguish an awaited retry from one running behind the caller —
both outcomes are `.failed`, so the value is the baseline either way. `finishedCount` is the whole
signal in this case, which is why it is worth having.

**Acceptance criteria**

1. The case contains no `Date()` and no `delay:`, and asserts `resolver.finishedCount == 1` after the
   second `awaitPath()` returns.
2. `grep -n "Date()" Tests/ShellPathStoreTests.swift` now matches only inside `waitUntil`'s deadline
   loop (spec success criterion 1).
3. No `Thread.sleep` runs on the passing path of either rewritten case: neither passes `delay:`, and
   the gate is released, never waited on.
4. Nothing under `Sources/` changed.

**Verification**

- `./scripts/ci.sh` — green, zero SwiftLint errors.
- The `grep` in criterion 2, pasted into the build log.
- `git diff --stat Sources/` is empty.
- `ShellPathStoreTests`' wall time from the `.xcresult`, compared against T1's figure and the base's;
  the two cases together drop 0.6 s of sleeping.

### T3: Prove both cases still fail when the rule is reverted

**Files**

| File | Change |
| --- | --- |
| `Sources/App/ShellPathStore.swift` | Line 57 reverted to `return task` for the duration of one test run, then restored. Not part of the task's diff. |
| `docs/superpowers/plans/2026-09-20-fix-the-wall-clock-flake-in-shellpathstoretests.md` | The watched failures pasted into the build log. |

**What it does**

`ShellPathStore.swift:57` — `return hasCompletedAResolution ? nil : task` — is the whole rule behind
both rewritten cases. Change it to `return task`, so every caller awaits the resolution it started,
and run the suite. Both cases must fail, and each failure must name the finished-call count rather
than an elapsed time. Each takes about 5 s to fail, because the held call's bounded wait is what
releases the wrongly-awaiting caller; that is the cost paid only on the broken path.

Expected in the degraded case: the second `awaitPath()` returns only after the gate times out, by
which time call 2 has published `/opt/homebrew/bin`, so **both** the value assertion and
`finishedCount` fail. In the failed case only `finishedCount` fails, as T2 records.

Restore the line, re-run, and confirm green before the task ends. Other cases in the suite may also
fail under the revert — they assert on `callCount` and values, not on the finished count — and those
failures are neither proof nor a problem; report them but do not act on them.

**Acceptance criteria**

1. The build log carries the verbatim failure text for both cases, each naming
   `resolver.finishedCount`.
2. `Sources/App/ShellPathStore.swift` is restored: `git diff Sources/` is empty at the end of the
   task, and line 57 reads `return hasCompletedAResolution ? nil : task`.
3. `./scripts/ci.sh` is green after the restore.

**Verification**

- The failing run's output, pasted into the build log under the entry for this task.
- `git diff --stat Sources/` empty, and `git status --porcelain` showing only this change's files.
- `./scripts/ci.sh` green on the restored tree.

## Checkpoint: after T3

- `./scripts/ci.sh` green on a tree whose only diff is `Tests/ShellPathStoreTests.swift` plus the
  spec and this plan.
- Every one of the spec's seven success criteria has an entry in the build log naming how it was
  checked.

## Risks

| Risk | Impact | Mitigation |
| --- | --- | --- |
| A held thread is left blocked when a case fails before `release()` | Low | The wait is bounded at 5 s, so the thread is released whatever the test does; the suite cannot hang on it. |
| `finished` incremented outside the lock | Low | The increment is specified as `lock.withLock`, the same lock `calls` uses; the fake stays `@unchecked Sendable` for the same reason it already is. |
| A future case passes both `delay:` and `holdingCall:` and is surprised | Low | The held call skipping `delay` is stated in the fake's doc comment; no case today passes both. |
| The temporary revert in T3 is committed | Medium | T3's acceptance criterion 2 is an empty `git diff Sources/`, checked before the task ends. |

## Build log

Build agents append one entry per task here, headed `#### T<n>: <task name>`. `### ` is reserved for
the task list above.

#### T1: Hold the refresh open in the degraded case

**What landed**

| File | State |
| --- | --- |
| `Tests/ShellPathStoreTests.swift` | `FakeResolver` gained `holdingCall:` (1-based), a `DispatchSemaphore` gate with a bounded 5 s wait, `release()` and `finishedCount`; its doc comment now names both knobs and what each is for. `testADegradedValueIsReturnedWithoutWaiting` dropped `delay: 0.3` and both `Date()` reads, and asserts `resolver.finishedCount == 1` after the second `awaitPath()` returns, releasing the gate on the line below. |
| `Sources/` | Unchanged. `git diff --stat Sources/` empty. |

`next()` carries the new call's index out of the lock, then outside it either waits on the gate (when
the index is `holdingCall`) or sleeps `delay`, and increments `finished` under the lock before
returning. `calls` is still incremented inside the first lock, so `callCount` keeps counting
**started** calls and the eight existing readings are unchanged.

**Evidence**

No watched failure belongs to this task: the plan makes the negative control T3, which reverts
`ShellPathStore.swift:57` to `return task` once both cases are rewritten and records both failures
together. T1's own evidence is the wall time and the surviving grep matches below.

Per-case durations from the `.xcresult`
(`Test-ClearwayTests-2026.09.20_18-54-32--0300.xcresult`), read with
`xcrun xcresulttool get test-results tests`:

```
testADegradedValueIsReturnedWithoutWaiting()      0.0016s   (was 0.3s — the delay is gone)
testAFailedResolutionIsNotAwaitedASecondTime()    0.3s      (T2's, still delayed)
testAnEagerResolutionIsJoinedRatherThanDuplicated() 0.21s   (keeps delay: 0.2, per decision 7)
testTwoConcurrentCallsStartOneResolution()        0.21s     (keeps delay: 0.2, per decision 7)
ShellPathStoreTests, whole suite                  0.744s
```

`grep -n "Date()\|delay:" Tests/ShellPathStoreTests.swift` — exactly the matches the plan predicts,
with nothing left in the degraded case:

```
94:        let resolver = FakeResolver(outcomes: [.failed, .failed], delay: 0.3)
99:        let started = Date()
103:        XCTAssertLessThan(Date().timeIntervalSince(started), 0.2, "a retry must run behind the caller")
107:        let resolver = FakeResolver(outcomes: [.full("/opt/homebrew/bin")], delay: 0.2)
173:        let resolver = FakeResolver(outcomes: [.full("/opt/homebrew/bin")], delay: 0.2)
191:        let deadline = Date().addingTimeInterval(timeout)
192:        while Date() < deadline {
212:    private let delay: TimeInterval
218:    init(outcomes: [ShellPathResolver.Outcome], delay: TimeInterval = 0, holdingCall: Int? = nil) {
```

Lines 94, 99 and 103 are `testAFailedResolutionIsNotAwaitedASecondTime`, which T2 removes; 107 and
173 are the two cases that keep `delay:`; 191–192 are `waitUntil`'s deadline loop.

**Deviations**

None.

**Gate**

`./scripts/ci.sh` — green. `Executed 676 tests, with 0 failures (0 unexpected) in 111.737
(111.946) seconds`, `Test Succeeded`, `==> CI passed.` `swiftlint lint --quiet
Tests/ShellPathStoreTests.swift` exits 0 with no output. `git status --porcelain` shows only
`Tests/ShellPathStoreTests.swift` plus this change's spec and plan.
