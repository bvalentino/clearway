# Plan: Surface agent-hook install and socket failures in Settings

Breaks down `docs/superpowers/specs/2026-09-21-surface-agent-hook-install-and-socket-failures-in-settings.md`.

**Date:** 2026-09-21
**Base:** 6afcc8d (`Move per-file CLAUDE.md notes into Sources/App and Sources/Ghostty (#248)`)

## Architecture decisions carried from the spec

- One `@Published private(set) var health: AgentHookHealth` on `AgentActivityMonitor`, set in
  `start()` from the enable attempt and reset to `.off` in `stop()`. It is the last enable
  attempt's outcome and nothing else — no watcher, no re-check (decisions 2, and Out of scope).
- Every rule is pure and lives in a new `Sources/App/AgentHookHealth.swift`, `import Foundation`
  only: the per-file outcome, the install report, the socket outcome, the health cases, the
  resolve, and each case's message. Neither the monitor nor the installer decides anything
  (decision 3).
- Precedence, most fatal first, exactly one case displayed: socket owned by another Clearway →
  socket could not be opened → forwarder script not written → no agent directory at all → a
  settings file refused, naming it → otherwise `listening`. The socket outranks the install
  because it is the single channel (decision 4).
- A single absent agent directory is **not** a failure. Absence is reported only when *every*
  agent directory is absent (decision 5).
- Nothing is displayed when healthy. No "Listening" confirmation; the existing Codex `/hooks`
  subtitle is untouched (decision 6).
- The failure line is its own row directly under the toggle in the Appearance section, present
  only when the health has a message: `Label(message, systemImage: "exclamationmark.triangle")`
  at `.callout`. Not a third `Text` inside the `Toggle` label (decision 7).
- `SettingsView` takes the monitor as an `@ObservedObject` init parameter, passed from the
  `Settings` scene. Never `.environmentObject` — the monitor is injected on the project
  `WindowGroup` alone and the `Settings` scene is outside it (decision 8).
- A failed start still stores `true`. No production code changes for this; a test pins it
  (decision 9).
- No retry affordance. Toggling off and on is the retry (decision 10).
- **The listener probes for a live owner before unlinking** (decision 11, operator-confirmed).
  `connect` to the path first: connected → a live owner, so neither unlink nor bind, report
  "owned by another instance"; `ECONNREFUSED` → a stale inode, so unlink and bind exactly as
  today; anything else (`ENOTSOCK`, a directory, a regular file) falls through to the same
  unlink-then-bind, which fails honestly as "could not be opened".
- **`stop()` unlinks the socket path only when this process bound it** (decision 12,
  operator-confirmed). The existing ordering — unlink after the listener is released, on the main
  actor both times — is unchanged.
- `install(home:)` returns a report; `uninstall(home:)` stays `Void`. Every existing log line
  stays exactly as it is: the report names the file, the log carries the underlying error
  (decision 13).
- The five messages, verbatim, one sentence each, no second line (decision 14):
  - `Another Clearway instance is using the hook socket.`
  - `The hook socket at ~/.clearway/hook.sock could not be opened.`
  - `The hook script could not be written to ~/.clearway/hooks.`
  - `No ~/.claude or ~/.codex directory was found, so no hooks were installed.`
  - `~/.claude/settings.json could not be updated.` — the path as the refused outcome carries it.
- An empty hook payload is dropped **silently**; the "did not parse" warning stays for every
  non-empty one. The live-owner probe is now a routine source of zero-byte connections
  (decision 15).
- Out of scope, and not to be added by any task: sidebar/tab-strip/menu-bar indication, a
  per-agent breakdown, a Retry or Reveal button, repairing or quarantining any file, health for
  anything after the enable attempt, and any change to what the toggle stores or its default.

**Implementation notes the spec implies but does not spell out**

- **The refused outcome carries a home-relative display path**, built by the installer from the
  agent directory name and the file name (`~/.claude/settings.json`, `~/.codex/hooks.json`), not
  from the absolute path it wrote to. `NSString.abbreviatingWithTildeInPath` reads the real
  `NSHomeDirectory()`, so under the tests' temp root it would abbreviate nothing and the pinned
  message would differ between CI and a developer machine. The absolute path keeps going to the
  log lines, which are unchanged.
- **`AgentHookInstaller.mergeAgentSettings(installing:home:)` is called directly by
  `AgentHookInstallerTests`** (two sites). Once it returns outcomes, those two calls need `_ =`
  or Swift warns on the unused result; new code must not introduce a warning.

## Dependency graph

```
T1 (AgentHookHealth.swift + AgentHookHealthTests.swift)
 │
 ├──> T2 (installer returns the report)  ──┐
 │                                         │
 └──> T3 (listener: live-owner probe, socket outcome, silent empty payload)
                                           │
                                           ├──> T4 (monitor publishes health; gated unlink)
                                           │          │
                                           │          └──> T5 (SettingsView row + ClearwayApp wiring)
                                           │                     │
                                           └─────────────────────┴──> T6 (Sources/App/CLAUDE.md notes)
```

T2 and T3 are independent of each other and can run in either order or in parallel once T1 has
landed. T4 needs both, because `start()` resolves the health from the install report and the socket
outcome together. T5 needs the published value. T6 documents what T2–T5 built and runs last.

### T1: The pure health model, the resolve and the messages

**Files**

- `Sources/App/AgentHookHealth.swift` (new)
- `Tests/AgentHookHealthTests.swift` (new)

**What it does**

Adds the whole vocabulary this change turns on, `import Foundation` only, no I/O, no actor
isolation. Nothing else references it yet — T2–T5 wire it in.

```swift
enum AgentHookFileOutcome: Equatable, Sendable {
    case absent                    // the agent's config directory is not there
    case installed                 // the managed block is in place
    case refused(path: String)     // unreadable, not a JSON object, not re-serialisable,
                                   // not backed up, or not written; `path` is home-relative
}

struct AgentHookInstallReport: Equatable, Sendable {
    let scriptWritten: Bool
    let files: [AgentHookFileOutcome]
}

enum AgentHookSocketOutcome: Equatable, Sendable {
    case listening
    case ownedByAnotherInstance
    case unopenable
}

enum AgentHookHealth: Equatable, Sendable {
    case off
    case listening
    case socketOwnedByAnotherInstance
    case socketUnopenable
    case scriptNotWritten
    case noAgentDirectory
    case settingsRefused(path: String)

    static func resolve(install: AgentHookInstallReport, socket: AgentHookSocketOutcome) -> AgentHookHealth
    var message: String?
}
```

`resolve` applies the precedence in the decisions above, in that order: the socket cases first,
then `scriptWritten == false`, then `files` being non-empty and every element `.absent`, then the
**first** `.refused` in `files` (so `.claude` outranks `.codex`, matching the order the installer
walks them), else `.listening`.

`message` answers `nil` for `.off` and `.listening` and the spec's sentence for every other case.
`.settingsRefused` interpolates its stored path: `"\(path) could not be updated."`.

**Acceptance criteria**

- Every type above exists in the one new file, which imports `Foundation` and nothing else.
- `resolve` returns the more fatal case for every pairing: a socket failure beats any install
  failure; `scriptNotWritten` beats `noAgentDirectory` and `settingsRefused`; `noAgentDirectory`
  beats nothing else but is only reached when *every* file is `.absent`; one `.absent` beside one
  `.refused` resolves to `.settingsRefused`; one `.absent` beside one `.installed` resolves to
  `.listening`.
- `message` is `nil` for exactly `.off` and `.listening`, and matches the five spec strings
  character for character otherwise.
- No file outside this pair is touched.

**Verification**

- `Tests/AgentHookHealthTests.swift` covers every case of `message` and every branch of `resolve`,
  including the precedence pairings named above. It touches no socket and no disk and needs no
  `@MainActor`.
- `./scripts/ci.sh` green (it runs `xcodegen generate`, without which the two new files are
  invisible to the build).
- `swiftlint lint --quiet` reports zero errors and introduces no new warning.

### T2: The installer reports what it did

**Files**

- `Sources/App/AgentHookInstaller.swift`
- `Tests/AgentHookInstallerTests.swift`

**What it does**

Turns the installer's silent returns into a value, without changing a single thing it does to disk
and without removing or rewording any existing `Ghostty.logger` line.

- `installScript(_:)` returns `Bool` — `true` when the forwarder is on disk and executable at the
  end of the call (including the branch where the body already matched and nothing was written),
  `false` from the `catch`.
- `merge(installing:directory:name:)` returns `AgentHookFileOutcome`, taking the home-relative
  display path as a parameter (or building it from the directory's last component and `name`):
  - the directory guard → `.absent`
  - unreadable file, not a JSON object, not re-serialisable, backup refused, write threw →
    `.refused(path:)`
  - the `after == before` no-op and a successful write → `.installed`
- `mergeAgentSettings(installing:home:)` returns `[AgentHookFileOutcome]` in `agentFiles` order.
- `install(home:)` returns `AgentHookInstallReport(scriptWritten:files:)`.
- `uninstall(home:)` stays `Void` and discards the outcomes.
- The two direct `mergeAgentSettings` call sites in `AgentHookInstallerTests` (around lines 181 and
  185) discard the result explicitly so the build stays warning-free.

**Acceptance criteria**

- `install(home:)` returns a report whose `files` has one element per entry in `agentFiles`, in
  that order.
- A home with `.claude` present and `.codex` absent reports `[.installed, .absent]`.
- A home with neither directory reports `[.absent, .absent]` and `scriptWritten == true`.
- A `.claude/settings.json` holding `[1, 2, 3]` reports `.refused(path: "~/.claude/settings.json")`
  and the file is still byte-identical afterwards.
- Every existing test in `AgentHookInstallerTests` passes unchanged in its assertions: no disk
  behaviour, no log line and no message text moved.
- `AgentActivityMonitor.start()` still compiles — discard the report there for now if T4 has not
  landed; T4 owns consuming it.

**Verification**

- New tests in `Tests/AgentHookInstallerTests.swift` for the three report shapes above, all driven
  against the existing `TempRootTestCase` root; none reaches the real home.
- `./scripts/ci.sh` green.
- `swiftlint lint --quiet` reports zero errors and no new warning.

### T3: The listener leaves a live owner alone and says which socket failure occurred

**Files**

- `Sources/App/AgentActivityMonitor.swift`
- `Tests/AgentActivityMonitorTests.swift`

**What it does**

Fixes the steal, and turns the listener's `nil` into a reason.

- `HookSocketListener.start(socketPath:onPayload:)` returns both the listener and the outcome —
  e.g. `-> (listener: HookSocketListener?, outcome: AgentHookSocketOutcome)`, or a `Result`. Either
  shape is fine as long as `start()` in the monitor can hold the listener and read the outcome.
  It stays `nonisolated static`.
- `listeningDescriptor(at:)` gains the probe, **before** the `unlink`:
  1. Open a throwaway `AF_UNIX`/`SOCK_STREAM` socket and `connect` it to `socketPath`, closing it
     immediately whatever happens.
  2. `connect` succeeded → a live owner. Return the `ownedByAnotherInstance` outcome **without**
     unlinking and **without** binding. Log one line naming the path.
  3. `connect` failed → fall through to the existing `unlink`-then-`bind`-then-`listen`-then-
     `O_NONBLOCK` sequence, unchanged, including its existing error log. A failure there is
     `unopenable`.
  The existing address-too-long and `socket()` failures are `unopenable` too.
- Everything here stays outside any actor. **Never** write a `setEventHandler` /
  `setCancelHandler` literal from an isolated method (CLAUDE.md, Concurrency).
- The monitor's `onPayload` closure drops an empty payload with no log line; a non-empty payload
  that does not parse keeps the existing warning. Update the comment above the guard to say why
  empty is now routine (the probe).
- The monitor keeps a record of whether it actually listened, for T4's gated `unlink`.

**Acceptance criteria**

- With a live listener already bound at the path, a second `start` does not unlink it, does not
  bind, and returns the `ownedByAnotherInstance` outcome; the first listener keeps receiving.
- With a stale socket inode at the path (no owner), `start` unlinks and binds as before.
- With a regular file or a directory at the path, `start` reaches the same unlink-then-bind and
  reports `unopenable` or binds successfully, exactly as it does today — the two existing tests
  `testAStaleSocketFileDoesNotStopTheListenerBinding` and
  `testASecondEnableDoesNotReachTheInstallerAfterABindThatFailed` keep their current outcomes with
  no edit to their assertions.
- A zero-byte payload produces no log line; a non-empty unparseable one still does.
- Every existing test in `AgentActivityMonitorTests` passes unchanged.

**Verification**

- A new test builds a second `AgentActivityMonitor` over the same temp home, enables both, and
  asserts the first monitor still receives a fired event after the second enabled. Disable both in
  the test (or in `tearDown`) so neither outlives it.
- `./scripts/ci.sh` green, with the suite **finishing** — a listener left bound is the failure mode
  here, so confirm the run completes rather than only that it reported no failure.
- `swiftlint lint --quiet` reports zero errors and no new warning.

### T4: The monitor publishes its health and stops unlinking what it did not bind

**Files**

- `Sources/App/AgentActivityMonitor.swift`
- `Tests/AgentActivityMonitorTests.swift`

**What it does**

- Adds `@Published private(set) var health: AgentHookHealth = .off` to `AgentActivityMonitor`.
- `start()` keeps the install report from `AgentHookInstaller.install(home:)` and the socket
  outcome from `HookSocketListener.start`, assigns the listener as it does today, and sets
  `health = AgentHookHealth.resolve(install:socket:)`. No branching on the outcome beyond that —
  the precedence lives in `resolve`.
- `stop()` sets `health = .off` and runs `unlink(paths.socketPath)` **only if this process bound
  the socket** — i.e. only if the last `start()` produced the `listening` outcome. The ordering is
  unchanged: release the listener first, unlink after, on the main actor both times. Reset whatever
  flag records that so a second `stop()` cannot unlink either.
- Nothing else changes: `setEnabled` still latches on `isEnabled`, still calls `start()`/`stop()`
  on the transition, and still ignores what `start()` achieved.

**Acceptance criteria**

- A healthy enable leaves `health == .listening` and the Appearance section has nothing to show.
- An enable with a directory standing where the socket goes leaves `health == .socketUnopenable`,
  and `settings.agentHooksEnabled` / `isEnabled` are unaffected.
- A second monitor enabled while a first is listening leaves the second's
  `health == .socketOwnedByAnotherInstance`.
- A `~/.claude/settings.json` holding `[1, 2, 3]`, with the socket free, leaves
  `health == .settingsRefused(path: "~/.claude/settings.json")`.
- A home with neither `.claude` nor `.codex`, socket free, leaves `health == .noAgentDirectory`.
- `stop()` on a monitor whose `start()` never bound leaves the path exactly as it was — in
  particular the live owner's socket survives the second instance's whole enable/disable cycle.
- `stop()` on a monitor that did bind still removes the socket, so
  `testDisablingClosesTheSocketAndForgetsEverySurface` passes unchanged.
- `health` returns to `.off` on every disable.

**Verification**

- New tests in `Tests/AgentActivityMonitorTests.swift` for each bullet above, all under the temp
  home the suite already builds.
- One test pins decision 9: enabling with a bind that cannot succeed still leaves the monitor's
  enabled latch on, so the next `setEnabled(true)` is a no-op and the next launch retries.
- One test pins the live-owner case end to end: first monitor enabled, second monitor enabled then
  disabled, and an event fired afterwards still reaches the first.
- `./scripts/ci.sh` green, with the suite finishing.
- `swiftlint lint --quiet` reports zero errors and no new warning.

### T5: The failure line under the toggle

**Files**

- `Sources/App/SettingsView.swift`
- `Sources/App/ClearwayApp.swift`

**What it does**

- `SettingsView` gains `@ObservedObject var agentActivity: AgentActivityMonitor` beside its
  existing `settings`.
- In the Appearance section, directly after the `Toggle(isOn: $settings.agentHooksEnabled)` row
  and inside the same `Section`, renders the failure row when and only when
  `agentActivity.health.message` is non-nil:
  `Label(message, systemImage: "exclamationmark.triangle")` with `.font(.callout)` and
  `.foregroundStyle(.red)`, matching `SidebarView.swift:300` and `DebugTerminalSheet.swift:15`.
  It is its own row in the `Form`, not a third `Text` inside the `Toggle` label.
- The Codex `/hooks` subtitle and the comment above it stay exactly as they are.
- `ClearwayApp`'s `Settings` scene passes the existing `agentActivity` `@StateObject` into
  `SettingsView(settings:agentActivity:)`. No `.environmentObject` is added to that scene, and the
  project `WindowGroup`'s injections are untouched.

**Acceptance criteria**

- With `health == .listening` or `.off`, the Appearance section renders exactly what it renders
  today — no extra row, no extra copy.
- With any other health, exactly one warning row appears under the toggle, carrying that health's
  message and the `exclamationmark.triangle` symbol.
- Toggling off and on re-runs the enable attempt and the row updates or disappears in place,
  because `health` is `@Published` and the view observes the monitor.
- The monitor reaches `SettingsView` by parameter only; nothing in the `Settings` scene reads it
  from the environment.

**Verification**

- `./scripts/ci.sh` green (`xcodegen generate` first; both changed files are already in the
  target).
- `swiftlint lint --quiet` reports zero errors and no new warning.
- `grep -n "environmentObject" Sources/App/ClearwayApp.swift` shows no injection added to the
  `Settings` scene.
- Rendering is left to the operator's by-hand check; the copy itself is pinned by T1's tests.

### T6: Record the health rule in the per-file notes

**Files**

- `Sources/App/CLAUDE.md`

**What it does**

Extends the agent-activity paragraph block (currently around lines 314–400) with what T2–T5 built,
in the same voice as its neighbours — a rule per bold lead-in, no summary of the diff:

- The monitor publishes a **third** value, `health`, and why it costs nothing to publish there
  (it changes only on a toggle transition, unlike a tool name) — the existing "publishes two
  values, not three" paragraph is now wrong and must be corrected rather than left standing.
- The precedence, one line: socket before install, one case displayed, `listening` otherwise; and
  that the whole mapping is pure, in `AgentHookHealth.swift`, `import Foundation` only.
- That a single absent agent directory is not a failure and only "every directory absent" is.
- **The listener probes for a live owner before unlinking**, replacing the existing sentence
  "`bind` unlinks a stale path first" — which is now only half true — with the three-way rule:
  connected means a live owner and Clearway neither unlinks nor binds, `ECONNREFUSED` means a
  stale inode and the unlink stands, anything else falls through to the same honest failure. Say
  why: unlinking unconditionally let a second instance steal the feed from the first while both
  reported success.
- **`stop()` unlinks only when this process bound**, or the retry in the toggle would destroy the
  live owner's socket.
- That an empty payload is dropped silently because the probe is a routine source of one, while a
  non-empty unparseable payload still logs.
- That `SettingsView` takes the monitor by parameter because the `Settings` scene is outside the
  project `WindowGroup` — the existing "One owner … injected on the project `WindowGroup` only"
  sentence stays true and this is why.

**Acceptance criteria**

- The two sentences the change falsifies — "The monitor publishes two values, not three" and
  "`bind` unlinks a stale path first" — are corrected, not merely appended to.
- No note describes a behaviour no task built.
- The file stays a list of per-file rules; nothing moves to the root `CLAUDE.md`.

**Verification**

- `./scripts/ci.sh` green (documentation only, but the gate is the stage's regression check).
- `git status --porcelain` shows only intended files.

## Risks

| Risk | Impact | Mitigation |
| --- | --- | --- |
| A `setEventHandler` / `setCancelHandler` literal written from an isolated method traps in `dispatch_assert_queue` when libdispatch runs it | High — it cost a shipped release | T3 keeps the whole socket path in `nonisolated static` factories; the probe is added inside `listeningDescriptor`, which is already one |
| A test leaves a listener bound and the next test in the suite reports "owned by another instance" | High — cross-test flake with a confusing message | Every test that enables a second monitor disables it in the test or in `tearDown`; T3 and T4 both require the suite to *finish*, not merely to report no failure |
| The refused path is abbreviated through `NSHomeDirectory()` and the message differs under a temp root | Medium — a pinned string that passes locally and fails in CI, or vice versa | T2 builds the home-relative path from the agent directory name; T1's tests pin the exact string with no filesystem at all |
| `stop()` still runs `AgentHookInstaller.uninstall` from a second instance, removing the hook entries from the settings files while the first instance is still listening | Medium | Pre-existing and out of scope here — decision 12 gates the `unlink` only. Recorded as a follow-up, not fixed in this change |
| The probe's zero-byte connection reaches the owner's accept loop and logs a warning every time a second instance starts | Low | Decision 15; T3 drops an empty payload silently and keeps the warning for truncated ones |
