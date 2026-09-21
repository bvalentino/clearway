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

---

### T8: App-level wiring

**What landed.**

| File | State |
| --- | --- |
| `Sources/App/ClearwayApp.swift` | `@StateObject private var agentActivity: AgentActivityMonitor`, built in `init()` beside the `claimsShortcut` line, where both process-scoped statics are now wired: `Ghostty.SurfaceView.agentEnvironment = AgentHookIdentity.environment` and `TerminalManager.retireSurface`, whose closure captures the monitor weakly. The project `WindowGroup`'s content gains `.environmentObject(agentActivity)`, an `.onAppear` calling `setEnabled(settings.agentHooksEnabled)` and an `.onChange` of the same value. |
| `Sources/App/ContentView.swift` | `@EnvironmentObject claudeActivityMonitor` and both `updateWorktrees(…)` calls removed. The file shrank from 1014 to 1011 lines; nothing was added to it. |
| `Tests/AgentHookIdentityTests.swift` | `testTheSurfaceProviderIsWiredAtLaunch` — the app-hosted pin on the one line that cannot fail loudly. |

**Evidence.** The provider defaults to `{ _, _ in [] }`, so a missing wiring line compiles, lints,
launches and ships a feature that does nothing: every surface hands its shell no
`CLEARWAY_SURFACE_ID`, the forwarder exits on its first guard, and no hook ever reaches the socket.
Nothing else in the suite touches it. So T8 was first built with every other line in place and that
one absent, and `./scripts/ci.sh` run against it:

```
    ✖ testTheSurfaceProviderIsWiredAtLaunch, XCTAssertEqual failed: ("[]") is not equal to ("["CLEARWAY_SURFACE_ID", "CLEARWAY_WORKTREE_ID", "CLEARWAY_HOOK_SOCKET"]")
    ✖ testTheSurfaceProviderIsWiredAtLaunch, XCTAssertEqual failed: ("nil") is not equal to ("Optional("E42B50F7-7B9C-4175-B206-6512BC92EDD9")")
Executed 740 tests, with 2 failures (0 unexpected) in 108.292 (108.431) seconds
```

The `[]` **is** the silent defect. That the same test is green after the one-line addition is also
what proves the test can see the wiring at all: the unit-test bundle is hosted by the app, so
`ClearwayApp.init` has already run when the bundle loads, and the static carries what it left there.

**The `setEnabled` half verified itself on that same run.** The hosted app opened its window, which
is what `.onAppear` hangs off, and the machine's real agent config shows the whole install path ran
end to end from the wiring alone:

```
$ ls -la ~/.claude/settings.json.clearway-backup ~/.clearway/hooks/clearway-hook.sh
-rw-r--r--@ 1 bvalentino  staff  47925 Sep 20 17:54 /Users/bvalentino/.claude/settings.json.clearway-backup
-rwxr-xr-x@ 1 bvalentino  staff    276 Sep 20 20:06 /Users/bvalentino/.clearway/hooks/clearway-hook.sh
$ python3 -c '…count entries containing clearway-hook.sh…'
clearway entries: 9
```

The backup is byte-for-byte the 47,925-byte file as it stood before (`17:54`, the pre-run mtime),
the nine events of D4 each carry one entry, and the user's own thirteen hook events — including four
Clearway does not install — are still there. Worth stating plainly for the sign-off stage: **any**
`./scripts/ci.sh` run from here on installs the block into the developer's real
`~/.claude/settings.json`, because the test host launches the app and the toggle defaults on. That
is the feature, not a test artefact; GitHub's runner has no `~/.claude`, and T4's directory gate
makes it a no-op there.

**Deviations from the plan.**

- **`ProjectWindow` keeps its `ClaudeActivityMonitor` until T9.** The task says to delete the
  `@StateObject` and the `.environmentObject` now, and its acceptance criterion names the three
  files that may still reference the type afterwards — `SidebarView.swift` among them. But
  `SidebarView` reads it as an `@EnvironmentObject`, and an `@EnvironmentObject` nothing injects is
  a `fatalError` the first time the view body runs: T8 as written makes the app unlaunchable until
  T9 lands, which costs the operator the by-hand check at the end of this task and breaks the rule
  that each layer leaves a working product. The two lines stay until T9 removes the reader. They are
  inert — `ContentView` no longer calls `updateWorktrees`, so the monitor starts no watcher and its
  `workingWorktreeIds` is permanently empty, which is the old dot going dark one task early rather
  than any behaviour change. **T9 must delete them**; T11's repo-wide grep catches it otherwise.
- **The toggle is driven from the scene, not from `init`.** As the plan suggests, but worth stating
  why it is not a one-shot: `setEnabled` has to re-run when the setting changes, and the App struct
  has no lifecycle hook between `init` and the scene. Both calls are idempotent and a second window
  simply repeats them.

One detail the plan left open, recorded for T9 and T10: `agentActivity` is injected on the project
`WindowGroup` only, not on the task or prompt window groups — the two readers T9 and T10 add are
`SidebarView` and `MainTerminalTabStrip`, both inside `ContentView`. A standalone window that
reached for it would fault, the same way the `ClaudeActivityMonitor` note above describes.

**Gate.** `./scripts/ci.sh` — green, run after the last edit. `Executed 740 tests, with 0 failures
(0 unexpected) in 107.656 seconds`, then `==> CI passed.` `git status --porcelain` before the commit
showed three modified files and nothing else: no new Swift file, so `xcodegen` left
`project.pbxproj` untouched, and no `default.profraw` — the test host's launch does not drop one.

---

### T9: The sidebar dot and the subagent rows

**What landed.**

| File | State |
| --- | --- |
| `Sources/App/WorktreeRow.swift` | `isWorking: Bool` → `phase: AgentPhase`. The dot `Group` is a `switch` over it: `.waiting` → a static 7 pt purple circle, "Waiting for permission"; `.working` → the pulsing orange circle, its tooltip now "Agent is working"; `.idle` → the blue notification circle when there is one. `.animation(…, value: phase)`. New `SubagentRow` in the same file: the agent type, with the in-flight tool as a `.subheadline`/`.secondary` caption. |
| `Sources/App/SidebarView.swift` | `@EnvironmentObject agentActivity: AgentActivityMonitor` replaces `claudeActivityMonitor`. `worktreeRowView` reads `worktreePhases[wt.id]` and `worktreeSubagents[wt.id]` — `!wt.isMain` gone (D23), `isOpen` kept — and emits one `SubagentRow` per roster entry after the worktree row, each with no `.tag`, `.moveDisabled(true)` and `.padding(.leading, statusRowIndent + leadingIndent)`. |
| `Sources/App/ProjectWindow.swift` | The `ClaudeActivityMonitor` `@StateObject` and its `.environmentObject` deleted, as T8's log requires: the reader and the injection go in one change or the app faults. |

**Evidence.** No watched failure, and the task is the one place in this feature where that is the
honest answer rather than a gap. Every rule T9 could get wrong that a test can reach —
`waiting > working > idle`, the roster's contents and its stable order — was lifted into
`AgentActivityStore` in T2 and is pinned there. What is left is a SwiftUI body: `WorktreeRow` needs
no `ghostty_app_t` but has no output an `XCTAssert` can read, and `SidebarView` needs six
`EnvironmentObject`s and a `List`. The rendering is the operator's by-hand check, exactly as the
task's **Verified by** says.

Both halves of the type change are load-bearing and neither can fail quietly: `isWorking: Bool` →
`phase: AgentPhase` is a compile error at the one call site until it is updated, and deleting
`ProjectWindow`'s injection while `SidebarView` still read the old monitor would be the
`@EnvironmentObject` `fatalError` T8 recorded — which is why the two lines moved in this commit and
not the last one.

**Deviations from the plan.**

- **The subagent rows are gated on `isOpen` too**, not only the dot. The task names the gate for the
  dot alone, but a closed worktree has had its surfaces retired by `cleanupState(for:)`, so a
  non-empty roster there is stale state rather than something to draw. One `isOpen` decides both,
  which is also what keeps the row and its children from disagreeing about whether the worktree is
  live.
- **A subagent with no `agent_type` renders "Subagent".** `AgentSubagent.type` is optional because a
  `PreToolUse` carrying an `agent_id` whose `SubagentStart` was missed creates the entry with no
  type (T2's `startTool` upsert). Blanking the primary text would draw an empty row with a tool name
  under it.
- **The purple dot carries `.transition(.opacity)` and no pulse**, per D22 — shape as well as hue
  separates it from working.

The reorder risk the task flags did not need its fallback: `./scripts/ci.sh` is green and the
`.onMove` closures still index `rows`, the worktree collection, which no extra view changes. Whether
drag targeting behaves with a variable number of views per element is the operator's check below,
and the recorded fallback stands if it does not.

**Gate.** `./scripts/ci.sh` — green, run after the last edit. `Executed 740 tests, with 0 failures
(0 unexpected) in 109.242 seconds`, then `==> CI passed.` `git status --porcelain` before the commit
showed three modified files and nothing else: no new Swift file, so `xcodegen` left
`project.pbxproj` untouched, and no `default.profraw`.

---

### T10: The tool name on the tab chip

**What landed.**

| File | State |
| --- | --- |
| `Sources/App/MainTerminalTabStrip.swift` | `TabChip` gains `toolName: String?`, rendered after the title as an 11 pt `.secondary` `Text`, `lineLimit(1)`, `.truncationMode(.tail)`, and absent entirely when nil. Title and tool name sit in a nested `HStack` that carries the `frame(maxWidth: .infinity, alignment: .leading)` the title used to; the title keeps `.layoutPriority(1)` so a fixed-width chip truncates the tool name first. `TerminalTabChip` gains the same parameter and passes it through. `MainTerminalTabStrip` gains `@EnvironmentObject agentActivity: AgentActivityMonitor` and resolves the value once per chip as `surfaceToolNames[tab.surface.surfaceId.uuidString]`. |

**Evidence.** No watched failure, and as in T9 that is the honest answer rather than a gap. The whole
task is a SwiftUI body: `TabChip` is a `private struct` with no output an `XCTAssert` can read, and
the strip needs five `EnvironmentObject`s and a live `Ghostty.SurfaceView`, which needs a real
`ghostty_app_t`. The rule behind the value — a lead tool name present only while a tool is in
flight — was lifted into `AgentActivityStore` in T2 and is pinned there
(`AgentActivityStoreTests.swift:28,32,42,47,58,128,139,157`), and the key this view looks the value
up under is pinned end to end in T6:
`AgentActivityMonitorTests.swift:72` waits on `monitor.surfaceToolNames[surfaceId]` after driving a
real `PreToolUse` through the installed forwarder, with `surfaceId` the same
`CLEARWAY_SURFACE_ID` string `AgentHookIdentity.environment` stamps from `surfaceId.uuidString`.
So the one line that could silently look up the wrong key is covered by an existing test rather
than by a new one.

**Deviations from the plan.** None in substance. Two shapes the task left open:

- **The tool name is read in `MainTerminalTabStrip` and passed down**, as the task says, rather than
  read by `TerminalTabChip` from its own `@EnvironmentObject`. Either spelling rebuilds the strip on
  every `PreToolUse`/`PostToolUse` — the monitor's published dictionary is one object every observer
  watches — so the choice is about scoping, and passing it down keeps `TerminalTabChip`'s
  `@ObservedObject` the only per-surface observation, which is what its existing note is about.
- **The title/tool pair is nested rather than placed side by side in the outer `HStack`.** The
  title's `frame(maxWidth: .infinity, alignment: .leading)` moved to the pair, so with no tool name
  the chip lays out exactly as before, and with one the two texts stay left-aligned together instead
  of the title pushing the tool name off the end.

**Gate.** `./scripts/ci.sh` — green, run after the last edit. `Executed 740 tests, with 0 failures
(0 unexpected) in 110.499 seconds`, then `==> CI passed.` `git status --porcelain` before the commit
showed one modified file and nothing else: no new Swift file, so `xcodegen` left `project.pbxproj`
untouched, and no `default.profraw`.

### T11: Retire `ClaudeActivityMonitor`

**What landed.**

| File | State |
| --- | --- |
| `Sources/App/ClaudeActivityMonitor.swift` | Deleted (295 lines). The mtime heuristic, its per-worktree `WatcherState` dictionary, the `~/.claude/projects` parent watcher, and the 8-second `expirySeconds` timer expiry go with it. |
| `Tests/RAIICleanupTests.swift` | `testClaudeActivityMonitorDeallocates` removed. `testAgentActivityMonitorDeallocates` from T6 is the surviving RAII pin for the activity path. |
| `Sources/App/ClaudeSessionFiles.swift` | Doc comment's `, used by ClaudeActivityMonitor` clause dropped — the last reference to the type in `Sources/`. T12 rewrites the rest of that comment along with the now-callerless path helpers. |
| `Clearway.xcodeproj/project.pbxproj` | Regenerated by `xcodegen` inside `ci.sh`; the file reference and build-phase entry are gone. |

**Evidence.** This task deletes code and adds no behaviour, so there is no failing test to watch —
its acceptance criterion is a grep. Before the deletion it named three files:

```
$ grep -rn "ClaudeActivityMonitor\|claudeActivityMonitor\|workingWorktreeIds" Sources/ Tests/ | sed 's/:.*//' | sort | uniq -c
  10 Sources/App/ClaudeActivityMonitor.swift
   1 Sources/App/ClaudeSessionFiles.swift
   4 Tests/RAIICleanupTests.swift
```

After it, that grep and the `expirySeconds` sweep both exit 1 with no output. T8's deviation note
warned that a surviving `ProjectWindow` `@StateObject` would be caught here; T9 had already removed
it, so the grep found none.

**Deviations from the plan.** One addition to the named file list: the task lists only the deleted
file and `RAIICleanupTests.swift`, but `ClaudeSessionFiles.swift`'s doc comment named the type too,
so its acceptance grep could not come back empty without that one-clause edit. The plan's own T12
description confirms that file survives T11 otherwise.

**Gate.** `./scripts/ci.sh` — green, run after the last edit. `Executed 739 tests, with 0 failures
(0 unexpected) in 109.045 seconds`, then `==> CI passed.` The count drops by one from T10's 740:
the deleted RAII case. `git status --porcelain` before the commit showed the four files above and
nothing else — no untracked files and no `default.profraw`.

### T12: Rename `ClaudeSessionFiles` to `FileWatchers`

**What landed.**

| File | State |
| --- | --- |
| `Sources/App/ClaudeSessionFiles.swift` → `Sources/App/FileWatchers.swift` | Renamed with `git mv`, so git records it as `R` and history follows. `enum ClaudeSessionFiles` → `enum FileWatchers`; `makeWatcher` and `defaultWatchMask` and their doc comments are byte-identical. |
| (same file) | `claudeDir`, `encodePathForClaude`, `projectsParentDir` and `projectDir(forWorktreePath:)` deleted — T11 removed their only caller. The type doc comment now reads "The single door every file-system `DispatchSource` in the app goes through". The two `// MARK:` dividers went with the split they separated: one concern is left. `@preconcurrency import Dispatch` on line 1 is untouched, as the task says. |
| `Sources/App/TodoManager.swift`, `Sources/App/PromptManager.swift`, `Sources/App/WorkTaskManager.swift` | The four call sites updated (`TodoManager:137`, `PromptManager:144`, `WorkTaskManager:374,452`). Identifier-only substitution; no other line changed. |
| `Clearway.xcodeproj/project.pbxproj` | Regenerated by `xcodegen` inside `ci.sh` — the file reference and build-phase entry follow the new name. `project.yml` globs `Sources`, so no spec edit was needed. |

**Evidence.** A rename with no behaviour change has no failing test to watch; the acceptance
criteria are greps. After the change:

```
$ grep -rn "ClaudeSessionFiles\|encodePathForClaude\|projectsParentDir\|projectDir(forWorktreePath" Sources/ Tests/; echo "exit: $?"
exit: 1
```

```
$ grep -rn "makeFileSystemObjectSource" Sources/ Tests/
Sources/App/FileWatchers.swift:29:        let source = DispatchSource.makeFileSystemObjectSource(
```

`FileWatchers.makeWatcher` is still the only one, so CLAUDE.md's single-door rule holds under the
new name.

**Deviations from the plan.** None. `import Foundation` was kept although only `open`/`close`/
`O_EVTONLY` need it now — dropping it is a separate change and would not shorten the file's one
remaining concern.

**Gate.** `./scripts/ci.sh` — green, run after the last edit. `Executed 739 tests, with 0 failures
(0 unexpected) in 106.947 seconds`, then `==> CI passed.` The count is unchanged from T11, as a
rename should leave it. `git status --porcelain` before the commit showed the five files above and
nothing else — no untracked files and no `default.profraw`.

### T13: Document the pipeline in CLAUDE.md

**What landed.**

| File | State |
| --- | --- |
| `CLAUDE.md` — Concurrency | `ClaudeSessionFiles.swift:1` → `FileWatchers.swift:1`; the RAII-holder bullet's `ClaudeActivityMonitor.WatcherState` example replaced by `HookSocketListener`; the single-`DispatchSource`-door rule renamed to `FileWatchers.makeWatcher`, narrowed to **file-system** sources, and given the hook socket's read source as the one source that keeps the rule (`nonisolated static` factory) rather than the door. |
| `CLAUDE.md` — `Ghostty.SurfaceView` bullet | `agentEnvironment` beside `claimsShortcut`: why the provider exists (this layer must not learn the hook feature's names), that its `{ _, _ in [] }` default makes a missing wiring line silent, the test that pins it and why an app-hosted bundle can see it, and the `strdup`/`defer` lifetime against libghostty's `dupeZ`. |
| `CLAUDE.md` — new `Sources/App/` bullet | The six files, the socket and why not a port, `nc -U -w 1` and the `-N` trap, the two-line framing and the pretty-printed-body truncation, the three guards and the unconditional `exit 0`, the two ids, content recognition with no marker key and no `matcher`, the document-not-bytes write gate, the one-time backup and the backup-failure refusal, both directory gates, Codex's `/hooks` trust step and the copy exception, no clock anywhere, change-gated publishing, one owner and the injection scope, `retireSurface`, `AgentHookPaths(home:)`, and the `waiting > working > idle` dot with the purple rationale and the `isMain`/`isOpen` change. |
| `CLAUDE.md` — Pipeline | A paragraph under the regression/gate table: on a developer machine every `ci.sh` run installs the block into the real `~/.claude/settings.json` and takes the one-time backup, because the test host launches the app and the toggle defaults on; GitHub's runner has no `~/.claude`. |

**Evidence.** A documentation task has no failing test to watch. Its acceptance criterion is a grep,
which now exits 1:

```
$ grep -n "ClaudeSessionFiles\|ClaudeActivityMonitor" CLAUDE.md; echo "exit: $?"
exit: 1
```

Every claim was written from the build logs above rather than from the plan's original intent, so
the deviations are what the file now records: the third forwarder guard (T3), both agents gated on
their config directory rather than only Codex (T4), the document comparison and the
backup-cancels-the-write rule (T4), `AgentHookPaths(home:)` and the dedicated serial queue (T6), the
toggle's subtitle shape (T7), the injection scope and the `ci.sh` side effect (T8), and the
subagent rows sharing the dot's `isOpen` gate (T9).

**Deviations from the plan.**

- **The `ci.sh` paragraph is a fifth edit the task does not list.** T8's log asks for it in as many
  words, and it is the one thing in this feature that changes what a later stage sees on the
  operator's own machine.
- **The "it scales to collections" sentence went with its example.** `ClaudeActivityMonitor` was the
  only collection of RAII holders in the app; `WorkTaskManager`'s watcher dictionaries hold
  `DispatchSourceFileSystemObject` directly, which the bullet above already covers as `Sendable`. The
  rule is restated on the live single holder instead of kept alive by a type that no longer exists.
- **The single-`DispatchSource`-door rule was narrowed, not just renamed.** The plan asks only for
  the rename, but T6 added a second source outside `makeWatcher`, so "**every** `DispatchSource` goes
  through" had become false and would have sent the next reader to force an `AF_UNIX` listener
  through a file-watcher factory.

**Gate.** `./scripts/ci.sh` — green, run after the last edit. `Executed 739 tests, with 0 failures
(0 unexpected) in 110.033 seconds`, then `==> CI passed.` The count is unchanged from T12, as a
documentation-only change should leave it. `git status --porcelain` before the commit showed
`M CLAUDE.md` and the plan document and nothing else — no untracked files and no `default.profraw`:
the test host's launch does not drop one.

### Simplify

`/simplify` over `main...HEAD`. Quality only, no behaviour changed: dropped `AgentActivityStore`'s
four test-only members (`retire(worktreeId:)` plus the three single-key readers, each of which
rebuilt a whole derivation per lookup) so the tests read the same three dictionaries the views do;
stopped `worktreeSubagents` building empty buckets only to filter them out; moved the
`BackgroundTask` → `AgentSubagent` translation onto `runningBackgroundSubagents` so
`AgentSurfaceState` no longer names the wire format; held one `JSONDecoder` on `AgentHookEnvelope`;
un-stored `Ghostty.SurfaceView.worktreeId`, whose one reader had the pane's `key` in scope, so the
libghostty wrapper carries no App concept again; made `AgentHookInstaller`'s three `home` defaults
required and corrected the three doc comments that described call sites and isolation the code does
not have; folded `WorktreeRow`'s three hand-written dots into one `ActivityDot`; and lifted the
duplicated `waitFor` and short-`/tmp`-home fixtures into `TestHelpers` (`@MainActor`, or every
closure a main-actor suite passes becomes a value sent across an actor boundary).

**Gate.** `./scripts/ci.sh` — green, run after the last edit. `Executed 742 tests, with 0 failures
(0 unexpected) in 111.587 seconds`, then `==> CI passed.` One fewer than C7's 743: the deleted test
is `testRetiringAWorktreeDropsEveryOneOfItsSurfaces`, which pinned a door no shipped path reaches.
`git status --porcelain` showed the ten modified files and nothing else — no untracked files and no
`default.profraw`.

## Changelog

Operator changes made after the hands-on check. These are decisions, not plan tasks; no later stage
may revert them.

### C1 — One left edge for a worktree row and its subagent rows

**Reported.** In the sidebar grouped by status, a worktree row's title sat well to the right of both
its section header and the ungrouped `main` row, and the subagent rows under it started at a third,
further-right edge.

**Cause.** Three leading edges, all from `SidebarRowMetrics.statusRowIndent` (21pt):
`statusSection` passed it as `leadingIndent` to every worktree row it built, and
`worktreeRowView` gave each `SubagentRow` `statusRowIndent + leadingIndent` — 42pt inside a status
section. The metric existed to land a row's icon on the *letter* its status header's title starts
with, which is what pushed the row past the header and past `main`.

**Decision.** Remove the padding at its source rather than compensate on the child rows. The
`leadingIndent` parameter is gone from `worktreeRowView`, `statusSection` passes nothing, and the
`SubagentRow` `.padding(.leading, …)` is gone, so a worktree row and its subagent rows share the
list's own leading edge and every worktree row — grouped, status-sectioned or ungrouped — starts
where `main` does. `statusRowIndent` and its `titleLeadingBearing` term had no other reader and were
deleted with it; `headerLeadingInset`, which lands the status header's *icon* on the row icon
column, stays and is now what aligns a status section with its rows.

| File | State |
| --- | --- |
| `Sources/App/SidebarIcon.swift` | `statusRowIndent` and `titleLeadingBearing` removed |
| `Sources/App/SidebarView.swift` | `leadingIndent` parameter and both `.padding(.leading, …)` removed |

**Gate.** `./scripts/ci.sh` — green, run after the last edit. `Executed 739 tests, with 0 failures
(0 unexpected)`, then `==> CI passed.` Layout carries no test; the count is unchanged, as a
padding-only change should leave it.

### C2 — `Stop` no longer takes the background subagents' rows away

**Reported.** A Claude Code session in a Clearway tab launched two background subagents through the
`Agent` tool — Claude Code's own status line listed them as `general-purpose  Count Swift files
slowly` and `general-purpose  Count test files slowly`. The sidebar showed **one** child row,
intermittently, reading "Subagent" over the tool "Bash".

**Captured, not guessed.** A scratchpad-only capture — a hook script that appends its stdin to a
file, installed through `claude --settings <scratchpad file>`, nothing in the repo and the installed
forwarder untouched — recorded the real payloads of a session that launches two background agents
(Claude Code 2.1.278). The sequence, fields only:

```
SubagentStart  agent_id=a42b0698…  agent_type=general-purpose
SubagentStart  agent_id=aa713d00…  agent_type=general-purpose
Stop           background_tasks=[{id:a42b0698…,type:subagent,status:running,agent_type:general-purpose},
                                 {id:aa713d00…,type:subagent,status:running,agent_type:general-purpose}]
PreToolUse     agent_id=a42b0698…  agent_type=general-purpose  tool_name=Bash
SubagentStop   agent_id=a42b0698…  agent_type=general-purpose
```

**Cause.** Both fields the spec assumed are there, on every event that names a subagent. What is not
as assumed is `Stop`: it fires **while background subagents are still running** — that is what a
background launch means — and `AgentActivityStore` answered it with `subagents.removeAll()`. Both
rows went as soon as the lead finished its turn, a second after they appeared. What the operator
then saw was the roster re-created by a subagent's own `PreToolUse`: one row, because only one agent
was between `PreToolUse` and `PostToolUse` at a time, and unnamed, because `startTool` recorded the
tool and dropped the `agent_type` beside it, leaving `SubagentRow` on its "Subagent" fallback.

**Decision.** `Stop` carries `background_tasks`, documented as `id` / `type` / `status` /
`description` / `agent_type`, so the sweep is kept and made exact: **the roster is reduced to the
entries it reports as a running subagent**, carrying over each row's in-flight tool. A missed
`SubagentStop` still cannot pin a row, and a `Stop` that names none — every agent with no background
work, Codex included, and any payload without the field — clears the roster exactly as before.
Beside it, `startTool` now records the `agent_type` its event carries, so a row first seen through
its tool traffic is named too. `description` is on the wire and is deliberately not rendered: the
rows name the agent type and its tool, which is what was asked for.

| File | State |
| --- | --- |
| `Sources/App/AgentHookEvent.swift` | `background_tasks` decoded as `BackgroundTask` values; `runningBackgroundSubagents` filters to `type == "subagent"`, `status == "running"` |
| `Sources/App/AgentActivityStore.swift` | `Stop` calls `keepOnly(…)` instead of `removeAll()`; `startTool`/`SubagentStart` share `note(agentId:type:)` |
| `Tests/AgentActivityStoreTests.swift` | three tests replaying the captured payloads verbatim; `testStopClearsEveryOpenSubagent` renamed for the branch it now pins |
| `CLAUDE.md` | the `Stop` rule and the `agent_type`-on-every-event rule |

**Evidence.** The three new tests, run against the unfixed store (`-only-testing:ClearwayTests/
AgentActivityStoreTests`, sources reverted to `HEAD` from a scratchpad copy and restored after):

```
testBackgroundSubagentsSurviveTheLeadsStop: XCTAssertEqual failed:
  ("[]") is not equal to ("["a42b06983b46906f7", "aa713d00cbb27a6be"]")
testASubagentStopDropsOneRowAndTheNextStopKeepsTheOther: XCTAssertEqual failed:
  ("[]") is not equal to ("["aa713d00cbb27a6be"]")
testASubagentFirstSeenThroughItsToolTrafficIsStillNamed: XCTAssertEqual failed:
  ("[nil]") is not equal to ("[Optional("general-purpose")]")
Executed 20 tests, with 6 failures (0 unexpected)
```

**The `SessionStart:startup` hook error is not Clearway's.** The forwarder writes nothing to stdout:
its `printf` goes into the pipe feeding `nc`, whose own output is `>/dev/null 2>&1`, and it
`exit 0`s. Run by hand with a live socket it produced 0 bytes on stdout, 0 on stderr, exit 0. The
offending hook is the `addy-agent-skills` plugin's `hooks/session-start.sh`, which concatenates a
skill's raw Markdown into a JSON string; run with a sample `SessionStart` payload its output fails
`json.loads` with `Invalid control character at: line 3 column 115`. Left alone.

**Gate.** `./scripts/ci.sh` — green, run after the last edit. `Executed 742 tests, with 0 failures
(0 unexpected)`, then `==> CI passed.`

### C3 — A subagent row carries a glyph in the icon column

**Reported.** After C1 a subagent row is plain text against the list's leading edge. The operator
wants it to carry an icon rather than an indent, so it reads as a child without a second edge.

**Decision.** `SubagentRow` becomes a `Label` whose icon is a `SidebarIcon`, the same slot the
worktree row's glyph, the top-level destinations and the status headers draw into — so the shared
left edge C1 established is untouched, the weight and size come from the row's own font exactly as
they do for every other icon in the sidebar, and nothing about the padding changes. The symbol is
`point.3.connected.trianglepath.dotted`: connected nodes read as work fanned out from the row above,
it collides with nothing else in the sidebar's vocabulary, and, unlike a branch or arrow glyph, it
carries no git meaning in a git app. SF Symbols dates it to 2021 — macOS 12.0, below the 13.0
deployment target, where the worktree row's own `square.on.square.intersection.dashed` is macOS 13.0.

| File | State |
| --- | --- |
| `Sources/App/WorktreeRow.swift` | `SubagentRow` is a `Label` over a `SidebarIcon`; text unchanged |

**Gate.** `./scripts/ci.sh` — green, run after the last edit. `Executed 742 tests, with 0 failures
(0 unexpected)`, then `==> CI passed.` The row carries no test; the count is unchanged, as an
icon-only change should leave it.

### C4 — A subagent row names the work, not only the agent type

**Reported.** The brief asks for each subagent's type "and the description when the hooks provide
one". C2 found one on the wire and left it unrendered, so the rows read `general-purpose` twice over
where Claude Code's own status line reads `general-purpose  Count Swift files slowly` and
`general-purpose  Count test files slowly`.

**Decision.** `Stop`'s `background_tasks` entries carry `description` beside `id`, `type`, `status`
and `agent_type` — C2's capture recorded it and its test helper already emitted it — so
`BackgroundTask` decodes it and `AgentSubagent` holds it. Nothing else on the wire carries one:
`SubagentStart` still does not, and correlating one out of the `Agent` tool's `PreToolUse` is still
rejected for the reason Decision 25 gave. That makes the carry-over load-bearing rather than
defensive: `keepOnly` takes `task.description ?? subagents[task.id]?.description`, the same shape
the type already used, so a later `Stop` whose entry omits the summary cannot blank a row no other
event could repair.

`SubagentRow` puts it beside the type in an `HStack`, secondary, with the in-flight tool still on
the line below. The type carries `.layoutPriority(1)`: it is what identifies the row, so the
description is what truncates when the sidebar is narrow.

Spec Decision 25 said the description is not shown; it now records that it is, what supplies it and
what it falls back to.

| File | State |
| --- | --- |
| `Sources/App/AgentHookEvent.swift` | `BackgroundTask.description` decoded |
| `Sources/App/AgentActivityStore.swift` | `AgentSubagent.description`; `keepOnly` carries it over when the entry omits it |
| `Sources/App/WorktreeRow.swift` | `SubagentRow` draws type and description on one line |
| `Tests/AgentActivityStoreTests.swift` | `testAStopsDescriptionLandsOnTheRowAndIsNotBlankedByLaterEvents`; `stop(running:)` takes a description per entry, and omits the key when given none |
| `docs/…/specs/…md` | Decision 25 rewritten |
| `CLAUDE.md` | the `background_tasks`-only source of the summary and its carry-over |

**Evidence.** Two watched failures, both with the test in place and the store reverted from a
scratchpad copy (`-only-testing:ClearwayTests/AgentActivityStoreTests`).

With `keepOnly` not recording the description at all — the whole behaviour absent:

```
AgentActivityStoreTests.swift:267: XCTAssertEqual failed:
  ("[nil]") is not equal to ("[Optional("Count Swift files slowly")]")
AgentActivityStoreTests.swift:275: XCTAssertEqual failed:
  ("[nil]") is not equal to ("[Optional("Count Swift files slowly")]")
Executed 21 tests, with 2 failures (0 unexpected)
```

With `keepOnly` recording `task.description` but not carrying it over — only the second half
missing, which is the half the brief names:

```
AgentActivityStoreTests.swift:275: XCTAssertEqual failed:
  ("[nil]") is not equal to ("[Optional("Count Swift files slowly")]")
Executed 21 tests, with 1 failure (0 unexpected)
```

**Gate.** `./scripts/ci.sh` — green, exit 0, run after the last edit. `Executed 743 tests, with 0
failures (0 unexpected)`, then `==> CI passed.` One test more than C3's 742, as one added test
should leave it. The row's layout carries no test, the same as C3.

### C5 — A subagent row is one line, and the store stops recording a subagent's tool

**Reported.** Looking at the rows C4 produced, the operator asked for the second line — the
subagent's in-flight tool name — to go. The first line, type plus description, stays exactly as it
is.

**Decision.** `SubagentRow`'s `VStack` collapses to the `HStack` that was its first line. That left
`AgentSubagent.toolName` with no reader outside its own tests, so the field is deleted rather than
kept as state nothing renders: `startTool`'s subagent branch now only upserts the row from
`agent_id`/`agent_type`, `keepOnly` no longer carries a tool over, and `finishTool` is the lead's
guard alone. The rule the field's two helpers existed to hold — a subagent's tool traffic must never
touch `leadToolName` — is unchanged and still pinned, since the tab chip (T10) reads that label and
is not affected by any of this.

The three tests that asserted a subagent's tool went with it. Two of them keep the case they were
written for by asserting the row instead: tool traffic that names a subagent still upserts its row
and still leaves the lead's label alone.

| File | State |
| --- | --- |
| `Sources/App/WorktreeRow.swift` | `SubagentRow` is one line: type, description |
| `Sources/App/AgentActivityStore.swift` | `AgentSubagent.toolName` removed; `startTool`, `keepOnly`, `finishTool` follow |
| `Tests/AgentActivityStoreTests.swift` | the four subagent-`toolName` assertions removed, two replaced by roster assertions |
| `docs/…/specs/…md` | Decisions 20, 24 and 25, and the subagent-row acceptance line |
| `CLAUDE.md` | the row is one line; a subagent's tool is not recorded |

**Evidence.** None to watch fail: this removes a rendered line and the state behind it, so there is
no behaviour to pin that the surviving tests do not already cover. The regression risk it does carry
— the lead's label being blanked by a subagent's `PostToolUse` — is exactly what
`testSubagentToolTrafficLeavesTheLeadToolAlone` still asserts, and it passed after the edit.

**Gate.** `./scripts/ci.sh` — green, exit 0, run after the last edit. `Executed 743 tests, with 0
failures (0 unexpected)`, then `==> CI passed.` The count is unchanged: no test was deleted, only
assertions inside three of them.

### C6 — A subagent row's text starts on the worktree row's title, and its slot carries a `└`

**Reported.** The C3 glyph was the wrong mark: a subagent row should read as nested inside the
worktree row above it, with its text on that row's **title** edge — where "Replace the JSONL-mti…"
starts, right of the `⌘N` badge column. Mid-change the operator amended it: the leading slot does
carry a glyph after all, but the `└` a terminal draws for a child line, not a node-graph symbol.

**Decision.** Nothing about the row's structure had to move: `SubagentRow` was already a `Label`
over a `SidebarIcon`, which is why its text already sits on the title column — measured on
screenshot 3 at 2x, the worktree title and the subagent text both ink at x = 83. So the change is
the glyph alone. `SidebarChildConnector` (`SidebarIcon.swift`, beside the slot geometry it is sized
from) strokes a `Path` 1 pt in `.secondary`: down the slot's centre from its top to its middle, then
out to the slot's trailing edge, in a box the width of the icon column. It is drawn rather than
typed because `└`'s shape belongs to the font and the sidebar's is proportional, and it is not
`arrow.turn.down.right`, which points at the row rather than joining it.

| File | State |
| --- | --- |
| `Sources/App/SidebarIcon.swift` | `SidebarChildConnector` and its private `ChildConnector` shape |
| `Sources/App/WorktreeRow.swift` | `SubagentRow`'s icon is the connector; the `point.3.connected.trianglepath.dotted` of C3 is gone |
| `docs/…/specs/…md` | Decision 24 |
| `CLAUDE.md` | the row's two columns and the connector |

**Gate.** `./scripts/ci.sh` — green, exit 0, run after the last edit. `Executed 743 tests, with 0
failures (0 unexpected)`, then `==> CI passed.` The count is unchanged, as a glyph-only change
should leave it.

### C7 — A status section header sits on its rows' two columns

**Reported.** Under Group by → Status the five headers are misaligned against the rows: the header's
glyph must sit on the `⌘N` badge's column and its label on the row title's column.

**What was measured.** Both operator screenshots, at 2x, with the symbols' own left bearings
measured off-app in the scratchpad (`NSImage(systemSymbolName:)` rendered to a bitmap, ink bounds
against the image frame) so an ink position could be turned into a frame position:

| Thing | Ink starts | Its bearing | So its slot/frame starts |
| --- | --- | --- | --- |
| Header glyph (`circle` and its four siblings, 11 pt) | 28 px | 2 px | 26 px = 13 pt |
| Worktree row `⌘N` badge (caption2 monospaced) | 30 px | 0 px | 30 px = 15 pt |
| Subagent row glyph (`point.3…`, 13 pt) | 33 px | 3 px | 30 px = 15 pt |
| Header label | 74 px | — | 13 + 18 + 6 = 37 pt |
| Worktree row title | 83 px | — | 15 + 18 + 8 = 41 pt |

So **both** columns were 4 pt out, not one: the glyph slot by 2 pt and the title by 4 pt. The title
carried the extra 2 pt because the header hand-set its icon-to-title gap to 6 while a row gets
`Label`'s own gap. That gap is **8 pt and does not scale with the font** — measured with an
`ImageRenderer` probe in the scratchpad, a `Label` of two rectangles at 11, 13 and 17 pt, whose
title ran from x = 52 px against a 36 px icon in all three.

**Decision.** The header is now the same `Label` over the same `SidebarIcon` the rows are built
from, so it has no icon-to-title gap of its own and the title column follows the glyph column by
construction; `headerIconSpacing` had no other reader and is deleted. `.labelStyle(.titleAndIcon)`
is stated on it, since a `Section` header is free to resolve a `Label` to another style and a header
that dropped its glyph would be a worse defect than the one being fixed. That leaves
`headerLeadingInset` as the one number, and it goes 4 → 6 pt: the measurement above puts the
header's raw inset at 15 − 6 = 9 pt against a row's 15 pt. Nothing else moves — the Worktrees header
and the group headers carry no inset and no icon slot, and neither did before.

| File | State |
| --- | --- |
| `Sources/App/SidebarIcon.swift` | `headerIconSpacing` removed; `headerLeadingInset` 4 → 6 with the measurement recorded |
| `Sources/App/SidebarView.swift` | `statusSection`'s header is a `Label` over a `SidebarIcon` |

**Gate.** `./scripts/ci.sh` — green, exit 0, run after the last edit. `Executed 743 tests, with 0
failures (0 unexpected)`, then `==> CI passed.` Layout carries no test; the count is unchanged, as
an alignment-only change should leave it.

### Review fixes

Four findings from the review of the built feature. One commit each, each through `./scripts/ci.sh`.
No operator-verified behaviour changes in any of them.

#### R1 — The hook toggle latches on the transition, not on the listener

**Reported.** `setEnabled` is driven from `ClearwayApp`'s `.onAppear`, which fires once per window.
`start()` latched only on `listener != nil`, so a bind that failed re-ran `AgentHookInstaller.install`
for every window opened after it; `stop()` had no latch at all, so with the toggle off every window
re-ran `uninstall`. Both are synchronous settings-file rewrites on the main actor.

**What landed.** One `private var isEnabled` on the monitor, set in `setEnabled` regardless of
whether the bind succeeded, so each transition runs the installer exactly once. `start()`'s
`guard listener == nil` goes with it — the latch above it is now the whole rule.

| File | State |
| --- | --- |
| `Sources/App/AgentActivityMonitor.swift` | `isEnabled` latch in `setEnabled`; `start()`'s listener guard removed |
| `Tests/AgentActivityMonitorTests.swift` | the two branches of the latch |

**Evidence.** Both watched red against the unfixed monitor, run under the suite's short temp home:

```
Tests/AgentActivityMonitorTests.swift:117: error: -[ClearwayTests.AgentActivityMonitorTests
  testASecondEnableDoesNotReachTheInstallerAfterABindThatFailed] : XCTAssertFalse failed - the
  second enable must run nothing, so the forwarder it already wrote stays gone
Tests/AgentActivityMonitorTests.swift:138: error: -[ClearwayTests.AgentActivityMonitorTests
  testDisablingAMonitorThatWasNeverEnabledReachesNoUninstaller] : XCTAssertEqual failed:
  ("4 bytes") is not equal to ("1853 bytes") - a monitor that never started has nothing to tear down
```

The enable case needs a bind that fails, or the old listener guard already covers it: a **directory**
standing where the socket goes makes `bind` fail without stopping the install, which is the shape
the finding names. The disable case needs no setup at all — it is the every-launch case, the toggle
off and `.onAppear` handing the monitor `false` once per window.

**Gate.** `./scripts/ci.sh` — green, exit 0, run after the last edit. `Executed 744 tests, with 0
failures (0 unexpected)`, then `==> CI passed.`

#### R2 — The dot's precedence is a pure static, not a SwiftUI body

**Reported.** Waiting > working > idle-with-notification > none, gated on `isOpen`, was split across
two SwiftUI bodies: `SidebarView` pre-applied the `isOpen` gate to the phase it passed down, and
`WorktreeRow`'s body switched on the result. Neither half is reachable from XCTest.

**What landed.** `WorktreeRow.dot(phase:hasNotification:isOpen:) -> Dot?`, beside `rowTexts` and for
the same reason, with the body switching on its result. `WorktreeRow` gained `isOpen` and
`SidebarView` now hands it the raw phase.

The lift made explicit a rule the split had hidden: **`isOpen` gates the phase alone.** `SidebarView`
forced the phase to `.idle` for a closed worktree but passed `hasNotification` through untouched, so
a closed worktree carrying a terminal notification has always shown the blue dot. That is the
behaviour the operator verified, so the static reproduces it exactly and two of the six cases pin it.

| File | State |
| --- | --- |
| `Sources/App/WorktreeRow.swift` | `Dot` and `dot(phase:hasNotification:isOpen:)`; the body switches on it; `isOpen` property |
| `Sources/App/SidebarView.swift` | passes the raw phase and `isOpen` |
| `Tests/WorktreeRowTests.swift` | `WorktreeRowDotTests`, six cases |
| `CLAUDE.md` | the precedence names the static, and says the gate is on the phase alone |

**Evidence.** No watched failure, and none is claimable: this extracts an existing rule unchanged
rather than fixing a defect, the same as `WorktreeRowTextTests` before it. The proof that it is
unchanged is the pair of closed-worktree cases above, which encode what the two bodies did between
them rather than what either said on its own.

**Gate.** `./scripts/ci.sh` — green, exit 0, run after the last edit. `Executed 750 tests, with 0
failures (0 unexpected)`, then `==> CI passed.` 744 → 750 is the six new cases.

#### R3 — The tab chip's tool name is its own observable

**Reported.** `MainTerminalTabStrip` took `@EnvironmentObject agentActivity` to read
`surfaceToolNames`, which changes twice per tool call and is app-wide. Every one of those changes
invalidated the whole strip in every window — against the file's own doc comment about scoping
`@ObservedObject` to the chip for exactly this reason.

**What landed.** `surfaceToolNames` moves off the monitor onto `AgentActivityMonitor.ToolNames`, a
nested `ObservableObject` the monitor holds as a plain `let` and `ClearwayApp` injects beside the
monitor itself. `TerminalTabChip` observes it directly and resolves its own surface's name;
`MainTerminalTabStrip` now reads nothing off the monitor at all, so it drops the environment object
rather than keeping a narrower one. The sidebar's two readers are untouched.

| File | State |
| --- | --- |
| `Sources/App/AgentActivityMonitor.swift` | nested `ToolNames`; `publish()` writes `toolNames.bySurface` |
| `Sources/App/MainTerminalTabStrip.swift` | the chip holds the `@EnvironmentObject`; the strip holds none, and passes no `toolName` |
| `Sources/App/ClearwayApp.swift` | `.environmentObject(agentActivity.toolNames)` |
| `Tests/AgentActivityMonitorTests.swift` | the republish case; the existing reader follows the value |
| `CLAUDE.md` | the monitor publishes two values, not three |

**Evidence.** Watched red against the code as committed at R1 — the sources restored from `git show
HEAD:…` with the test written against the old `surfaceToolNames` — then restored from the scratchpad:

```
Tests/AgentActivityMonitorTests.swift:90: error: -[ClearwayTests.AgentActivityMonitorTests
  testAToolNameChangeDoesNotRepublishTheMonitor] : Fulfilled inverted expectation
  "the monitor republished".
```

The case fires `UserPromptSubmit` first and waits for `.working`, so the phase is already where the
`PreToolUse` would leave it: the only value the tool event changes is the tool name, and an inverted
expectation on `monitor.objectWillChange` is what says so.

**Gate.** `./scripts/ci.sh` — green, exit 0, run after the last edit. `Executed 751 tests, with 0
failures (0 unexpected)`, then `==> CI passed.`

#### R4 — `~/.clearway`'s `0700` is reasserted, not assumed

**Reported.** `installScript` passed `dirMode` as a create attribute, so it applied only to a
directory Clearway created. `AgentHookScript` calls that mode the socket's whole access control, and
a `~/.clearway` that already exists — one predating the feature, or one a umask left wider — was
left as found.

**What landed.** The create drops the attribute and one `setAttributes` reasserts `0700` on both
directories on every install, the same shape as the script mode immediately below it.

| File | State |
| --- | --- |
| `Sources/App/AgentHookInstaller.swift` | the mode is reasserted per directory, not set by the create |
| `Tests/AgentHookInstallerTests.swift` | the pre-existing-directory case, and a `mode` helper |

**Evidence.** Watched red against the installer as committed at R3, restored from `git show HEAD:…`
and then restored from the scratchpad — `493` is `0o755`, `448` is `0o700`:

```
Tests/AgentHookInstallerTests.swift:140: error: -[ClearwayTests.AgentHookInstallerTests
  testTheClearwayDirectoriesAreNarrowedEvenWhenTheyAlreadyExist] : XCTAssertEqual failed:
  ("Optional(493)") is not equal to ("Optional(448)")
Tests/AgentHookInstallerTests.swift:141: error: … ("Optional(493)") is not equal to ("Optional(448)")
```

It is the suite's first case to drive `installScript`, which the file's own header had left to the
operator; it stays honest about the real `~/.clearway` because `install(home:)` takes the temp root.

**Gate.** `./scripts/ci.sh` — green, exit 0, run after the last edit. `Executed 752 tests, with 0
failures (0 unexpected)`, then `==> CI passed.`

#### R10 — Closing a project window retires its surfaces

**Reported.** Critical, and confirmed by two reviewers: `closeWorktree` and `removeSurface` are the
only manager-level doors that reach `Self.retireSurface`, and both run from explicit user actions.
`TerminalManager` is `@MainActor` with no `deinit`. So an agent working in a tab when the operator
closed the project window left its surface state in `AgentActivityMonitor` for the rest of the
session — reopening the project showed a lit dot and phantom subagent rows with no event left that
could clear them.

**What already happened on window close: nothing explicit.** The search found no
`NSWindow.willCloseNotification` observer, no `onDisappear`, and no teardown in `ProjectWindow` /
`ProjectContentView` — `closeAllSurfaces` exists only for `applicationWillTerminate`, through
`AppDelegate` and `TerminalManager.closeAllManagers`. The surfaces are freed by ARC: the window
closes, SwiftUI releases the `@StateObject` `TerminalManager`, and each `Ghostty.SurfaceView`'s
`SurfaceHandle` deinit reaches `ghostty_surface_free`, which SIGHUPs the shell. So this is not a
leak of the surfaces themselves, but it is an ARC-timed free that reports nothing, and it is why no
retirement happened. Two consequences stay out of scope and are recorded as follow-ups: the close is
not deterministic, and `CloseConfirmationDelegate` tells the operator "Close terminal sessions?"
for a close that never explicitly closes one.

**What landed.** `TerminalManager.retireAllSurfaces()` retires every surface the manager owns —
each main tab, the secondary shell and every task terminal — in one pass over `allSurfaces`.
`ProjectContentView` hangs it off `WindowCloseHandler`, an `NSViewRepresentable` that observes
`NSWindow.willCloseNotification` on whatever window its view lands in. Not an isolated `deinit`
(SE-0371 is barred at this deployment target, and reading `panes` from a nonisolated one is barred
anyway), and not the window delegate, whose slot `CloseConfirmationDelegate` already holds a layer
up where the window's managers are out of reach. The observation captures the closure, not the
view, so the retirement still runs once the close has released the view hierarchy that owned it;
the hop is `Task { @MainActor in }` rather than `assumeIsolated`, per the house rule, and it is safe
because that captured closure keeps the manager and its panes alive until it runs.
`closeAllSurfaces` calls the same method, so the static's "every door that drops a surface reports
it here" is true of the termination door too.

| File | State |
| --- | --- |
| `Sources/App/TerminalManager.swift` | `retireAllSurfaces()`; `closeAllSurfaces` calls it |
| `Sources/App/ProjectWindow.swift` | `WindowCloseHandler` + `WindowCloseHandlerView`; `ProjectContentView` retires on close |
| `Tests/WindowCloseHandlerTests.swift` | the door fires on its window's close, and not after the view has left it |
| `CLAUDE.md` | window close is a retirement door, and why it is neither a `deinit` nor the delegate |

**Evidence.** The defect's own proof is not reachable from XCTest: a surface needs a real
`ghostty_app_t`, so no test can put one in a manager to watch it stay counted. What is reachable is
the door, which needs only an `NSWindow`. Watched red with the observation registration removed
(`observation = nil` in its place) and the rest of the change in — the sources restored from the
scratchpad afterwards:

```
Tests/WindowCloseHandlerTests.swift:31: error: -[ClearwayTests.WindowCloseHandlerTests
  testClosingTheHostingWindowRunsTheHandler] : Asynchronous wait failed: Exceeded timeout of 2
  seconds, with unfulfilled expectations: "the window-close handler ran".
```

The retirement that door runs — that `allSurfaces` covers main tabs, the secondary and the task
terminals — stays manual, and is what the operator's Try line exercises.

**Gate.** `./scripts/ci.sh` — green, exit 0, run after the last edit. `Executed 762 tests, with 0
failures (0 unexpected)`, then `==> CI passed.`
