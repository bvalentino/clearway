# Plan: replace the JSONL-mtime activity dot with agent lifecycle hooks

**Date:** 2026-09-20
**Base:** 5d8df20

Breaks down `docs/superpowers/specs/2026-09-20-replace-activity-dot-with-agent-lifecycle-hooks.md`.
Every design decision lives there; this file only orders the work and says how each piece is
verified. Read the spec's Decisions table before starting any task — the decision numbers below
refer to it.

## Architecture decisions carried from the spec

One line each, so a build agent reading only this file builds the right thing.

1. **Transport** — a `SOCK_STREAM` Unix domain socket at `~/.clearway/hook.sock`; one connection per
   hook invocation; the server reads to EOF. No TCP, no port, no entitlement. (D1)
2. **Forwarder** — `/usr/bin/nc -U -w 1 "$CLEARWAY_HOOK_SOCKET"`, absolute path. macOS `nc` has **no**
   `-N` flag; it already shuts the write side on stdin EOF. Never use `-N`. (D2, Risk "nc is the
   transport")
3. **Framing** — line 1 the surface id, line 2 the worktree id, then the agent's raw JSON to EOF.
   No escaping, no `jq`, no length prefix. (D3)
4. **Events installed** — `SessionStart`, `SessionEnd`, `UserPromptSubmit`, `PreToolUse`,
   `PostToolUse`, `PermissionRequest`, `SubagentStart`, `SubagentStop`, `Stop`. (D4)
5. **Identity** — three env vars on the surface: `CLEARWAY_SURFACE_ID` (a UUID per
   `Ghostty.SurfaceView`), `CLEARWAY_WORKTREE_ID` (the worktree id, which is its path), and
   `CLEARWAY_HOOK_SOCKET`. The script's first line is `[ -n "$CLEARWAY_SURFACE_ID" ] || exit 0`,
   which makes a `claude` started in Terminal.app a no-op. (D5)
6. **Two ids, not one** — the surface id does not survive a relaunch; the worktree id does. An event
   whose surface id is unknown to this process still lights its worktree's dot and renders its
   subagent rows. (D6)
7. **Which surfaces are stamped** — pane main tabs, pane secondary, task bottom terminal. The
   before-remove hook sheet and the debug terminal are not. (D7)
8. **Managed block is unversioned** — compute the desired block, remove every entry recognised as
   Clearway's, insert the desired one, write only if the result differs. (D10)
9. **Recognition rule** — `type == "command"` and a `command` containing
   `/.clearway/hooks/clearway-hook.sh`. No marker key. Emptied group, emptied event array and
   emptied `hooks` object are each removed in turn. (D11)
10. **No `matcher` key** — it is omitted, which matches everything. `"*"` is not a valid regex. (D12)
11. **Settings merge** — `JSONSerialization`, re-serialised `.prettyPrinted` **and** `.sortedKeys`,
    written atomically. Values preserved, key order and whitespace not. One backup to
    `settings.json.clearway-backup` before the first modification. (D13, operator-confirmed)
12. **Unparseable settings** — write nothing, log through `Ghostty.logger`, no quarantine, no
    rename. (D14)
13. **Codex** — `~/.codex/hooks.json` written only when `~/.codex` already exists; Clearway never
    creates the directory. (D15)
14. **Codex trust copy** — the Settings toggle carries one line of copy naming the `/hooks` trust
    step. This is the deliberate exception to CLAUDE.md's "no helper text". (D16,
    operator-confirmed)
15. **Toggle** — Settings → Appearance, `Toggle("Show agent activity", …)`, default **on**, key
    `clearway.agentHooksEnabled`. Off uninstalls the block and closes the listener; on installs and
    opens. (D17)
16. **One owner** — a single app-level `AgentActivityMonitor` (`@MainActor ObservableObject`) as a
    `@StateObject` on `ClearwayApp`, injected with `.environmentObject`. It replaces the per-window
    `ClaudeActivityMonitor`: one process, one socket. (D18)
17. **Pure state machine** — `AgentActivityStore` is a value type with no I/O. The monitor does
    socket plumbing and publishing only. (D19)
18. **Transitions** — `SessionStart` resets the surface to idle with an empty roster;
    `UserPromptSubmit` → working, lead tool cleared; `PreToolUse` without `agent_id` → working with
    lead tool, with `agent_id` → upsert that subagent's tool and mark the surface working;
    `PostToolUse` clears the corresponding tool and stays working; `PermissionRequest` → waiting,
    recording `tool_name`; `SubagentStart` upserts from `agent_id`/`agent_type`; `SubagentStop`
    removes it; `Stop` → idle, clearing the lead tool **and the whole roster**; `SessionEnd` drops
    the surface entry. An event for a surface id retired in this process is ignored. (D20)
19. **Dot derivation** — `waiting > working > idle` over every surface carrying the worktree id,
    including surfaces this process never owned. Working is any surface working **or** any surface
    holding a live subagent. (D21)
20. **Waiting has its own colour** — a static 7 pt `.purple` dot, tooltip "Waiting for permission".
    The operator overrode the spec's original reuse of the blue notification dot. Orange is the
    working dot, blue the plain-shell notification, red means failure and green success elsewhere in
    the app, and yellow is both a status-badge colour and one hue family from orange. Purple appears
    nowhere in `Sources/` today. Working keeps its pulsing orange; waiting does not pulse, so shape
    separates them as well as hue. Precedence in `WorktreeRow`: waiting, then working, then the
    plain-shell notification. (D22, operator override)
21. **No suppression for main** — `SidebarView`'s `!wt.isMain` goes. `isOpen` stays. (D23)
22. **Subagent rows** — extra views inside the existing `ForEach` body, after the worktree row: no
    `.tag` (so not selectable), `.moveDisabled(true)`,
    `.padding(.leading, SidebarRowMetrics.statusRowIndent)`, text only — agent type with the
    in-flight tool name as a secondary caption. No `OutlineGroup`, no `DisclosureGroup`. (D24)
23. **Type alone** — no subagent description; `SubagentStart` carries only `agent_type` and
    `agent_id`. (D25)
24. **`ClaudeSessionFiles` is renamed, not deleted** — it keeps `makeWatcher` and
    `defaultWatchMask` (CLAUDE.md's single `DispatchSource` door, four other callers) and loses the
    Claude path helpers; the file and enum become `FileWatchers`. (D26)
25. **Surface retirement** — a `static` callback on `TerminalManager`, wired once in
    `ClearwayApp.init`, mirroring the `SurfaceView.claimsShortcut` provider. Never reconcile against
    a list of live surfaces. (D27)
26. **Tool name on the tab** — the lead's in-flight tool shows as secondary text on the tab chip,
    present only while a tool is in flight. (D28)

## Plan-level elaborations

Two implementation shapes the spec left open. Both follow patterns CLAUDE.md already documents.

- **The env-var names cross a layer boundary.** `Sources/Ghostty/` wraps libghostty and must not
  import Clearway's hook feature. So `Ghostty.SurfaceView` gains a `nonisolated static var
  agentEnvironment: (UUID, String?) -> [(key: String, value: String)]`, defaulting to
  `{ _, _ in [] }` and wired once in `ClearwayApp.init` to `AgentHookIdentity.environment` — exactly
  the process-scoped provider shape CLAUDE.md describes for `claimsShortcut`. The names live in one
  place, on the App side, and a test can round-trip them without a `ghostty_app_t`.
- **The `withCString` generalisation is a `strdup` pair, not a closure tower.** Assumption 2 records
  that Zig `dupeZ`s both key and value into the surface config's arena, so the Swift C strings need
  to live only across the `ghostty_surface_new` call. Build the `[ghostty_env_var_s]` with `strdup`,
  `defer { free(…) }` after the call, and leave the existing nested `withCString` for
  `working_directory` / `command` untouched.

## Dependency graph

```
T1 AgentHookEvent (wire model)
 │
 ├─► T2 AgentActivityStore (state machine) ─┐
 │                                          │
T3 AgentHookScript + AgentHookSettings      │
 │       │                                  │
 │       └─► T4 AgentHookInstaller ─────────┤
 │                                          │
 ├─► T5 Surface identity (env vars, retire) │
 │                                          ▼
T6 AgentActivityMonitor  ◄── T7 Settings toggle
 │
 └─► T8 App wiring (ClearwayApp / ProjectWindow / ContentView)
        │
        ├─► T9  Sidebar dot + subagent rows
        ├─► T10 Tab chip tool name
        │
        └─► T11 Delete ClaudeActivityMonitor
              │
              └─► T12 Rename ClaudeSessionFiles → FileWatchers
                    │
                    └─► T13 CLAUDE.md
```

T1, T3 and T7 have no dependencies and can run in parallel. T5 needs only T3. T9 and T10 are
independent of each other.

## Verification

Every task's regression check is the project's one command:

```bash
./scripts/ci.sh
```

It regenerates the Xcode project — without which a new Swift file is invisible to the build — lints,
builds and runs the suite. Do not hand-write an `xcodebuild` line. A task whose acceptance criteria
name specific tests still runs the whole command, since that is the only runner.

---

### T1: The hook wire model

**Files:** `Sources/App/AgentHookEvent.swift` (new), `Tests/AgentHookEnvelopeTests.swift` (new).

**What it does.** Defines the value types the socket stream decodes into, and nothing else. Pure: no
I/O, no actor, no `import AppKit`.

- `AgentHookEvent`: `hookEventName: String`, `agentId: String?`, `agentType: String?`,
  `toolName: String?`. Decoded from the hook JSON's `hook_event_name`, `agent_id`, `agent_type`,
  `tool_name` (D3, Assumption 6). Every other field in the payload is ignored — decode with an
  explicit `CodingKeys` and read only these four.
- `AgentHookEnvelope`: `surfaceId: String`, `worktreeId: String`, `event: AgentHookEvent`.
- `static func parse(_ data: Data) -> AgentHookEnvelope?`: splits the first two newline-terminated
  lines off the front as the surface id and the worktree id, then JSON-decodes the remainder.
  Returns `nil` when fewer than two lines precede the body, when either id is empty, when the body
  is not an object, or when `hook_event_name` is absent.

**Acceptance criteria.**

- A payload of `"<uuid>\n/Users/x/my repo/.worktrees/a b\n{\"hook_event_name\":\"PreToolUse\",\"tool_name\":\"Bash\"}"`
  parses to that surface id, that worktree id (spaces intact), and an event with
  `hookEventName == "PreToolUse"` and `toolName == "Bash"`.
- A pretty-printed, multi-line JSON body parses identically to its compact form — the split is on
  the first two lines only, never on every newline.
- A body carrying unknown fields (`session_id`, `cwd`, `transcript_path`, `tool_input`,
  `permission_mode`, `turn_id`, `last_assistant_message`) parses and ignores them.
- `parse` returns `nil` for: empty data, one line and no body, two lines and an empty body,
  a non-JSON body, a JSON array body, and a body with no `hook_event_name`.
- `agentId` / `agentType` are `nil` when absent and populated when present.

**Verified by.** `Tests/AgentHookEnvelopeTests.swift`, run through `./scripts/ci.sh`.

---

### T2: The activity state machine

**Files:** `Sources/App/AgentActivityStore.swift` (new), `Tests/AgentActivityStoreTests.swift` (new).

**Depends on:** T1.

**What it does.** The pure rule the monitor is a shell around. A `struct` with no I/O, no actor and
no reference to `TerminalManager` or any view type — the same split as
`TerminalManager.firstTabSource` and `Worktree.visible`.

Types:

- `enum AgentPhase { case idle, working, waiting }` — ordered so `waiting > working > idle` is
  expressible as a rule, not as nested `if`s at the call site.
- `struct AgentSubagent: Identifiable, Equatable { let id: String; var type: String?; var toolName: String? }`
  — `id` is the hook's `agent_id`.
- `struct AgentSurfaceState { var phase: AgentPhase; var leadToolName: String?; var subagents: [String: AgentSubagent] }`.

API on `AgentActivityStore`:

- `mutating func apply(_ envelope: AgentHookEnvelope)` — the transitions of D18 above, exactly.
  Records the surface's worktree id on every event so the derivations can find it.
- `mutating func retire(surfaceId: String)` — drops the entry **and** remembers the id as retired, so
  a later in-flight event for it is ignored (D20's last sentence).
- `mutating func retire(worktreeId: String)` — drops every surface carrying it.
- `func phase(forWorktree id: String) -> AgentPhase` — D19: `waiting` if any surface carrying that
  worktree id is waiting; else `working` if any is working **or** holds a non-empty roster; else
  `idle`.
- `func subagents(forWorktree id: String) -> [AgentSubagent]` — every live subagent across that
  worktree's surfaces, in a deterministic order (sort by `id`) so the sidebar does not reshuffle.
- `func leadToolName(forSurface id: String) -> String?` — what the tab chip reads.

**Acceptance criteria.**

- `UserPromptSubmit` → `working`; the same surface's `Stop` → `idle`.
- `PreToolUse` with no `agent_id` sets `leadToolName`; the matching `PostToolUse` clears it and the
  phase stays `working`.
- `PreToolUse` carrying an `agent_id` sets that subagent's tool and leaves `leadToolName` alone; the
  matching `PostToolUse` clears the subagent's tool, not the lead's.
- `PermissionRequest` → `waiting` with the tool recorded; a following `PostToolUse` or
  `UserPromptSubmit` returns it to `working`.
- `SubagentStart` adds a row; its `SubagentStop` removes it; a `Stop` with two subagents still open
  clears both.
- `SessionStart` on a surface that was mid-work resets it to `idle` with an empty roster.
- `SessionEnd` drops the surface entirely — its worktree reads `idle` if no sibling surface is busy.
- An event for a surface retired by `retire(surfaceId:)` changes nothing.
- Two surfaces on **different** worktrees produce independent phases and rosters; two surfaces on
  the **same** worktree combine by the precedence rule (one waiting + one working → `waiting`).
- A surface whose id was never seen before but whose worktree id is known still lights that
  worktree (D6) — there is no registration step.
- A surface that is `idle` but holds a live subagent makes its worktree read `working`.
- `subagents(forWorktree:)` returns a stable order across repeated calls.
- No timer, no `Date`, no expiry anywhere in the file.

**Verified by.** `Tests/AgentActivityStoreTests.swift` — one test per bullet, driving envelopes
built in-process through `AgentHookEnvelope.parse` so the wire format is exercised too. Run through
`./scripts/ci.sh`.

---

### T3: The hook script, the `~/.clearway` layout, and the pure settings merge

**Files:** `Sources/App/AgentHookScript.swift` (new), `Sources/App/AgentHookSettings.swift` (new),
`Tests/AgentHookSettingsTests.swift` (new).

**What it does.** Two pure files: the text and paths Clearway installs, and the merge that puts them
into a decoded JSON object. No file I/O in either — T4 owns that.

`AgentHookScript`:

- `clearwayDir` = `~/.clearway`, `hooksDir` = `<clearwayDir>/hooks`,
  `scriptPath` = `<hooksDir>/clearway-hook.sh`, `socketPath` = `<clearwayDir>/hook.sock`.
- `dirMode: 0o700`, `scriptMode: 0o755`.
- `body: String` — the forwarder, five lines of `/bin/sh`:

  ```sh
  #!/bin/sh
  [ -n "$CLEARWAY_SURFACE_ID" ] || exit 0
  [ -S "$CLEARWAY_HOOK_SOCKET" ] || exit 0
  printf '%s\n%s\n' "$CLEARWAY_SURFACE_ID" "$CLEARWAY_WORKTREE_ID" | cat - | /usr/bin/nc -U -w 1 "$CLEARWAY_HOOK_SOCKET" >/dev/null 2>&1
  exit 0
  ```

  The pipeline must forward the preamble **and** the hook JSON arriving on this script's stdin, in
  that order, and must exit 0 unconditionally so no hook can ever block or deny anything. Use
  `/usr/bin/nc` by absolute path and **never** `-N` (D2). Spell the exact pipeline however is
  correct — `{ printf …; cat; } | /usr/bin/nc …` is the straightforward form — but keep the three
  guards and the unconditional `exit 0`.
- `command: String` — what goes in the hook entry: `"$HOME"/.clearway/hooks/clearway-hook.sh`, the
  spelling both agents resolve because a `command` with no `args` runs through a shell
  (Assumption 7).
- `installedEvents: [String]` — the nine of D4, in a fixed order.
- `AgentHookIdentity.environment(surfaceId: UUID, worktreeId: String?) -> [(key: String, value: String)]`
  — `CLEARWAY_SURFACE_ID`, `CLEARWAY_WORKTREE_ID` (omitted when `worktreeId` is nil),
  `CLEARWAY_HOOK_SOCKET`. This is the provider `Ghostty.SurfaceView` will call (see Plan-level
  elaborations).

`AgentHookSettings` — pure functions over `[String: Any]` (what `JSONSerialization` hands back), the
same shape for both agents' files:

- `static func install(into settings: [String: Any]) -> [String: Any]` — for each of
  `installedEvents`, ensure `settings["hooks"][event]` contains a group `["hooks": [["type": "command", "command": AgentHookScript.command]]]`
  with **no** `matcher` key (D12); remove any pre-existing Clearway entry first so the result is
  idempotent.
- `static func uninstall(from settings: [String: Any]) -> [String: Any]` — remove every recognised
  Clearway entry (D11), then collapse: a group whose `hooks` array is now empty is removed; an event
  array that is now empty is removed; a `hooks` object that is now empty is removed.
- `static func isClearwayEntry(_ entry: Any) -> Bool` — `type == "command"` and `command` contains
  `/.clearway/hooks/clearway-hook.sh`.

**Acceptance criteria.**

- `install` into `[:]` produces exactly nine event keys, each with one group, each group's single
  hook `{"type":"command","command":<AgentHookScript.command>}`, and **no** `matcher` key anywhere.
- `install` is idempotent: `install(install(x))` equals `install(x)` for an empty file, a file with
  user hooks, and a file already carrying a Clearway block.
- `install` into a settings object holding unrelated top-level keys and a user's own
  `hooks.PreToolUse` group leaves both untouched and appends Clearway's group beside the user's.
- `uninstall(install(x))` equals `x` for: `[:]`, a file with only user hooks, and a file with user
  hooks on the same events Clearway installs.
- `uninstall` on a file whose only hook was Clearway's leaves **no** `hooks` key at all — the
  emptied group, the emptied event array and the emptied `hooks` object are each removed.
- `uninstall` leaves a user's `{"type":"command","command":"~/bin/my-hook.sh"}` and a
  non-`command`-type entry in place.
- A hand-written Clearway entry that carries an extra `matcher` or a different quoting of the same
  script path is still recognised and removed (the rule is substring containment, not equality).
- `AgentHookIdentity.environment` returns three pairs for a non-nil worktree id and two for nil.

**Verified by.** `Tests/AgentHookSettingsTests.swift`, run through `./scripts/ci.sh`.

---

### T4: The installer — the file side

**Files:** `Sources/App/AgentHookInstaller.swift` (new).

**Depends on:** T3.

**What it does.** Everything T3 refuses to do: touch the disk. `nonisolated` throughout; it is
called from the monitor but does no UI work.

- `static func install()` / `static func uninstall()`.
- Creates `~/.clearway` at `0o700` and `~/.clearway/hooks` at `0o700`, writes `scriptPath` with
  `AgentHookScript.body` at `0o755`, rewriting only when the on-disk bytes differ.
- For `~/.claude/settings.json`: read; if absent, treat as `[:]`; if present but not parseable as a
  JSON **object**, write nothing and log through `Ghostty.logger` (D14) and return. Apply
  `AgentHookSettings.install`/`uninstall`. Re-serialise with
  `[.prettyPrinted, .sortedKeys]`. If the bytes equal what is on disk, write nothing. Otherwise: if
  `settings.json.clearway-backup` does not already exist, copy the current file to it first (the
  one-time backup of D13), then write atomically.
- For `~/.codex/hooks.json`: identical, but **only when `~/.codex` exists as a directory**. Clearway
  never creates it (D15). An absent `hooks.json` inside an existing `~/.codex` is created.
- Logs one line per file actually written, through `Ghostty.logger`.

**Acceptance criteria.**

- Running `install()` twice in a row writes the settings file at most once — the second call finds
  identical bytes and is a no-op. This is what makes D10's "no version counter" work.
- A settings file that is valid JSON but a top-level array, or that is not JSON at all, is left
  byte-identical and the failure is logged; `install()` still returns without throwing.
- With `~/.codex` absent, no `~/.codex` directory and no `hooks.json` appear.
- The backup is taken before the first modification and never overwritten afterwards.
- Both files are written atomically (`Data.write(to:options: .atomic)`), never truncated in place.

**Verified by.** Not unit-tested directly — the paths are absolute under `$HOME` and a test that
rewrote the developer's real `~/.claude/settings.json` would be worse than no test. The pure half is
already covered by T3's tests; this task's criteria are verified by reading the code against them and
by the operator's by-hand check listed in the spec's success criteria. `./scripts/ci.sh` must still
be green (this file compiles and lints).

> If a build agent wants coverage here, the only acceptable shape is to make the two file paths
> injectable parameters defaulting to the real ones and drive a temp directory. Do that only if it
> costs no extra indirection at the call sites; do not invent a protocol.

---

### T5: Surface identity

**Files:** `Sources/Ghostty/Ghostty.SurfaceView.swift`, `Sources/App/TerminalManager.swift`,
`Sources/App/TerminalManager+TaskTerminals.swift`, `Tests/AgentHookIdentityTests.swift` (new).

**Depends on:** T3 (for `AgentHookIdentity`), T1 (for the round-trip test).

**What it does.** Stamps every surface that can host an agent with its identity, and gives the app a
way to retire a surface id.

`Ghostty.SurfaceView`:

- `init` gains `worktreeId: String? = nil` as its last parameter. The view gains
  `let surfaceId = UUID()` and `let worktreeId: String?`, stored beside `initialWorkingDirectory`.
- `nonisolated static var agentEnvironment: (UUID, String?) -> [(key: String, value: String)] = { _, _ in [] }`
  — the process-scoped provider, wired in T8. Keeps `Sources/Ghostty` free of App types.
- `init` calls the provider, `strdup`s each key and value into a `[ghostty_env_var_s]`, sets
  `config.env_vars` and `config.env_var_count`, and `free`s them after `ghostty_surface_new`
  returns. Zig dupes both strings into the surface config's arena (Assumption 2), so they need to
  live only across that call. Leave the existing nested `withCString` for `working_directory` and
  `command` exactly as it is.

`TerminalManager`:

- Pass `worktreeId:` at the four construction sites — the pane secondary in `pane(for:)`, both
  surfaces in `appendTab` (the tab and the cold-pane secondary), and the respawn in
  `replaceSurface`. `replaceSurface` passes the **dead surface's stored `worktreeId`**, not a
  recomputed one (D9).
- `nonisolated(unsafe) static var retireSurface: (UUID) -> Void = { _ in }` — the D27 callback,
  wired once in T8. Call it for every surface being dropped from `removeSurface`,
  `closeWorktree`, `cleanupState(for:)`'s pane teardown and `replaceSurface`'s dead secondary.
  Never reconcile against a list of live surfaces.

`TerminalManager+TaskTerminals`:

- `taskSurface(for:app:projectPath:)` and `openTaskTerminal(…)` pass `worktreeId: projectPath` —
  that parameter already carries the task terminal's working directory, which is the main worktree's
  path (`WorkTaskCoordinator.planWorkingDirectory`), and a worktree id **is** its path
  (Assumption 8).
- `closeTaskTerminal` retires the surface it removes.

**Acceptance criteria.**

- Every `Ghostty.SurfaceView(...)` call in `TerminalManager.swift` and
  `TerminalManager+TaskTerminals.swift` passes a `worktreeId`. The two that must **not** —
  `ContentView.swift:710` (before-remove hook sheet) and `DebugTerminalSheet.swift:47` — are
  untouched and still compile on the defaulted parameter (D7).
- `replaceSurface` copies the dead surface's `worktreeId` rather than deriving one.
- Every path that drops a surface calls `TerminalManager.retireSurface` with its id.
- No `@convention(c)` or `@convention(block)` literal is introduced anywhere in this task, and no
  `DispatchSource` is created outside `makeWatcher`.
- `./scripts/ci.sh` is green.

**Verified by.** `Tests/AgentHookIdentityTests.swift`, the round trip that needs no `ghostty_app_t`:
take `AgentHookIdentity.environment(surfaceId:worktreeId:)`, build the two-line preamble from the
values it returns exactly as the script's `printf` would, append a hook JSON body, and assert
`AgentHookEnvelope.parse` recovers the same surface id and worktree id — including for a worktree
path containing spaces. Plus a compile-time check: the construction sites are enumerated by
`grep -n "Ghostty.SurfaceView(" Sources/` and read against the list above.

---

### T6: The monitor — socket, roster, install/uninstall

**Files:** `Sources/App/AgentActivityMonitor.swift` (new), `Tests/RAIICleanupTests.swift`.

**Depends on:** T2, T4, T7.

**What it does.** The one object that owns the socket, holds an `AgentActivityStore`, and publishes
what the views read.

- `@MainActor final class AgentActivityMonitor: ObservableObject`.
- `@Published private(set) var worktreePhases: [String: AgentPhase]`,
  `@Published private(set) var worktreeSubagents: [String: [AgentSubagent]]`,
  `@Published private(set) var surfaceToolNames: [String: String]` — derived from the store after
  every applied event, republished only when the derived value actually changed, so a per-tool-call
  event storm does not re-render the sidebar on every event.
- `func setEnabled(_ enabled: Bool)` — the whole toggle behaviour (D17): on, it calls
  `AgentHookInstaller.install()` and opens the listener; off, it closes the listener, clears the
  published state and calls `AgentHookInstaller.uninstall()`. Idempotent.
- `func retire(surfaceId: UUID)` — forwards to the store; this is what `TerminalManager.retireSurface`
  is wired to.

Socket plumbing — read CLAUDE.md's Concurrency section before writing a line of it:

- Unlink any stale `hook.sock`, `bind`, `listen`, then a `DispatchSource.makeReadSource` on the
  listening descriptor whose handler `accept`s and reads one connection to EOF.
- **Every** `DispatchSource` in this file is built by a `nonisolated static` factory that takes its
  handler as a plain `() -> Void`, and `setEventHandler` / `setCancelHandler` are never called from
  an isolated method. This is the rule that cost v1.9.3 a shipped crash. Prefer extending
  `FileWatchers`/`ClaudeSessionFiles` with a `makeReadSource` sibling over writing a second door, or
  put the factory on `AgentActivityMonitor` itself as `nonisolated static`.
- The accept/read handler hops to the main actor with `Task { @MainActor in }`, never
  `MainActor.assumeIsolated` — a `DispatchSource` callback is exactly the path CLAUDE.md forbids it
  on.
- Cleanup is RAII: the source lives in a holder whose own `deinit` cancels it, so the
  `nonisolated deinit` reads nothing isolated. `ScheduledWork` and `ClaudeActivityMonitor`'s
  `WatcherState` are the precedents.
- No timer anywhere. No expiry. No polling.

**Acceptance criteria.**

- `AgentActivityMonitor` contains no `DispatchWorkItem`, no `asyncAfter`, no `Timer` and no `Date`.
- No `setEventHandler` or `setCancelHandler` call appears inside an actor-isolated method in this
  file.
- `setEnabled(false)` after `setEnabled(true)` leaves no bound socket and no published state.
- A monitor built and enabled inside an `autoreleasepool` deallocates when the pool drains.
- `./scripts/ci.sh` is green.

**Verified by.** A new `testAgentActivityMonitorDeallocates` in `Tests/RAIICleanupTests.swift`,
modelled on the existing `testClaudeActivityMonitorDeallocates` (which stays until T11): build the
monitor, enable it, let the pool drain, assert the weak reference is nil — proving the read source is
cancelled. The no-timer and no-isolated-handler criteria are verified by reading the file; they are
structural, not behavioural, and a test cannot pin them.

---

### T7: The Settings toggle

**Files:** `Sources/App/SettingsManager.swift`, `Sources/App/SettingsView.swift`,
`Tests/SettingsManagerTests.swift`.

**What it does.** Adds `clearway.agentHooksEnabled` and the Appearance row that drives it.

- `SettingsKey.agentHooksEnabled = "clearway.agentHooksEnabled"`.
- `@Published var agentHooksEnabled: Bool` with the same `didSet { defaults.set(…) }` shape as
  `showDetachedWorktrees`, read in `init` as
  `defaults.object(forKey:) as? Bool ?? true` — default **on** (D17).
- In `SettingsView`'s `Section("Appearance")`, below `Toggle("Show detached worktrees", …)`:
  `Toggle("Show agent activity", isOn: $settings.agentHooksEnabled)` plus **one** line of secondary
  copy naming the Codex trust step — the deliberate exception to CLAUDE.md's no-helper-text rule
  (D16). One sentence, e.g. "Codex requires running `/hooks` once to trust the hooks Clearway
  installs." Nothing else: no subtitle for the toggle itself, no explanation of what the dot means.

**Acceptance criteria.**

- A `SettingsManager` built over a fresh `UserDefaults` suite reads `agentHooksEnabled == true`.
- Setting it to `false` persists; a new manager over the same suite reads `false`.
- The Appearance section carries exactly one new toggle and exactly one new line of copy.

**Verified by.** Two cases added to `Tests/SettingsManagerTests.swift` following the file's existing
suite-based pattern, run through `./scripts/ci.sh`.

---

### T8: App-level wiring

**Files:** `Sources/App/ClearwayApp.swift`, `Sources/App/ProjectWindow.swift`,
`Sources/App/ContentView.swift`.

**Depends on:** T5, T6, T7.

**What it does.** Makes one monitor for the process, wires the two process-scoped providers, and
removes the per-window monitor's plumbing.

`ClearwayApp`:

- `@StateObject private var agentActivity = AgentActivityMonitor()`, injected with
  `.environmentObject(agentActivity)` beside `caffeine` and `portMonitor`.
- In `init()`, beside the existing `Ghostty.SurfaceView.claimsShortcut = AppKeyboardShortcuts.claims`
  line and for the same reason: `Ghostty.SurfaceView.agentEnvironment = AgentHookIdentity.environment`
  and `TerminalManager.retireSurface = { … }` forwarding to the monitor. Both are process-scoped
  statics, so they belong here and nowhere else.
- Call `agentActivity.setEnabled(settings.agentHooksEnabled)` once the scene is up, and again
  whenever the setting changes — an `.onChange(of: settings.agentHooksEnabled)` on the window
  group's content is the least machinery. `setEnabled` is idempotent, so a duplicate call is
  harmless.

`ProjectWindow`: delete the `@StateObject private var claudeActivityMonitor` and its
`.environmentObject(claudeActivityMonitor)`.

`ContentView`: delete `@EnvironmentObject private var claudeActivityMonitor` and both
`claudeActivityMonitor.updateWorktrees(…)` calls (`:340` and `:403`). Add nothing — the file sits at
SwiftLint's `file_length` limit.

**Acceptance criteria.**

- `ClaudeActivityMonitor` is referenced from exactly two files after this task —
  `ClaudeActivityMonitor.swift`, `SidebarView.swift` — plus `RAIICleanupTests.swift`. (T9 and T11
  take the rest.)
- The `retireSurface` closure captures the monitor weakly or reaches it through a stored weak
  reference; it must not keep the app's monitor alive past teardown or capture a window.
- `ContentView.swift` does not grow — `swiftlint lint --quiet` reports no new `file_length`
  violation.
- `./scripts/ci.sh` is green.

**Verified by.** `./scripts/ci.sh`; the reference count by
`grep -rn "ClaudeActivityMonitor\|claudeActivityMonitor" Sources/ Tests/`.

---

### T9: The sidebar dot and the subagent rows

**Files:** `Sources/App/SidebarView.swift`, `Sources/App/WorktreeRow.swift`.

**Depends on:** T8.

**What it does.** Renders the three-way phase and the roster.

`WorktreeRow`:

- `var isWorking: Bool` becomes `var phase: AgentPhase = .idle`. The dot `Group` becomes, in order:
  `.waiting` → a static 7 pt `Circle().fill(.purple)` with `.help("Waiting for permission")`, no
  pulse; `.working` → the existing pulsing orange circle with `.help("Agent is working")` (the
  string stops naming Claude); else `hasNotification` → the existing blue circle with
  `.help("Terminal notification")`. The `.animation(…, value:)` follows `phase`.
- A new `SubagentRow` view in the same file: the agent type as the primary text and the in-flight
  tool name as a `.font(.subheadline).foregroundStyle(.secondary)` caption when there is one. Text
  only, no icon (D24).

`SidebarView`:

- `@EnvironmentObject private var agentActivity: AgentActivityMonitor` replaces
  `claudeActivityMonitor`.
- `worktreeRowView` computes `let phase = isOpen ? agentActivity.worktreePhases[wt.id] ?? .idle : .idle`
  — `isOpen` stays, `!wt.isMain` **goes** (D23) — and becomes a `@ViewBuilder` returning the worktree
  row followed by one `SubagentRow` per `agentActivity.worktreeSubagents[wt.id]`, each with no
  `.tag`, `.moveDisabled(true)` and `.padding(.leading, SidebarRowMetrics.statusRowIndent + leadingIndent)`.
  All three `ForEach` bodies (`worktreesSection`, `groupSection`, `statusSection`) already go through
  this one function, so emitting the extra rows there covers every section at once.

**Acceptance criteria.**

- The main worktree's row shows the working dot when its surface is working — nothing suppresses it.
- Waiting renders purple and does not pulse; working renders orange and does; a worktree that is
  neither but has a terminal notification renders blue. Precedence is waiting > working >
  notification.
- A closed worktree (`!isOpen`) renders no agent dot regardless of stored phase.
- Subagent rows appear under their worktree in all three sections, are not selectable (no `.tag`),
  cannot be dragged, and are indented to the status-row indent.
- `.onMove` still reorders worktrees correctly with subagent rows present — the move closure indexes
  `rows`, which is unchanged.
- `./scripts/ci.sh` is green.

**Verified by.** `./scripts/ci.sh` plus the store-level tests from T2, which already pin the
precedence rule and the roster contents. Nothing in a SwiftUI body is reachable from XCTest — the
rules that can be tested were lifted into `AgentActivityStore` in T2, and the rendering itself is an
operator by-hand check from the spec's success criteria.

> The spec's "Extra rows inside a reorderable `ForEach`" risk lands here. If drag targeting
> misbehaves, the recorded fallback is to suppress subagent rows while a drag is in progress —
> report it rather than inventing a different shape.

---

### T10: The tool name on the tab chip

**Files:** `Sources/App/MainTerminalTabStrip.swift`.

**Depends on:** T8.

**What it does.** Shows the lead agent's in-flight tool beside the surface title, and only while a
tool is in flight (D28).

- `TerminalTabChip` gains the tool name and passes it to `TabChip`, which renders it as secondary
  text after the title — smaller, `.secondary`, `lineLimit(1)`, and absent entirely when nil so the
  chip does not reserve space for it.
- The value comes from `agentActivity.surfaceToolNames[surface.surfaceId.uuidString]`. Read it in
  `MainTerminalTabStrip` (which already holds `@EnvironmentObject`s) and pass it down, so
  `TerminalTabChip` keeps observing only its own surface — the file's existing note explains why
  that scoping matters.

**Acceptance criteria.**

- A tab with no agent, or an agent between tool calls, renders exactly as it does today — same
  width, same layout.
- A tab whose lead agent is mid-tool renders the tool name after the title.
- The active chip's accent background and the hover close button are unchanged.
- `./scripts/ci.sh` is green.

**Verified by.** `./scripts/ci.sh`; the underlying rule (`leadToolName(forSurface:)`) is already
pinned by T2's tests. The rendering is an operator by-hand check.

---

### T11: Retire `ClaudeActivityMonitor`

**Files:** `Sources/App/ClaudeActivityMonitor.swift` (deleted),
`Tests/RAIICleanupTests.swift`.

**Depends on:** T9.

**What it does.** Deletes the mtime heuristic now that nothing reads it, and drops its RAII test —
`testAgentActivityMonitorDeallocates` from T6 already covers the replacement.

**Acceptance criteria.**

- `grep -rn "ClaudeActivityMonitor\|claudeActivityMonitor\|workingWorktreeIds" Sources/ Tests/`
  returns nothing.
- No timer-based expiry survives anywhere in the codebase's activity path — the 8-second
  `expirySeconds` constant is gone with the file.
- `./scripts/ci.sh` is green. `xcodegen generate` inside it is what makes the deletion take effect;
  a hand-written `xcodebuild` would still compile the removed file.

**Verified by.** The grep above, then `./scripts/ci.sh`.

---

### T12: Rename `ClaudeSessionFiles` to `FileWatchers`

**Files:** `Sources/App/ClaudeSessionFiles.swift` → `Sources/App/FileWatchers.swift`,
`Sources/App/TodoManager.swift`, `Sources/App/PromptManager.swift`,
`Sources/App/WorkTaskManager.swift`.

**Depends on:** T11.

**What it does.** Keeps CLAUDE.md's single `DispatchSource` door and drops the Claude relationship
the name claims but the type no longer has (D26).

- `git mv Sources/App/ClaudeSessionFiles.swift Sources/App/FileWatchers.swift` so history follows.
- Rename `enum ClaudeSessionFiles` to `enum FileWatchers`. Keep `makeWatcher` and
  `defaultWatchMask` and their doc comments verbatim — the `nonisolated` comment on `makeWatcher` is
  load-bearing documentation. Rewrite the type's own doc comment to say what it now is.
- Delete `claudeDir`, `encodePathForClaude`, `projectsParentDir` and
  `projectDir(forWorktreePath:)` — T11 removed their only caller.
- Update the four call sites in `TodoManager.swift:137`, `PromptManager.swift:144` and
  `WorkTaskManager.swift:374,452`.
- Leave the `@preconcurrency import Dispatch` on line 1 alone. CLAUDE.md names it as the one
  remaining instance and as predating the RAII holder; removing it is a separate change.

**Acceptance criteria.**

- `grep -rn "ClaudeSessionFiles\|encodePathForClaude\|projectsParentDir" Sources/ Tests/` returns
  nothing.
- `FileWatchers.makeWatcher` is still the only `DispatchSource.makeFileSystemObjectSource` call in
  the codebase.
- `./scripts/ci.sh` is green.

**Verified by.** The greps above, then `./scripts/ci.sh`.

---

### T13: Document the pipeline in CLAUDE.md

**Files:** `CLAUDE.md`.

**Depends on:** T12.

**What it does.** Records what a future reader cannot recover from the code.

- A bullet under `Sources/App/` for the hook pipeline: the six new files and what each owns, the
  two-line framing, why `nc` and not `curl`, why the transport is a Unix socket and not a port, that
  the managed block is reconciled by content rather than versioned, that Codex hooks need the
  user's `/hooks` trust step, and that the one line of Settings copy is the deliberate exception to
  the no-helper-text rule.
- The `Ghostty.SurfaceView` bullet gains the `agentEnvironment` provider beside `claimsShortcut`,
  with the same reason: process-scoped, not per-window, and it keeps `Sources/Ghostty` free of App
  types.
- The Concurrency section's `DispatchSource` rule: `ClaudeSessionFiles.makeWatcher` becomes
  `FileWatchers.makeWatcher`, and the `@preconcurrency import Dispatch` sentence follows the file to
  `FileWatchers.swift:1`.
- The sidebar-dot sentence: the dot is now derived from agent lifecycle events with no timer and no
  expiry, main is no longer suppressed, and waiting-on-permission is purple because orange, blue,
  red, green and yellow are each already spoken for.

**Acceptance criteria.**

- Every sentence added is one a reader could not get from the code — no restating a function
  signature, no comment-shaped prose.
- No stale `ClaudeSessionFiles` or `ClaudeActivityMonitor` reference survives in the file.
- `./scripts/ci.sh` is green (it lints and builds; the doc change is inert to it, which is the
  point — run it anyway so the task ends on a green tree).

**Verified by.** `grep -n "ClaudeSessionFiles\|ClaudeActivityMonitor" CLAUDE.md` returns nothing,
then `./scripts/ci.sh`.

## Risks carried from the spec

| Risk | Lands in | Mitigation |
| --- | --- | --- |
| Codex hooks do nothing until trusted | T7 | One line of Settings copy. There is no API to pre-trust. |
| A fork per tool call on both sides of every call | T3 | Accepted. If agents measurably slow, drop `PreToolUse`/`PostToolUse` — which also drops the tool readout. |
| `settings.json` key order changes once | T4 | Sorted, deterministic output afterwards; one backup before the first write. |
| Extra rows inside a reorderable `ForEach` | T9 | Fallback is to suppress subagent rows during a drag. Report, do not redesign. |
| A `SIGKILL`ed session pins a dot | T2 | Accepted by design — no timers. Clears on the next relaunch. |
| A shadowed `nc` breaks forwarding silently | T3 | `/usr/bin/nc` by absolute path. |

## Build log

### T1: The hook wire model

**What landed.**

| File | State |
| --- | --- |
| `Sources/App/AgentHookEvent.swift` | New. `AgentHookEvent` (`hookEventName`, `agentId`, `agentType`, `toolName`, explicit snake_case `CodingKeys`) and `AgentHookEnvelope` (`surfaceId`, `worktreeId`, `event`) with `static func parse(_ data: Data) -> AgentHookEnvelope?`. Pure: `import Foundation` only. |
| `Tests/AgentHookEnvelopeTests.swift` | New. 14 cases covering both ids, the compact/pretty-printed equivalence, unknown-field tolerance, optional subagent fields, and the six refusals plus the two empty-id refusals. |

**Evidence.** The parse rule was first implemented the careless way — decode the whole payload to a
`String` and `split(separator: "\n")`, taking `lines[2]` as the body — and `./scripts/ci.sh` was run
against it. The discriminating tests went red:

```
Test Suite 'AgentHookEnvelopeTests' started at 2026-09-20 18:48:43.193.
    ✖ testPrettyPrintedBodyParsesIdenticallyToItsCompactForm, XCTAssertNotNil failed
    ✖ testPrettyPrintedBodyParsesIdenticallyToItsCompactForm, XCTAssertEqual failed: ("nil") is not equal to ("Optional(Clearway.AgentHookEnvelope(surfaceId: "8F1D4C0A-5B2E-4A77-9C31-6E0F2A8D1B44", worktreeId: "/Users/x/my repo/.worktrees/a b", event: Clearway.AgentHookEvent(hookEventName: "PreToolUse", agentId: nil, agentType: nil, toolName: Optional("Bash"))))")
    ✖ testUnknownFieldsAreIgnored, XCTAssertEqual failed: ("nil") is not equal to ("Optional("PostToolUse")")
    ✖ testUnknownFieldsAreIgnored, XCTAssertEqual failed: ("nil") is not equal to ("Optional("Edit")")
Executed 690 tests, with 4 failures (0 unexpected) in 108.445 (108.672) seconds
```

That proves the tests discriminate: a body arriving pretty-printed, which Assumption 1's probe
observed on the wire, is truncated to `{` by any split that treats every newline as a delimiter.
The shipped `parse` takes the first two newlines off the byte buffer with `Data.firstIndex(of:)` and
hands the untouched remainder to `JSONDecoder`.

**Deviations from the plan.** None. The plan named `AgentHookEvent.swift` and
`AgentHookEnvelopeTests.swift`; both carry exactly the types and the acceptance criteria listed.

Two details the plan left to the implementation, recorded so T2 and T6 can rely on them:

- `AgentHookEvent` is `Decodable`, not `Codable` — nothing encodes an event, and the envelope is
  never written back to the socket.
- Both types are `Equatable`, so the compact/pretty equivalence is one assertion rather than four,
  and T2's transition tests can compare whole values.
- The JSON body slice is re-wrapped with `Data(body)` before decoding rather than passed as a
  `Data.SubSequence` with a non-zero `startIndex`.
- The empty-id refusals are two of the tests: the plan's acceptance list names the rule ("when
  either id is empty") without listing the case.

**Gate.** `./scripts/ci.sh` — green. `Executed 690 tests, with 0 failures (0 unexpected) in 108.986
seconds`, then `==> CI passed.`

### T2: The activity state machine

**What landed.**

| File | State |
| --- | --- |
| `Sources/App/AgentActivityStore.swift` | New. `AgentPhase` (`Comparable` over `idle < working < waiting`), `AgentSubagent`, `AgentSurfaceState`, and `AgentActivityStore` with `apply`, both `retire` overloads, `phase(forWorktree:)`, `subagents(forWorktree:)` and `leadToolName(forSurface:)`. Pure: `import Foundation` only. |
| `Tests/AgentActivityStoreTests.swift` | New. 17 cases, one per acceptance bullet, every event driven in through `AgentHookEnvelope.parse`. |

**Evidence.** The three rules most easily got wrong were first implemented the careless way and
`./scripts/ci.sh` run against them: `effectivePhase` returning the stored phase alone, `Stop`
clearing only the lead tool, and `PostToolUse` clearing `leadToolName` unconditionally. All four
discriminating assertions went red:

```
    ✖ testIdleSurfaceHoldingALiveSubagentReadsAsWorking, XCTAssertEqual failed: ("idle") is not equal to ("working")
    ✖ testStopClearsEveryOpenSubagent, XCTAssertTrue failed
    ✖ testSubagentToolTrafficLeavesTheLeadToolAlone, XCTAssertEqual failed: ("nil") is not equal to ("Optional("Edit")")
    ✖ testSubagentToolTrafficLeavesTheLeadToolAlone, XCTAssertEqual failed: ("[Optional("Grep")]") is not equal to ("[nil]")
Executed 707 tests, with 4 failures (0 unexpected) in 106.987 (107.210) seconds
```

That proves the tests discriminate: a roster-blind derivation goes dark the moment the lead is
between turns while subagents run, a `Stop` that does not sweep pins a row on any missed
`SubagentStop`, and a `PostToolUse` carrying an `agent_id` blanks the lead's tab label while the
lead is still working. The shipped rules are the three comments in the file.

**Deviations from the plan.**

- `AgentSurfaceState` carries a fourth field, `worktreeId`, rather than the plan's three. The plan
  says the store "records the surface's worktree id on every event"; a parallel
  `[surfaceId: worktreeId]` dictionary would have to be pruned in step with `surfaces` in three
  places (`SessionEnd` and both `retire`s), and a drift between the two is exactly the bug that
  strands a lit dot. On the state it is unrepresentable.
- `retire(worktreeId:)` calls `retire(surfaceId:)` per surface, so a worktree teardown also
  remembers its surface ids as retired. The plan only requires that it "drops every surface carrying
  it", but an in-flight hook for a torn-down pane would otherwise re-light a worktree the user just
  closed. It cannot interfere with D6: an agent surviving a relaunch arrives with a surface id this
  process never minted, not a retired one.

Two details the plan left open, recorded for T6 and T9:

- `PermissionRequest` records its tool exactly as `PreToolUse` does — to the subagent when the event
  carries an `agent_id`, to the lead otherwise — so the `PostToolUse` that follows clears the same
  slot. D20 says only "recording `tool_name`".
- `SubagentStart` does not touch `phase`. It does not need to: `effectivePhase` lifts any surface
  holding a non-empty roster to working, which is the acceptance criterion "a surface that is idle
  but holds a live subagent makes its worktree read working".
- `surfaces` is `private`. The monitor and the views read through the three derivations only.
- No clock: `grep -nE "Date|Timer|asyncAfter|sleep|expir|ScheduledWork|DispatchQueue"` over the file
  matches one word, in the comment saying nothing expires.

**Gate.** `./scripts/ci.sh` — green. `Executed 707 tests, with 0 failures (0 unexpected) in 109.536
seconds`, then `==> CI passed.`

### T3: The hook script, the `~/.clearway` layout, and the pure settings merge

**What landed.**

| File | State |
| --- | --- |
| `Sources/App/AgentHookScript.swift` | New. `AgentHookScript` — the four paths, `dirMode`/`scriptMode`, `scriptPathMarker`, `command`, `body`, `installedEvents` — and `AgentHookIdentity` with the three env-var name constants and `environment(surfaceId:worktreeId:)`. Pure: `import Foundation` only. |
| `Sources/App/AgentHookSettings.swift` | New. `install(into:)`, `uninstall(from:)`, `isClearwayEntry(_:)` over `[String: Any]`, plus the private `withoutClearwayEntries` that drives the collapse. Pure. |
| `Tests/AgentHookSettingsTests.swift` | New. 10 cases: the nine installed events with no `matcher`, idempotency over three starting shapes, unrelated keys and user groups preserved, the round trip over three shapes, the collapse, foreign entries left alone, hand-edited recognition, the recognition refusals, the identity pairs, and the forwarder's guards and transport. |

**Evidence.** The three rules most easily got wrong were implemented the careless way first —
recognition by **equality** with `AgentHookScript.command`, an `install` that appends without
removing Clearway's own entries first, and an `uninstall` that filters entries but collapses no
container — and `./scripts/ci.sh` was run against that. Five of the ten cases went red; the other
five passed:

```
Test Suite 'AgentHookSettingsTests' started at 2026-09-20 19:07:25.447.
    ✖ testHandWrittenClearwayEntriesAreStillRecognised, XCTAssertTrue failed
    ✖ testInstallIsIdempotentForEveryStartingShape, XCTAssertEqual failed: ("{
    ✖ testInstallIsIdempotentForEveryStartingShape, XCTAssertEqual failed: ("{
    ✖ testInstallIsIdempotentForEveryStartingShape, XCTAssertEqual failed: ("{
    ✖ testUninstallLeavesEntriesItDoesNotOwn, XCTAssertEqual failed: ("{
    ✖ testUninstallRemovesEveryContainerItEmpties, XCTAssertNil failed: "["PostToolUse": [["hooks": []]], "SubagentStop": [["hooks": []]], "SubagentStart": [["hooks": []]], "PreToolUse": [["hooks": []]], "Stop": [["hooks": []]], "SessionEnd": [["hooks": []]], "UserPromptSubmit": [["hooks": []]], "PermissionRequest": [["hooks": []]], "SessionStart": [["hooks": []]]]"
    ✖ testUninstallRemovesEveryContainerItEmpties, XCTAssertTrue failed
Executed 10 tests, with 10 failures (0 unexpected) in 0.089 (0.090) seconds
```

That quoted `XCTAssertNil` value **is** the defect the collapse rule exists to prevent: an uninstall
that removes only the entries leaves nine event keys each holding an empty group, so the file keeps
a visible trace of a feature the user turned off — and the next `install` would append beside them.
The equality failure is the second: a user who hand-edits the entry, or an older spelling of the
same path, leaves a hook forwarding to a socket nothing is listening on.

**The forwarder was verified on the wire**, since nothing compiles shell text. Probe in the
scratchpad only (`clearway-hook.sh` extracted verbatim from the Swift raw-string literal, `srv.py` an
`AF_UNIX` `SOCK_STREAM` server); nothing was written into the repo:

```
RECV<<<8F1D4C0A-5B2E-4A77-9C31-6E0F2A8D1B44
/Users/x/my repo/.worktrees/a b
{
  "hook_event_name": "PreToolUse",
  "tool_name": "Bash"
}>>>
send exit=0
elapsed=0.027s
unset-surface exit=0
unset-worktree exit=0
missing-socket exit=0
```

Both preamble lines arrive intact including the spaces in the path, the pretty-printed body is
untouched, the server's `recv` loop sees EOF with no shutdown flag, and each of the three guards
exits 0 without connecting.

**Deviations from the plan.**

- **A third guard, `[ -n "$CLEARWAY_WORKTREE_ID" ] || exit 0`.** The plan's printed script carries
  two but its prose says "keep the three guards". `AgentHookIdentity.environment` returns two pairs
  for a nil worktree id, so a surface Decision 7 excludes still carries `CLEARWAY_SURFACE_ID` and
  would fork `nc` for a payload whose empty second line `AgentHookEnvelope.parse` refuses anyway.
  The guard makes D7's "invisible" hold at the script rather than incidentally at the parser, and
  saves a round trip per tool call on any such surface.
- **`AgentHookScript.command` is built from `scriptPathMarker`**, not written out twice. The marker
  is the recognition substring of D11, so spelling the command independently of it is the one way
  `install` and `uninstall` could stop agreeing on what Clearway owns.
- **`install` skips an event whose existing value it cannot read** rather than overwriting it. The
  plan says only "ensure `settings["hooks"][event]` contains a group". A user's `hooks.Stop` holding
  something other than an array of objects is data Clearway is a guest in — the same reasoning as
  D14's refusal to quarantine an unparseable file.
- **`uninstall` drops a container only when it emptied it.** An event array the user left empty, or
  an empty `hooks` object, is returned untouched, so `uninstall` is a genuine identity on any file
  carrying no Clearway entry. Without that the round-trip criterion would hold only for the three
  shapes the tests name.

Two details the plan left open, recorded for T4 and T5:

- `dirMode`/`scriptMode` are plain `Int` octal literals; T4 wraps them for
  `FileAttributeKey.posixPermissions`.
- The script body is a raw string (`#"""`), so `printf`'s `\n` stays literal. The test asserts the
  body carries all three env-var names, calls `/usr/bin/nc` by absolute path, contains no ` -N` and
  ends with `exit 0` — the `-N` pin matters because macOS reads it as a probe count and a script
  using it fails on every hook with no diagnostic.
- `AgentHookScript.socketPath` is 37 bytes on this machine, well inside `sun_path`'s 104. The probe
  above had to bind a relative path because the scratchpad's own directory exceeds it; `~/.clearway`
  does not.

**Gate.** `./scripts/ci.sh` — green. `Executed 717 tests, with 0 failures (0 unexpected) in 111.299
seconds`, then `==> CI passed.` `git status --porcelain` before the commit showed only this task's
three new files and the `xcodegen`-regenerated `project.pbxproj`.

---

### T4: The installer — the file side

**What landed.**

| File | State |
| --- | --- |
| `Sources/App/AgentHookInstaller.swift` | New. `install()` / `uninstall()`, the private `installScript()` (dirs at `0o700`, forwarder at `0o755`, rewritten only when the bytes differ), and `mergeAgentSettings(installing:home:)` over both agents' files with the private `merge`, `serialised` and `backUp` under it. |
| `Tests/AgentHookInstallerTests.swift` | New. 9 cases driving the settings half against a temp home: the block and the no-op second call, an absent file created with no backup, the round trip, the two refusals to write, the unreadable file, the one-time backup, and both Codex paths. |

**Evidence.** The three rules that decide *not* to write were implemented the careless way first —
the write gated on `after != onDisk` (bytes) rather than on the two documents, a backup taken on
every modification instead of once, and `createDirectory(withIntermediateDirectories:)` in place of
the gate on the agent's config directory already existing — and `./scripts/ci.sh` was run against
that. Four of the nine cases went red:

```
    ✖ testCodexIsSkippedWhenItsDirectoryIsAbsent, XCTAssertFalse failed - an absent ~/.codex means Codex is not installed, and Clearway never creates it
    ✖ testTheBackupIsTakenOnceAndNeverRefreshed, XCTAssertEqual failed: ("{
    ✖ testUninstallCreatesNoSettingsFileOfItsOwn, XCTAssertFalse failed
    ✖ testUninstallDoesNotRewriteAFileThatNeverCarriedTheBlock, XCTAssertEqual failed: ("243 bytes") is not equal to ("138 bytes")
    ✖ testUninstallDoesNotRewriteAFileThatNeverCarriedTheBlock, XCTAssertFalse failed - nothing was modified, so nothing was backed up
Executed 9 tests, with 5 failures (0 unexpected) in 0.125 (0.127) seconds
```

The `243 bytes` against `138 bytes` **is** the defect the document comparison exists to prevent: an
uninstall on a file that never carried the block re-serialises it sorted and pretty-printed, so every
user who merely toggles the feature off — including one who never turned it on — has their
`settings.json` rewritten to say nothing changed. The backup failure is the second: its
`XCTAssertEqual` printed Clearway's own nine-event block where the user's two-key file should be,
because the second modification had copied the already-installed file over the backup. D13's backup
is the user's only copy of the file as they wrote it, and the careless version destroys it on the
first uninstall.

**Deviations from the plan.**

- **Both agents are gated on their config directory existing, not just Codex.** The plan gates
  `~/.codex` (D15) and says only "if absent, treat as `[:]`" for `~/.claude/settings.json`, which
  leaves the `~/.claude`-absent case to a write that throws and logs on every launch. One rule for
  both — the agent's directory is where Clearway is a guest, and it never creates one — removes the
  special case and applies D15's reasoning where it holds equally: a user with no `~/.claude` has
  never run Claude Code.
- **The no-op test is "the document is already what Clearway wants", not "the bytes match".** The
  plan's criterion is the second call finding identical bytes. Comparing the re-serialised *before*
  and *after* documents is strictly stronger and is what makes the uninstall refusal above possible;
  byte equality alone cannot express it, since the user's own formatting never matches the
  canonical form.
- **A backup that cannot be taken cancels the write.** `backUp` returns `Bool` and `merge` refuses
  on false. The plan says the backup is taken before the first modification; on a failure the
  choice is between rewriting the file with no copy of the original and not installing. The merge is
  acceptable *because* of the backup, so the install is what gives way, and the failure is logged.
- **`uninstall()` leaves the forwarder script on disk.** D17 says the toggle uninstalls the block
  and closes the listener; the script's own first guard makes it a no-op with nothing listening, so
  removing it would only make re-enabling the toggle more work.
- **Coverage was added through the plan's named hatch, narrowed.** `mergeAgentSettings` takes one
  `home: String = NSHomeDirectory()`, so the test drives both agents' files inside a temp root and
  no test can reach the developer's real `~/.claude` or `~/.codex`. `install()` and `uninstall()`
  stay zero-argument, so no call site carries the parameter. The forwarder half is left untested
  rather than made injectable: its paths are `AgentHookScript`'s fixed statics, and pointing a test
  at them would write under the real `~/.clearway`.

**Gate.** `./scripts/ci.sh` — green. `Executed 726 tests, with 0 failures (0 unexpected) in 112.128
seconds`, then `==> CI passed.` `git status --porcelain` before the commit showed only this task's
two new files and the `xcodegen`-regenerated `project.pbxproj`; no `default.profraw`, since nothing
here launched the app.

---

### T5: Surface identity

**What landed.**

| File | State |
| --- | --- |
| `Sources/Ghostty/Ghostty.SurfaceView.swift` | `let surfaceId = UUID()` and `let worktreeId: String?` beside `initialWorkingDirectory`; `init` gains `worktreeId:` as its last defaulted parameter; `static var agentEnvironment` — the process-scoped provider, defaulting to `{ _, _ in [] }`; `init` builds the `[ghostty_env_var_s]` with `strdup` and frees it in a `defer` after `ghostty_surface_new`. |
| `Sources/App/TerminalManager.swift` | `static var retireSurface: (UUID) -> Void` plus the private `retire(_ pane:)` that reports every surface a pane holds. `worktreeId:` passed at all four construction sites; `replaceSurface` copies `deadSurface.worktreeId`. Retirement called from `closeMainTab`, `removeSurface`, `closeWorktree`, and both of `replaceSurface`'s drop paths. |
| `Sources/App/TerminalManager+TaskTerminals.swift` | `worktreeId: projectPath` at both construction sites; retirement from `closeTaskTerminal` and from `openTaskTerminal`'s replaced surface. |
| `Tests/AgentHookIdentityTests.swift` | New. 4 cases: the round trip through the forwarder's `printf`, a worktree path carrying spaces, the no-worktree surface, and the socket pair. |

**Evidence.** The rule the new file pins is D7's: a surface with no worktree carries **no**
`CLEARWAY_WORKTREE_ID` rather than an empty one. It was implemented the careless way —
`pairs.append((key: worktreeIdKey, value: worktreeId ?? ""))` — and `./scripts/ci.sh` run against
that:

```
Test Suite 'AgentHookIdentityTests' started at 2026-09-20 19:31:42.006.
    ✖ testASurfaceWithNoWorktreeSendsNothingTheParserWouldAccept, XCTAssertNil failed: "(key: "CLEARWAY_WORKTREE_ID", value: "")"
Executed 4 tests, with 1 failure (0 unexpected) in 0.049 (0.050) seconds
...
Executed 730 tests, with 3 failures (0 unexpected) in 112.475 (112.611) seconds
```

Only the first of that case's two assertions went red, and the split is the point: the blanked
variant still produces a payload `AgentHookEnvelope.parse` refuses, so the parser is the second line
of defence and the omission is the first. The forwarder's `[ -n "$CLEARWAY_WORKTREE_ID" ]` guard sits
between them and only fires on an absent or empty value — a variable set to `""` reaches it the same
way an unset one does, which is why the careless version costs a `nc` fork per tool call on the hook
sheet and the debug terminal rather than a lit dot.

The other half of this task — the env vars actually reaching the child process — is not reachable
from XCTest: nothing on `Ghostty.SurfaceView` is, and an instance needs a real `ghostty_app_t`
(CLAUDE.md). It is verified by reading, against the C contract and libghostty's own source:
`ghostty_env_var_s` is `{const char* key; const char* value;}` (`ghostty/include/ghostty.h:416-419`)
and `ghostty_surface_new` → `Surface.init` copies each pair with
`try alloc.dupeZ(u8, key)` / `try alloc.dupeZ(u8, value)` into the surface config's arena
(`ghostty/src/apprt/embedded.zig:536-547`), synchronously, before it returns. So the `strdup`ed
copies need to outlive that one call and nothing more, which is exactly the lifetime the `defer`
gives them — including on the `ghostty_surface_new` failure path, where the `guard`'s early `return`
runs it too.

The construction sites were enumerated as the plan asks:

```
$ grep -rn "Ghostty.SurfaceView(" Sources/
Sources/App/DebugTerminalSheet.swift:47:            surface = Ghostty.SurfaceView(app, workingDirectory: projectPath)
Sources/App/TerminalManager+TaskTerminals.swift:24:        let surface = Ghostty.SurfaceView(app, workingDirectory: projectPath, worktreeId: projectPath)
Sources/App/TerminalManager+TaskTerminals.swift:91:        let surface = Ghostty.SurfaceView(
Sources/App/TerminalManager.swift:155:        let secondary = Ghostty.SurfaceView(app, workingDirectory: dir, worktreeId: key)
Sources/App/TerminalManager.swift:309:        let surface = Ghostty.SurfaceView(
Sources/App/TerminalManager.swift:322:            let secondary = Ghostty.SurfaceView(app, workingDirectory: worktree.path, worktreeId: key)
Sources/App/TerminalManager.swift:441:            let newSurface = Ghostty.SurfaceView(app, workingDirectory: dir, worktreeId: deadSurface.worktreeId)
Sources/App/ContentView.swift:710:            let surface = Ghostty.SurfaceView(app, workingDirectory: worktreePath, command: hookShellCommand(cmd))
```

All six in `TerminalManager*` pass a worktree id (the two multi-line calls on their own lines); the
two D7 excludes — the before-remove hook sheet and the debug terminal — are untouched and compile on
the defaulted parameter.

**Deviations from the plan.**

- **Neither static is `nonisolated`.** `TerminalManager` is `@MainActor` and `SurfaceView` inherits
  `NSView`'s isolation, so a plain `static var` is main-actor-isolated on both, which is what every
  reader and the one writer (`ClearwayApp.init`, itself `@MainActor`) already are. `nonisolated` on a
  mutable static of non-`Sendable` function type would need `nonisolated(unsafe)` — an opt-out taken
  for nothing. This makes both exactly `claimsShortcut`'s shape, which the plan names as the model.
- **Retirement is reported from three doors the plan's list does not name**: `closeMainTab` (⌘W —
  the most common way a surface is dropped), `openTaskTerminal`'s replaced surface, and
  `replaceSurface`'s task-terminal branch. The acceptance criterion is "every path that drops a
  surface", and the enumeration in the task body is short of it.
- **`closeAllSurfaces` deliberately does not report.** It runs from `applicationWillTerminate` only;
  the ids it would retire die with the process a moment later, and the monitor they would reach is
  already going away.
- **`retire(_ pane:)` takes the pane, not a worktree id.** `removeSurface` and `closeWorktree` both
  already hold the removed `TerminalPane`, so the surfaces are read off the value that was just
  taken out of `panes` — there is no window in which the two could disagree about which surfaces the
  worktree held.

One detail the plan left open, recorded for T6 and T8: `agentEnvironment` takes the id and the
worktree positionally, `(UUID, String?)`, matching `AgentHookIdentity.environment`'s
`(surfaceId:worktreeId:)` in order, so T8's wiring is a bare function reference.

**Gate.** `./scripts/ci.sh` — green. `Executed 730 tests, with 0 failures (0 unexpected) in 115.593
seconds`, then `==> CI passed.` `git status --porcelain` before the commit showed only this task's
four files: the new test, the three modified sources, and the `xcodegen`-regenerated
`project.pbxproj`. No `default.profraw` — nothing here launched the app.

---

### T6: The monitor — socket, roster, install/uninstall

**What landed.**

| File | State |
| --- | --- |
| `Sources/App/AgentActivityMonitor.swift` | New. `@MainActor AgentActivityMonitor` — the three `@Published private(set)` dictionaries, `setEnabled(_:)`, `retire(surfaceId:)`, and the change-gated `publish()` — plus `HookSocketListener`, the RAII holder whose `deinit` cancels the read source, with every socket call and both `DispatchSource` handlers in its `nonisolated static` factory. |
| `Sources/App/AgentActivityStore.swift` | Gains the three whole-dictionary derivations the monitor publishes (`worktreePhases`, `worktreeSubagents`, `surfaceToolNames`); `phase(forWorktree:)` and `subagents(forWorktree:)` become lookups into them, so each rule is spelled once. |
| `Sources/App/AgentHookScript.swift` | The four path statics become `AgentHookPaths(home:)`, a struct with a defaulted `home`. Everything else is unchanged. |
| `Sources/App/AgentHookInstaller.swift` | `install(home:)` / `uninstall(home:)` thread that same `home` through `installScript`, which now takes the paths. |
| `Tests/AgentActivityMonitorTests.swift` | New. 6 cases driving the monitor end to end through the installed forwarder — real script, real `/usr/bin/nc -U`, real socket — under a temp home. |
| `Tests/RAIICleanupTests.swift` | `testAgentActivityMonitorDeallocates` added beside the existing `testClaudeActivityMonitorDeallocates`, which stays until T11. |
| `Tests/AgentHookIdentityTests.swift`, `Tests/AgentHookSettingsTests.swift` | `AgentHookScript.socketPath` → `AgentHookPaths().socketPath`. |

**Evidence.** The two rules that decide whether a payload is ever seen were implemented the careless
way first — `bind` without unlinking the stale path, and a single `read` instead of a loop to EOF —
and `./scripts/ci.sh` run against that. Exactly the two discriminating cases went red, with the
other four monitor cases and the dealloc test green beside them:

```
Test Suite 'AgentActivityMonitorTests' started at 2026-09-20 19:46:40.129.
    ✖ testAPayloadLargerThanOneReadArrivesIntact, XCTAssertEqual failed: ("nil") is not equal to ("Optional("Bash")") - the lead's in-flight tool
    ✖ testAStaleSocketFileDoesNotStopTheListenerBinding, XCTAssertEqual failed: ("idle") is not equal to ("working") - the worktree's phase over a stale socket path
Executed 6 tests, with 2 failures (0 unexpected) in 13.016 (13.018) seconds
```

Both failures are silent in production, which is why they are worth pinning: a socket inode left by
a process that died without closing makes `bind` fail with `EADDRINUSE`, so every launch after a
crash listens on nothing and no dot ever lights again; and a `PreToolUse` carries the whole
`tool_input`, so one 4 KB read truncates an Edit or a Write into invalid JSON that `parse` drops
without a trace.

**The two structural criteria cannot be tested, so they were verified against the built binary**, as
CLAUDE.md requires — a probe of this shape does not reproduce the trap, it runs the body off-main
silently:

```
$ nm Clearway.debug.dylib | grep HookSocket | xcrun swift-demangle | grep '\.start(socketPath'
0000000000012960 t closure #1 () -> () in static Clearway.HookSocketListener.start(socketPath:…)
0000000000012be8 t closure #2 () -> () in static Clearway.HookSocketListener.start(socketPath:…)

$ xcrun lldb -b -o "disassemble -s 0x12960 -c 200" Clearway.debug.dylib | grep -ciE "isCurrentExecutor|MainActor"
0
```

The cancel handler disassembles to frame setup, the profile counter, `close` and `ret`. Neither
block's prologue reaches `swift_task_isCurrentExecutor` or `MainActor.shared`, so neither traps when
libdispatch runs it on the listener's queue. The no-clock criterion is the second:
`grep -nE "DispatchWorkItem|asyncAfter|Timer|Date|sleep|expir"` over the file matches one word, in
the comment saying the socket read timeout is not an expiry.

**Deviations from the plan.**

- **The `~/.clearway` layout became `AgentHookPaths(home:)`.** T6's only acceptance criterion that a
  test can reach — that an enabled monitor still deallocates — requires enabling one, and
  `setEnabled(true)` installs hooks. With T3's fixed statics that meant a test run writing into the
  developer's real `~/.claude/settings.json` and binding their real `~/.clearway/hook.sock`, which is
  exactly what T4's `home` parameter exists to prevent. One parameter now threads through the whole
  feature, defaulted at every call site outside the tests, and the end-to-end coverage below is what
  it buys.
- **The store gained the three plural derivations.** The monitor publishes dictionaries and the store
  kept `surfaces` private with only single-key readers, so there was no way to enumerate what to
  publish. The single-key readers are now lookups into the plural ones rather than a second spelling
  of the same rule. `worktreeSubagents` omits a worktree with an empty roster, so a surface merely
  existing does not add a key.
- **The listener has its own file-local type rather than a `FileWatchers` sibling.** The plan offered
  either. `makeWatcher` opens a path `O_EVTONLY` and makes a file-system-object source; a listening
  `AF_UNIX` socket shares none of that — only the rule that the handlers are formed outside every
  actor, which `HookSocketListener` states in its own doc comment and is verified above.
- **A dedicated serial queue, not a global one.** A connection is read to EOF on the queue the source
  fires on. On `.global(qos:)` that parks a shared pool worker, which is what left `ShellPathStore`
  waiting behind a backgrounded editor (CLAUDE.md, `OpenInAppLauncher`). The listening descriptor is
  `O_NONBLOCK` and the accept loop drains until there is nothing pending, because a read source
  coalesces and one event can stand for several hook processes that arrived together.
- **`SO_RCVTIMEO` on the accepted connection.** Not an expiry on any state — the criterion the task
  names — but a floor under a peer that connects and then says nothing, which would otherwise park
  the one queue every later event is delivered on, permanently. Every real client is the forwarder's
  `nc`, whose descriptor closes when it exits.
- **`retire(worktreeId:)` is not exposed on the monitor.** T5 wires `TerminalManager.retireSurface`,
  which is per-surface; the store's worktree overload has no caller yet and adding a second door for
  nobody would be speculative.
- **Six behavioural tests, not the plan's one.** The dealloc test is there as specified, but it
  proves only that the source is cancelled. The socket, the accept loop, the read to EOF, the
  change-gated publishing and the toggle are the whole of this task, and the temp home makes them
  reachable: each test runs the forwarder `AgentHookInstaller` just wrote, with the three identity
  variables in the environment and the hook JSON on stdin, which is what an agent does. That also
  covers the installer's script half, which T4 left to the operator.

One detail left open for T8: `setEnabled(_:)` is idempotent in both directions and takes the whole
toggle, so the wiring is one call on launch and one in `.onChange`, with nothing to guard.

**Gate.** `./scripts/ci.sh` — green. `Executed 737 tests, with 0 failures (0 unexpected) in 116.014
seconds`, then `==> CI passed.` `git status --porcelain` before the commit showed only this task's
files — two new, five modified — and the `xcodegen`-regenerated `project.pbxproj`. No
`default.profraw`: nothing here launched the app.

### T7: The Settings toggle

**What landed.**

| File | State |
| --- | --- |
| `Sources/App/SettingsManager.swift` | `SettingsKey.agentHooksEnabled = "clearway.agentHooksEnabled"`; `@Published var agentHooksEnabled: Bool` with the `didSet { defaults.set(…) }` shape its three sibling toggles use, read in `init` as `defaults.object(forKey:) as? Bool ?? true`. |
| `Sources/App/SettingsView.swift` | One row at the end of `Section("Appearance")`: `Toggle(isOn: $settings.agentHooksEnabled)` whose label is two `Text`s — "Show agent activity" and the single line of Codex copy. |
| `Tests/SettingsManagerTests.swift` | `test_agentHooksEnabled_defaultsToTrue` and `test_agentHooksEnabled_persistsBeingTurnedOff`, in the file's existing per-test suite pattern. |

**Evidence.** The two rules are the default and the write, and no single careless implementation
gets both wrong, so each was written the careless way in turn and `./scripts/ci.sh` run against it.
First the default copied from its siblings (`?? false`), which is the shape a reader of the three
lines above it would write:

```
Test Suite 'SettingsManagerTests' started at 2026-09-20 19:55:40.060.
    ✖ test_agentHooksEnabled_defaultsToTrue, XCTAssertTrue failed
Executed 739 tests, with 1 failure (0 unexpected) in 111.104 (111.246) seconds
```

Then the default restored and the `didSet` dropped — a plain `@Published var`, which compiles and
works for a whole session:

```
Test Suite 'SettingsManagerTests' started at 2026-09-20 19:57:50.770.
    ✖ test_agentHooksEnabled_persistsBeingTurnedOff, XCTAssertFalse failed
Executed 739 tests, with 1 failure (0 unexpected) in 109.383 (109.524) seconds
```

Both defects are silent: a `false` default ships the feature off to everyone who never opens
Settings, and a missing `didSet` turns the toggle back on at every relaunch.

**Deviations from the plan.**

- **The copy is the toggle's own subtitle, not a separate row.** The plan said "one line of
  secondary copy"; Apple documents the shape — `Toggle`'s docs, fetched 2026-09-20: "For cases where
  adding a subtitle to the label is desired, use a view builder that creates multiple `Text` views
  where the first text represents the title and the second text represents the subtitle", with the
  worked example being exactly two `Text`s in the label closure. That binds the line to the control
  it qualifies instead of leaving a loose caption in the section, and it needs no availability gate:
  `init(isOn:label:)` is macOS 10.15+ and the deployment target is 13.0.
- **`/hooks` is written bare, not in backticks.** The plan's example sentence carries Markdown
  backticks; `Text` renders them literally in a `Form` label, so they would have shipped as visible
  characters.

**Gate.** `./scripts/ci.sh` — green, run after the last edit. `Executed 739 tests, with 0 failures
(0 unexpected) in 106.727 seconds`, then `==> CI passed.` `git status --porcelain` before the commit
showed three modified files and nothing else — no new Swift file, so `xcodegen` left
`project.pbxproj` untouched, and no `default.profraw`: nothing here launched the app.
