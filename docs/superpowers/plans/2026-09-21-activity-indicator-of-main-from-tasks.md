# Plan: Attribute a task terminal's agent activity to its task, not to main

Breaks down `docs/superpowers/specs/2026-09-21-activity-indicator-of-main-from-tasks.md`.

**Date:** 2026-09-21
**Base:** 7af507a9e555380d2429299ecd0e58c6fe96ad0a (Spec: attribute a task terminal's agent activity to its task)

## Architecture decisions carried from the spec

- A task surface is identified by its **task id**, the UUID the task file's frontmatter serialises.
  It is the only identity a task surface has that survives a relaunch (D1).
- One tagged wire value, `AgentActivityOwner`, with cases `worktree(String)` and `task(UUID)`,
  spelled `worktree:<path>` and `task:<uuid>` and decoded by splitting on the **first** colon, so a
  path containing a colon survives. The framing stays exactly two preamble lines; the forwarder
  keeps its `printf '%s\n%s\n'` (D2). A third preamble line was rejected: it makes "neither set"
  and "both set" representable (D3).
- `CLEARWAY_WORKTREE_ID` is **renamed** to `CLEARWAY_ACTIVITY_OWNER` and
  `AgentHookIdentity.worktreeIdKey` to `ownerKey`. No compatibility fallback reading either name:
  an agent already running at the upgrade loses its dot until its next `SessionStart`, one time
  (D4, D6 — operator has accepted this since the spec). Two env vars with the shell choosing
  between them was rejected: the forwarder decides nothing (D5).
- `Ghostty.SurfaceView` learns nothing about tasks. Its init parameter is renamed
  `worktreeId:` → `activityOwner: String?` and stays an opaque string it never interprets. The
  provider signature `(UUID, String?) -> [(key: String, value: String)]` is unchanged; only
  `AgentHookIdentity.environment` learns the owner type (D7).
- `AgentSurfaceState.worktreeId: String` becomes `owner: AgentActivityOwner`. The derivation splits
  in two: `worktreePhases: [String: AgentPhase]` over worktree owners only and a new
  `taskPhases: [UUID: AgentPhase]` over task owners only, so each key type is exactly what its
  reader holds (D8). One `[AgentActivityOwner: AgentPhase]` the readers index with a case was
  rejected — it would rewrite the sidebar's call site for no gain (D9).
- **No subagent child rows for tasks.** `worktreeSubagents` is filtered to worktree owners, so a
  task surface's roster contributes no key. A task whose lead is between turns with a live
  background subagent still shows the working dot, because `effectivePhase` lifts the surface
  before any derivation sees it (D10).
- `WorktreeRow`'s private `ActivityDot`, its `Dot` enum and the pulsing-glow block are lifted into
  one internal `AgentActivityDot` view with a nested `Kind` (`waiting` / `working` /
  `notification`). `WorktreeRow.dot(phase:hasNotification:isOpen:)` keeps its name and signature;
  only its return type becomes `AgentActivityDot.Kind?` (D11).
- The task row's rule is its own pure static, `WorkTaskRow.dot(phase:) -> AgentActivityDot.Kind?`:
  waiting, then working, then nothing. No `hasNotification`, no `isOpen` — both would be constants
  at the only call site (D12).
- `WorkTaskListView` takes `@EnvironmentObject private var agentActivity: AgentActivityMonitor` and
  passes `agentActivity.taskPhases[task.id] ?? .idle` into the row. The monitor is injected on the
  project `WindowGroup` and the list renders inside it (D13).
- The dot sits on the row's trailing edge after the existing `terminal` glyph, in the same `HStack`
  after the `Spacer()`. The glyph keeps its meaning — a live foreground process, agent or not
  (D14).
- The hook sheet and the debug terminal still carry no owner; their pairs omit the key and the
  forwarder's second guard fires (D15). A task terminal opened before its project path is known now
  carries an owner where it carried none (D16). Retirement is keyed on surface id alone and needs
  no new work (D17). Main's dot stays un-suppressed (D18).
- Out of scope: subagent rows and tool names for task terminals, any change to a task terminal's
  working directory, `WorkTaskCard` and the standalone Task window, a badge on the Tasks sidebar
  destination, blue notification dots on task rows, re-suppressing main's dot.

## Dependency graph

```
T1 (SurfaceView: worktreeId: → activityOwner:)
      │
      └── T2 (AgentActivityOwner on the wire; store keys on it; both producers stamp it)
                ├── T3 (CLEARWAY_ACTIVITY_OWNER + typed AgentHookIdentity.environment)
                │
                └── T5 (monitor publishes taskPhases; the task row renders the dot)
                          ▲
T4 (lift AgentActivityDot out of WorktreeRow) ──────┘

T6 (rewrite the now-false notes in Sources/App/CLAUDE.md)  ← after T2, T3, T5
```

T1 is a pure rename and must land first so T2 touches the same call sites once more only to wrap
their values. T2 is the atom: the parser, the store and both producers of the wire value have to
change together or the build is red and every dot goes dark. T3 depends on `AgentActivityOwner`
existing. T4 is independent of the wire entirely. T5 needs the store's `taskPhases` (T2) and
`AgentActivityDot` (T4). T6 describes the shape T2, T3 and T5 create.

**Every task ends with `./scripts/ci.sh` green** — the project's regression command, which
regenerates the Xcode project (without which a new Swift file is invisible to the build), lints,
builds and runs the suite. It is not repeated under each task's verification below.

### T1: Rename the surface's owner parameter to activityOwner

**Files:** `Sources/Ghostty/Ghostty.SurfaceView.swift`, `Sources/App/TerminalManager.swift`,
`Sources/App/TerminalManager+TaskTerminals.swift`, `Sources/Ghostty/CLAUDE.md`

**What it does.** A pure rename with no value change, so `Sources/Ghostty` stops naming a Clearway
concept it is about to stop carrying.

- `Ghostty.SurfaceView.init`'s fourth parameter `worktreeId: String? = nil` becomes
  `activityOwner: String? = nil` (`Ghostty.SurfaceView.swift:75`), and the one use inside the init,
  `Self.agentEnvironment(surfaceId, worktreeId)` (`:92`), reads `activityOwner`. The stored
  `agentEnvironment` provider's type is unchanged. The doc comment on `agentEnvironment` (`:66-68`)
  keeps its meaning; no new comment is added.
- The five call sites take the new label with the same values as today:
  `TerminalManager.swift:171`, `:329`, `:338`, `:464` (all pass `key`) and
  `TerminalManager+TaskTerminals.swift:24`, `:95` (both pass `projectPath`).
- `Sources/Ghostty/CLAUDE.md:17` — "from its `surfaceId` and `worktreeId`" becomes "from its
  `surfaceId` and `activityOwner`". Nothing else in that note changes: the layer still knows
  nothing about what the string means.

**Acceptance criteria.**
1. No occurrence of `worktreeId` remains in `Sources/Ghostty/`.
2. Every `Ghostty.SurfaceView(...)` call site compiles with the new label and passes the value it
   passed before.
3. Behaviour is unchanged: the env var stamped is still `CLEARWAY_WORKTREE_ID` with the same value.

**Verification.** `grep -rn "worktreeId" Sources/Ghostty/` returns nothing. `./scripts/ci.sh`
passes; `AgentHookIdentityTests` and `AgentActivityMonitorTests` are untouched and still green,
which is what pins criterion 3.

### T2: Put a tagged AgentActivityOwner on the wire and key the store on it

**Files:** `Sources/App/AgentHookEvent.swift`, `Sources/App/AgentActivityStore.swift`,
`Sources/App/TerminalManager.swift`, `Sources/App/TerminalManager+TaskTerminals.swift`,
`Tests/AgentHookEnvelopeTests.swift`, `Tests/AgentActivityStoreTests.swift`,
`Tests/AgentActivityMonitorTests.swift`

Seven files, three of them test updates forced by one field rename. This task is deliberately over
the usual five-file ceiling: the parser, the store and both producers of the second preamble line
are a single atom — splitting them leaves either a red build or a build where no dot lights at all.

**What it does.**

1. `AgentHookEvent.swift` — add the owner type beside the envelope that carries it:

```swift
/// Who a surface's agent activity belongs to. One tagged string on the wire so exactly one owner
/// is representable: a worktree names its path, a task names its id, and neither can be absent
/// while the other is set.
enum AgentActivityOwner: RawRepresentable, Equatable {
    case worktree(String)
    case task(UUID)

    var rawValue: String {
        switch self {
        case .worktree(let path): return "worktree:\(path)"
        case .task(let id): return "task:\(id.uuidString)"
        }
    }

    /// Split on the **first** colon only, so a worktree path containing one survives.
    init?(rawValue: String) {
        guard let colon = rawValue.firstIndex(of: ":") else { return nil }
        let value = String(rawValue[rawValue.index(after: colon)...])
        guard !value.isEmpty else { return nil }
        switch rawValue[rawValue.startIndex..<colon] {
        case "worktree": self = .worktree(value)
        case "task":
            guard let id = UUID(uuidString: value) else { return nil }
            self = .task(id)
        default: return nil
        }
    }
}
```

   `AgentHookEnvelope.worktreeId: String` becomes `owner: AgentActivityOwner`, and `parse` refuses
   a second line that does not decode:

```swift
guard let (surfaceId, afterSurface) = takeLine(data),
      let (ownerLine, body) = takeLine(afterSurface),
      !surfaceId.isEmpty,
      let owner = AgentActivityOwner(rawValue: ownerLine),
      let event = try? decoder.decode(AgentHookEvent.self, from: Data(body))
else { return nil }
```

   The `!worktreeId.isEmpty` check goes: an empty line has no colon and already fails to decode.
   The type's doc comment ("line 2 the worktree id") is corrected to name the owner.

2. `AgentActivityStore.swift` —
   - `AgentSurfaceState.worktreeId: String` becomes `owner: AgentActivityOwner`; the two
     construction sites (`:105`, `:187`) and the refresh at `:188` follow.
   - `worktreePhases` skips non-worktree owners:
     `guard case .worktree(let id) = state.owner else { return }` inside the `reduce(into:)`.
   - `worktreeSubagents` skips them likewise (`else { continue }` in the `for` loop), so a task
     surface's roster contributes no key.
   - New, beside them, with the same `max` rule over `effectivePhase`:

```swift
/// A task's own phase, keyed by the task id its terminal was stamped with. A task surface
/// contributes here and to nothing else; a worktree surface the reverse.
var taskPhases: [UUID: AgentPhase] {
    surfaces.values.reduce(into: [:]) { phases, state in
        guard case .task(let id) = state.owner else { return }
        phases[id] = Swift.max(phases[id] ?? .idle, state.effectivePhase)
    }
}
```

   - The comment above `worktreePhases` ("The three derivations…") becomes four.
3. `TerminalManager.swift` — the four sites from T1 pass
   `activityOwner: AgentActivityOwner.worktree(key).rawValue`.
4. `TerminalManager+TaskTerminals.swift` — the two sites pass
   `activityOwner: AgentActivityOwner.task(taskId).rawValue`, and the two-line comment at `:22-23`
   explaining the path/worktree-id conflation is **deleted**: it describes the bug this removes.
   `projectPath` stays the `workingDirectory` at both sites.
5. `Tests/AgentHookEnvelopeTests.swift` — the `payload` helper's second line becomes
   `AgentActivityOwner.worktree(worktreePath).rawValue`; assertions on `envelope?.worktreeId` become
   `envelope?.owner` compared against `.worktree(worktreePath)`. `testEmptyWorktreeIdParsesToNil`
   is renamed to name the owner. New cases, per the spec's mechanical criteria:
   - a `task:<uuid>` second line round-trips to `.task(uuid)`;
   - a `worktree:` path keeps its spaces **and** an inner colon
     (`/Users/x/my repo/.worktrees/a:b` → `.worktree("/Users/x/my repo/.worktrees/a:b")`);
   - an untagged second line (a bare path, as a pre-rename forwarder sends) parses to nil;
   - an unknown tag (`branch:main`) parses to nil;
   - `task:not-a-uuid` parses to nil;
   - a tag with an empty value (`worktree:`) parses to nil.
6. `Tests/AgentActivityStoreTests.swift` — the `apply`/`applyRaw` helpers take an
   `owner: AgentActivityOwner = .worktree(worktreeOne)` and write `owner.rawValue` as the second
   line; existing assertions are unchanged. New cases:
   - a task owner contributes to `taskPhases` and **not** to `worktreePhases`;
   - a worktree owner contributes to `worktreePhases` and **not** to `taskPhases`;
   - a task owner with a live subagent contributes **no** `worktreeSubagents` key, and its
     `taskPhases` entry is `.working` while its lead sits idle after `Stop`;
   - retiring a task surface clears its `taskPhases` entry;
   - two task owners each keep their own phase.
7. `Tests/AgentActivityMonitorTests.swift` — the `fire` helper's environment value for
   `AgentHookIdentity.worktreeIdKey` becomes `AgentActivityOwner.worktree(worktreePath).rawValue`
   (the **key** is still the old one; T3 renames it). The `worktreeId` constant is renamed
   `worktreePath` and the `worktreePhases[...]` lookups keep using it.

**Acceptance criteria.**
1. `AgentHookEnvelope.parse` accepts `worktree:<path>` and `task:<uuid>` and refuses an untagged,
   empty-valued or unknown-tagged second line.
2. A worktree path containing a colon round-trips intact.
3. `worktreePhases` and `worktreeSubagents` contain worktree owners only; `taskPhases` contains
   task owners only.
4. Every worktree surface (`pane`, `appendTab`'s two sites, the respawn) is stamped
   `worktree:<id>`; both task surfaces are stamped `task:<uuid>`, including the one built with a
   nil `projectPath`.
5. The main worktree's phase is no longer raised by an agent in a task terminal.

**Verification.** `AgentHookEnvelopeTests` covers 1 and 2; `AgentActivityStoreTests` covers 3 and
the retirement rule; `AgentActivityMonitorTests` still drives the real forwarder end to end, which
covers the round trip through `printf`. Criterion 4 is read off the four/two call sites; criterion 5
follows from 3 and 4 and is the operator's behavioural check. `./scripts/ci.sh` passes.

### T3: Rename the env var to CLEARWAY_ACTIVITY_OWNER and give environment the owner type

**Files:** `Sources/App/AgentHookScript.swift`, `Sources/App/ClearwayApp.swift`,
`Tests/AgentHookIdentityTests.swift`, `Tests/AgentHookSettingsTests.swift`,
`Tests/AgentActivityMonitorTests.swift`

**What it does.**

1. `AgentHookScript.swift` —
   - `static let worktreeIdKey = "CLEARWAY_WORKTREE_ID"` becomes
     `static let ownerKey = "CLEARWAY_ACTIVITY_OWNER"`.
   - `environment(surfaceId:worktreeId:)` becomes:

```swift
/// The owner pair is omitted rather than blanked when there is none, so the forwarder's second
/// guard fires and the surface stays invisible.
static func environment(surfaceId: UUID, owner: AgentActivityOwner?) -> [(key: String, value: String)] {
    var pairs = [(key: surfaceIdKey, value: surfaceId.uuidString)]
    if let owner {
        pairs.append((key: ownerKey, value: owner.rawValue))
    }
    pairs.append((key: socketKey, value: AgentHookPaths().socketPath))
    return pairs
}
```

   - The forwarder body's second guard becomes `[ -n "$CLEARWAY_ACTIVITY_OWNER" ] || exit 0` and
     its `printf` line reads `"$CLEARWAY_SURFACE_ID" "$CLEARWAY_ACTIVITY_OWNER"`. Nothing else in
     the script changes — three guards, one `nc` round trip, `exit 0`. The doc comment's "a surface
     with no worktree" becomes "a surface with no owner".
2. `ClearwayApp.swift:162` — the provider is wired through a decode, because the provider's
   parameter is an opaque `String?` while `environment` now takes the typed owner:

```swift
Ghostty.SurfaceView.agentEnvironment = { surfaceId, owner in
    AgentHookIdentity.environment(
        surfaceId: surfaceId,
        owner: owner.flatMap(AgentActivityOwner.init(rawValue:))
    )
}
```

   A string that does not decode yields no pair, which is the same outcome as no owner at all.
3. `Tests/AgentHookIdentityTests.swift` — the local `preamble` helper reads
   `values[AgentHookIdentity.ownerKey]`; the three `environment(surfaceId:worktreeId:)` calls take
   `owner:` with an `AgentActivityOwner`; assertions on `envelope?.worktreeId` become
   `envelope?.owner`. `testTheSurfaceProviderIsWiredAtLaunch` (`:68-74`) passes
   `AgentActivityOwner.worktree(path).rawValue` to the provider and the owner itself to
   `environment`. Add a case round-tripping `.task(UUID())` from `environment` through the
   forwarder's `printf` to `AgentHookEnvelope.parse`, alongside the existing worktree one; the
   no-owner surface stays unparseable.
4. `Tests/AgentHookSettingsTests.swift` — `:139-149` stamp through `owner:` and assert
   `"CLEARWAY_ACTIVITY_OWNER"`; `:161`'s key list takes the new name, which is what pins the
   forwarder's guards mentioning it.
5. `Tests/AgentActivityMonitorTests.swift` — the `fire` helper's key becomes
   `AgentHookIdentity.ownerKey`.

**Acceptance criteria.**
1. `CLEARWAY_WORKTREE_ID` appears nowhere in `Sources/` or `Tests/`.
2. `AgentHookIdentity.environment` takes `AgentActivityOwner?` and stamps `owner.rawValue` under
   `CLEARWAY_ACTIVITY_OWNER`, omitting the pair when the owner is nil.
3. The installed forwarder guards on and forwards `$CLEARWAY_ACTIVITY_OWNER`.
4. The launch-time provider wiring still produces the same keys as `environment` (the pin against
   a silently dead feature).

**Verification.** `grep -rn "CLEARWAY_WORKTREE_ID\|worktreeIdKey" Sources/ Tests/` returns nothing.
`AgentHookSettingsTests` covers 2 and 3, `AgentHookIdentityTests` covers 4 and both owner kinds
round-tripping through the real `printf` framing, `AgentActivityMonitorTests` runs the installed
script for real. `./scripts/ci.sh` passes.

### T4: Lift AgentActivityDot out of WorktreeRow

**Files:** `Sources/App/WorktreeRow.swift`

**What it does.** Replaces the private `ActivityDot`, the `WorktreeRow.Dot` enum and the
per-caller glow block with one internal view that owns hue, size, tooltip, glow and transition, so
a second row cannot drift from the first.

```swift
/// The dot on the trailing edge of a row that can carry agent activity. One shape and one size for
/// every state; the working dot's pulsing glow is the only thing that varies, and it belongs here
/// rather than to the callers so the two rows cannot drift.
struct AgentActivityDot: View {
    enum Kind {
        case waiting
        case working
        case notification
    }

    let kind: Kind
    @State private var glowExpanded = false

    var body: some View { ... }
}
```

- `kind` maps to today's values exactly: `.waiting` → purple, "Waiting for permission", with
  `.transition(.opacity)`; `.working` → orange, "Agent is working", the two `shadow`s with the
  `glowExpanded` radii, the `.easeInOut(duration: 1.5).repeatForever(autoreverses: true)`
  animation, the `onAppear`/`onDisappear` toggles and `.transition(.opacity)`; `.notification` →
  blue, "Terminal notification", no glow and **no** transition, as today. The 7 pt `Circle` and
  `.help(_:)` are shared.
- `glowExpanded` moves off `WorktreeRow` onto this view; `WorktreeRow`'s `@State private var
  glowExpanded` (`:14`) is deleted.
- `WorktreeRow.dot(phase:hasNotification:isOpen:)` keeps its name, its signature and its rule; only
  its return type becomes `AgentActivityDot.Kind?`. The `Dot` enum (`:40-44`) is deleted.
- The body's `switch` (`:68-87`) collapses to:

```swift
Group {
    if let kind = Self.dot(phase: phase, hasNotification: hasNotification, isOpen: isOpen) {
        AgentActivityDot(kind: kind)
    }
}
.animation(.easeOut(duration: 0.6), value: phase)
```

  The outer `.animation(..., value: phase)` stays on the `Group`, because it animates on the row's
  phase, not on the dot's own state.

**Acceptance criteria.**
1. `AgentActivityDot` is internal, nested `Kind` has the three cases, and it is the only place the
   hues, the 7 pt size, the help strings and the glow are written.
2. `WorktreeRow.dot(phase:hasNotification:isOpen:)` is unchanged but for its return type.
3. A worktree row renders the same dot in the same three states as before.

**Verification.** `Tests/WorktreeRowTests.swift` is **not** edited — it never spells the type name,
so it compiling and passing unchanged is the pin for criterion 2. `./scripts/ci.sh` passes.
Criterion 3 is the operator's check that worktree dots are unchanged.

### T5: Publish taskPhases and give the task row its dot

**Files:** `Sources/App/AgentActivityMonitor.swift`, `Sources/App/WorkTaskListView.swift`,
`Tests/AgentActivityMonitorTests.swift`, `Tests/WorkTaskRowTests.swift` (new)

**What it does.**

1. `AgentActivityMonitor.swift` — a third published derivation beside the two, change-gated the
   same way:

```swift
@Published private(set) var taskPhases: [UUID: AgentPhase] = [:]
```

   and in `publish()`:

```swift
let tasks = store.taskPhases
if tasks != taskPhases { taskPhases = tasks }
```

   The class comment's "publishes the derivations" needs no change; the `ToolNames` note stays as
   it is, since the tool label is still deliberately **not** on the monitor.
2. `WorkTaskListView.swift` —
   - the view gains `@EnvironmentObject private var agentActivity: AgentActivityMonitor` beside the
     other five;
   - `WorkTaskRow` loses `private` (the test target reaches it through `@testable import`, which
     raises internal, not private) and gains `var phase: AgentPhase = .idle` plus:

```swift
/// Which dot the row carries, or none. No `hasNotification` and no `isOpen`: a task terminal
/// raises no notification, and a retired surface has already left the store.
static func dot(phase: AgentPhase) -> AgentActivityDot.Kind? {
    switch phase {
    case .waiting: return .waiting
    case .working: return .working
    case .idle: return nil
    }
}
```

   - the row's trailing `HStack` (`:351-356`) keeps the `terminal` glyph first and adds the dot
     after it, inside the same `HStack`, with the same animation wrapper `WorktreeRow` uses:

```swift
Group {
    if let kind = Self.dot(phase: phase) {
        AgentActivityDot(kind: kind)
    }
}
.animation(.easeOut(duration: 0.6), value: phase)
```

   - the list's call site (`:219`) passes `phase: agentActivity.taskPhases[task.id] ?? .idle`.
3. `Tests/AgentActivityMonitorTests.swift` — one case: firing a `UserPromptSubmit` from a surface
   stamped `task:<uuid>` lands on `monitor.taskPhases[id]` as `.working` and leaves
   `monitor.worktreePhases` empty. It uses the existing `fire` helper with the owner value
   parameterised.
4. `Tests/WorkTaskRowTests.swift` (new) — pins `WorkTaskRow.dot(phase:)`: `.waiting` → `.waiting`,
   `.working` → `.working`, `.idle` → nil. `ci.sh` runs `xcodegen generate`, without which the new
   file is invisible to the build.

**Acceptance criteria.**
1. `AgentActivityMonitor.taskPhases` is published and change-gated alongside the other two.
2. `WorkTaskRow.dot(phase:)` is waiting over working over nothing.
3. A backlog task whose terminal hosts a working agent shows the pulsing orange dot on its row,
   after the `terminal` glyph; a waiting agent shows the static purple dot; an idle one shows
   nothing.
4. `WorkTaskListView` resolves the monitor from the environment (it renders inside the project
   `WindowGroup`, which injects it).

**Verification.** `WorkTaskRowTests` covers 2. `AgentActivityMonitorTests` covers 1 end to end
through the real socket. Criteria 3 and 4 are the operator's behavioural checks against the running
app; a missing injection would fault at runtime on the Tasks list, which the operator's first check
exercises. `./scripts/ci.sh` passes.

### T6: Rewrite the agent-pipeline notes that this change makes false

**Files:** `Sources/App/CLAUDE.md`

**What it does.** Five passages in the agent-pipeline bullet (`:314-441`) describe the shape this
change replaces. Each is rewritten in place, in the file's existing voice, with no new bullet added:

- **`:331` framing** — "two preamble lines — surface id, worktree id" becomes "surface id, activity
  owner", and the sentence names the two spellings `worktree:<path>` and `task:<uuid>` and the
  split-on-the-first-colon rule that lets a path keep a colon.
- **`:335` guards** — "surface id, worktree id, a socket that exists" becomes "surface id, activity
  owner, a socket that exists".
- **`:338` "Two ids, not one"** — rewritten to say what survives a relaunch and why the owner is
  tagged: the surface id does not survive, the owner does, and one tagged value is what makes
  "exactly one owner" the only representable shape. It also records the rename's one-time cost — an
  agent already running across the upgrade carries the old variable, so the forwarder's second
  guard fires and its dot stays dark until its next `SessionStart` — and that no fallback reading
  the old name was kept.
- **`:398` "The monitor publishes two values, not three"** — it now publishes three
  (`worktreePhases`, `worktreeSubagents`, `taskPhases`); the point being preserved is that the tool
  label is **not** among them and stays on the nested `ToolNames` object for the reason the rest of
  that passage gives.
- **`:434` the dot** — the precedence sentence gains the task row: `AgentActivityDot` is the one
  view both rows render, `WorkTaskRow.dot(phase:)` is the task rule (waiting over working over
  nothing, with no `hasNotification` and no `isOpen` because a task terminal raises no notification
  and a retired surface has already left the store), and task rows carry no subagent children by
  design.

**Acceptance criteria.**
1. No sentence in `Sources/App/CLAUDE.md` describes the worktree id as the second preamble line,
   the env var as `CLEARWAY_WORKTREE_ID`, or the monitor as publishing two values.
2. A reader who has not seen this plan can tell from the file why the owner is tagged, what the
   rename cost once, and which view draws both dots.

**Verification.** `grep -n "worktree id\|CLEARWAY_WORKTREE_ID\|two values, not three" Sources/App/CLAUDE.md`
returns only sentences that are still true. `./scripts/ci.sh` passes (markdown is excluded from the
target's sources, so this is a no-op regression check, run because the stage owns it).

### T7: Close the task terminal when a task is promoted to a worktree

**Files:** `Sources/App/WorkTaskCoordinator.swift`,
`Sources/App/TerminalManager+TaskTerminals.swift`, `Sources/App/CLAUDE.md`,
`Tests/WorkTaskCoordinatorTests.swift`

**What it does.** Added after review-pr. `confirmCreate` writes `updated.worktree = branch`
(`WorkTaskCoordinator.swift:101`) and leaves the task's bottom terminal running, while the link it
just wrote takes the task out of `backlogTasks` — the only renderer of `taskPhases` (assumption 5).
So an agent working in a promoted task's terminal lights no dot anywhere: not the task's row, which
no longer renders, and not main's, which T2 took it off. The operator chose closing that terminal
over leaving the agent stranded or widening the change to the aside card.

- `confirmCreate` calls `terminalManager.closeTaskTerminal(taskId)` inside its `if let taskId`
  block, after the write and its `written == nil` log. Unconditional on the task id, not on the
  write landing: a task whose file vanished between Start Now and Create is gone from the list
  either way, so its terminal has no row left to report to. `closeTaskTerminal` is today reached
  only from the two delete confirmations (`WorkTaskListView.swift:156`, `:174`).
- `closeTaskTerminal` clears `openTaskIds`, `taskTerminalVisible` and `taskTerminalHeights`
  unconditionally and keeps the surface teardown — `retireSurface` plus `closeSurface` — behind the
  `taskSurfaces` lookup. The task has no terminal after the call whether or not a surface was ever
  minted, and that bookkeeping is the only half XCTest can observe: a `Ghostty.SurfaceView` needs a
  `ghostty_app_t`. No reachable state has bookkeeping without a surface, so this changes no
  behaviour — every writer (`taskSurface(for:)`, `openTaskTerminal`) mints the surface in the same
  call that records the task as open.
- `Sources/App/CLAUDE.md` — the `confirmCreate` passage gains the close, why it is there, and that
  it is the one part of the write `abandonPendingCreate` cannot unwind.
- `Tests/WorkTaskCoordinatorTests.swift` — one case in the "Confirming a create" section: a task
  whose terminal height the operator dragged to 320 is promoted, and the stored height is gone,
  which only `closeTaskTerminal` does. Review-pr added the arrange guard that the seed landed, and
  extended `testConfirmCreateRecordsNoLinkWhenTheTaskIsGone` with the same pair, so the close being
  keyed on the task id rather than on the write landing is pinned rather than left to inspection.

**Acceptance criteria.**
1. Start Now → Create on a backlog task closes that task's bottom terminal, retiring any agent
   surface under `.task(id)`.
2. A hand-made worktree (no task id) closes nothing.
3. The two delete doors keep working exactly as they did.

**Verification.** `WorkTaskCoordinatorTests` covers 1 and, by `confirmCreate(taskId: nil, …)`
already being pinned, 2. Criterion 3 is pinned by the delete paths going through the same method
with a surface present, which no test can reach. `./scripts/ci.sh` passes.

### T8: Refuse to open a task terminal for a task promoted during its launch

**Files:** `Sources/App/WorkTaskCoordinator+TaskTerminal.swift`,
`Sources/App/TerminalManager+Commands.swift`, `Sources/App/WorkTaskManager.swift`,
`Sources/App/CLAUDE.md`, `Tests/TaskTerminalLaunchCommandTests.swift`

**What it does.** Added after review-pr. Both doors onto a task terminal claim the launch, suspend
on `await ShellEnvironment.awaitPath()`, and open the surface when they resume. T7 made the window
between those two moments matter: Start Now → Create promotes the task and closes its terminal, and
the resumed launch opens a new one for a task that has left `backlogTasks` — the same stranded,
dotless agent T7 exists to prevent, arrived by a different route. Delete is the second route to the
same place: it removes the file and closes the terminal, and a resumed launch reopens one for a task
with no row at all. Each door re-reads the task after the await and abandons itself when it is no
longer one the list renders.

- `WorkTaskCoordinator.taskIsStillInBacklog(_:)` is the whole rule: the task is in
  `workTaskManager.tasks` **and** names no worktree. A promoted task stays in the pool with a link
  (it is `backlogTasks` that filters it out); a deleted one leaves the pool. No new state — the
  launch claim is released by the `defer` either way.
- Both doors use it as their **entry** guard too, replacing the existence-only checks they had, so
  the rule is one rule read twice. Entry needs the full rule: `selectedTaskId` is cleared only when
  `git worktree add` reports back, so a promoted task stays selected and rendered until then, and a
  Cmd+J in that window took the `.reveal` branch — which mints a surface without reaching the
  post-await guard at all. On the toggle door the entry guard gates the **mint** only
  (`hasSurface || taskIsStillInBacklog`): hiding or revealing a surface the task already has takes
  nothing from a row that has left the list, and `TaskDetailView` renders a linked task and draws
  its toggle, so refusing there would strand a live agent in a pane no press can collapse.
- `WorkTaskManager.deleteTask` re-derives the pool as it removes the file, the way `createTask` and
  `relocateTaskToWorktree` already do. The watcher reload is 0.3s behind, which is longer than the
  window the rule guards, so the delete half of the rule never fired in the app before this.
  `reload` rather than dropping the id: disk is what the method wrote, so a removal that failed
  leaves the task standing instead of taking its row away and resurrecting it at the next
  unrelated load. It is per-manager — the standalone task window owns its own `WorkTaskManager`,
  so its Delete still reaches the project window behind the watcher.
- The Cmd+J launch guards between building the command and `openTaskTerminal`
  (`WorkTaskCoordinator+TaskTerminal.swift:39-41`).
- `planTask`'s await is not in `planTask`: `TerminalManager.run(_:inTaskTerminalFor:app:directory:)`
  calls `ShellEnvironment.awaitPath()` itself, between the caller's `Task` body starting and
  `openTaskTerminal`, so a guard in the coordinator alone would never see the promotion. `run` takes
  the resolved `path` as a parameter instead, and the coordinator awaits it, guards, and calls in —
  the deferred shape `taskTerminalLaunchCommand` already uses for the Cmd+J door. `run` keeps its
  own `awaitShellPrompt`, which runs after the surface exists.
- `Sources/App/CLAUDE.md` — the `confirmCreate` passage gains the in-flight launch, since the close
  it already describes is what the guard protects.
- `Tests/TaskTerminalLaunchCommandTests.swift` — the rule against the states `confirmCreate` and
  `deleteTask` actually leave behind, rather than a hand-set field, so the guard cannot drift from
  the two doors it guards against.

**Acceptance criteria.**
1. A launch suspended on `awaitPath` when the task is promoted opens no terminal on either door.
2. A launch suspended on `awaitPath` when the task is deleted opens no terminal on either door.
3. A task still in the backlog when the launch resumes opens its terminal exactly as before.
4. The launch claim is released in every case, so the next Cmd+J on a task that survived still
   works.
5. A press on the toggle for a task that is already promoted or already deleted mints nothing
   either, on the reveal branch as much as the launch branch — while a press on a surface the task
   already has still hides and reveals it.
6. `deleteTask` takes the task out of `tasks` without waiting for the watcher, so the deleted answer
   holds inside the debounce window rather than only after it, and a removal that failed leaves the
   row standing.

**Verification.** `TaskTerminalLaunchCommandTests` pins the rule on all three answers, driving the
promote through `confirmCreate` and the delete through `deleteTask` with no reload in between —
which is criterion 6. Criterion 4 is the `defer` that already released it, unchanged and above the
guard. Criterion 5 is the same method called at the door, the one line each door can carry.
`./scripts/ci.sh` passes.

## Risks

| Risk | Impact | Mitigation |
| --- | --- | --- |
| T2 is the whole wire at once; a mistake there darkens every dot, not just tasks | High | `AgentActivityMonitorTests` drives the installed forwarder over the real socket, so the round trip is covered by the suite rather than by inspection |
| The provider wiring in T3 decodes a string that T2's producers encoded; a mismatch silently omits the pair and ships a dead feature | High | `AgentHookIdentityTests.testTheSurfaceProviderIsWiredAtLaunch` compares the provider's keys against `environment`'s, and T3 extends it to a task owner |
| `WorkTaskRow` becoming internal invites reuse from outside the list | Low | It stays in `WorkTaskListView.swift` and takes only the values that file passes |
| An agent running across the upgrade loses its dot until its next `SessionStart` | Low | Accepted by the operator (D6), recorded in the notes by T6 |

## Accepted risks carried from the spec

- A `SIGKILL`ed agent in a task terminal pins the task's dot until its next `SessionStart` —
  nothing in the pipeline has a clock.
- The aside card and the standalone Task window show no activity for a task whose list row is lit.

## Changelog

- **2026-09-21, after review-pr (dc65bb3) — T7 added.** Operator decision: when a backlog task is
  promoted to a worktree through Start Now → Create, its bottom task terminal is closed, retiring
  any agent surface under `.task(id)`. A promoted task leaves `backlogTasks`, the only renderer of
  `taskPhases`, so an agent left running there would light no dot anywhere; the operator chose
  closing over leaving it stranded and over widening the change to the aside card. Recorded as
  Decision 19 in the spec, with a matching acceptance criterion.

- **2026-09-21, after T7 (38a1143) — no code change.** Operator decision: the close stays in
  `WorkTaskCoordinator.confirmCreate`, beside the link write and before `git worktree add`, rather
  than moving to `completePendingCreate` as the build agent proposed. A failed create therefore
  restores the task to the backlog without its terminal. Recorded as Decision 20 in the spec.

- **2026-09-21, after T7 (38a1143) — no code change.** Operator decision: promote does not confirm
  before closing a task terminal with a live process, unlike Delete and Plan, because promote is an
  explicit action on the task. Recorded as Decision 21 in the spec.

- **2026-09-22, rebase onto origin/main — one fix commit.** Main's #252 added four monitor cases to
  `Tests/AgentActivityMonitorTests.swift` that read `self.worktreeId`, the fixture property T2
  renamed to `worktreePath`; git merged both sides cleanly and the test target stopped compiling.
  The four references were renamed. Two `Sources/App/CLAUDE.md` conflicts were resolved by folding
  #253's `health` paragraph together with this branch's `taskPhases` rewrite (the monitor now
  publishes four values, not three), and one in `Clearway.xcodeproj/project.pbxproj` by keeping
  both file references.

- **2026-09-22, after review-pr (baa435d) — T8 added.** Operator decision: a task-terminal launch
  suspended on `await ShellEnvironment.awaitPath()` when the task is promoted through Start Now →
  Create must open nothing when it resumes, on the Cmd+J door and the `planTask` door alike.
  Otherwise the terminal T7 closes is reopened a moment later with the task already out of
  `backlogTasks`. Recorded as Decision 22 in the spec, with a matching acceptance criterion.

- **2026-09-22, with T8 — docs only.** The rebase onto `origin/main` orphaned every branch SHA the
  spec and the plan cite. Refreshed to the current ones: the spec's `Base` to `a311a93` (the commit
  this branch now sits on) and its "verified at base" line with it, the plan's `Base` to the spec
  commit `7af507a`, `05285ad` to `dc65bb3` and both `2950938` references to `38a1143`.

- **2026-09-22, during T8 — rule widened.** Operator decision on the build agent's follow-up: the
  guard reads the entry guard's whole rule, "still in `tasks` **and** naming no worktree", not
  "naming no worktree". A task deleted across the await must open nothing either — Delete closes the
  terminal the same way the promote does, and the narrower rule read a missing task as fine to open
  for. `taskWasPromoted` became `taskIsStillInBacklog` with the sense flipped. Folded into
  Decision 22 and the T8 acceptance criteria.

- **2026-09-22, after review (4662614) — T8 fix pass.** Two findings from the reviewer. F1: the
  delete half of `taskIsStillInBacklog` never fired in the app, because `deleteTask` removed only
  the file and `tasks` caught up behind the watcher's 0.3s debounce; `deleteTask` now drops the task
  from `tasks` synchronously, mirroring `persist`, and the test that had called `reloadFromDisk()`
  around the gap is the regression pin. F2: the docs claimed the post-await rule was "the entry
  guard's own rule read a second time" while the entry guards checked existence only. Read from the
  code, no legitimate door opens a task terminal for a task that already has a worktree, so both
  entry guards were tightened to `taskIsStillInBacklog` and the wording kept — this also closes the
  `.reveal` branch, which minted a surface without reaching the post-await guard at all. Acceptance
  criteria 5 and 6 added to T8.

- **2026-09-22, third review-pr pass (6674e2a) — two fixes, no new decisions.** F1: the toggle
  door's entry guard sat above the whole `switch`, so it refused `.hide` and `.reveal` as well as
  the mint. `TaskDetailView` renders a linked task and draws its terminal toggle, so a task that
  acquired a worktree without going through `closeTaskTerminal` — an external frontmatter write —
  left a running agent in a pane no press could collapse. The guard is now
  `hasSurface || taskIsStillInBacklog`, which keeps the `.reveal`-mints hole closed. F2:
  `deleteTask` dropped the id from `tasks` unconditionally while `removeItem` stayed `try?`, so a
  failed unlink took the row away with the file still on disk — and since nothing changed on disk,
  no watcher event fired to bring it back. It now calls `reload()`, the primitive `createTask` and
  `relocateTaskToWorktree` already use, which self-corrects and makes the existing test pin the
  file removal too. Also: the `abandonPendingCreate` claim in the guard's docstring is now pinned
  by the promote test, and the near-verbatim duplication between that docstring and
  `Sources/App/CLAUDE.md` was cut back to the sentences that span files. Acceptance criteria 5
  and 6 restated.

## Build log

### T1: Rename the surface's owner parameter to activityOwner

| File | State |
| --- | --- |
| `Sources/Ghostty/Ghostty.SurfaceView.swift` | `init`'s fourth parameter is `activityOwner: String? = nil`; the one use reads `Self.agentEnvironment(surfaceId, activityOwner)`. Provider type unchanged. |
| `Sources/App/TerminalManager.swift` | Four call sites (`:171`, `:329`, `:338`, `:464`) take `activityOwner: key`. |
| `Sources/App/TerminalManager+TaskTerminals.swift` | Two call sites (`:24`, `:95`) take `activityOwner: projectPath`. The path/worktree-id comment at `:22-23` stays; T2 deletes it. |
| `Sources/Ghostty/CLAUDE.md` | `:17` now reads "from its `surfaceId` and `activityOwner`". |

**Evidence.** No watched failure to quote: this is a pure rename with no behavioural change, so it
carries no regression test of its own. What pins criterion 3 is that `AgentHookIdentityTests` and
`AgentActivityMonitorTests` are untouched and still green — they drive the installed forwarder over
the real socket and assert `CLEARWAY_WORKTREE_ID` and its value end to end, so any change to what is
stamped would have turned them red.

**Criterion 1.** `grep -rn "worktreeId" Sources/Ghostty/` returns nothing (exit 1).

**Deviations.** None.

**Gate.** `./scripts/ci.sh` — passed, exit 0. 783 tests, 0 failures. `git status --porcelain`
lists only the four files above plus this plan.

### T2: Put a tagged AgentActivityOwner on the wire and key the store on it

| File | State |
| --- | --- |
| `Sources/App/AgentHookEvent.swift` | `AgentActivityOwner` added above `AgentHookEnvelope`, spelled and decoded exactly as the plan wrote it. `AgentHookEnvelope.worktreeId` is now `owner: AgentActivityOwner`; `parse` drops the `!worktreeId.isEmpty` check and refuses a second line that does not decode. The type's doc comment names the owner. |
| `Sources/App/AgentActivityStore.swift` | `AgentSurfaceState.worktreeId` is now `owner`; both construction sites and the refresh in `update` follow. `worktreePhases` and `worktreeSubagents` guard on `.worktree`; new `taskPhases: [UUID: AgentPhase]` guards on `.task`. The derivations comment reads "four". |
| `Sources/App/TerminalManager.swift` | The four sites (`:171`, `:329`, `:338`, `:464`) pass `AgentActivityOwner.worktree(key).rawValue`. |
| `Sources/App/TerminalManager+TaskTerminals.swift` | Both sites pass `AgentActivityOwner.task(taskId).rawValue`; `projectPath` stays the `workingDirectory`. The path/worktree-id comment at `:22-23` is deleted — it described the bug this removes. |
| `Tests/AgentHookEnvelopeTests.swift` | `payload` takes an `owner:` override defaulting to the tagged worktree value; assertions read `envelope?.owner`. New: a `task:<uuid>` round trip, a worktree path with spaces **and** an inner colon, and four refusals — untagged, unknown tag, `task:not-a-uuid`, `worktree:` with no value. `testEmptyWorktreeIdParsesToNil` is now `testEmptyOwnerParsesToNil`. |
| `Tests/AgentActivityStoreTests.swift` | `apply`/`applyRaw` take `owner: AgentActivityOwner = .worktree(worktreeOne)`; existing assertions unchanged. New "Task owners" section: the two exclusivity cases, a task owner's live background subagent, retirement, and two independent tasks. |
| `Tests/AgentActivityMonitorTests.swift` | `worktreeId` renamed `worktreePath`; the `fire` helper's value is `AgentActivityOwner.worktree(worktreePath).rawValue` under the still-old key, which T3 renames. |
| `Tests/AgentHookIdentityTests.swift` | Not in the plan's file list, but forced by the envelope field rename: three assertions on `envelope?.worktreeId` become `envelope?.owner`, and the values handed to `environment` are now tagged. The parameter and key names stay as they are; T3 owns those. |

**Evidence.** The watched failure is the exclusivity rule, the whole point of the task. With
`worktreePhases` and `worktreeSubagents` keyed on *every* owner — a `switch` mapping `.task` to its
`uuidString` in place of the `guard case .worktree` — the two new task cases go red and the rest of
the suite stays green:

```
✖ testATaskOwnerContributesToTaskPhasesAndNotToWorktreePhases, XCTAssertTrue failed
✖ testATaskOwnersLiveSubagentRaisesItsPhaseAndNoRosterKey, XCTAssertEqual failed:
  ("Optional(Clearway.AgentPhase.idle)") is not equal to ("Optional(Clearway.AgentPhase.working)")
Executed 27 tests, with 2 failures (0 unexpected)
```

Restoring the guards turns both green. The first assertion is criterion 5 in miniature: a task
surface raising a worktree key is exactly the dot on main this change exists to remove.

**Deviations.**

- `Tests/AgentHookIdentityTests.swift` is an eighth file. Its assertions name the envelope field
  this task renames, so the build is red without it. Only the field name and the values passed
  change; the `worktreeId:` label, `worktreeIdKey` and the task-owner case stay for T3.
- `testATaskOwnersLiveSubagentRaisesItsPhaseAndNoRosterKey` first drove a bare `Stop` through the
  `apply` helper and failed on the real gate: a `Stop` naming no `background_tasks` sweeps the
  roster, which is correct behaviour. It now uses the captured `subagentStart`/`stop(running:)`
  payloads, which is what "a live background subagent" actually looks like on the wire.

**Gate.** `./scripts/ci.sh` — passed, exit 0. 793 tests, 0 failures. `git status --porcelain` lists
only the eight files above plus this plan; no untracked files, `default.profraw` included.

### T3: Rename the env var to CLEARWAY_ACTIVITY_OWNER and give environment the owner type

| File | State |
| --- | --- |
| `Sources/App/AgentHookScript.swift` | `worktreeIdKey` is now `ownerKey = "CLEARWAY_ACTIVITY_OWNER"`; `environment(surfaceId:owner:)` takes `AgentActivityOwner?` and stamps `owner.rawValue`, omitting the pair when nil. The forwarder's second guard and its `printf` name the new variable; the script is otherwise byte-identical — three guards, one `nc` round trip, `exit 0`. The doc comment reads "a surface with no owner". |
| `Sources/App/ClearwayApp.swift` | The provider is a closure that decodes the opaque string: `owner.flatMap(AgentActivityOwner.init(rawValue:))`. A string that does not decode yields no pair, the same outcome as no owner. |
| `Tests/AgentHookIdentityTests.swift` | `preamble` reads `AgentHookIdentity.ownerKey`; the four `environment` calls take `owner:` with a typed owner. `testASurfaceWithNoWorktreeSendsNothingTheParserWouldAccept` is now `…NoOwner…`, and its MARK with it. New `testATaskOwnerRoundTripsThroughTheForwardersPreamble` takes `.task(UUID())` from `environment` through the `printf` framing to `AgentHookEnvelope.parse`. `testTheSurfaceProviderIsWiredAtLaunch` passes the raw value to the provider and the owner itself to `environment`. |
| `Tests/AgentHookSettingsTests.swift` | `testIdentityCarriesTheWorktreeOnlyWhenThereIsOne` is now `…TheOwner…`; it stamps through `owner:` and asserts the literal `"CLEARWAY_ACTIVITY_OWNER": "worktree:/Users/x/my repo"` — the tag is part of what is stamped, so the assertion spells it. The forwarder's guard list takes the new name. |
| `Tests/AgentActivityMonitorTests.swift` | The `fire` helper's key is `AgentHookIdentity.ownerKey`. |

**Evidence.** The watched failure is the plan's High risk: the provider wiring decodes a string T2's
producers encoded, and a mismatch silently omits the pair and ships a dead feature. With the decode
dropped — `owner: nil` in place of the `flatMap` — only `AgentHookIdentityTests` notices, and both
its assertions fire:

```
✖ testTheSurfaceProviderIsWiredAtLaunch, XCTAssertEqual failed:
  ("["CLEARWAY_SURFACE_ID", "CLEARWAY_HOOK_SOCKET"]")
  is not equal to ("["CLEARWAY_SURFACE_ID", "CLEARWAY_ACTIVITY_OWNER", "CLEARWAY_HOOK_SOCKET"]")
✖ testTheSurfaceProviderIsWiredAtLaunch, XCTAssertEqual failed:
  ("nil") is not equal to ("Optional("worktree:/Users/x/clearway")")
Executed 6 tests, with 2 failures (0 unexpected)
```

Every other suite stayed green in that run, `AgentActivityMonitorTests` included — it builds the
forwarder's environment itself rather than through the provider, so this one test is the whole of
what stands between a wiring mistake and a feature that lights nothing. Restoring the `flatMap`
turns it green.

**Criterion 1.** `grep -rn "CLEARWAY_WORKTREE_ID\|worktreeIdKey" Sources/ Tests/` returns nothing
(exit 1). The `worktreeId` identifiers still in `Sources/App` are worktree ids in the sidebar, the
tab strip and `TerminalManager`'s pane keys — unrelated to the hook pipeline and out of scope.

**Deviations.**

- `testTheSurfaceProviderIsWiredAtLaunch` gained a third assertion comparing the provider's stamped
  owner **value** against `owner.rawValue`, beyond the key-list comparison the plan specifies. The
  key list alone catches a decode that yields nil; it does not catch one that yields a different
  owner, which is the same silently-dead feature. It is one line at the site the risk table already
  nominates.

**Gate.** `./scripts/ci.sh` — passed, exit 0. 794 tests, 0 failures (793 after T2, plus the task
round trip). `git status --porcelain` lists only the five files above plus this plan; no untracked
files, no `default.profraw`.

### T4: Lift AgentActivityDot out of WorktreeRow

| File | State |
| --- | --- |
| `Sources/App/WorktreeRow.swift` | The private `ActivityDot` is now internal `AgentActivityDot` with a nested `Kind` (`waiting` / `working` / `notification`) and its own `@State private var glowExpanded`. It owns the hues, the 7 pt `Circle`, the `.help(_:)` strings, the two `shadow`s, the repeating `easeInOut` glow animation, the `onAppear`/`onDisappear` toggles and the `.transition(.opacity)` on the two phase kinds; `.notification` still carries no glow and no transition. `WorktreeRow.Dot` is deleted, `WorktreeRow.dot(phase:hasNotification:isOpen:)` keeps its name, signature and rule with `AgentActivityDot.Kind?` as its return type, `WorktreeRow`'s own `glowExpanded` is gone, and the body's four-case `switch` is the plan's `if let kind` inside the `Group` that keeps `.animation(.easeOut(duration: 0.6), value: phase)`. |

No test file was edited. `Tests/WorktreeRowTests.swift` never spells the enum's type name, so it
compiling and passing unchanged is the pin for criterion 2.

**Evidence.** That pin is load-bearing, not incidental. Swapping the two phase arms of
`WorktreeRow.dot` — `case .waiting: return .working`, `case .working: return .waiting` — turns
`WorktreeRowDotTests` red against the lifted type:

```
Tests/WorktreeRowTests.swift:68: error: -[ClearwayTests.WorktreeRowDotTests testWaitingBeatsEverythingElse] :
  XCTAssertEqual failed: ("Optional(Clearway.AgentActivityDot.Kind.working)")
  is not equal to ("Optional(Clearway.AgentActivityDot.Kind.waiting)")
Tests/WorktreeRowTests.swift:72: error: -[ClearwayTests.WorktreeRowDotTests testWorkingBeatsANotification] :
  XCTAssertEqual failed: ("Optional(Clearway.AgentActivityDot.Kind.waiting)")
  is not equal to ("Optional(Clearway.AgentActivityDot.Kind.working)")
Executed 6 tests, with 2 failures (0 unexpected)
```

The failure names `Clearway.AgentActivityDot.Kind`, which is the same assertion also confirming the
rename reached the tests without a line of test edit. Restoring the two arms turns it green.

**Criterion 1.** `grep -rn "ActivityDot" Sources/ Tests/` returns only the declaration and the one
call site in `WorktreeRow.body`; the strings "Waiting for permission", "Agent is working",
"Terminal notification", the `7` frame and both `shadow`s appear once each, inside
`AgentActivityDot`.

**Deviations.** One, in shape only. The plan sketches `var body: some View { ... }` without saying
how the three kinds branch; the body is a `switch kind` over a private `circle(_:help:)` helper, so
each hue and each help string is written exactly once. The rendered modifier chains are
arm-for-arm identical to the ones deleted from `WorktreeRow.body`.

**Gate.** `./scripts/ci.sh` — passed, exit 0. 794 tests, 0 failures, unchanged from T3 since no test
was added. `git status --porcelain` lists only `Sources/App/WorktreeRow.swift` and this plan; no
untracked files, no `default.profraw`.

### T5: Publish taskPhases and give the task row its dot

| File | State |
| --- | --- |
| `Sources/App/AgentActivityMonitor.swift` | `@Published private(set) var taskPhases: [UUID: AgentPhase]` sits between `worktreePhases` and `worktreeSubagents`, and `publish()` gates it the same way the other two are gated. The class comment and the `ToolNames` note are unchanged. |
| `Sources/App/WorkTaskListView.swift` | The view takes `@EnvironmentObject private var agentActivity: AgentActivityMonitor` beside the other six. `WorkTaskRow` is internal, gains `var phase: AgentPhase = .idle` and the pure static `dot(phase:)`, and its trailing `HStack` keeps the `terminal` glyph first and renders `AgentActivityDot` after it inside the plan's `Group` with `.animation(.easeOut(duration: 0.6), value: phase)`. The list's call site passes `phase: agentActivity.taskPhases[task.id] ?? .idle`. |
| `Tests/AgentActivityMonitorTests.swift` | The `fire` helper takes `owner: AgentActivityOwner? = nil`, defaulting to the worktree value every existing case relies on. New `testAForwardedEventFromATaskSurfaceLightsOnlyThatTask` fires a `UserPromptSubmit` under `task:<uuid>` through the installed forwarder and the real socket. |
| `Tests/WorkTaskRowTests.swift` (new) | `WorkTaskRowDotTests` pins the three arms of `WorkTaskRow.dot(phase:)`. `xcodegen generate` picked it up, so `Clearway.xcodeproj/project.pbxproj` carries the three generated entries for it. |

**Evidence.** Both new pins were watched red in one gate run, against the two mistakes they exist to
catch. Dropping the two publish lines from `publish()` — the derivation computed but never
published, a task dot that never lights — and swapping the two phase arms of `WorkTaskRow.dot`:

```
✖ testAForwardedEventFromATaskSurfaceLightsOnlyThatTask, XCTAssertEqual failed:
  ("idle") is not equal to ("working") - the task's phase
✖ testAWaitingAgentCarriesTheWaitingDot, XCTAssertEqual failed:
  ("Optional(Clearway.AgentActivityDot.Kind.working)")
  is not equal to ("Optional(Clearway.AgentActivityDot.Kind.waiting)")
✖ testAWorkingAgentCarriesTheWorkingDot, XCTAssertEqual failed:
  ("Optional(Clearway.AgentActivityDot.Kind.waiting)")
  is not equal to ("Optional(Clearway.AgentActivityDot.Kind.working)")
Executed 798 tests, with 3 failures (0 unexpected)
```

The monitor case's second assertion — `worktreePhases` still empty — is criterion 5 of the whole
change end to end over the real forwarder: a task's agent lights the task and leaves main dark.
Restoring both turns all three green.

**Deviations.** None. The new test file carries the same
`call to main actor-isolated static method … in a synchronous nonisolated context` warning
`WorktreeRowTests` already carries for the same reason — a `View`'s static reached from a
nonisolated `XCTestCase` — and is left matching its sibling rather than annotated differently.

**Gate.** `./scripts/ci.sh` — passed, exit 0. 798 tests, 0 failures (794 after T4, plus the monitor
case and the three row cases). `git status --porcelain` lists only the four files above, the
regenerated `Clearway.xcodeproj/project.pbxproj` and this plan; no `default.profraw`.

### T6: Rewrite the agent-pipeline notes that this change makes false

| File | State |
| --- | --- |
| `Sources/App/CLAUDE.md` | Five passages of the agent-pipeline bullet rewritten in place; no bullet added, nothing else touched. **Framing** (`:331`) reads "surface id, activity owner" and names the two spellings `worktree:<path>` / `task:<uuid>` and the split-on-the-first-colon rule. **Guards** (`:336`) reads "surface id, activity owner, a socket that exists". **"Two ids, not one, and the second one is tagged"** (`:340`) says the surface id does not survive a relaunch and the owner does, why one tagged value makes "exactly one owner" the only representable shape, and records the rename to `CLEARWAY_ACTIVITY_OWNER` with no fallback and its one-time cost — the second guard fires for an agent running across the upgrade and its dot stays dark until its next `SessionStart`. **The monitor** (`:407`) publishes "three values, not four" — `worktreePhases`, `taskPhases`, `worktreeSubagents` — and says the tool label is not among them, keeping the `ToolNames` reasoning intact. **The dot** (`:444`) is now keyed on "the same owner", names `AgentActivityDot` as the one view both rows render, keeps the worktree rule, and adds `WorkTaskRow.dot(phase:)` over `taskPhases` with its no-`hasNotification`/no-`isOpen` reason and why task rows carry no subagent children while a live subagent still counts as work through `effectivePhase`. |

**Evidence.** Documentation only: no behaviour changes, so there is no watched failure to quote and
no regression test is owed. What each rewritten sentence asserts was read back off the code rather
than off the plan — `AgentActivityOwner.rawValue`/`init?(rawValue:)` in `AgentHookEvent.swift`, the
three guards and the `printf` in `AgentHookScript.body`, `AgentHookIdentity.ownerKey`, the three
`@Published` properties and their gates in `AgentActivityMonitor.publish()`, the
`worktreeSubagents` filter in `AgentActivityStore`, and `WorkTaskRow.dot(phase:)` with its call
site in `WorkTaskListView`.

**Criterion 1.** `grep -n "worktree id\|CLEARWAY_WORKTREE_ID\|two values, not three\|worktreeId"
Sources/App/CLAUDE.md` returns one line — `:348`, the sentence recording that
`CLEARWAY_ACTIVITY_OWNER` was renamed from `CLEARWAY_WORKTREE_ID` and that no fallback reads the
old name, which the task asks for. No sentence describes the second preamble line as the worktree
id, the live variable as the old name, or the monitor as publishing two values.

**Deviations.** None in substance. Three neighbouring lines were re-wrapped where a replaced phrase
changed their length; no sentence outside the five passages changed.

**Gate.** `./scripts/ci.sh` — passed, exit 0. 798 tests, 0 failures, unchanged from T5 since
markdown is not in the target's sources. `git status --porcelain` lists only
`Sources/App/CLAUDE.md` and this plan; no untracked files, no `default.profraw`.

### Simplify

The phase→dot mapping the two row rules had each spelled out is now
`AgentActivityDot.Kind(phase:)`, and the shared view moved to its own
`Sources/App/AgentActivityDot.swift` rather than staying in the file named after one of its two
callers. `TerminalManager.makeSurface(_:workingDirectory:command:owner:)` replaces six hand-written
`AgentActivityOwner…rawValue` conversions at the Ghostty seam. Left alone: the store's twin
`worktreePhases`/`taskPhases` reductions (a generic key extractor reads worse than the six
duplicated lines) and the provider's decode in `ClearwayApp`, which is what keeps `environment`
typed so no caller can stamp an untagged owner. `./scripts/ci.sh` — passed, exit 0, 798 tests,
0 failures, unchanged from T6.

### T7: Close the task terminal when a task is promoted to a worktree

| File | State |
| --- | --- |
| `Sources/App/WorkTaskCoordinator.swift` | `confirmCreate` ends its `if let taskId` block with `terminalManager.closeTaskTerminal(taskId)`, after the write and its `written == nil` log, so a task whose file vanished loses its terminal too. The doc comment says why the close is there. |
| `Sources/App/TerminalManager+TaskTerminals.swift` | `closeTaskTerminal` clears `openTaskIds`, `taskTerminalVisible` and `taskTerminalHeights` unconditionally and keeps `retireSurface` + `closeSurface` behind the `taskSurfaces` lookup. No reachable state carries the bookkeeping without a surface — both writers mint one in the same call — so behaviour is unchanged and the bookkeeping is now observable from XCTest. |
| `Sources/App/CLAUDE.md` | The `confirmCreate` passage gains the close, its reason (a promoted task leaves `backlogTasks`, the only renderer of `taskPhases`), and that it is the one part of the write `abandonPendingCreate` cannot unwind. |
| `Tests/WorkTaskCoordinatorTests.swift` | `testConfirmCreateClosesThePromotedTasksTerminal`: a task whose terminal height was set to 320 is promoted, and the height reads back as the 200 default. |

**Evidence.** With the `closeTaskTerminal` call removed from `confirmCreate` — the code as review-pr
found it — the new case is the only failure in the suite:

```
✖ testConfirmCreateClosesThePromotedTasksTerminal, XCTAssertEqual failed:
  ("320.0") is not equal to ("200.0") - a promoted task keeps no terminal of its own
Executed 799 tests, with 1 failure (0 unexpected)
```

Restoring the one line turns it green. The surface half of the close cannot be driven from XCTest —
a `Ghostty.SurfaceView` needs a `ghostty_app_t` — so what the case pins is that the promote reaches
`closeTaskTerminal`; that the method retires the surface it finds is the line beside the teardown,
and `AgentActivityStoreTests.testRetiringATaskSurfaceClearsItsTaskPhase` pins what retirement then
does to the dot.

**Deviations.** One. The plan's file list did not name the `closeTaskTerminal` restructure as a
change in its own right; it is the seam that makes the promote observable, and it is described in
the task above.

**Gate.** `./scripts/ci.sh` — passed, "==> CI passed." under `set -euo pipefail`, so exit 0. 799
tests, 0 failures (798 after T6, plus this case). `git status --porcelain` lists only the four files
above plus this plan and the spec; no untracked files, no `default.profraw`.

### T8: Refuse to open a task terminal for a task promoted during its launch

| File | State |
| --- | --- |
| `Sources/App/WorkTaskCoordinator+TaskTerminal.swift` | `taskIsStillInBacklog(_:)` is the rule both doors re-read the task through — in `tasks`, naming no worktree. The Cmd+J launch guards between building the command and `openTaskTerminal`; `planTask` awaits the PATH itself, guards, then calls `run` with it. |
| `Sources/App/TerminalManager+Commands.swift` | `run(_:inTaskTerminalFor:app:directory:path:)` takes the resolved PATH instead of awaiting one. Its own `awaitShellPrompt` is unchanged — that one runs after the surface exists. |
| `Sources/App/CLAUDE.md` | The `confirmCreate` passage gains the in-flight launch and why the PATH await moved out of `run`. |
| `Tests/TaskTerminalLaunchCommandTests.swift` | `testALaunchOpensNothingOnceCreateHasWrittenTheLink`: a backlog task passes the rule, and the same task after `confirmCreate` does not. `testALaunchOpensNothingOnceTheTasksFileIsDeleted`: the same for a task removed through `deleteTask`. |

**Evidence.** Twice. The rule is new, so the unfixed code cannot be compiled against these cases;
what was watched instead is the rule answering as the code it replaced behaved. First, always
"open it" — the pre-T8 behaviour at both call sites:

```
✖ testALaunchOpensNothingOnceCreateHasWrittenTheLink, XCTAssertTrue failed -
  a launch resuming after the promote must open nothing
Executed 839 tests, with 1 failure (0 unexpected)
```

Then, after the operator widened the rule, the narrower `?.worktree == nil` it replaced — which
answers "still in the backlog" for a task that is not in `tasks` at all:

```
✖ testALaunchOpensNothingOnceTheTasksFileIsDeleted, XCTAssertFalse failed -
  a launch resuming after the delete must open nothing
Executed 840 tests, with 1 failure (0 unexpected)
```

Each time, restoring the one line turns it green, and neither mutation moved any other case.

What the cases cannot pin is the wiring: both doors need a `ghostty_app_t` XCTest cannot produce,
so that each of them consults the rule is the two `guard` lines beside their awaits and this note,
the same limit `planCommand` and `taskTerminalToggle` already carry.

**Deviations.** Three.

1. Review-pr's recommended guard was inline at each call site. It is a named method instead, because
   an inline `workTaskManager.tasks.first(where:)?.worktree == nil` is the only part of this an
   XCTest can reach, and spelled inline it is reachable from nowhere.
2. Review-pr placed the plan door's guard at the `await terminalManager.run(…)` line. The await the
   decision names is **inside** `run`, between the caller's `Task` body starting and
   `openTaskTerminal`, so a guard there would resume and open the terminal regardless — it would
   close only the window between `planTask` returning and its `Task` body starting. `run` takes the
   resolved `path` as a parameter and the coordinator owns the suspension, which also makes both
   doors the same shape: resolve the PATH, re-read the task, open. The staged branch of `run` does
   not use the path and now waits for it, which costs nothing measurable — `ShellEnvironment`
   resolves eagerly at launch and `awaitPath` returns at once once a full value is known.
3. The delete cases were asked for "on each door". They are one case, because both doors consult
   one method: a second copy would be the same three lines under a different name, and neither door
   is reachable from XCTest to distinguish them. The same limit applies to the promote case.

**Follow-up settled.** The first cut of this task guarded on `?.worktree == nil`, which passes for a
task that has left `tasks` entirely; the operator took that follow-up back into T8 rather than
leaving it. The rule is now the entry guard's, re-read.

**Gate.** `./scripts/ci.sh` — passed, "==> CI passed." under `set -euo pipefail`, so exit 0. 840
tests, 0 failures (838 before, plus these two). `git status --porcelain` lists only the four files
above plus this plan and the spec; no untracked files, no `default.profraw`.

#### T8 fix pass after review (F1, F2)

| File | State |
| --- | --- |
| `Sources/App/WorkTaskManager.swift` | `deleteTask` drops the task from `tasks` as it removes the file, the mirror of `persist`'s in-memory write-back, and re-syncs the per-file watchers the way `persist` does. |
| `Sources/App/WorkTaskCoordinator+TaskTerminal.swift` | Both entry guards are now `taskIsStillInBacklog`: `toggleTaskTerminal`'s existence check and a new line in `planTask` beside the `planCommand` unwrap. The docstring says what the method is instead of pointing at a guard that checked something else. |
| `Sources/App/CLAUDE.md` | The "read a second time" sentence now names the entry guards as the same call, says why entry needs the full rule, and records `deleteTask`'s in-memory half. |
| `Tests/TaskTerminalLaunchCommandTests.swift` | `testALaunchOpensNothingOnceTheTasksFileIsDeleted` no longer calls `reloadFromDisk()`. It is now the regression pin for F1 rather than a test that arranged the fix away. |

**F1 — the delete half never fired in the app.** `deleteTask` removed the file and nothing else;
`tasks` caught up through the file watcher behind a 0.3s debounce, which is longer than the window
between a launch's `await` and its resume. So a launch resuming inside it still found the task in
`tasks` with `worktree == nil` and opened a terminal. The test hid it by reloading. Watched red on
the unfixed `deleteTask`, with the reload removed:

```
/Users/…/Tests/TaskTerminalLaunchCommandTests.swift:84: error:
  -[ClearwayTests.TaskTerminalLaunchCommandTests testALaunchOpensNothingOnceTheTasksFileIsDeleted]
  : XCTAssertFalse failed - a launch resuming after the delete must open nothing
Executed 1 test, with 1 failure (0 unexpected)
```

Green on the same test once `deleteTask` drops the task from the pool. The other three callers
(`WorkTaskWindow`'s alert, `WorkTaskListView`'s two) each close the window or the row right after
the call, so an earlier disappearance from `tasks` is what they already wanted; no test depended on
the file-only behaviour — `TaskTerminalLaunchCommandTests` was the only caller in the suite.

**F2 — the entry guards were tightened, the wording kept.** The code says no legitimate door opens a
task terminal for a task that already has a worktree. The Tasks list renders `backlogTasks` alone,
`selectedTaskId` is only ever set from that list or from `newTaskAction`'s brand-new task, and
`TaskDetailView` is built only for `selectedTaskId`. But `ContentView` clears `selectedTaskId` in
the `lastCreatedBranch` handler — after `git worktree add` returns — so between Create and that
moment the promoted task is still selected and still rendered, and Cmd+J or the path-bar button
reached `taskTerminalToggle` and took `.reveal` (T7 closed the surface, so `hasSurface` is false;
with no Main Terminal command configured `.reveal` is the answer). `.reveal` mints a task surface
and never reaches the post-await guard, which is the hole the wording claimed was already closed.
Tightening costs nothing: a create that fails restores the task through `abandonPendingCreate`, and
the guard passes again on the next press. `planTask` takes the same line, after the `planCommand`
unwrap so a wrong-kind command still logs its own refusal.

The entry guards themselves stay unreachable from XCTest — both doors take a `ghostty_app_t` — so
the pin is `taskIsStillInBacklog` plus the one `guard` line each, the limit the post-await guards
already carry.

**Gate.** `./scripts/ci.sh` — "==> CI passed." under `set -euo pipefail`. 840 tests, 0 failures; the
count is unchanged because F1 fixed a test that existed rather than adding one.
