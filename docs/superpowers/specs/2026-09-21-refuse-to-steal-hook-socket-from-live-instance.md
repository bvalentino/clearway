# Refuse to steal the hook socket from a live Clearway instance

**Date:** 2026-09-21
**Base:** 6afcc8d5a07022b79dc988c4716ae516460481ad

`HookSocketListener` unlinks `~/.clearway/hook.sock` before `bind`, unconditionally
(`AgentActivityMonitor.swift:160`). That is right for the inode a crashed or quit instance left
behind, and wrong when another Clearway is still listening on it: the unlink replaces the path's
inode, the older instance keeps reading a socket nothing can reach any more, and every hook event
stops arriving there with no dot change and no diagnostic. A developer machine hits this daily,
because `build.sh` produces `Clearway (<worktree>).app` beside `ci.sh`'s `Clearway.app`. After this
change the listener connects to the path first: a connect that succeeds means a live owner, so the
unlink and the bind are both skipped, the fact is logged, and the monitor publishes a state saying
so. Only a path nothing answers on is replaced. The newer instance never takes the socket; it runs
without hook events until the older one quits.

## Decisions

| # | Question | Decision | Source |
| --- | --- | --- | --- |
| 1 | What happens when a live listener already owns the socket? | Log it, skip the unlink and the bind, and publish a state on `AgentActivityMonitor` that a later companion task renders in Settings. The Settings UI is not touched here. | Operator |
| 2 | Does the newer instance ever take over? | No. The older instance's surfaces are the ones carrying `CLEARWAY_HOOK_SOCKET`, `CLEARWAY_SURFACE_ID` and `CLEARWAY_WORKTREE_ID` that match its socket, so its events are the ones that mean anything. The newer instance runs without hook events until the older one quits. | Operator |
| 3 | How is liveness decided? | One `connect(2)` on a fresh `AF_UNIX`/`SOCK_STREAM` descriptor to the same path, before the unlink. Success means a live listener; anything else means the path is free to replace. Verified in the scratchpad (Assumption 1): live listener → 0, stale inode → `ECONNREFUSED`, regular file → `ENOTSOCK`, directory → `ENOTSOCK`, absent → `ENOENT`, all under 0.1 ms. No timeout handling is needed: a local `AF_UNIX` connect either completes or fails in the kernel without blocking on a peer. | Spec (verified) |
| 4 | What defends the path — a successful connect, or a recognised errno? | Only a successful connect. The rule is stated positively so an errno nobody predicted falls through to "replace it", which is the behaviour Clearway has today and which keeps a crashed instance from disabling the feature permanently. `ENOTSOCK` in particular is what the two non-socket cases return, and both must still be unlinked. | Spec |
| 5 | Where does the probe live? | In `HookSocketListener`, as another `nonisolated static` step of `listeningDescriptor(at:)`, immediately before the `unlink`. The whole socket path stays outside any actor per CLAUDE.md, and keeping the probe adjacent to the unlink it guards is what makes the invariant local — a probe done in the monitor would leave an unconditional unlink two files away from its only guard. | Spec |
| 6 | What does `start` return now? | A three-case `HookSocketOutcome`: `.listening(HookSocketListener)`, `.ownedByAnotherInstance`, `.unavailable`. It replaces the optional return, which could not distinguish the two failures. | Spec |
| 7 | What state does the monitor publish? | `@Published private(set) var socketState: AgentHookSocketState`, four cases: `.off`, `.listening`, `.ownedByAnotherInstance`, `.unavailable`. The operator named the first three; `.unavailable` is added because a bind that fails for any other reason (a directory standing where the socket goes — the case `AgentActivityMonitorTests.swift:147` already pins) has no honest spelling among them, and reporting it as `.off` or as another instance's fault would be a lie the companion task then renders. It costs one case and no logic: `start` already knows. | Operator + Spec |
| 8 | Does `stop()` still unlink? | Only when this instance is the one that bound. `stop()` unlinks unconditionally today (`AgentActivityMonitor.swift:82`), which is the same theft by a second door: a blocked instance whose toggle is switched off would delete the live instance's socket. The unlink is gated on `socketState == .listening`. | Spec |
| 9 | What does the probe look like to the live instance? | One connection that closes with nothing written, which its accept loop reads as a zero-byte payload and logs as "did not parse" (`AgentActivityMonitor.swift:70-72`). An empty payload is a hang-up, never a hook event, so the parse guard gains `!payload.isEmpty` and returns silently. Without it every launch of a second Clearway writes a false malformed-event warning into the first one's log. | Spec |
| 10 | Does a blocked instance retry? | No. Nothing in this component has a clock (`AgentActivityMonitor.swift:10`) and a timer polling a socket path would be the first. The retry is the toggle: `setEnabled(false)` then `setEnabled(true)` re-runs `start()`, and a relaunch does the same. The affordance that offers it belongs to the companion task that renders `socketState` in Settings. | Spec |
| 11 | Does a blocked instance still install the hooks? | Yes — `start()` is unchanged in that order. The live instance installed the identical block, and the install is a content reconciliation that writes only on a difference (Decision 10 of the 2026-09-20 spec), so the second instance's install is a no-op rather than a fight. | Spec |
| 12 | Is the saturated-backlog false negative accepted? | Yes. A live listener whose backlog is full refuses a connect (`ECONNREFUSED`, Assumption 1 probe F), so an instance busy enough to have 64 unaccepted connections could be read as stale and replaced. The accept loop drains to `EAGAIN` on every event and hook connections are one per lifecycle event, so reaching 64 pending requires the queue to be parked; it is recorded as a known limit, not mitigated with a retry. | Spec |
| 13 | What pins the rule in tests? | Two cases in `AgentActivityMonitorTests`, both under a temp home. Live: start a listener at the path, `stat` the socket's inode, start a second listener at the same path, assert the outcome is `.ownedByAnotherInstance`, assert the inode is unchanged (no unlink), and assert an event fired at that path still reaches the first listener (no bind, and the first is still reachable). Stale: `bind`+`listen` a raw socket and close the descriptor without unlinking, then assert the listener binds and receives. The inode assertion is what makes "no unlink" observable; a file-exists check would pass against a steal. | Spec |
| 14 | Is the Settings toggle or any view changed? | No. `socketState` has no reader in this change. | Operator |

## Assumptions

Verified against the codebase at base `6afcc8d` and by one probe script written **in the
scratchpad** (`/private/tmp/claude-501/…/78825cbe-…/scratchpad/probe.py`); nothing was written into
the repo.

1. **`connect(2)` separates a live listener from every other state of the path.** Probe,
   2026-09-21, macOS 25.6.0, `AF_UNIX`/`SOCK_STREAM`: a listening socket with backlog 64 →
   `connect` returns 0 in under 0.1 ms; a path whose listener bound, listened and closed without
   unlinking → `ECONNREFUSED` (61); a regular file → `ENOTSOCK` (38); a directory → `ENOTSOCK`;
   an absent path → `ENOENT` (2); a live listener with `listen(1)` and its backlog saturated →
   `ECONNREFUSED`.
2. **The unconditional unlink is the whole of the bug.** Same probe: `bind` to a path a live
   listener owns, without unlinking first, fails `EADDRINUSE` (48). The kernel already refuses to
   take a live socket; only the unlink makes it possible.
3. **A steal is silent on both sides.** Same probe: after `unlink` + `bind` by a second socket, the
   path's `st_ino` changes (100168344 → 100168349). The first listener's descriptor stays open and
   valid, so it reports no error and simply never accepts again — which is why the symptom today is
   a dot that stops changing rather than a log line.
4. **There are exactly two unlink sites.** `AgentActivityMonitor.swift:82` in `stop()` and
   `AgentActivityMonitor.swift:160` in `listeningDescriptor(at:)`. They are the only calls to
   `unlink(2)` in `Sources/`; every other `grep -rn "unlink" Sources/` hit is prose or a view name.
5. **One monitor per process, driven by a latch that can re-run.** `ClearwayApp.swift:149` holds
   the single `AgentActivityMonitor`; `:178-180` call `setEnabled` from an `.onAppear` that fires
   once per window and from `.onChange`. `setEnabled` guards on `isEnabled`
   (`AgentActivityMonitor.swift:46`), so a second window does not re-run `start()` — which is also
   why nothing re-probes on its own (Decision 10).
6. **The existing stale-file test stays green under the new rule.**
   `AgentActivityMonitorTests.swift:50-58` writes the bytes `stale` as a regular file at the socket
   path; a connect to it returns `ENOTSOCK`, which is not a live listener, so the unlink and the
   bind still run. `:147-159` creates a directory there: also `ENOTSOCK`, so the unlink is attempted
   and fails, `bind` fails, and the outcome is `.unavailable` — the same "no listener" the test
   asserts against.
7. **Both instances resolve the same fixed path.** `AgentHookPaths.init`
   (`AgentHookScript.swift:11-16`) derives `~/.clearway/hook.sock` from `home`, whose only
   non-test caller takes `NSHomeDirectory()`. Two Clearway builds on one machine therefore contend
   for one path by construction; the socket is not per-bundle and this change does not make it so.
8. **Tests can drive the listener directly and need a short path.** `HookSocketListener.start` is
   internal and the suite already uses `@testable import Clearway`. `makeShortTempHome`
   (`Tests/TestHelpers.swift:81-85`) exists because `sun_path` is 104 bytes and
   `listeningDescriptor` refuses anything longer (`AgentActivityMonitor.swift:147-150`); the new
   cases use it the way every other case in the suite does.

## Objective and success criteria

Make the second Clearway on a machine harmless to the first, and make its own degraded state
legible to the code that will render it. Done when:

- With a Clearway already listening, launching a second one leaves the socket's inode untouched,
  logs that another instance owns it, and leaves the second monitor in `.ownedByAnotherInstance`.
  The first instance keeps receiving events throughout, and its log carries no malformed-payload
  warning caused by the probe.
- Switching the second instance's toggle off does not remove the first instance's socket, and the
  first keeps receiving events afterwards.
- A socket inode left by a killed instance is still unlinked and rebound, so a crash does not cost
  the feature until the next reboot. The regular-file and directory cases behave as they do today.
- A monitor that binds publishes `.listening`; one that cannot bind for any other reason publishes
  `.unavailable`; a monitor whose toggle is off publishes `.off`.
- No timer, no polling and no retry loop is added anywhere in the agent-activity pipeline.
- No view, no `SettingsManager` key and no `.environmentObject` wiring changes.
- `./scripts/ci.sh` is green, with the two new cases in `AgentActivityMonitorTests` and every
  existing case in that suite unchanged.

## Verification

From the project's `## Pipeline` section. One command is both the per-task regression check and the
sign-off gate:

```bash
./scripts/ci.sh
```

It regenerates the Xcode project, lints, builds and runs the test suite. Before any CI stamp or
sign-off, also run:

```bash
git status --porcelain
```

and report untracked or ignored files; a Debug launch leaves an un-gitignored `default.profraw`,
which blocks sign-off.

## Files this touches

- `Sources/App/AgentActivityMonitor.swift` — the probe and the two guarded unlinks, the
  `HookSocketOutcome` return, the `AgentHookSocketState` published property, the empty-payload
  guard.
- `Tests/AgentActivityMonitorTests.swift` — the two new cases from Decision 13.
- `Sources/App/CLAUDE.md` — lines 324-325 state the unlink as unconditional ("`bind` unlinks a
  stale path first"); they are corrected to name the connect probe and the refusal.

## Out of scope

- **Any Settings UI.** `socketState` is published and unread until the companion task lands
  (Decision 1). That task also owns whatever retry affordance the state deserves.
- **`AgentHookInstaller.uninstall` between two instances.** Switching one instance's toggle off
  removes the managed hook block from `~/.claude/settings.json` for both, because the block is
  per-machine and carries no owner. That is the same shape of collision as the socket, it predates
  this task, the brief does not mention it, and fixing it means a reference count or a per-instance
  block. Recorded as a follow-up.
- **Per-bundle socket paths.** Giving `Clearway (<worktree>).app` its own socket would end the
  contention rather than arbitrate it, but it would also mean an agent's surface can only ever
  reach the build that launched it, and it contradicts Decision 2's premise that a single fixed
  path is what lets an agent survive a relaunch.
- **The saturated-backlog window** (Decision 12).
