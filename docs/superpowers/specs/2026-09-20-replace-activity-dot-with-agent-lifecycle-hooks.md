# Replace the JSONL-mtime activity dot with agent lifecycle hooks

**Date:** 2026-09-20
**Base:** b4369a5adaf99c58d5c7dcee82041c99b37c2f60

The sidebar's orange "working" dot is inferred from the newest `~/.claude/projects/<slug>/*.jsonl`
mtime with an 8-second expiry: Claude-only, binary, blind to subagents, unable to tell Clearway's own
tab from any other `claude` in the same directory, and suppressed for the main worktree because of
that. It is replaced by the lifecycle hooks Claude Code and Codex both ship. Clearway writes one
small forwarding script and a managed block of hook entries into `~/.claude/settings.json` and
`~/.codex/hooks.json`, stamps every terminal surface it opens with an identity in the surface's
environment, and listens on a Unix domain socket at a fixed path. Each hook invocation opens one
connection, writes two identity lines and the raw hook JSON, and closes. From that stream Clearway
keeps exact per-surface state — idle, working, waiting on permission — plus a roster of live
subagents, and derives the sidebar dot and a set of non-selectable child rows from it. No timers, no
directory guessing, and no dot at all for agents Clearway did not launch.

## Decisions

| # | Question | Decision | Source |
| --- | --- | --- | --- |
| 1 | What is the "local endpoint"? | A Unix domain socket at `~/.clearway/hook.sock`, `SOCK_STREAM`, one connection per event, server reads to EOF. No TCP port: nothing to allocate, nothing to discover after a relaunch, no listening-socket firewall exposure, and no network entitlement on an app that has none today (`Clearway.entitlements` holds one key, `com.apple.security.cs.allow-unsigned-executable-memory`). Access control is the `0700` mode on `~/.clearway`. | Spec (brief says "a local endpoint") |
| 2 | How does a hook script reach the socket? | `/usr/bin/nc -U -w 1 "$CLEARWAY_HOOK_SOCKET"`. Verified in the scratchpad (Assumption 1): 19 ms round trip, exit 0 and ~10 ms when the socket is missing or the identity is unset. macOS `nc` has **no** `-N` flag — its `-N` is `num_probes` — but it already shuts the write side down on stdin EOF, which is what lets the server read to EOF. `curl --unix-socket` was rejected: it speaks HTTP, so it would buy a request parser for nothing. | Spec (verified) |
| 3 | What framing carries the identity alongside the hook JSON? | A two-line preamble: line 1 the surface id, line 2 the worktree id, then the agent's raw JSON to EOF. No escaping, no `jq`, no `base64`, no length prefix. Embedding the worktree id *inside* the JSON was rejected: it is a filesystem path and escaping `"`/`\` in `/bin/sh` without `jq` is the kind of string surgery that fails on exactly the path that matters. Verified to carry a path with spaces and a pretty-printed multi-line payload intact. The only shape it cannot express is a path containing a newline, which a git worktree path does not have. | Spec (verified) |
| 4 | Which events are installed? | `SessionStart`, `SessionEnd`, `UserPromptSubmit`, `PreToolUse`, `PostToolUse`, `PermissionRequest`, `SubagentStart`, `SubagentStop`, `Stop`. `SessionEnd` is added to the brief's list: it is the only clear a surface Clearway no longer owns can get, and with no timer anywhere an orphaned session would otherwise pin a dot until the next launch. | Operator (brief) + Spec |
| 5 | How does an event identify its surface? | Three environment variables set on the surface at creation: `CLEARWAY_SURFACE_ID` (a UUID minted per `Ghostty.SurfaceView`), `CLEARWAY_WORKTREE_ID` (the worktree id, which is the worktree's path — `Worktree.swift:19`), and `CLEARWAY_HOOK_SOCKET`. A hook process inherits the parent environment (Assumption 3), so they reach the script through the shell and the agent. The script's first line is `[ -n "$CLEARWAY_SURFACE_ID" ] || exit 0`, which is what makes a `claude` started in Terminal.app a no-op. | Operator (brief) + Spec |
| 6 | Why carry the worktree id as well as the surface id? | Because the surface id does not survive a Clearway relaunch and the acceptance criteria require that an agent running across one still lights its dot. A worktree id is its path, which is stable. An event whose surface id is unknown to this process is still attributed to its worktree: the dot lights and subagent rows render; only the per-tab tool label is unavailable, because there is no tab to put it on. | Spec |
| 7 | Which surfaces get an identity? | The ones that can host an agent: a pane's main tabs, a pane's secondary shell, and a task's bottom terminal. The before-remove hook sheet (`ContentView.swift:710`) and the debug terminal (`DebugTerminalSheet.swift:47`) get none, so any agent typed into them is invisible — the same neutral no-op as a terminal Clearway did not launch. | Spec |
| 8 | How are the env vars passed to libghostty? | `ghostty_surface_config_s.env_vars` / `env_var_count`, which the header already declares (Assumption 2). `Ghostty.SurfaceView.init` gains one parameter, `worktreeId: String?`; the view mints `let surfaceId = UUID()` itself and stores `worktreeId` beside the existing `initialWorkingDirectory`. Nothing else changes at the call sites but that one argument. | Spec (verified) |
| 9 | What happens to a respawned secondary? | `replaceSurface` (`TerminalManager.swift:425`) passes the dead surface's stored `worktreeId` to the new one, which mints a fresh surface id. The dead id is retired, so its state and rows go with it. | Spec |
| 10 | Is the managed block versioned? | No. Clearway computes the block it wants, removes every entry it recognises as its own, inserts the desired one, and writes only if the result differs from what is on disk. Content reconciliation subsumes "refreshed when its recorded version differs" and cannot drift when the file is hand-edited. | Spec (supersedes the brief's version counter) |
| 11 | How is a Clearway entry recognised? | By `type == "command"` and a `command` string containing `/.clearway/hooks/clearway-hook.sh`. An emptied group, an emptied event array and an emptied `hooks` object are each removed in turn, so uninstalling leaves a file with no trace. No extra marker key is added to the entries: the schema is the agents', not Clearway's, and an unknown key is a validation risk for nothing. | Spec |
| 12 | Is `matcher` set? | No, it is omitted. The matcher means a different thing per event — tool name for `PreToolUse`, startup reason for `SessionStart`, agent type for `SubagentStart` — and an omitted matcher matches everything (Assumption 4). `"*"` is not a valid regex and would be a silent miss. | Spec (verified) |
| 13 | Does rewriting `settings.json` preserve the file byte-for-byte? | No, and it cannot with `JSONSerialization`, whose dictionaries are unordered. The file is re-serialised `.prettyPrinted` **and** `.sortedKeys` — deterministic, so every subsequent write is a no-op — and written atomically. The user's entries are preserved value-for-value, not byte-for-byte; key order and whitespace change once, on the first install. Before that first modification Clearway copies the file to `settings.json.clearway-backup`. An order-preserving JSON model was rejected as ~150 lines of parser to protect whitespace. The operator confirmed the value-for-value merge with the one-time backup after the spec was written. | Spec + Operator (confirmed) |
| 14 | What happens to a settings file that does not parse? | Nothing is written and the failure is logged through `Ghostty.logger`, the way `SettingsManager` logs an undecodable `openInApps`. No quarantine, no rename: unlike `SavedCommandStore`'s `commands.json`, this file is the user's and Clearway is a guest in it. | Operator (brief) + Spec |
| 15 | When is `~/.codex/hooks.json` written? | Only when `~/.codex` exists, and Clearway never creates it. An absent directory means Codex is not installed. | Operator (brief) |
| 16 | Do Codex hooks work as soon as Clearway writes them? | No. Codex records trust against a hook's hash and **skips new or changed hooks until the user trusts them** with `/hooks` (Assumption 5). Claude Code has no such gate — its `/hooks` menu is read-only and a settings edit is picked up by a file watcher. So the Settings toggle carries one line of copy naming the `/hooks` step for Codex. This is the deliberate exception to CLAUDE.md's "no helper text": without it a Codex user sees a toggle that is on and does nothing. The operator confirmed keeping that one line after the spec was written. | Spec (verified) + Operator (confirmed) |
| 17 | Where does the toggle live and what is its default? | Settings → Appearance, `Toggle("Show agent activity", …)`, default **on**, key `clearway.agentHooksEnabled` on `SettingsManager` beside `showDetachedWorktrees`. Turning it off uninstalls the block and closes the listener; turning it on installs and opens. | Operator (brief) |
| 18 | Who owns the listener and the roster? | One app-level `AgentActivityMonitor` (`@MainActor`, `ObservableObject`) as a `@StateObject` on `ClearwayApp`, injected with `.environmentObject`, the way `PortMonitor` and `CaffeineManager` already are (`ClearwayApp.swift:129-130,160-163`). It replaces the per-window `@StateObject` in `ProjectContentView` (`ProjectWindow.swift:80`): one process has one socket, and a per-window owner would try to bind it twice. | Spec |
| 19 | How is the state machine kept testable? | It is a separate value type, `AgentActivityStore`, with no I/O: `apply(_ event:)`, `retire(surfaceId:)`, `retire(worktreeId:)` and the derivations. `AgentActivityMonitor` owns one and does nothing but socket plumbing and publishing. Same split as `TerminalManager.firstTabSource` and `Worktree.visible` — a pure rule lifted out of an object no test can construct. | Spec |
| 20 | What are the transitions? | `SessionStart` → reset the surface entry to idle with an empty roster. `UserPromptSubmit` → working, clear the lead tool. `PreToolUse` with no `agent_id` → working, lead tool = `tool_name`; with an `agent_id` → upsert that subagent with `tool_name`, surface working. `PostToolUse` → clear the corresponding tool name, stay working. `PermissionRequest` → waiting on permission, recording `tool_name`. `SubagentStart` → upsert the subagent from `agent_id`/`agent_type` with no tool. `SubagentStop` → remove that subagent. `Stop` → idle, clear the lead tool **and the whole roster**, so a missed `SubagentStop` cannot pin a row. `SessionEnd` → drop the surface entry. Any event for a surface id that was retired in this process is ignored. | Operator (brief) + Spec |
| 21 | How is a worktree's dot derived? | `waiting > working > idle`, over every surface carrying that worktree id, including surfaces this process never owned. Working is any surface working **or** any surface holding a live subagent. Waiting wins over working because it is the state that needs the user. | Operator (brief) + Spec |
| 22 | What does "waiting on permission" look like? | Its **own** colour — a static 7 pt `.purple` dot, tooltip "Waiting for permission" — not the blue notification dot the spec first proposed. The operator overrode that reuse: waiting is a distinct state and must read as one at a glance. `.purple` is the pick because every other system hue is spoken for or misleading: orange is the working dot, blue is the plain-shell notification, red means failure throughout the app (`SidebarView.swift:301`, `TaskDetailView.swift:67`), green means success (`PromptListView.swift:56`, `WorktreeStatus.swift:28`), and yellow is both a status badge (`WorktreeStatus.swift:27`) and one hue family from orange, which at 7 pt is not distinguishable. Purple appears nowhere in `Sources/` today. Working keeps the orange pulsing dot unchanged; waiting does not pulse, so shape as well as hue separates them. Precedence in `WorktreeRow` is waiting, then working, then the plain-shell notification. | Operator (override) + Spec |
| 23 | Is the main worktree's dot still suppressed? | No. `SidebarView.swift:525`'s `!wt.isMain` goes: the suppression existed only because the mtime heuristic could not tell Clearway's tab from any other. `isOpen` stays, since a worktree with no pane has no surface to report. | Operator (brief) |
| 24 | How do subagent rows render? | As extra views inside the existing `ForEach` body, after the worktree row: no `.tag`, so they are not selection destinations (the precedent is the search, loading and error rows in `worktreesSection`); `.moveDisabled(true)`; `.padding(.leading, SidebarRowMetrics.statusRowIndent)`, the metric status sections already use to indent past the icon column. Text only, no icon: the agent type, with the in-flight tool name as a secondary caption. No `OutlineGroup`, no `DisclosureGroup` — the sidebar has neither today. | Spec |
| 25 | Is the subagent's description shown? | Yes, when a `Stop` supplies one — beside the type on the same line, the way Claude Code's own status line writes the pair (`general-purpose  Count Swift files slowly`), with the in-flight tool still below. `SubagentStart` carries no description and the correlation out of the `Agent` tool's `PreToolUse` this originally rejected is still rejected, but the captured payloads of change C4's predecessor show `Stop`'s `background_tasks` entries carry `description` beside `id`/`type`/`status`/`agent_type`. It is stored on the roster row and a later event that omits it never blanks it, so the row keeps the summary for the subagent's whole life. Type alone remains what a row falls back to. | Operator (change C4) + Spec (captured payload) |
| 26 | Is `ClaudeSessionFiles` deleted? | No — only its Claude-specific half. `makeWatcher` has four other callers (`TodoManager.swift:137`, `PromptManager.swift:144`, `WorkTaskManager.swift:374,452`) and CLAUDE.md names it the single door every `DispatchSource` must go through. The path helpers (`encodePathForClaude`, `projectsParentDir`, `projectDir(forWorktreePath:)`) go with `ClaudeActivityMonitor`, and the file and enum are renamed to `FileWatchers` so the name stops claiming a Claude relationship it no longer has. The brief's "`ClaudeSessionFiles`' watcher are deleted" is corrected here. | Spec (correction) |
| 27 | How does the monitor learn a surface is gone? | A `static` callback on `TerminalManager`, wired once in `ClearwayApp.init` to the monitor's `retire`, mirroring the `SurfaceView.claimsShortcut` provider CLAUDE.md already describes as the right shape for a process-scoped seam. It fires from `removeSurface`, `replaceSurface`, `cleanupState(for:)` and the task-terminal close. Reconciling against a list of live surfaces was rejected: it would prune exactly the orphaned ids Decision 6 depends on. | Spec |
| 28 | Does the lead's tool name reach the tab? | Yes, on the tab chip in `MainTerminalTabStrip`, as secondary text beside the surface title, present only while a tool is in flight. | Operator (brief) |

## Assumptions

Every assumption below was verified against the codebase at base `b4369a5`, against the vendored
`ghostty.h`, or by fetching the vendor documentation on 2026-09-20. The transport was verified with
a probe script written **in the scratchpad**
(`/private/tmp/claude-501/…/scratchpad/hook.sh`, `srv2.py`); nothing was written into the repo.

1. **`nc -U` delivers the payload and fails fast.** Probe, 2026-09-20: a script piping a two-line
   preamble plus a pretty-printed multi-line JSON body into `/usr/bin/nc -U -w 1 <socket>` delivered
   `b'1F2E\n/Users/x/my repo/.worktrees/a b\n{\n  "hook_event_name": "PreToolUse", …'` to a listening
   `AF_UNIX` server in 0.019 s, and the server's `recv` loop saw EOF without any shutdown flag. With
   `CLEARWAY_SURFACE_ID` unset the script exits 0 in 0.009 s; with the socket path missing it exits 0
   in 0.012 s. `/usr/bin/nc` and `/usr/bin/curl` are both present in the base system. macOS `nc -h`
   lists `-N num_probes  Number of probes to send before generating a write timeout event`, so
   OpenBSD's `-N` shutdown flag does not exist here — a script using it fails.

2. **libghostty accepts per-surface environment variables.**
   `ghostty/include/ghostty.h:416-419` declares
   `typedef struct { const char* key; const char* value; } ghostty_env_var_s;` and lines 448-449 of
   the `ghostty_surface_config_s` struct declare `ghostty_env_var_s* env_vars;` and
   `size_t env_var_count;`. The header the build actually compiles against,
   `ghostty/macos/GhosttyKit.xcframework/macos-arm64_x86_64/Headers/ghostty.h`, carries the same
   declarations at the same lines, so the prebuilt binary's ABI matches.
   `ghostty/src/apprt/embedded.zig:538-549` consumes them by `alloc.dupeZ`-ing key and value into the
   surface config's arena and putting them into `config.env.map`, which is **merged** into the child
   environment rather than replacing it. Because Zig dupes, the Swift-side C strings need to live
   only across the `ghostty_surface_new` call — but they do need to live across it, which is why the
   existing nested `withCString` shape in `Ghostty.SurfaceView.swift:76-93` must be generalised
   rather than replaced with a temporary.

3. **Hook processes inherit the environment of the terminal that started the agent.** Claude Code
   hooks reference, fetched 2026-09-20: "A hook process inherits the parent environment, apart from
   the `OTEL_*` exporter variables that Claude Code removes from every subprocess it spawns and, when
   `CLAUDE_CODE_SUBPROCESS_ENV_SCRUB` is set to `1`, the variables it strips." Codex's page states
   all hooks "inherit session working directory context". Neither strips arbitrary user variables.

4. **An omitted matcher matches every occurrence of the event.** Claude Code hooks guide, fetched
   2026-09-20: "Matching on `.*` or leaving the matcher empty would auto-approve every tool
   permission prompt, including file writes and shell commands." The same page's matcher table shows
   the matcher's meaning changing per event — tool name for `PreToolUse`, `startup|resume|clear|…`
   for `SessionStart`, agent type for `SubagentStart`/`SubagentStop` — which is why one literal
   cannot be shared across nine events.

5. **Claude Code picks settings edits up live; Codex requires a trust step.** Claude Code hooks
   reference, fetched 2026-09-20: "Direct edits to hooks in settings files are normally picked up
   automatically by the file watcher", and the guide: "The `/hooks` menu is read-only. To add,
   modify, or remove hooks, edit your settings JSON directly or ask Claude to make the change."
   There is no snapshot-at-startup statement anywhere on either page. Codex hooks page, fetched
   2026-09-20: "Before a non-managed hook can run, Codex requires you to review and trust the exact
   hook definition", and it "records trust against the hook's current hash, so new or changed hooks
   are marked for review and skipped until trusted"; the escape hatch is
   `--dangerously-bypass-hook-trust`, which Clearway will not set for the user.

6. **The event fields the state machine relies on exist on both agents.** Claude Code hooks
   reference, fetched 2026-09-20 — common fields on every event: `session_id`, `cwd`,
   `hook_event_name`, plus `agent_id` ("Unique identifier for subagent (when inside subagent)") and
   `agent_type` ("Agent name (when using `--agent` or inside subagent)"). `PreToolUse` and
   `PostToolUse` carry `tool_name`, `tool_input`, `tool_use_id`; `PermissionRequest` carries
   `tool_name`, `tool_input`, `tool_use_id`; `SubagentStart` carries `agent_type` and `agent_id` and
   **nothing else**; `SubagentStop` adds `last_assistant_message`; `Stop` carries
   `last_assistant_message` and `stop_reason`; `SessionStart` carries `startup_reason`.
   Codex hooks page, fetched 2026-09-20 — common fields `session_id`, `cwd`, `hook_event_name`,
   `model`, `transcript_path`, `permission_mode`, `turn_id`; `PreToolUse`/`PostToolUse` carry
   `tool_name`, `tool_use_id`, `tool_input`; `PermissionRequest` carries `tool_name`, `tool_input`;
   `SubagentStart`/`SubagentStop` carry `agent_id`, `agent_type`, `turn_id`. So the four fields
   Clearway reads — `hook_event_name`, `agent_id`, `agent_type`, `tool_name` — are spelled
   identically on both, and nothing needs to know which agent sent an event.

7. **A `command` hook with no `args` runs through a shell on both agents.** Claude Code hooks
   reference, fetched 2026-09-20: "**Shell form** runs when `args` is absent. The `command` string is
   passed to a shell: `sh -c` on macOS and Linux…". Codex's documented example is
   `"command": "python3 ~/.codex/hooks/session_start.py"`, whose `~` only resolves under a shell. So
   `"$HOME"/.clearway/hooks/clearway-hook.sh` is a portable spelling for both.

8. **A worktree id is a stable filesystem path.** `Sources/App/Worktree.swift:19` —
   `var id: String { path ?? branch ?? "" }`. `TerminalManager.panes` is keyed by it
   (`TerminalManager.swift:14,136`), as are `notifiedWorktrees`, `openWorktreeIds`, `asideVisible`
   and the rest. That is what makes it usable as an identity that outlives the process.

9. **One initializer creates every terminal in the app.**
   `Ghostty.SurfaceView.init(_:workingDirectory:command:)` at `Ghostty.SurfaceView.swift:61`, with
   eight construction sites: `TerminalManager.swift:142` (pane secondary), `:296-300` (`appendTab`,
   the sole door for main tabs), `:308` (`appendTab`'s cold pane path), `:425` (`replaceSurface`),
   `TerminalManager+TaskTerminals.swift:22` and `:87` (task bottom terminal),
   `ContentView.swift:710` (before-remove hook sheet) and `DebugTerminalSheet.swift:47`.

10. **The sidebar has no hierarchy today and an established way to fake one.**
    `SidebarView.swift:66-77` is a flat `List(selection:)`; grouping is `Section` + `ForEach`
    (`:231-252`, `:270-323`, `:358-393`, `:396-430`). There is no `OutlineGroup` and no
    `DisclosureGroup` anywhere in `Sources/`. Status sections indent their rows with
    `SidebarRowMetrics.statusRowIndent` (`SidebarIcon.swift:14`), and three rows inside
    `worktreesSection` — the search field (`:277-279`), the loading row (`:291-296`) and the error
    row (`:298-319`) — are already non-selectable purely by carrying no `.tag`.

11. **Both dots are drawn in `WorktreeRow`, not in `SidebarView`.** `WorktreeRow.swift:49-69`: an
    orange 7 pt `Circle` with a pulsing shadow and `.help("Claude is working")` when `isWorking`,
    else a blue 7 pt `Circle` with `.help("Terminal notification")` when `hasNotification`.
    `SidebarView.swift:524-525` computes both flags, and `:525` is where
    `isOpen && !wt.isMain && …workingWorktreeIds.contains(wt.id)` suppresses the dot for main.

12. **The app is not sandboxed.** `Clearway.entitlements` contains only
    `com.apple.security.cs.allow-unsigned-executable-memory`. Binding a Unix socket under `$HOME` and
    writing `~/.claude/settings.json` need no entitlement. Release builds do enable the hardened
    runtime (`project.yml`), which does not restrict either.

13. **`~/.claude/settings.json` and `~/.codex` both exist on the development machine**, so both
    install paths and the "`~/.codex` absent" path are exercisable by hand. Neither file's contents
    were read.

## Objective and success criteria

Replace an mtime heuristic with exact, agent-reported state, and show what the agent is actually
doing. Done when:

- A fresh launch on a machine with user hooks already in `~/.claude/settings.json` leaves every
  user entry intact as a value and adds Clearway's beside them. Turning the toggle off removes only
  Clearway's entries and leaves the file with no trace of them.
- `~/.codex/hooks.json` is written only when `~/.codex` exists. A settings file that does not parse
  is left untouched, the failure is logged, and that agent simply shows no dot.
- Submitting a prompt in a Clearway agent tab lights the worktree dot within a second; that tab's
  `Stop` clears it. No timer-based expiry exists anywhere in the new code.
- A permission prompt switches the dot to the waiting treatment; answering it returns to working;
  focusing the tab does not clear it.
- Spawning a subagent adds a non-selectable child row under the worktree naming its type and its
  in-flight tool; the row goes on that subagent's `SubagentStop`, and any surviving rows go on the
  lead's `Stop`.
- Two worktrees each running an agent show independent dots and rows. A `claude` started in
  Terminal.app in the same directory changes nothing.
- The main worktree row shows the dot when its tab is working.
- Quitting and relaunching Clearway with an agent still running: the agent's next event lights that
  worktree's dot in the new instance.
- An agent in a task's bottom terminal counts toward its worktree's dot and roster.
- `./scripts/ci.sh` is green, with tests covering the state transitions, the settings merge, the
  identity round trip and the dot derivation, none of which needs a running agent or a
  `ghostty_app_t`.

## Verification

From the project's `## Pipeline` section. One command serves as both the per-task regression check
and the sign-off gate:

```bash
./scripts/ci.sh
```

It regenerates the Xcode project (without which new Swift files are invisible to the build), lints,
builds and runs the test suite. Before any CI stamp or sign-off, also run:

```bash
git status --porcelain
```

and report untracked or ignored files; they block sign-off. Expect the un-gitignored
`default.profraw` after any Debug launch.

## Files this change touches

New, in `Sources/App/`:

- `AgentHookEvent.swift` — the wire model. `AgentHookEnvelope.parse(_ data: Data) -> AgentHookEnvelope?`
  splits the two preamble lines from the JSON body and decodes `hook_event_name`, `agent_id`,
  `agent_type`, `tool_name`. Pure.
- `AgentActivityStore.swift` — `SurfacePhase`, `SubagentState`, `SurfaceState`, the `apply`/`retire`
  transitions of Decision 20 and the derivations of Decision 21. Pure; no I/O, no actor.
- `AgentActivityMonitor.swift` — `@MainActor ObservableObject` owning one store, the socket and the
  installer. Publishes the per-worktree phase and the per-worktree subagent roster. Its socket and
  `DispatchSource` handlers are built in a `nonisolated static` factory, never inside an isolated
  method, per CLAUDE.md's `DispatchSource` rule.
- `AgentHookScript.swift` — the script text as a constant, plus the `~/.clearway` layout
  (`hook.sock`, `hooks/clearway-hook.sh`) and the `0700`/`0755` modes.
- `AgentHookSettings.swift` — the pure merge: `install(into:)` / `uninstall(from:)` over a decoded
  JSON object, the recognition rule of Decision 11, and the empty-container collapse.
- `AgentHookInstaller.swift` — the file side: parse, apply, compare, back up once, write atomically,
  log a parse failure, skip Codex when `~/.codex` is absent.

Changed:

- `Sources/Ghostty/Ghostty.SurfaceView.swift` — `init` gains `worktreeId: String?`; the view gains
  `let surfaceId = UUID()` and `let worktreeId: String?`; the nested `withCString` shape generalises
  to carry the `ghostty_env_var_s` array across `ghostty_surface_new`.
- `Sources/App/TerminalManager.swift` — passes `worktreeId` at `:142`, `:296-300`, `:308` and `:425`;
  gains the `static` retire callback of Decision 27 and calls it from `removeSurface`,
  `replaceSurface` and `cleanupState(for:)`.
- `Sources/App/TerminalManager+TaskTerminals.swift` — passes the main worktree's id at `:22` and
  `:87`, and retires the surface when a task terminal closes.
- `Sources/App/ClearwayApp.swift` — the app-level `@StateObject` and `.environmentObject`, the
  `TerminalManager` retire wiring beside the existing `SurfaceView.claimsShortcut` wiring, and the
  install/uninstall on launch.
- `Sources/App/ProjectWindow.swift` — drops the per-window `ClaudeActivityMonitor` `@StateObject`
  and its `.environmentObject`.
- `Sources/App/ContentView.swift` — drops the `@EnvironmentObject` and both `updateWorktrees` calls
  (`:340`, `:403`); gains nothing.
- `Sources/App/SidebarView.swift` — `worktreeRowView` reads the phase instead of
  `workingWorktreeIds`, `!wt.isMain` goes, and the enclosing `ForEach` bodies emit the subagent child
  rows.
- `Sources/App/WorktreeRow.swift` — `isWorking: Bool` becomes the three-way phase; the blue dot gains
  the waiting meaning and its tooltip.
- `Sources/App/MainTerminalTabStrip.swift` — the tab chip shows the lead's in-flight tool name.
- `Sources/App/SettingsManager.swift`, `Sources/App/SettingsView.swift` — the key, the published
  property and the Appearance toggle with its one line of Codex copy.
- `Sources/App/ClaudeSessionFiles.swift` → `Sources/App/FileWatchers.swift` — keeps `makeWatcher` and
  `defaultWatchMask`, loses the Claude path helpers, renames the enum; four call sites follow.
- `Sources/App/ClaudeActivityMonitor.swift` — deleted.
- `Tests/RAIICleanupTests.swift` — `testClaudeActivityMonitorDeallocates` becomes the equivalent for
  `AgentActivityMonitor`, proving the socket source is cancelled.
- New tests: `AgentHookEnvelopeTests`, `AgentActivityStoreTests`, `AgentHookSettingsTests`,
  `AgentHookIdentityTests` (the env-pair → preamble → parse round trip).
- `CLAUDE.md` — a bullet for the hook pipeline under `Sources/App/`, the `ClaudeSessionFiles`
  rename in the Concurrency section's `DispatchSource` rule, and the sidebar-dot sentence.

## Out of scope

- Grok. It documents no hooks; `agentAllowlist` is untouched.
- Persisting the roster or any state across a relaunch. It is rebuilt from events only.
- A dot for a session Clearway did not start, or for any session while the toggle is off.
- Any change to what the desktop-notification dot does for a plain shell, or to
  `TerminalManager.notifiedWorktrees`' population and focus-clearing.
- Cost, context, token or status-line data. Only lifecycle and tool events.
- `~/.codex/config.toml`, `<repo>/.codex/hooks.json`, project-level `.claude/settings.json`, and
  plugin-bundled hooks. One user-level file per agent.
- Making a subagent row selectable, draggable, groupable or a drop target.
- Reading or surfacing `tool_input`, `last_assistant_message`, `transcript_path` or
  `permission_mode`.
- Blocking, allowing or otherwise deciding anything from a hook. Every entry Clearway installs is
  neutral: it prints nothing and exits 0.
- Prompting the user to run Codex's `/hooks` trust step, or passing
  `--dangerously-bypass-hook-trust` on their behalf.

## Open risks

- **Codex hooks do nothing until trusted** (Decision 16). The toggle can be on, the file correct, and
  a Codex agent still report nothing until the user runs `/hooks` once. One line of settings copy is
  the whole mitigation; there is no API to pre-trust a hook.
- **`PreToolUse`/`PostToolUse` spawn a script per tool call.** Accepted, as the brief says. The
  script is five lines of `/bin/sh` and a 19 ms `nc` round trip, but it is still a fork per tool
  call on both sides of every call. If agents measurably slow down, the tool-name readout is the
  first thing to cut, which means dropping exactly those two events.
- **Rewriting `settings.json` reorders its keys once** (Decision 13). Sorted output is stable
  afterwards, and a backup is taken, but a user who keeps that file in git will see one large diff.
- **Extra rows inside a reorderable `ForEach`.** Subagent rows are emitted from the same `ForEach`
  body as the worktree row, whose `.onMove` indexes the worktree collection. The indices do not
  change, but SwiftUI's drag targeting across a variable number of views per element is not
  something a unit test can pin. If it misbehaves, the fallback is to suppress subagent rows while a
  drag is in progress.
- **An orphaned session can pin a dot.** A pre-relaunch agent killed with `SIGKILL` fires neither
  `Stop` nor `SessionEnd`, and there is no timer by design. The dot clears on the next Clearway
  relaunch. Accepted.
- **`nc` is the transport.** It is a base-system binary and the probe is unambiguous, but a user who
  shadows `nc` on `PATH` breaks forwarding silently. The script calls `/usr/bin/nc` by absolute path
  to close that.
