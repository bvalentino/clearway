# Stage, never submit, when a prompt is delivered to a running agent

**Date:** 2026-09-19
**Base:** 1206708 (`Keep worktree groups, order and grouping mode in git config (#230)`)

PR #229 fixed one of three prompt-delivery paths: a saved `.agent` command with auto-run off now
stages its prompt with `sendText` instead of running it. Two paths were left behind. The Prompts
aside's play button still goes through `sendToActiveMainTab(asCommand: false)`, which calls
`sendPaste` — trim, send, **press Enter** — so the prompt runs the moment it lands. And
`buildAgentPromptCommand` logs a failed prompt-file write and hands back the command anyway, so the
agent launches with `$(cat)` over a missing file and starts with an empty prompt. This change makes
staging one rule, applied at both staged call sites, and turns the write failure into a refused
launch with an alert instead of a silent empty start.

## Decisions

| # | Question | Decision | Source |
| --- | --- | --- | --- |
| 1 | What does the Prompts play button do instead of `sendPaste`? | Sends the prompt with `sendText` and no Enter, so it lands staged on whatever the active tab is running. `sendCommand` (`asCommand: true`, the Todos panel) is untouched — a todo is sent *to be run*. | Task |
| 2 | Is the text trimmed first? | Yes. `sendPaste` trims both ends today (`Sources/Ghostty/Ghostty.SurfaceView.swift:455`), and dropping that along with the Enter would *introduce* trailing-newline delivery where there is none now. A trailing `\n` is not inert: outside bracketed paste, libghostty rewrites every `\n` to `\r` (`ghostty/src/input/paste.zig:101-105`), which is an Enter — so an untrimmed "staged" prompt submits itself at any prompt without bracketed paste (`/bin/dash -i` is the case `TerminalManager+Commands.swift:47-49` already names). The new behaviour is exactly `sendPaste` minus `sendEnter`. | Spec author |
| 3 | Where does the trim rule live? | `TerminalManager.stagedText(_:)`, a pure `static` beside `promptDelivery` in `TerminalManager+Agent.swift`. Nothing on `Ghostty.SurfaceView` is reachable from XCTest, so a decision rule there gets lifted into a tested helper — the split CLAUDE.md requires and `promptDelivery` / `proceedsWithLaunch` already make. | Spec author |
| 4 | Does `startAgentTab`'s staged send use it too? | Yes. "Make the Prompts path match" is only true if there is one definition of what staging hands the surface; two call sites trimming differently is the same defect in a new place. One line at `TerminalManager+Agent.swift:106`, and it closes the same trailing-newline hole for a saved agent command whose text was typed with a trailing return. | Spec author |
| 5 | Does `sendToActiveMainTab` keep its `asCommand: Bool`? | Yes. Two call sites, one per value, and an enum for a two-valued flag with no third case is indirection this change does not need. Its doc comment is rewritten to say "runs" vs "stages" rather than naming the two surface primitives. | Spec author |
| 6 | Does `sendPaste` survive? | Yes — `TerminalManager+Panels.swift:20` still uses it to run a hook command in the secondary terminal, where Enter is wanted. It is no longer reachable from any prompt-delivery path. | Spec author |
| 7 | What does `buildAgentPromptCommand` return when the write fails? | `nil` (return type becomes `(command: String, promptFile: String)?`). `FileManager.createFile` reports only a `Bool`, so there is no error to carry and a `Result` or `throws` would invent detail that does not exist. The existing log line stays at the failure point, where the path is in hand, raised from `.warning` to `.error`. | Spec author |
| 8 | What does the caller do with `nil`? | `startAgentTab`'s `.argv` case ends its in-flight claim, opens **no** tab, and presents an `NSAlert` — `messageText` "Couldn't start \<command\>", `informativeText` naming the temp directory the write failed in. | Task + spec author |
| 9 | Why an alert, and why presented from the coordinator? | `NSAlert().runModal()` is this app's pattern for a fire-and-forget message (`ClearwayApp.swift:68`, `:90`; `OpenInMenu.swift:38-48`, whose comment rejects a `@Published` failure that "would have to be wired into both entry points' view trees for one message"). `startAgentTab` has four doors — ⌥⌘T, the `+` menu's agent rows, a saved agent command, a created worktree's first tab — so threading an outcome back would wire four. Only the argv path can fail this way, and it is a single point inside the coordinator. | Spec author |
| 10 | Is the alert wording a tested helper? | No. `OpenInAppLauncher.failureMessage` earns its `static` by branching on empty shell output; this message has no branching, and a test pinning a constant string pins nothing. The string is inlined at the one call site. | Spec author |
| 11 | Should the failure instead fall back to staged delivery (open bare, paste the prompt)? | No. The task says surface the failure rather than launch, and a silent downgrade from "run this prompt" to "type it in for me" is the same class of defect as the empty start it replaces. | Task |
| 12 | Does anything change for `submit: true` when the write succeeds, or for `.bare`? | No. Those paths are byte-for-byte what they are today. | Spec author |

## Assumptions

Each verified against the codebase at `1206708`, or against the vendored `ghostty/` submodule.
No probe scripts were written; the paste behaviour was read out of libghostty's source.

1. **`sendToActiveMainTab(asCommand: false)` has exactly one caller.** `ContentView.swift:729`, `sendPromptToTerminal`, the Prompts aside's play button. `asCommand: true` has exactly one, `TodosPanelView.swift:163`. (`grep -rn "sendToActiveMainTab" Sources`)
2. **`sendPaste` trims and presses Enter.** `Sources/Ghostty/Ghostty.SurfaceView.swift:454-459`: `trimmingCharacters(in: .whitespacesAndNewlines)`, guard non-empty, `sendText`, `sendEnter`. `sendText` (`:433-438`) does neither.
3. **An untrimmed trailing newline can submit.** `ghostty_surface_text` → `Surface.textCallback` → `completeClipboardPaste(text, allow_unsafe: true)` (`ghostty/src/Surface.zig:3237-3243`, `6019-6024`), which encodes with `input.paste.encode`. With bracketed paste off, that function replaces every `\n` with `\r` (`ghostty/src/input/paste.zig:101-105`); with it on, the data is fenced by `ESC[200~`/`ESC[201~` and newlines are literal (`:93-98`).
4. **`buildAgentPromptCommand` has exactly one non-test caller.** `TerminalManager+Agent.swift:90`, the `.argv` case of `startAgentTab`. Seven tests in `Tests/TerminalManagerTests.swift:154-247` call it directly and read `.command` / `.promptFile` off the tuple.
5. **The write failure is recoverable-looking and silent today.** `AgentLaunch.swift:47-56` logs a `.warning` and falls through; the recipe is `$1 "$(cat "$2")"` (`:57`), so a missing file makes `cat` fail and the agent receive `""`.
6. **`filePrefix` is a parameter with a default** (`AgentLaunch.swift:42`), and the file path is `NSTemporaryDirectory()` + `"\(filePrefix)-\(uuid).md"` (`:44-45`). A prefix containing a path separator names a directory that does not exist, so `createFile` fails — that is how the `nil` branch is reached from a test without touching permissions.
7. **`startAgentTab` must release its claim on every early return.** `TerminalManager+Agent.swift:80-83` already does this for the "pane is gone" bail, and nothing cancels the `Task`, so the `nil` branch has to do the same or the worktree's empty-state gate stays set for the process lifetime.
8. **`TerminalManager` already imports AppKit** (`TerminalManager.swift:1`); `TerminalManager+Agent.swift` imports only `GhosttyKit` and gains `import AppKit`.
9. **`NSAlert` from a coordinator has precedent.** `ClearwayApp.swift:68` and `:90` build and run one outside any view.
10. **`ContentView.swift` needs no edit.** The change is inside `sendToActiveMainTab`; the call site's arguments are unchanged. This matters because that file is past SwiftLint's 1000-line `file_length` error and survives only on a file-wide disable.
11. **`promptDelivery`'s `.staged` case is the one that sends text** (`TerminalManager+Agent.swift:101-106`); `.argv` and `.bare` send none.

## Objective

A prompt delivered to something already running is staged, never submitted, by every path that
delivers one — and a launch that cannot carry its prompt does not happen silently.

### Success criteria

- Prompts aside → play, with an agent running in the active tab: the prompt appears in the agent's
  input and is **not** sent. The tab takes focus, as it does today.
- Prompts aside → play, with a plain shell in the active tab: the prompt lands on the prompt line
  unrun, including when the prompt file ends with a newline.
- Todos panel → send: unchanged, still runs the line.
- A saved agent command with auto-run **on**, when the prompt file cannot be written: no tab opens
  and an alert names the failure. With auto-run on and the write succeeding: unchanged.
- A saved agent command with auto-run **off**: unchanged in behaviour, now routed through the same
  staging rule.
- `grep -rn "sendPaste" Sources` returns only `Ghostty.SurfaceView.swift` and
  `TerminalManager+Panels.swift`.
- `./scripts/ci.sh` green.

## Commands

Regression check for every build step, and the full gate at sign-off, are the same command:

```bash
./scripts/ci.sh
```

It regenerates the Xcode project, lints, builds and runs the test suite. Lint alone:

```bash
swiftlint lint --quiet
```

`ci.sh` does not refuse on a dirty tree, so run `git status --porcelain` before any CI stamp and
report untracked or ignored files — expect the un-gitignored `default.profraw` after any Debug
launch.

## Files this change touches

**Edited**

- `Sources/App/AgentLaunch.swift` — `buildAgentPromptCommand` returns
  `(command: String, promptFile: String)?` and answers `nil` on a failed write; the log line becomes
  an `.error` at that return. The doc comment states the `nil` contract and that the caller refuses
  the launch.
- `Sources/App/TerminalManager+Agent.swift` — new `static func stagedText(_:) -> String` beside
  `promptDelivery`; the staged send at `:106` goes through it; the `.argv` case handles `nil` by
  ending the claim, logging, presenting the alert and returning without appending a tab. Gains
  `import AppKit`.
- `Sources/App/TerminalManager.swift` — `sendToActiveMainTab`'s non-command branch becomes
  `surface.sendText(Self.stagedText(text))`; the doc comment is rewritten in terms of run vs stage.
- `Tests/TerminalManagerTests.swift` — the seven existing `buildAgentPromptCommand` cases unwrap the
  optional (`try XCTUnwrap`, each `func` gains `throws`).
- `CLAUDE.md` — the `AgentLaunch.swift` bullet (`:191-197`) gains the `nil`-on-write-failure contract
  and the refused launch; the staged-case paragraph (`:223-224`) becomes the one staging rule, naming
  `stagedText` and why the trim is load-bearing rather than cosmetic.

**New tests** (`Tests/TerminalManagerTests.swift`)

- `stagedText`: a trailing newline is removed; a leading one is removed; interior newlines survive
  intact; whitespace-only text reduces to empty; ordinary text is returned unchanged.
- `buildAgentPromptCommand` returns `nil` when the prompt file cannot be written (a `filePrefix`
  naming a directory that does not exist), and writes no file.

## Out of scope

- `sendCommand` and the Todos panel's send-to-terminal path.
- `TerminalManager+Panels.swift`'s hook-command `sendPaste`, where Enter is the point.
- Any change to argv delivery when the write succeeds, to `buildBareCommand`, or to the in-flight
  marker rules.
- Making `sendToActiveMainTab`'s flag an enum, or adding a third delivery mode.
- Recovering from a failed prompt-file write by retrying, choosing another directory, or falling back
  to staged delivery.
- `ShellSend` and the terminal-command path, which already stages its last line correctly.
