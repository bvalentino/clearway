# Plan: Stage, never submit, when a prompt is delivered to a running agent

**Date:** 2026-09-19
**Base:** 1206708 (`Keep worktree groups, order and grouping mode in git config (#230)`)

Breaks down `docs/superpowers/specs/2026-09-19-stage-never-submit-prompt-to-running-agent.md`. Every
design decision below is carried from that spec; this document only orders the work and says how each
piece is verified.

## Architecture decisions carried from the spec

1. **Staging is one rule with one definition**: `TerminalManager.stagedText(_:) -> String`, a pure
   `static` beside `promptDelivery` in `TerminalManager+Agent.swift`. It trims both ends
   (`.whitespacesAndNewlines`) and returns the result. Both staged call sites go through it.
   (Decisions 3, 4.)
2. **The trim is load-bearing, not cosmetic.** Outside bracketed paste libghostty rewrites every
   `\n` to `\r` (`ghostty/src/input/paste.zig:101-105`), which is an Enter — so an untrimmed
   "staged" prompt submits itself at a prompt without bracketed paste. The new behaviour is exactly
   `sendPaste` minus `sendEnter`. (Decision 2, Assumption 3.)
3. **The Prompts aside's play button stages.** `sendToActiveMainTab`'s `asCommand: false` branch
   becomes `surface.sendText(Self.stagedText(text))` instead of `surface.sendPaste(text)`.
   `asCommand: true` (the Todos panel) is untouched — a todo is sent *to be run*. (Decision 1.)
4. **`sendToActiveMainTab` keeps its `asCommand: Bool`.** Two call sites, one per value; an enum for
   a two-valued flag is indirection this change does not need. Only its doc comment changes, to say
   "runs" vs "stages" rather than naming the surface primitives. (Decision 5.)
5. **`sendPaste` survives** — `TerminalManager+Panels.swift:20` still runs a hook command with it,
   where Enter is the point. After this change it is reachable from no prompt-delivery path.
   (Decision 6.)
6. **`buildAgentPromptCommand` returns `(command: String, promptFile: String)?` and answers `nil`
   when the prompt file cannot be written.** `FileManager.createFile` reports only a `Bool`, so
   there is no error to carry; a `Result` or `throws` would invent detail that does not exist. The
   existing log line stays at the failure point, raised from `.warning` to `.error`. (Decision 7.)
7. **The caller refuses the launch.** `startAgentTab`'s `.argv` case, on `nil`: ends its in-flight
   claim if it owns it, opens **no** tab, presents an `NSAlert` and returns. No fallback to staged
   delivery, no retry, no other directory — a silent downgrade is the same class of defect as the
   empty start it replaces. (Decisions 8, 11.)
8. **The alert is presented from the coordinator**, `NSAlert().runModal()`, this app's pattern for a
   fire-and-forget message (`ClearwayApp.swift:68`, `:90`; `OpenInMenu.swift:38-48`). `startAgentTab`
   has four doors, so threading an outcome back would wire four. `messageText` is
   "Couldn't start \<command\>"; `informativeText` names the temp directory the write failed in. The
   wording is inlined at the one call site, not a tested helper — it has no branching. (Decisions 9,
   10.)
9. **Nothing changes for `submit: true` when the write succeeds, or for `.bare`.** (Decision 12.)
10. **`ContentView.swift` is not edited.** The change is inside `sendToActiveMainTab`; the call
    site's arguments are unchanged. That file is past SwiftLint's `file_length` error and survives
    only on a file-wide disable. (Assumption 10.)

## Dependency graph

```
T1 (stagedText + both staged call sites)
        │
        ▼
T2 (buildAgentPromptCommand → optional, refused launch + alert)
        │
        ▼
T3 (CLAUDE.md)
```

T1 and T2 are independent in content but must run in order: both edit
`Sources/App/TerminalManager+Agent.swift` and `Tests/TerminalManagerTests.swift`. T3 documents both
and runs last.

## Regression command

Every task's criteria are verified with the project's regression command:

```bash
./scripts/ci.sh
```

It regenerates the Xcode project, lints, builds and runs the test suite. A new Swift file is
invisible to the build until `xcodegen generate` runs, which is why no hand-written `xcodebuild`
line substitutes.

### T1: One staging rule, applied at both staged call sites

**Files**

- `Sources/App/TerminalManager+Agent.swift`
- `Sources/App/TerminalManager.swift`
- `Tests/TerminalManagerTests.swift`

**What it does**

Adds `static func stagedText(_ text: String) -> String` to the `TerminalManager` extension in
`TerminalManager+Agent.swift`, beside `promptDelivery`. Its body is
`text.trimmingCharacters(in: .whitespacesAndNewlines)`. Its doc comment states why the trim is
load-bearing: outside bracketed paste libghostty turns a trailing `\n` into `\r`, so untrimmed
"staged" text submits itself.

Routes both staged sends through it:

- `TerminalManager+Agent.swift:106` — the `.staged` tail of `startAgentTab` becomes
  `surface.sendText(Self.stagedText(prompt))`. Its existing comment is updated: the rule is no longer
  "`sendText`, not `sendPaste`" but "`stagedText` + `sendText`, the one staging rule".
- `TerminalManager.swift:227-235` — `sendToActiveMainTab`'s `else` branch becomes
  `surface.sendText(Self.stagedText(text))`, replacing `surface.sendPaste(text)`. The doc comment at
  `:225-226` is rewritten in terms of run vs stage: `asCommand: true` runs the text as a command,
  `false` stages it on whatever the tab is running without submitting it.

`sendPaste`'s non-empty guard is not carried over. `sendText("")` writes zero bytes, and
`transferFirstResponder` already ran on the empty-text path today, so the two are indistinguishable
in behaviour.

**Acceptance criteria**

- `grep -rn "sendPaste" Sources` returns only `Sources/Ghostty/Ghostty.SurfaceView.swift` (the
  definition) and `Sources/App/TerminalManager+Panels.swift` (the hook command). No
  prompt-delivery path names it.
- `sendToActiveMainTab`'s `asCommand: true` branch is byte-for-byte unchanged, and
  `Sources/App/ContentView.swift` and `Sources/App/TodosPanelView.swift` have no diff.
- New tests in `Tests/TerminalManagerTests.swift`, under a `// MARK: - stagedText` section, pin:
  a trailing newline is removed; a leading newline is removed; interior newlines survive intact;
  whitespace-only text reduces to `""`; ordinary text is returned unchanged.

**Verification**

- `./scripts/ci.sh` green, with the new `stagedText` tests running.
- `grep -rn "sendPaste" Sources` shows exactly the two surviving files.

### T2: A prompt file that cannot be written refuses the launch

**Files**

- `Sources/App/AgentLaunch.swift`
- `Sources/App/TerminalManager+Agent.swift`
- `Tests/TerminalManagerTests.swift`

**What it does**

`buildAgentPromptCommand`'s return type becomes `(command: String, promptFile: String)?`. When
`FileManager.createFile` answers `false`, it logs at `.error` (the existing message and path, raised
from `.warning`) and returns `nil` at that point — the recipe and command string are never built. The
success path is unchanged. The doc comment gains the `nil` contract and states that the caller
refuses the launch rather than starting the agent with an empty prompt.

`TerminalManager+Agent.swift` gains `import AppKit` (it imports only `GhosttyKit` today;
`TerminalManager.swift:1` already imports AppKit, so the module is available). The `.argv` case of
`startAgentTab`'s `Task` becomes a `guard let launch = buildAgentPromptCommand(...) else { ... }`:
on `nil` it ends the in-flight claim when `ownsLaunch`, presents the alert, and `return`s without
calling `appendTab`. Releasing the claim on this early return is mandatory — nothing cancels the
`Task`, and `TerminalManager+Agent.swift:80-83` already does the same for the "pane is gone" bail; a
leaked claim leaves the worktree's empty-state gate set for the process lifetime.

The alert is built and run inline:

```swift
let alert = NSAlert()
alert.messageText = "Couldn't start \(command)"
alert.informativeText = "..."   // names NSTemporaryDirectory()
alert.runModal()
```

`.bare` and `.staged` delivery are untouched.

**Acceptance criteria**

- The seven existing `buildAgentPromptCommand` cases in `Tests/TerminalManagerTests.swift:154-247`
  unwrap the optional with `try XCTUnwrap`; each `func` gains `throws`. Their assertions are
  otherwise unchanged.
- A new test: `buildAgentPromptCommand` with a `filePrefix` containing a path separator — naming a
  subdirectory of `NSTemporaryDirectory()` that does not exist — returns `nil` and leaves no file at
  the path it would have used.
- On the `nil` branch `startAgentTab` appends no tab and calls `endAgentLaunch` when `ownsLaunch`.
- With the write succeeding, argv delivery is unchanged: the command string, the prompt file and the
  tab are what they are today.

**Verification**

- `./scripts/ci.sh` green, with the `nil` case and the seven rewritten cases running.
- `swiftlint lint --quiet` reports no new errors for the added `import AppKit` and the alert block.

### T3: Record the two rules in CLAUDE.md

**Files**

- `CLAUDE.md`

**What it does**

Two surgical edits, no rewrite:

- The `AgentLaunch.swift` bullet (around `:191-197`) gains the `nil`-on-failed-write contract and
  that the caller refuses the launch with an alert rather than starting the agent on an empty
  prompt.
- The staged-case paragraph (around `:223-224`) becomes the one staging rule: staged delivery is
  `stagedText` + `sendText` at **both** call sites — `startAgentTab`'s `.staged` tail and
  `sendToActiveMainTab(asCommand: false)` — and the trim is load-bearing, not cosmetic, because
  outside bracketed paste libghostty rewrites `\n` to `\r` and an untrimmed trailing newline is an
  Enter. Note that `sendPaste` survives only for the hook command in `TerminalManager+Panels.swift`,
  where Enter is wanted.

**Acceptance criteria**

- Both bullets state the contract a future reader would otherwise have to rediscover from
  `paste.zig`.
- No other section of `CLAUDE.md` is touched, and no line is rewritten that the change does not
  affect.

**Verification**

- `git diff CLAUDE.md` shows only those two regions.
- `./scripts/ci.sh` green (unchanged by a docs edit, run as the regression check for the step).

## Out of scope

Carried from the spec: `sendCommand` and the Todos panel's send path; the hook-command `sendPaste`;
argv delivery when the write succeeds; `buildBareCommand`; the in-flight marker rules; making
`asCommand` an enum or adding a third delivery mode; recovering from a failed write by retrying,
choosing another directory, or falling back to staged delivery; `ShellSend` and the terminal-command
path.

## Build log

### T1: One staging rule, applied at both staged call sites

**What landed**

| File | State |
| --- | --- |
| `Sources/App/TerminalManager+Agent.swift` | `static func stagedText(_:) -> String` added beside `promptDelivery`; `.staged` tail now `surface.sendText(Self.stagedText(prompt))`; gains `import Foundation` |
| `Sources/App/TerminalManager.swift` | `sendToActiveMainTab`'s `else` branch is `surface.sendText(Self.stagedText(text))`; doc comment rewritten as run vs stage |
| `Tests/TerminalManagerTests.swift` | new `// MARK: - stagedText` section, four cases |
| `Sources/App/ContentView.swift`, `Sources/App/TodosPanelView.swift` | untouched, as planned |

**Evidence**

The four `stagedText` cases were written first and watched fail against the unfixed code. `./scripts/ci.sh` on that tree:

```
❌ Tests/TerminalManagerTests.swift:426:40: type 'TerminalManager' has no member 'stagedText'
❌ Tests/TerminalManagerTests.swift:427:40: type 'TerminalManager' has no member 'stagedText'
❌ Tests/TerminalManagerTests.swift:428:40: type 'TerminalManager' has no member 'stagedText'
❌ Tests/TerminalManagerTests.swift:433:40: type 'TerminalManager' has no member 'stagedText'
❌ Tests/TerminalManagerTests.swift:437:40: type 'TerminalManager' has no member 'stagedText'
❌ Tests/TerminalManagerTests.swift:438:40: type 'TerminalManager' has no member 'stagedText'
❌ Tests/TerminalManagerTests.swift:442:40: type 'TerminalManager' has no member 'stagedText'
```

The behavioural half of the task — the Prompts play button no longer pressing Enter — has no test
that can watch it fail: `sendToActiveMainTab` needs a `Ghostty.SurfaceView`, and nothing on that
type is reachable from XCTest. The decision rule is what got lifted out and pinned, the split
CLAUDE.md requires. The call-site change is pinned instead by the grep criterion below.

**Deviations**

One, small: the plan named only the two edits, but `stagedText`'s body needs
`trimmingCharacters(in:)`, so `TerminalManager+Agent.swift` gains `import Foundation` (it imported
only `GhosttyKit`). T2's planned `import AppKit` is unaffected.

The old three-line comment at the `.staged` send is deleted rather than reworded. Its content —
why staged delivery does not press Enter — now lives on `stagedText`'s doc comment, where the rule
itself is; restating it at the call site would be the second copy this task exists to remove.

**Gate**

`./scripts/ci.sh` — passed, exit 0. 560 tests, 0 failures.

Acceptance greps:

- `grep -rn "sendPaste" Sources` → `Sources/Ghostty/Ghostty.SurfaceView.swift:454` (the definition)
  and `Sources/App/TerminalManager+Panels.swift:12,20` (the hook command). No prompt-delivery path
  names it.
- `git diff --stat` → three files, none of them `ContentView.swift` or `TodosPanelView.swift`.

### T2: A prompt file that cannot be written refuses the launch

**What landed**

| File | State |
| --- | --- |
| `Sources/App/AgentLaunch.swift` | `buildAgentPromptCommand` returns `(command: String, promptFile: String)?`; the failed-write branch is now a `guard` that logs at `.error` (same message and path) and returns `nil` before the recipe is built; doc comment carries the `nil` contract and the refused launch |
| `Sources/App/TerminalManager+Agent.swift` | gains `import AppKit`; the `.argv` case is a `guard let launch = buildAgentPromptCommand(...)` that, on `nil`, ends the claim when `ownsLaunch`, runs an `NSAlert` and returns without `appendTab` |
| `Tests/TerminalManagerTests.swift` | the seven existing `buildAgentPromptCommand` cases unwrap with `try XCTUnwrap` and gained `throws`; one new case pins the `nil` branch |

**Evidence**

The `nil` case was written first and watched fail against the unfixed code. `./scripts/ci.sh` on that
tree:

```
✖ test_buildAgentPromptCommand_returnsNil_whenThePromptFileCannotBeWritten, XCTAssertNil failed:
  "(command: "/bin/sh -c 'export PATH=\"$3\"; set -f; $1 \"$(cat \"$2\")\"; rc=$?; rm -f \"$2\";
  exit $rc' -- 'claude' '/var/folders/.../clearway-missing-dir-80DBBF01-.../prompt-A1F1A5D7-....md'
  '/opt/homebrew/bin:/usr/bin:/bin'", promptFile: "...")"
  - an unwritable prompt file must refuse the launch, not build a command
Executed 561 tests, with 1 failure (0 unexpected)
```

That failure is the bug itself: with the write failed, the builder still handed back a command whose
`$(cat)` over the missing file seeds the agent with an empty prompt.

`try XCTUnwrap` on the seven existing cases is a no-op against the pre-change signature —
`XCTUnwrap` takes `T?` and a non-optional `T` promotes — so those seven neither failed nor needed to.
Their assertions are unchanged.

The refused launch itself has no test that can watch it fail: `startAgentTab` needs a
`ghostty_app_t` and `appendTab` builds a `Ghostty.SurfaceView`, neither reachable from XCTest. The
decision rule is what got lifted out — `buildAgentPromptCommand`'s `nil` — and it is pinned; the
`guard` at the call site is one branch over it.

**Deviations**

None. The alert wording is the planned shape: `messageText` "Couldn't start \<command\>",
`informativeText` naming `NSTemporaryDirectory()`, inlined at the single call site with
`.warning` style and an OK button, matching `OpenInMenu.presentFailure`.

**Gate**

`./scripts/ci.sh` — passed, "==> CI passed.", 561 tests, 0 failures. `swiftlint lint --quiet` — exit
0; the only two warnings are pre-existing (`WorktreeConfigStore.swift:406`, `WorktreeDraft.swift:17`)
and neither is in a file this task touched.

`git status --porcelain` before the commit: the three files above, modified, nothing untracked.

### T3: Record the two rules in CLAUDE.md

**What landed**

| File | State |
| --- | --- |
| `CLAUDE.md` (`AgentLaunch.swift` bullet) | the `buildAgentPromptCommand` paragraph gains the `nil`-on-failed-write contract, and that `startAgentTab`'s `.argv` case ends its claim when it owns it, runs an `NSAlert` naming the command and the temp directory, and opens no tab — with the no-fallback-to-a-bare-tab rule stated |
| `CLAUDE.md` (`startAgentTab` bullet, staged case) | the "`sendText`, never `sendPaste`" sentence becomes the one staging rule: `stagedText` + `sendText` at both call sites, `sendToActiveMainTab(asCommand: false)` named as the second; why the trim is load-bearing (`paste.zig` rewriting `\n` to `\r`); `sendPaste` surviving only for `TerminalManager+Panels.swift`'s hook command; `stagedText` added to the list of `static` rules testable without a `ghostty_app_t` |

The wording was written against the two shipped diffs (`git show 5ace77e`, `git show 2d29ebd`), not
against the plan, so it records `buildAgentPromptCommand`'s optional return and the alert raised from
`startAgentTab` as they actually landed.

**Evidence**

A documentation task has no test that can watch anything fail; the acceptance criteria are the
diff's shape, and both hold:

- `git diff CLAUDE.md` → two hunks, at the `AgentLaunch.swift` bullet and at the staged-case
  paragraph. `15 insertions(+), 5 deletions(-)` in one file; no other section touched, and the five
  deleted lines are the four-line staged-case sentence plus the one line the new `nil` paragraph
  extends.
- `git status --porcelain` before the commit → `M CLAUDE.md` alone. No `default.profraw`, nothing
  untracked.

**Deviations**

None.

**Gate**

`./scripts/ci.sh` — passed, "==> CI passed.", exit 0. 561 tests, 0 failures. The two SwiftLint
warnings are the pre-existing pair (`WorktreeConfigStore.swift:406`, `WorktreeDraft.swift:17`).
