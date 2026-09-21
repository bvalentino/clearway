# Plan: Surface agent-hook install and socket failures in Settings

Breaks down `docs/superpowers/specs/2026-09-21-surface-agent-hook-install-and-socket-failures-in-settings.md`.

**Date:** 2026-09-21
**Base:** 15793b2 (`Refuse to steal the hook socket from a live Clearway instance (#252)`).
Planned against 6afcc8d; rebased — see the last Changelog entry.

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
| `stop()` still runs `AgentHookInstaller.uninstall` from a second instance, removing the hook entries from the settings files while the first instance is still listening | Medium | **No longer out of scope.** The review proved it and the operator moved it onto this branch: decision 16 gates the uninstall on holding a listener, exactly as decision 12 gates the `unlink`. See the changelog |
| The probe's zero-byte connection reaches the owner's accept loop and logs a warning every time a second instance starts | Low | Decision 15; T3 drops an empty payload silently and keeps the warning for truncated ones |

## Build log

### T1: The pure health model, the resolve and the messages

| File | State |
| --- | --- |
| `Sources/App/AgentHookHealth.swift` | New. `AgentHookFileOutcome`, `AgentHookInstallReport`, `AgentHookSocketOutcome`, `AgentHookHealth` with `resolve(install:socket:)` and `message`. `import Foundation` only. |
| `Tests/AgentHookHealthTests.swift` | New. 13 tests: every `message` case and every `resolve` branch, including each precedence pairing the task names. No socket, no disk, no `@MainActor`. |
| `project.yml` | Changed. `**/CLAUDE.md` excluded from the `Clearway` target's `Sources` path. Deviation — see below. |
| `Clearway.xcodeproj/project.pbxproj` | Regenerated by `xcodegen`: the two new files added, no other change. |

**Evidence**

The tests were written first and watched fail on the unimplemented model:

```
❌ Tests/AgentHookHealthTests.swift:10:90: cannot find type 'AgentHookInstallReport' in scope
❌ Tests/AgentHookHealthTests.swift:10:62: cannot find type 'AgentHookFileOutcome' in scope
❌ Tests/AgentHookHealthTests.swift:20:22: cannot find 'AgentHookHealth' in scope
```

**Deviation: the gate was already red at base**

The first `./scripts/ci.sh` run never reached Swift compilation:

```
❌ error: Multiple commands produce '…/Clearway.app/Contents/Resources/CLAUDE.md'
⚠️ duplicate output file … on task: CpResource … Sources/Ghostty/CLAUDE.md (in target 'Clearway')
```

`6afcc8d` (#248) put a `CLAUDE.md` in both `Sources/App` and `Sources/Ghostty`; `xcodegen` treats
each as a bundle resource and both flatten to `Contents/Resources/CLAUDE.md`. The committed
`project.pbxproj` predates that move, so the breakage only appears once `ci.sh` regenerates — which
is why `main`'s CI has been failing since that merge (run 35613723428, and the PR run before it).
No task in this plan can be verified without a build, so the minimal fix landed here: the two notes
are excluded from the target. Nothing else in the generated project changed, which is also why this
commit's `pbxproj` diff is additions only.

**Gate**

`./scripts/ci.sh` — exit 0. `Executed 792 tests, with 0 failures (0 unexpected) in 122.743 seconds`.
All 13 `AgentHookHealthTests` cases reported `Passed` in the result bundle. `swiftlint lint --quiet`
runs inside that gate and reported no error and no new warning.

### T2: The installer reports what it did

| File | State |
| --- | --- |
| `Sources/App/AgentHookInstaller.swift` | Changed. `installScript` returns `Bool`, `merge` returns `AgentHookFileOutcome` and takes the home-relative `displayPath`, `mergeAgentSettings` returns `[AgentHookFileOutcome]` in `agentFiles` order, `install(home:)` returns `AgentHookInstallReport`. `uninstall(home:)` stays `Void` and discards. No disk behaviour changed and no log line was moved, reworded or removed. |
| `Sources/App/AgentActivityMonitor.swift` | Changed, one line: `_ = AgentHookInstaller.install(home: home)`. T4 owns consuming the report. |
| `Tests/AgentHookInstallerTests.swift` | Changed. Three new tests under `// MARK: - The report`; the four existing direct call sites discard the result with `_ =`. No existing assertion touched. |

The display path is built in `mergeAgentSettings` from the agent's own directory name
(`"~/\(agent.directory)/\(agent.name)"`), not abbreviated from the absolute path:
`abbreviatingWithTildeInPath` reads the real `NSHomeDirectory()`, so under the suite's temp root it
would abbreviate nothing and the pinned message would differ between CI and a developer machine. The
absolute path still goes to every log line, unchanged.

`mergeAgentSettings` was **not** marked `@discardableResult`. The two test call sites and
`uninstall` say `_ =` instead, so a future caller that drops an install report has to say so.

**Evidence**

The three new tests were written first and watched fail against the unchanged installer. The
pre-change `Sources/App/AgentHookInstaller.swift` and `Sources/App/AgentActivityMonitor.swift` were
restored from `HEAD` over a scratchpad copy of the new ones (never `git stash` or `git checkout`),
`xcodebuild … build-for-testing` was run, and the copies restored afterwards:

```
Tests/AgentHookInstallerTests.swift:185:30: error: value of tuple type '()' has no member 'scriptWritten'
Tests/AgentHookInstallerTests.swift:186:31: error: value of tuple type '()' has no member 'files'
Tests/AgentHookInstallerTests.swift:194:30: error: value of tuple type '()' has no member 'scriptWritten'
Tests/AgentHookInstallerTests.swift:195:31: error: value of tuple type '()' has no member 'files'
Tests/AgentHookInstallerTests.swift:205:31: error: value of tuple type '()' has no member 'files'
Tests/AgentHookInstallerTests.swift:205:45: error: type 'Equatable' has no member 'refused'
```

**Deviations from the plan**

None.

**Gate**

`./scripts/ci.sh` — exit 0, `==> CI passed.`
`Executed 795 tests, with 0 failures (0 unexpected) in 122.656 seconds` (792 at T1, plus the three
new ones). `swiftlint lint --quiet` — exit 0, no output. `git status --porcelain` shows the three
changed files and nothing else.

### T3: The listener leaves a live owner alone and says which socket failure occurred

| File | State |
| --- | --- |
| `Sources/App/AgentActivityMonitor.swift` | Changed. `HookSocketListener.start` returns `(listener:outcome:)`; a new `nonisolated static hasLiveOwner(at:)` probes with `connect` before anything else and short-circuits to `.ownedByAnotherInstance` without unlinking or binding; `listeningDescriptor` is otherwise untouched apart from taking its address from a shared `socketAddress(for:)`, and every failure below the probe is `.unopenable`. The monitor drops an empty payload silently and records `didBindSocket`. |
| `Tests/AgentActivityMonitorTests.swift` | Changed. Three new tests: the end-to-end steal, and the two socket outcomes under a new `// MARK: - The socket`. No existing test edited. |

The probe lives in its own `nonisolated static` beside `listeningDescriptor` rather than inside it:
the plan put it there, but `listeningDescriptor` answers "bind me a descriptor" and would have had
to return a two-case failure to carry the distinction. `start` calls the probe first, so it still
runs before the `unlink`, and the whole socket path stays outside any actor — no
`setEventHandler`/`setCancelHandler` literal moved or was added.

`didBindSocket` is written and reset but not yet read: T4 owns gating `stop()`'s `unlink` on it, and
`stop()` still unlinks unconditionally here.

**Evidence**

`testASecondInstanceLeavesTheLiveOwnersSocketAlone` was written first and watched fail against the
unchanged listener — the second instance unlinked the owner's socket, bound its own, and took the
feed:

```
Tests/AgentActivityMonitorTests.swift:75: error: -[ClearwayTests.AgentActivityMonitorTests testASecondInstanceLeavesTheLiveOwnersSocketAlone] : XCTAssertEqual failed: ("working") is not equal to ("idle") - the owner's phase after a second instance enabled
Tests/AgentActivityMonitorTests.swift:78: error: -[ClearwayTests.AgentActivityMonitorTests testASecondInstanceLeavesTheLiveOwnersSocketAlone] : XCTAssertTrue failed - the second instance never bound, so no event reaches it
```

The two outcome tests could not be run against the unchanged code at all: `start` returned
`HookSocketListener?`, so `.outcome` did not exist.

The silent empty-payload drop has no test. It is a `Ghostty.logger` line that is not emitted, and
nothing in the suite captures `os_log`; the probe that produces the zero-byte connection is covered
by the three tests above.

**Deviations from the plan**

The probe is its own function rather than a branch inside `listeningDescriptor` (above). Nothing
else.

**Gate**

`./scripts/ci.sh` — `==> CI passed.`, and the suite **finished**:
`Executed 798 tests, with 0 failures (0 unexpected) in 125.164 seconds` (795 at T2, plus the three
new ones), so no test left a listener bound. `swiftlint lint --quiet` — exit 0, no output.
`git status --porcelain` shows only `Sources/App/AgentActivityMonitor.swift` and
`Tests/AgentActivityMonitorTests.swift`.

### T4: The monitor publishes its health and stops unlinking what it did not bind

| File | State |
| --- | --- |
| `Sources/App/AgentActivityMonitor.swift` | Changed. `@Published private(set) var health: AgentHookHealth = .off`; `start()` keeps the install report and resolves the health from it and the socket outcome; `stop()` sets `health = .off` and gates the `unlink` on `didBindSocket`, which T3 wrote and left unread. Nothing else moved: the latch, the ordering inside `stop()` and the install call itself are unchanged. |
| `Tests/AgentActivityMonitorTests.swift` | Changed. Five new tests — one under the existing socket section for the owner's socket surviving a second instance's whole enable/disable cycle, four under a new `// MARK: - The health`. No existing test edited. |

`stop()` releases the listener, sets `.off`, unlinks only when this process bound, then clears
`didBindSocket` — so a second `stop()` cannot unlink either, and the flag is still readable when the
`unlink` decision is made.

**Evidence**

`testASecondInstancesDisableLeavesTheLiveOwnersSocketAlone` was written first and watched fail
against the unconditional `unlink`: the second instance, which never bound, took the path away on
its way out and the owner went deaf while still reading as enabled.

```
Tests/AgentActivityMonitorTests.swift:163: error: -[ClearwayTests.AgentActivityMonitorTests testASecondInstancesDisableLeavesTheLiveOwnersSocketAlone] : XCTAssertTrue failed - the owner's socket survives the second instance
Tests/AgentActivityMonitorTests.swift:165: error: -[ClearwayTests.AgentActivityMonitorTests testASecondInstancesDisableLeavesTheLiveOwnersSocketAlone] : XCTAssertEqual failed: ("idle") is not equal to ("working") - the owner's phase after a second instance came and went
```

The four health tests could not be run against the unchanged monitor at all: `health` did not exist.

The temp home the suite builds has neither agent directory, so the healthy-enable test creates
`~/.claude` first — without it a clean enable resolves to `.noAgentDirectory`, which is what
`testAHomeWithNeitherAgentIsReportedAsHavingNoDirectory` pins from the other side.

**Deviations from the plan**

Decision 9 is pinned inside `testAFailedEnableStaysEnabledAndKeepsReportingItsFailure` rather than
in a test of its own: the pre-existing `testASecondEnableDoesNotReachTheInstallerAfterABindThatFailed`
already pins the latch from the installer's side, and the live-owner end-to-end case is the same
test as the gated-unlink one, which also asserts the second instance's
`health == .socketOwnedByAnotherInstance` and its return to `.off`. Nothing else.

**Gate**

`./scripts/ci.sh` — `==> CI passed.`, and the suite **finished**:
`Executed 803 tests, with 0 failures (0 unexpected) in 127.969 seconds` (798 at T3, plus the five
new ones), so no test left a listener bound. `swiftlint lint --quiet` — exit 0, no output.
`git status --porcelain` shows only `Sources/App/AgentActivityMonitor.swift` and
`Tests/AgentActivityMonitorTests.swift`.

### T5: The failure line under the toggle

| File | State |
| --- | --- |
| `Sources/App/SettingsView.swift` | Changed. Gains `@ObservedObject var agentActivity: AgentActivityMonitor`; the Appearance section renders `Label(message, systemImage: "exclamationmark.triangle")` at `.font(.callout)` / `.foregroundStyle(.red)` as its own row after the agent-hooks toggle, only when `agentActivity.health.message` is non-nil. The Codex `/hooks` subtitle and its comment are untouched. |
| `Sources/App/ClearwayApp.swift` | Changed. One line: the `Settings` scene now builds `SettingsView(settings:agentActivity:)` from the existing `@StateObject`. |

**Evidence**

No test was written: the task's own verification assigns the copy to T1's tests (which pin all five
strings character for character) and the rendering to the operator's by-hand check. There is no
behavioural claim here to watch fail — the row is a `nil` check over a value T4 already publishes
and T4's tests already pin for every case.

**Deviations from the plan**

None. `SettingsView` had exactly one construction site in the app and none in the tests, so the new
parameter needed no other call updated.

**Gate**

`./scripts/ci.sh` — `==> CI passed.`, `Executed 803 tests, with 0 failures (0 unexpected)`.
`swiftlint lint --quiet` — exit 0, no output.
`grep -n "environmentObject" Sources/App/ClearwayApp.swift` — seven hits, all pre-existing: six on
the project `WindowGroup` and one in `clearwayChrome`. None in the `Settings` scene.
`git status --porcelain` shows only `Sources/App/ClearwayApp.swift` and
`Sources/App/SettingsView.swift`.

### T6: Record the health rule in the per-file notes

| File | State |
| --- | --- |
| `Sources/App/CLAUDE.md` | Edited. Four edits inside the agent-activity paragraph block: the file list gains `AgentHookHealth.swift` ("the first six are `import Foundation` only"); the transport paragraph's "`bind` unlinks a stale path first" sentence is replaced by the three-way live-owner probe plus the gated `stop()` unlink and the silent empty payload; "publishes two values, not three" becomes "three values, not four" with `health` named and a new paragraph for the resolve precedence and the one-absent-directory rule; the "One owner" paragraph gains why `SettingsView` takes the monitor by parameter and that the failure line is its own row. |

**Evidence**

Documentation only — no behavioural claim, so no test to watch fail. Every sentence written was
checked against the landed code rather than the plan: the probe and its `connect`-succeeded /
`ECONNREFUSED` / anything-else branches against `AgentActivityMonitor.listeningDescriptor(at:)` and
`liveOwner`, `didBindSocket` against `start()`/`stop()`, the empty-payload drop against the
`onPayload` guard, the precedence order against `AgentHookHealth.resolve`, and the parameter
injection against `SettingsView`'s `@ObservedObject var agentActivity` and `ClearwayApp`'s
`Settings` scene.

**Deviations from the plan**

Two placements differ from the plan's bullet order, both to keep each rule beside the sentence it
qualifies rather than collecting them at the end: the probe, the gated unlink and the empty payload
went into the transport paragraph (which held the falsified `bind` sentence), and the
`SettingsView`-by-parameter rule went into the "One owner" paragraph (which states the injection it
follows from). The plan named no line numbers, so nothing was overridden.

**Gate**

`./scripts/ci.sh` — `==> CI passed.`, `Executed 803 tests, with 0 failures (0 unexpected)`.
`git status --porcelain` — only `Sources/App/CLAUDE.md` before this log was appended; no untracked
or ignored files.

### Simplify

`didBindSocket` and its gated `unlink` in `stop()` were retired: `HookSocketListener` is built only
on the `.listening` outcome, so holding one *is* "this process bound the path", and its own `deinit`
now unlinks beside `source.cancel()` — the RAII shape the root `CLAUDE.md` already prescribes, and
not the cancel handler, which runs on the source's queue. The empty-payload drop moved from the
monitor's parse closure into `acceptPending`, where the probe that produces it lives; the
`sockaddr_un` rebind is one `withSocketAddress` helper instead of a copy each for `connect` and
`bind`; `resolve` uses `for case .refused`; `testAFailedEnableStaysEnabledAndKeepsReportingItsFailure`
was a verbatim copy of `testASecondEnableDoesNotReachTheInstallerAfterABindThatFailed`, so its two
health assertions moved into that test and the copy went; one health test was renamed to say what it
asserts; and `project.yml` excludes `**/*.md` rather than that one filename.

`./scripts/ci.sh` — exit 0, `==> CI passed.`,
`Executed 802 tests, with 0 failures (0 unexpected) in 130.171 seconds` (803 at T6, minus the merged
duplicate). `git status --porcelain` shows six changed files and nothing untracked or ignored.

## Changelog

### Review fix: gate the uninstall on having owned the socket

The review proved the risk row the plan had recorded as out of scope. The operator moved it onto
this branch.

| File | State |
| --- | --- |
| `Sources/App/AgentActivityMonitor.swift` | Changed. `stop()` captures whether a listener was held and runs `AgentHookInstaller.uninstall` only then — the same gate the unlink already had, since `HookSocketListener.start` builds one only on the `.listening` outcome. |
| `Tests/AgentActivityMonitorTests.swift` | Changed. New `testASecondInstancesDisableLeavesTheLiveOwnersHooksInstalled`. `testAStartOverALiveOwnerReportsItAndLeavesTheSocketWhereItIs` moves its socket-file assertion inside the `withExtendedLifetime(owner.listener)` block, where the owner is provably still alive (review nit). |
| `docs/superpowers/specs/…-settings.md` | Changed. Decision 16 records the gate; success criterion 7 now covers the hook block as well as the socket. |
| `Sources/App/CLAUDE.md` | Changed. The gate covers the uninstall, not only the unlink. |

**Evidence**

The new test was watched fail on the unfixed `stop()`:

```
[ghostty] Another instance is already listening at /tmp/clearway-hook-monitor-7C543EFC/.clearway/hook.sock.
[ghostty] Removed the Clearway hooks in /tmp/clearway-hook-monitor-7C543EFC/.claude/settings.json
Tests/AgentActivityMonitorTests.swift:189: error: -[ClearwayTests.AgentActivityMonitorTests
testASecondInstancesDisableLeavesTheLiveOwnersHooksInstalled] : XCTAssertEqual failed:
("4 bytes") is not equal to ("1853 bytes") - the owner's hooks survive a second instance that never bound
```

4 bytes is `{ }`: the second instance had taken the owner's whole managed block out.

**Deviations**

The gate is `listener != nil` rather than `health == .listening`. Both were offered; the listener is
the one that is exactly right, because a socket that bound while one agent's settings file was
refused resolves to `.settingsRefused` and still installed the other agent's block, which a disable
must still remove.

**Gate**

`./scripts/ci.sh` — exit 0, `==> CI passed.`,
`Executed 803 tests, with 0 failures (0 unexpected)` (802 after the simplify pass, plus this one).
`git status --porcelain` shows the five files above and nothing untracked or ignored.

### Review fix: narrow the socket probe to the errnos Decision 11 verified

The conventions review found that `hasLiveOwner` returned a `Bool`, so every errno `connect` could
produce that was not one of the three Decision 11 verified fell through to the unlink and the bind.
`EACCES` is the case that matters: a live owner's socket whose mode, or whose directory's mode,
denies this process answers `EACCES`, the `Bool` read it as "nobody is there", and the instance
unlinked that owner's socket and bound over it — both then displaying "listening", which is the
failure Decision 11 exists to stop. The operator decided to narrow it.

| File | State |
| --- | --- |
| `Sources/App/AgentActivityMonitor.swift` | Changed. `hasLiveOwner(at:) -> Bool` becomes `probe(at:) -> PathProbe`, a private three-case enum: `.liveOwner` (connect succeeded), `.stale` (`ENOENT`, `ECONNREFUSED`, `ENOTSOCK` — unlink and bind as before), `.unexplained(code:)` (everything else, plus a path too long for `sun_path` and a `socket()` that fails). `start` switches on it and reports `.unopenable` for `.unexplained` without touching the path. Still `nonisolated static` throughout. |
| `Tests/AgentActivityMonitorTests.swift` | Changed. Two tests and a `bindAndAbandon` helper that leaves a real socket inode at a path: `testAStartOverAnAbandonedSocketInodeUnlinksItAndListens` (the `ECONNREFUSED` branch, which had no test — only the `ENOTSOCK` regular-file case did) and `testAStartOverAPathTheProcessMayNotReachLeavesItAloneAndReportsItUnopenable` (the `EACCES` branch). |
| `docs/superpowers/specs/…-settings.md` | Changed. Decision 11 records the narrowing and names the operator; Assumption 6 records the re-probe. |
| `Sources/App/CLAUDE.md` | Changed. The probe has three answers, not two, and the note no longer says anything else falls through to unlink-then-bind. |

**Evidence**

The `EACCES` test was watched fail on the unfixed probe. The fall-through was restored (`case let
code: return code == 0 ? .unexplained(code: code) : .stale`, i.e. the old `Bool`), and:

```
Test Case '-[ClearwayTests.AgentActivityMonitorTests
testAStartOverAPathTheProcessMayNotReachLeavesItAloneAndReportsItUnopenable]' started.
Tests/AgentActivityMonitorTests.swift:181: error: … XCTAssertEqual failed: ("listening") is not equal to ("unopenable")
Tests/AgentActivityMonitorTests.swift:182: error: … XCTAssertNil failed: "Clearway.HookSocketListener"
Test Case '…' failed (0.051 seconds).
```

`.listening` is the steal: the old probe had unlinked a socket it could not reach and bound its own
over it.

`testAStartOverAnAbandonedSocketInodeUnlinksItAndListens` **passes on the unfixed code too**, and is
recorded here as a characterisation test rather than a regression proof: the `ECONNREFUSED` branch
was already correct, it simply had no test. It is the only one of the three accounted-for refusals
that involves a real socket inode, which is what the existing regular-file test cannot stand in for.

**Deviations**

The brief expected a directory at the socket path to produce an errno outside the listed three. It
does not: a scratchpad `connect` probe (macOS 25.6, `AF_UNIX`/`SOCK_STREAM`) answers `ENOTSOCK` (38)
for a directory and for a regular file alike, `ENOENT` (2) for nothing at all, `ECONNREFUSED` (61)
for an abandoned inode, and `EACCES` (13) for a socket, or a containing directory, at mode `000`.
`EACCES` is therefore what the unexpected-errno test provokes, and
`testAStartOverAPathThatCannotBeBoundReportsItAsUnopenable` keeps its meaning: a directory is still
`.stale`, still reaches the unlink, and still fails honestly at `bind`.

The new `EACCES` test is skipped under `getuid() == 0`, because root reaches every mode and no errno
outside the three would then be reachable. Neither CI nor a developer machine runs the suite as root.

**Gate**

`./scripts/ci.sh` — exit 0, `==> CI passed.`,
`Executed 808 tests, with 0 failures (0 unexpected)` (806 before these two).
`git status --porcelain` shows the four files above plus this plan, and nothing untracked or
ignored.

### Rebase onto #252

`origin/main` landed `Refuse to steal the hook socket from a live Clearway instance (#252)` while
this branch was open. It had built the same live-owner probe independently, so the overlap was
semantic rather than textual and the branch was rebased onto it with **one** probe left standing:
#252's, extended only where the health reporting needs an answer it does not distinguish. The two
spec and plan commits replayed unchanged; the ten implementation commits were resolved once and
collapsed into a single commit on top.

| File | State |
| --- | --- |
| `Sources/App/AgentActivityMonitor.swift` | #252's listener is the base. Kept from it: `HookSocketOutcome` carrying the listener, `unixAddress`/`withUnixAddress`, the inode-scoped `unlink` in `HookSocketListener.deinit`, `identity(of:)`, the empty-payload guard, the `DescriptorOutcome` shape. Kept from this branch: `health` in place of `socketState`, the install report, the mapping onto `AgentHookSocketOutcome`, the uninstall gate in `stop()`, and `probe(at:) -> PathProbe` in place of `isAnswering(at:) -> Bool?`. `.unavailable` is renamed `.unopenable` so the listener and the health model use one word. |
| `Tests/AgentActivityMonitorTests.swift` | #252's file is the base, its `socketState` assertions restated against `health`. Dropped as redundant: this branch's `testASecondInstanceLeavesTheLiveOwnersSocketAlone`, `testAStartOverALiveOwnerReportsItAndLeavesTheSocketWhereItIs`, `testAStartOverAnAbandonedSocketInodeUnlinksItAndListens`, `testAStartOverAPathThatCannotBeBoundReportsItAsUnopenable` and `testASecondInstancesDisableLeavesTheLiveOwnersSocketAlone` — #252 pins each of those rules, and pins them harder, by the socket's inode rather than by its existence. Carried over: the `EACCES` case (now monitor-level, `testAPathThisProcessMayNotReachIsLeftAloneAndReportedUnopenable`), the two hook-uninstall gate cases, and the health section. |
| `Sources/App/CLAUDE.md` | One merged note. #252's live-owner paragraph keeps the probe, the inode-scoped unlink and the `deinit` placement; this branch's third probe answer, uninstall gate, installer short-circuit and health rules fold into it. |
| `project.yml` | **Unchanged.** #252's base already excludes `**/*.md` from the `Clearway` target's sources, so T1's identical change is dropped. |
| `docs/superpowers/specs/…-settings.md` | Decisions 11, 12 and 16 credit #252 for the probe, the `deinit` unlink and the inode scoping, and record what this branch adds on top. |

**Deviations**

#252's `isAnswering` deliberately let every `connect` errno fall through to the unlink, so that an
unknown one could not disable the feature until the next reboot. That argument was sound while the
only channel was `Ghostty.logger`; it stops holding once Settings displays the refusal, which is
this branch's whole subject. The narrowing therefore stands and the comment arguing the other way
is replaced.

#252's `socketState` is removed rather than kept beside `health`. Nothing outside its own tests read
it, and `health` answers the same three socket cases plus the install half, so keeping both would
publish one fact twice.
