# Plan: refuse to steal the hook socket from a live Clearway instance

**Date:** 2026-09-21
**Base:** 6afcc8d5a07022b79dc988c4716ae516460481ad

Breaks down `docs/superpowers/specs/2026-09-21-refuse-to-steal-hook-socket-from-live-instance.md`.
Every design decision lives there; this file only orders the work and says how each piece is
verified. The `(D<n>)` markers below point at that spec's Decisions table.

## Architecture decisions carried from the spec

1. **Liveness is one `connect(2)`** on a fresh `AF_UNIX`/`SOCK_STREAM` descriptor to the same path,
   made immediately before the existing `unlink`. No timeout, no retry: a local `AF_UNIX` connect
   completes or fails in the kernel. (D3, D5)
2. **Only a successful connect defends the path.** Every errno — `ECONNREFUSED`, `ENOTSOCK`,
   `ENOENT`, anything unforeseen — falls through to today's behaviour: unlink, then bind. (D4)
3. **The probe lives in `HookSocketListener.listeningDescriptor(at:)`**, as another
   `nonisolated static` step. The whole socket path stays outside any actor, because
   `setEventHandler`/`setCancelHandler` take `@convention(block)` closures. (D5, project CLAUDE.md)
4. **`HookSocketListener.start` returns `HookSocketOutcome`** — `.listening(HookSocketListener)`,
   `.ownedByAnotherInstance`, `.unavailable` — replacing the optional, which could not tell the two
   failures apart. (D6)
5. **The monitor publishes `@Published private(set) var socketState: AgentHookSocketState`** with
   four cases: `.off`, `.listening`, `.ownedByAnotherInstance`, `.unavailable`. Initial value
   `.off`. (D7)
6. **`stop()` unlinks only when this instance bound**, i.e. only when `socketState == .listening`.
   An unconditional unlink in `stop()` is the same theft by a second door. (D8)
7. **An empty payload is a hang-up, not a malformed event.** The probe's connection closes without
   writing, which the live instance accepts as a zero-byte payload; the parse guard gains
   `!payload.isEmpty` and returns silently, so a second launch writes no false warning into the
   first instance's log. (D9)
8. **No clock is added.** No timer, no polling, no retry. The retry is the toggle and the relaunch.
   (D10)
9. **A blocked instance still installs the hooks.** `start()` keeps its current order; the install
   is a content reconciliation that writes only on a difference. (D11)
10. **No view, no `SettingsManager` key, no `.environmentObject` wiring changes.** `socketState` has
    no reader in this change; the companion task renders it. (D1, D14)
11. **The saturated-backlog false negative is accepted**, not mitigated. (D12)

## Dependency graph

```
T1: probe, outcome, published state, empty-payload guard, both D13 tests
     │
     ├── T2: stop() unlinks only what this instance bound (+ its test)
     │
     └── T3: correct Sources/App/CLAUDE.md lines 324-325
```

T2 needs `socketState` and `HookSocketOutcome` from T1. T3 describes the rule T1 and T2 ship and
must land after both. T2 and T3 do not touch the same files and are otherwise independent.

## Task list

### T1: Refuse a socket path a live instance still answers on

**Files**

- `Sources/App/AgentActivityMonitor.swift`
- `Tests/AgentActivityMonitorTests.swift`

**What it does**

In `HookSocketListener` (same file, below the monitor):

- Add a top-level `enum HookSocketOutcome { case listening(HookSocketListener); case
  ownedByAnotherInstance; case unavailable }` and change `start(socketPath:onPayload:)` to return
  it instead of `HookSocketListener?`.
- In `listeningDescriptor(at:)`, after the `sun_path` length guard and the address is filled, and
  **before** the `unlink` at line 160, probe the path: open a second `AF_UNIX`/`SOCK_STREAM`
  descriptor, `connect` it to the same address, close it unconditionally, and treat a return of `0`
  — and only `0` — as a live owner. On a live owner, close the listening descriptor, log through
  `Ghostty.logger` that another Clearway instance owns the path (path `privacy: .public`, matching
  the two `logger.error` calls already in the function), and return the "owned" case without
  unlinking or binding.
- `listeningDescriptor` needs three outcomes rather than an optional. Use a private nested enum
  (`case open(Int32)`, `case ownedByAnotherInstance`, `case unavailable`) and let `start` map it
  onto `HookSocketOutcome`; `HookSocketOutcome` itself cannot serve, because the descriptor is not
  a listener yet.
- Keep the probe `nonisolated static`. Take the already-filled `sockaddr_un` by value and make the
  mutable copy inside the probe; do not reach for `address` through an escaping pointer.

In `AgentActivityMonitor`:

- Add `enum AgentHookSocketState { case off, listening, ownedByAnotherInstance, unavailable }` at
  file scope (no associated values, so `==` is free) and
  `@Published private(set) var socketState: AgentHookSocketState = .off`.
- In `start()`, switch on the outcome: `.listening(let listener)` stores the listener and sets
  `socketState = .listening`; the other two store nothing and set the matching state. The
  `AgentHookInstaller.install(home:)` call stays first and unconditional (D11).
- In `stop()`, set `socketState = .off`. Leave the unlink alone here — T2 owns it.
- In the `onPayload` closure, add `guard !payload.isEmpty else { return }` above the existing
  `AgentHookEnvelope.parse` guard, with one line saying an empty payload is the liveness probe's
  hang-up, never an event.

Tests (Decision 13), both under `makeShortTempHome` via the existing `setUp`:

- **Live owner.** `monitor.setEnabled(true)`; read the socket's inode
  (`FileManager.default.attributesOfItem(atPath: paths.socketPath)[.systemFileNumber]`); build a
  second `AgentActivityMonitor(home: home)` and `setEnabled(true)` on it; assert its `socketState`
  is `.ownedByAnotherInstance`; assert the inode is unchanged; then `try fire(...)` a
  `UserPromptSubmit` and `waitFor(.working, …)` on the **first** monitor's `worktreePhases`. Do not
  call `setEnabled(false)` on the second monitor in this test — that gate is T2's.
- **Stale inode.** Create `paths.clearwayDir`, then `socket`/`bind`/`listen` a raw `AF_UNIX`
  descriptor at `paths.socketPath` and `close` it **without** unlinking. Then
  `monitor.setEnabled(true)`, `fire` a `UserPromptSubmit`, and `waitFor(.working, …)`. This is the
  case that proves a crashed instance does not cost the feature.

**Acceptance criteria**

- A second monitor started against a path a live listener owns reports `.ownedByAnotherInstance`,
  leaves the inode untouched, and the first monitor keeps receiving events.
- A socket inode left behind by a closed-without-unlink descriptor is still unlinked and rebound.
- A monitor that binds publishes `.listening`; a bind that fails for any other reason publishes
  `.unavailable`; a monitor whose toggle is off publishes `.off`.
- `unlink` is still called in exactly two places in `Sources/` (the one in `stop()` and the one in
  `listeningDescriptor`); no timer, queue or retry is added.
- The existing cases in `AgentActivityMonitorTests` are unchanged and still pass — in particular
  `testAStaleSocketFileDoesNotStopTheListenerBinding` (regular file → `ENOTSOCK` → replace) and
  `testASecondEnableDoesNotReachTheInstallerAfterABindThatFailed` (directory → `ENOTSOCK` → bind
  fails → `.unavailable`, and the latch still holds).

**Verification**

- `./scripts/ci.sh` green (regenerates the project, lints, builds, runs the suite), run after the
  last edit. Report the command and its exit status.
- `grep -rn "unlink" Sources/` shows the same two call sites.

### T2: `stop()` unlinks only the socket this instance bound

**Files**

- `Sources/App/AgentActivityMonitor.swift`
- `Tests/AgentActivityMonitorTests.swift`

**What it does**

Gate `stop()`'s `unlink(paths.socketPath)` on `socketState == .listening`, read before
`socketState` is reset to `.off`. Keep the existing ordering — the unlink runs after the listener is
released and on the main actor both times, which is what
`testTheFeedSurvivesADisableAndReEnable` pins. Replace the existing comment's claim only where it
is now wrong; the disable-then-enable reason still stands.

Add one test: first monitor enabled; second `AgentActivityMonitor(home: home)` enabled and asserted
`.ownedByAnotherInstance`; record the socket's inode; `setEnabled(false)` on the **second** monitor;
assert the socket still exists with the same inode, then `fire` a `UserPromptSubmit` and
`waitFor(.working, …)` on the first monitor. `AgentHookInstaller.uninstall` leaves the forwarder
script on disk (`AgentHookInstaller.swift:24-28`), so `fire` still runs after the second monitor's
teardown.

**Acceptance criteria**

- Switching a blocked instance's toggle off leaves the live instance's socket inode in place, and
  the live instance keeps receiving events afterwards.
- A monitor that bound still unlinks its own socket on `stop()`; `testTheFeedSurvivesADisableAndReEnable`
  and `testDisablingAMonitorThatWasNeverEnabledReachesNoUninstaller` still pass.

**Verification**

- `./scripts/ci.sh` green, run after the last edit.

### T3: Correct the unconditional-unlink claim in `Sources/App/CLAUDE.md`

**Files**

- `Sources/App/CLAUDE.md`

**What it does**

Lines 324-325 currently read "`bind` unlinks a stale path first, or one crash leaves an inode that
makes every later launch fail `EADDRINUSE` and no dot ever lights again." Rewrite that sentence so
it states both halves of the shipped rule: the listener connects to the path first, a connect that
succeeds means a live owner and the unlink and bind are both skipped (the instance publishes
`.ownedByAnotherInstance` and runs without hook events until the owner quits), and only a path
nothing answers on is unlinked and rebound — which is what keeps a crash from costing the feature.
Name `stop()`'s matching gate in the same place, since the two unlinks are one invariant. Keep the
surrounding prose and the file's voice; change nothing else in the file.

**Acceptance criteria**

- No sentence in `Sources/App/CLAUDE.md` describes the unlink as unconditional.
- The note names the connect probe, the refusal, and the `stop()` gate.
- The diff touches only those lines.

**Verification**

- `git diff --stat` shows `Sources/App/CLAUDE.md` alone.
- `./scripts/ci.sh` green (documentation-only, but the stamp is per task).

## Risks

| Risk | Impact | Mitigation |
| --- | --- | --- |
| The probe connection is logged as a malformed event by the live instance | Medium — a false warning on every second launch | The `!payload.isEmpty` guard is part of T1, not a follow-up (D9) |
| `listeningDescriptor` growing a second enum reads as indirection | Low | It is three states a caller must distinguish, not an abstraction; `start` collapses it immediately |
| A live listener with a saturated backlog is read as stale | Low, accepted | Recorded as a known limit (D12); no retry |

## Out of scope

Settings UI for `socketState`, `AgentHookInstaller.uninstall`'s cross-instance collision, per-bundle
socket paths, and the saturated-backlog window — all per the spec's "Out of scope".
