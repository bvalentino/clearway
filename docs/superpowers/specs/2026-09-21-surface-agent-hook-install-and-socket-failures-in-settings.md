# Surface agent-hook install and socket failures in Settings

**Date:** 2026-09-21
**Base:** 6afcc8d5a07022b79dc988c4716ae516460481ad

Settings → Appearance → Show agent activity reads on whenever the stored preference is on, whatever
happened when the feature tried to start. A socket that could not be bound, a settings file that
could not be parsed, backed up or written, and a machine with neither `~/.claude` nor `~/.codex` are
each logged through `Ghostty.logger` and nowhere else, so the user sees a toggle that is on and dots
that never light. This change gives `AgentActivityMonitor` one published health value, derived from
the last enable attempt, and renders its failure line under the toggle beside the existing Codex
`/hooks` line. The mapping from installer and listener outcomes to that line is a pure function with
no I/O, tested on its own. One failure the brief names cannot be observed today and is fixed here so
that it can be: a second Clearway unlinks the live socket before binding it, so it steals the feed
from the first instance and both report success. The listener now probes for a live owner, leaves it
alone, and reports it.

## Decisions

| # | Question | Decision | Source |
| --- | --- | --- | --- |
| 1 | Does the sidebar show anything when the monitor is unhealthy? | **No.** Settings is the one place that explains a feature that is not running. The sidebar's job is per-worktree state; a process-wide install failure has no worktree to attach to, and an icon that means "this whole feature is broken" sitting in a per-row column is a second vocabulary for the dot. The user's door to the explanation is the toggle they set. | Operator (brief recommendation, confirmed) |
| 2 | Where does the health value live? | One `@Published private(set) var health` on `AgentActivityMonitor`, set in `start()` from the enable attempt and reset to `.off` in `stop()`. It changes only on a toggle transition, so publishing it on the monitor costs nothing — unlike a tool name, which is why `ToolNames` is separate (`AgentActivityMonitor.swift:13-21`). | Spec |
| 3 | What is the pure part? | A new `Sources/App/AgentHookHealth.swift`, `import Foundation` only: the per-agent-file outcome, the install report, the health cases, one `static` resolve from (install report, socket outcome) to health, and the one-line message each case displays. The monitor and the installer produce the inputs; no rule lives in either. Same split as `AgentActivityStore`, and it is what keeps the mapping reachable from XCTest with no socket and no disk. | Operator (brief) + Spec |
| 4 | What are the failure cases, and in what precedence? | Most fatal first, exactly one displayed: **(a)** the socket is owned by another Clearway instance; **(b)** the socket could not be opened for any other reason; **(c)** the forwarder script could not be written; **(d)** neither `~/.claude` nor `~/.codex` exists, so no hooks were installed anywhere; **(e)** an agent settings file was refused — unreadable, not a JSON object, not re-serialisable, not backed up, or not written — naming the file. Otherwise `listening`. The socket outranks the rest because it is the single channel: with it closed, a perfect install delivers nothing. | Spec |
| 5 | Is a missing `~/.codex` alone a failure? | **No.** An absent agent directory is how "this agent is not installed here" is spelled (`AgentHookInstaller.swift:12-15`), and a user who has only Claude Code would otherwise carry a permanent warning about a tool they do not use. Absence is reported only when *every* agent directory is absent, which is the case where nothing will ever arrive. The brief's "a `~/.codex` directory that is absent" is narrowed to that here. | Spec (narrows the brief) |
| 6 | Is anything shown when the feature is healthy? | **No.** CLAUDE.md allows supporting copy only where it prevents error; a "Listening" confirmation restates the toggle. The existing Codex `/hooks` subtitle stays as it is — it is the documented exception and it is about a step the user must still take, not about a failure. | Spec (CLAUDE.md, "UI descriptions") |
| 7 | How is the failure line rendered? | As its own row directly under the toggle in the Appearance section, present only when the health has a message: a `Label(message, systemImage: "exclamationmark.triangle")` at `.callout`, matching the one warning idiom the app already has (`SidebarView.swift:300`, `DebugTerminalSheet.swift:15`). Not a third `Text` inside the `Toggle` label: macOS `Form` styling defines a title and a subtitle, a third `Text` is not a documented shape, and a subtitle cannot carry the warning symbol. | Spec |
| 8 | How does `SettingsView` reach the monitor? | As an `@ObservedObject` init parameter beside `settings`, passed in the `Settings` scene (`ClearwayApp.swift:246-249`). Not `.environmentObject`: the `Settings` scene is outside the project `WindowGroup`, and CLAUDE.md pins the monitor as injected on that `WindowGroup` only, so anything else reaching for it in the environment faults. A parameter keeps that statement true. | Spec (CLAUDE.md, `Sources/App/CLAUDE.md:407-410`) |
| 9 | Does a failed start change what the toggle stores? | **No**, and nothing has to change for that: `agentHooksEnabled`'s `didSet` writes to `UserDefaults` unconditionally (`SettingsManager.swift:84-88`) and `setEnabled` latches `isEnabled` before it calls `start()`, regardless of the outcome (`AgentActivityMonitor.swift:45-53`). Turning it on with a failing bind records on and the next launch retries. This is pinned by a test, not by new code. | Operator (brief) |
| 10 | Is there a retry affordance? | Nothing new. Toggling off and on is a transition, so `setEnabled` runs `stop()` then `start()` and the health line updates in place — the user who quits the other instance and flips the toggle sees it clear. A "Retry" button would be a second door to the same action. | Spec |
| 11 | Why does the listener probe for a live owner? | Because the failure the brief calls "another Clearway instance owning the socket" does not exist today: `listeningDescriptor` unlinks the path before binding (`AgentActivityMonitor.swift:160`), so the second instance always wins and the *first* goes deaf with no error anywhere. Both would display "listening", which is the exact lie this change exists to stop. The listener now `connect`s to the path first: connected means a live owner, so it neither unlinks nor binds and reports case (a); `ECONNREFUSED` means a stale inode, so it unlinks and binds as before; `ENOTSOCK`/anything else falls through to the same unlink-then-bind, which fails honestly as case (b). Verified in the scratchpad (Assumption 6). | Spec (fixes a precondition of the brief) |
| 12 | Does disabling still unlink the socket path? | Only when this process bound it. `stop()` unlinks unconditionally today (`AgentActivityMonitor.swift:82`), which after Decision 11 would let an instance that never bound destroy the live owner's socket — the retry in Decision 10 would break the instance the user is trying to keep. The unlink is gated on having been listening; the existing ordering (unlink after the listener is released, on the main actor both times) is unchanged. | Spec |
| 13 | What does the installer return? | `install(home:)` returns a report: whether the forwarder was written, and one outcome per agent settings file (`absent`, `installed`, `refused(path:)`). `uninstall(home:)` stays `Void` — health goes to `.off` and there is nothing to display. The existing log lines stay: the line names the file, the log carries the underlying error. | Spec |
| 14 | What do the messages say? | One sentence each, no second line: (a) "Another Clearway instance is using the hook socket."; (b) "The hook socket at ~/.clearway/hook.sock could not be opened."; (c) "The hook script could not be written to ~/.clearway/hooks."; (d) "No ~/.claude or ~/.codex directory was found, so no hooks were installed."; (e) "~/.claude/settings.json could not be updated." — the path abbreviated with a tilde. No "see Console", no instructions: the state is the information. | Spec |
| 15 | What happens to the zero-byte payload the probe delivers? | The owner's accept loop takes the probe connection, reads EOF, and logs "A hook payload of 0 bytes did not parse and was dropped." (`AgentActivityMonitor.swift:70-72`). An empty payload is dropped silently instead — it now has a routine source, and the warning exists to catch a *truncated* event, which is never empty. | Spec |

## Assumptions

Every assumption was verified at base `6afcc8d`. The socket behaviour was verified with a probe
script written **in the scratchpad**
(`/private/tmp/claude-501/…/8f9cf797-8c7f-4de1-b889-4cb07a9dca93/scratchpad/probe.py`); nothing was
written into the repo. This task integrates no third-party SDK or API — the surfaces are POSIX
sockets and the app's own files — so no vendor documentation was fetched.

1. **Every failure is logged and nowhere else.** `HookSocketListener.start` returns `nil` on any
   failure and the monitor assigns it straight to `listener` with no branch
   (`AgentActivityMonitor.swift:64-75`, `131`, `154-157`, `167-174`). `AgentHookInstaller.install`
   returns `Void`; each refusal is a `Ghostty.logger` call followed by `return`
   (`AgentHookInstaller.swift:19-22`, `64-66`, `85`, `93`, `104`, `116`, `140`). Nothing reaches a
   view.

2. **An absent agent directory is not even logged.** `merge` returns on its directory guard before
   any logging (`AgentHookInstaller.swift:73-74`), so today the "no hooks anywhere" case is silent
   in Console as well as in the UI.

3. **The stored preference is already independent of the outcome.** `SettingsManager.swift:84-88`
   writes on every `didSet`; `AgentActivityMonitor.swift:46-52` sets `isEnabled` before `start()`
   and ignores what `start()` achieved.

4. **`SettingsView` gets no environment objects.** The `Settings` scene passes `settings` by
   parameter and applies only `.preferredColorScheme` (`ClearwayApp.swift:246-249`); the monitor is
   injected on the project `WindowGroup` alone (`ClearwayApp.swift:175-176`).

5. **The existing two-`Text` toggle is the only helper copy in the form.** `SettingsView.swift:29-34`
   carries the Codex `/hooks` subtitle and the comment naming it the one exception.

6. **`connect` separates a live owner from a stale inode, and `bind` alone cannot.** Scratchpad
   probe, 2026-09-21, `AF_UNIX`/`SOCK_STREAM` on macOS 25.6: against a live listener `connect`
   succeeds and `bind` on the same path fails `EADDRINUSE`; after `unlink` the same `bind` succeeds
   and the path then answers to the *second* socket, which is the steal; with the listener closed
   and the inode left behind `connect` fails `ECONNREFUSED`; with a regular file or a directory at
   the path `connect` fails `ENOTSOCK`. The two existing bind tests stand on the last case —
   `testAStaleSocketFileDoesNotStopTheListenerBinding` puts a regular file there and
   `testASecondEnableDoesNotReachTheInstallerAfterABindThatFailed` puts a directory there
   (`Tests/AgentActivityMonitorTests.swift:50-58`, `147-159`), so both keep reaching the unlink and
   keep their current outcomes.

7. **The backlog absorbs the probe.** The listener calls `listen(descriptor, 64)`
   (`AgentActivityMonitor.swift:168`), so a probe `connect` completes without the owner accepting,
   and the probe closing immediately gives the owner a zero-byte read.

## Objective and success criteria

Give the user one honest line about why agent activity is not working, in the place they turned it
on.

1. With the hooks installed and the socket bound, the Appearance section is unchanged: the toggle
   and the Codex `/hooks` subtitle, no new copy.
2. With a bind that cannot succeed, the toggle stays on and one line under it names the socket.
3. With another Clearway already listening, the second instance does not unlink or rebind the path,
   the first instance keeps receiving events, and the second displays the "another Clearway
   instance" line.
4. With `~/.claude/settings.json` unreadable or not a JSON object, the line names that file.
5. With neither `~/.claude` nor `~/.codex` present, the line says no hooks were installed.
6. Turning the toggle on while any of those is true still stores `true`; the next launch retries.
7. Turning the toggle off from an unhealthy state unlinks nothing this process did not bind.
8. Toggling off and on re-attempts and the line updates or clears in place.
9. The whole mapping — every outcome combination to every displayed case, and each case's message —
   is covered by tests that touch no socket and no disk.

## Verification

```bash
./scripts/ci.sh
```

The regression check and the full gate are the same command here, per the project's `## Pipeline`
section. Note what it does on a developer machine: the test host launches the app, so the toggle's
default-on install rewrites the real `~/.claude/settings.json` and takes its one-time
`settings.json.clearway-backup`. That is the feature, not a test artefact. No test may reach the real
home — `AgentActivityMonitorTests` and `AgentHookInstallerTests` both drive a temp root, and the new
tests do the same or need no filesystem at all.

`git status --porcelain` before the sign-off stamp: a Debug launch drops an un-gitignored
`default.profraw` in the repo root.

## Files

- `Sources/App/AgentHookHealth.swift` — **new.** The per-file outcome, the install report, the health
  cases, the pure resolve, the messages. `import Foundation` only.
- `Sources/App/AgentHookInstaller.swift` — `install` returns the report; each refusal branch names
  its outcome instead of only logging.
- `Sources/App/AgentActivityMonitor.swift` — publishes `health`; `start()` resolves it from the
  install report and the socket outcome; `stop()` resets it and gates the `unlink` on having been
  listening; `HookSocketListener.start` reports which socket failure occurred and probes for a live
  owner before unlinking; an empty payload is dropped without the warning.
- `Sources/App/SettingsView.swift` — takes the monitor; renders the failure row under the toggle.
- `Sources/App/ClearwayApp.swift` — passes the monitor into the `Settings` scene.
- `Sources/App/CLAUDE.md` — the health value, the precedence, the live-owner probe and the gated
  unlink, in the agent-activity notes.
- `Tests/AgentHookHealthTests.swift` — **new.** The mapping and the messages.
- `Tests/AgentActivityMonitorTests.swift` — health after a bind that cannot succeed, health while
  another listener owns the path, that the owner's feed survives a second monitor's start and stop,
  and that a never-listening monitor's `stop()` leaves the path alone.
- `Tests/AgentHookInstallerTests.swift` — the report's outcomes for an absent directory, an
  unreadable file and a successful install.

## Out of scope

- Any sidebar, tab-strip or menu-bar indication of an unhealthy monitor (Decision 1).
- A per-agent breakdown of which agents got hooks (Decision 5).
- A Retry button, a Reveal-in-Finder button, or a link into Console (Decisions 10, 14).
- Repairing anything: a file Clearway cannot read is still left alone, and no settings file is
  quarantined or renamed.
- Health for anything after the enable attempt — a settings file the user breaks later, an agent that
  never fires a hook, or a Codex install the user has not trusted with `/hooks`. The value is the
  last enable attempt's outcome and nothing else.
- Changing what the toggle stores, its default, or when `ClearwayApp` drives it.
