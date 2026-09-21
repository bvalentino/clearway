# Plan: Attribute a task terminal's agent activity to its task, not to main

Breaks down `docs/superpowers/specs/2026-09-21-activity-indicator-of-main-from-tasks.md`.

**Date:** 2026-09-21
**Base:** 4636187aa6504c6213374a59850408bb1ff2f764 (Spec: attribute a task terminal's agent activity to its task)

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
