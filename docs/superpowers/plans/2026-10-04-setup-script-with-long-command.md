# Plan: Setup tab types the After create hook verbatim, once

Breaks down `docs/superpowers/specs/2026-10-04-setup-script-with-long-command.md`.

**Date:** 2026-10-04
**Base:** b144719 (Spec: Setup tab types the After create hook verbatim, once)

The spec's Decisions table (D1-D10) is the source of truth. This plan orders the work and says how
it is verified. It decides nothing new.

## Architecture decisions carried from the spec

- D1: the Setup tab types the interpolated hook string exactly as `openSetupTab` receives it,
  through the existing `surface.sendPaste(hook)` (trim ends, paste, Enter). No wrapper.
- D2: `openSetupTab` no longer calls `ShellEnvironment.awaitPath()`. The login shell's `PATH` is
  the authority.
- D3: `hookShellCommand` (`Sources/App/ContentViewHelpers.swift`) and `HookShellCommandTests` are
  unchanged. Before remove (`ContentView.swift:762`) becomes its only caller.
- D4: the duplicate echo comes from injecting on the first OSC 7, which zsh emits from the first
  `precmd` hook, before ZLE takes the tty out of cooked mode. Command length is irrelevant.
- D5: `TerminalManager.awaitShellPrompt` waits while `surface.pwd == nil || surface.needsConfirmQuit`,
  under the same 750 ms `shellReadinessFallback` and 10 ms `shellReadinessPoll`. No libghostty
  patch, no new C export.
- D6: with `confirm-close-surface = false` the gate degrades to today's `pwd` gate; with `always`
  every wait runs to the 750 ms fallback. Accepted.
- D7: the other `awaitShellPrompt` callers (saved shell commands, the staged plan launch,
  `startAgentTab`'s staged prompt) take the new gate with no code change.
- D8: bash and fish readiness are out of scope.
- D9: the readiness fix and the Setup-tab change are one task.
- D10: no new unit test. `Ghostty.SurfaceView` is not reachable from XCTest. Verification is
  `./scripts/ci.sh` plus the operator's manual check of the spec's criteria 1-10. Agents never
  launch the app.

## Dependency graph

```
T1 (prompt gate + verbatim Setup hook)   single task, no dependencies
```

## Tasks

### T1: Gate on the prompt mark and type the Setup hook verbatim

**Files:**
- `Sources/App/TerminalManager+Commands.swift`
- `Sources/App/TerminalManager+Setup.swift`
- `Sources/App/CLAUDE.md`

**What it does:**

1. `TerminalManager+Commands.swift`, `awaitShellPrompt(on:)`: change the loop condition from
   `surface.pwd == nil` to `surface.pwd == nil || surface.needsConfirmQuit`, keeping the deadline
   check and the poll sleep. Rewrite the doc comment above it to state: the gate is a reported
   `pwd` and the cursor being at a prompt (`needsConfirmQuit` is `false` only once the `133;A`
   mark, which zsh integration puts inside the first `PS1`, has been drawn); why the first OSC 7
   alone was early (zsh emits it from the first `precmd`, before ZLE leaves cooked mode, so text
   sent then is echoed raw under the login banner and replayed on the prompt line); the
   `confirm-close-surface` dependency (`false` falls back to the `pwd` gate, `always` to the 750 ms
   fallback); and keep the existing fallback rationale for shells without integration and agent
   tabs. Drop measurements in the current comment that the spec's finding contradicts (the claim
   that text sent on the OSC 7 edge "ran exactly once"). Keep it short; per the user's rules a
   comment exists only to prevent a regression.
2. `TerminalManager+Setup.swift`, `openSetupTab`: delete `let path = await ShellEnvironment.awaitPath()`
   and replace `surface.sendPaste(hookShellCommand(hook, path: path))` with
   `surface.sendPaste(hook)`. The `Task { @MainActor in … }` keeps `awaitShellPrompt` then
   `sendPaste`. `appendTab(..., name: "Setup", activate: false)` is untouched. Update the doc
   comment only if it no longer matches (it says "run the After create hook at its first prompt",
   which still holds).
3. `Sources/App/CLAUDE.md`, the `appendTab` / Setup-tab note at lines 335-342: say the hook is
   typed verbatim into the Setup tab's login shell at its first prompt (no `/bin/sh -c`, no `PATH`
   export, no failure banner), and that Before remove is now the only user of `hookShellCommand`.
   Do not touch line 221 or the `sendPaste` note at 380-382; both remain accurate.

**Acceptance criteria:**
- `awaitShellPrompt` returns only when `pwd` is non-`nil` and `needsConfirmQuit` is `false`, or at
  the 750 ms deadline; constants unchanged.
- `TerminalManager+Setup.swift` contains no `awaitPath` and no `hookShellCommand`; it calls
  `sendPaste(hook)` after `awaitShellPrompt`.
- `hookShellCommand`, `ContentView.swift`'s Before remove path, `HookShellCommandTests`,
  `TerminalManager+Agent.swift`, and the other `awaitShellPrompt` call sites are unchanged
  (`git diff --stat b144719` lists only the three files above).
- `./scripts/ci.sh` exits 0 after the last edit, with no new SwiftLint warnings in the touched files.

**Verification:**
- `./scripts/ci.sh`; report the command and exit status.
- `grep -n "awaitPath\|hookShellCommand" Sources/App/TerminalManager+Setup.swift` prints nothing.
- `grep -rn "hookShellCommand(" Sources/App --include=*.swift` shows only the definition in
  `ContentViewHelpers.swift` and the call in `ContentView.swift`.
- `git diff --stat b144719` lists exactly the three files.
- Spec criteria 1-10 (hook shown once and run, no wrapper text, live shell after, Before remove
  unchanged, other injection paths intact) are checked by the operator in a Debug build. The build
  agent does not launch the app.

## Risks

| Risk | Impact | Mitigation |
| --- | --- | --- |
| A user config with `confirm-close-surface = always` makes every prompt wait take 750 ms. | Low | Accepted in D6; behaves like a shell without integration does today. |
| Bash and fish still race (D8). | Low | Out of scope; reported as a follow-up in the spec. |

## Build log

### T1: Gate on the prompt mark and type the Setup hook verbatim

| File | State |
| --- | --- |
| `Sources/App/TerminalManager+Commands.swift` | `awaitShellPrompt` loops while `surface.pwd == nil \|\| surface.needsConfirmQuit`, same 750 ms fallback and 10 ms poll. Doc comment rewritten: prompt-mark gate, why the first OSC 7 was early, the `confirm-close-surface` dependency; the "ran exactly once" measurement and the "3.5x" ratio built on it are gone. |
| `Sources/App/TerminalManager+Setup.swift` | `openSetupTab` no longer awaits `ShellEnvironment.awaitPath()`; it calls `surface.sendPaste(hook)` after `awaitShellPrompt`. |
| `Sources/App/CLAUDE.md` | Setup-tab note: hook typed verbatim at the first prompt, no `/bin/sh -c`, no `PATH` export, no failure banner; Before remove is the only `hookShellCommand` user. |

**Evidence.** No watched failure: per D10 there is no unit test, since `Ghostty.SurfaceView` is not
reachable from XCTest. Checks run after the last code edit:
- `grep -n "awaitPath\|hookShellCommand" Sources/App/TerminalManager+Setup.swift` prints nothing.
- `grep -rn "hookShellCommand(" Sources/App --include='*.swift'` shows only
  `ContentViewHelpers.swift:20` (definition) and `ContentView.swift:762` (Before remove).
- `git diff --stat b144719` before committing listed exactly the three files above (this plan file
  was untracked and is committed alongside).
- `swiftlint lint --quiet` on the two Swift files: exit 0, no output.

**Deviations.** None.

**Gate.** `./scripts/ci.sh` exit 0: 950 tests, 0 failures, "CI passed."

**Operator check.** Spec criteria 1-10 in a Debug build; the build agent did not launch the app.

### Simplify

Rewrapped one over-long line in the `Sources/App/CLAUDE.md` Setup-tab note; no code change. `hookShellCommand`'s `path:` parameter stays, since `HookShellCommandTests` passes it.
