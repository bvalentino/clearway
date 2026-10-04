# Setup tab types the After create hook verbatim, once

**Date:** 2026-10-04
**Base:** be4a80f (Bundle clearway skill and add skill installer to Settings, #268)

The Setup tab that opens when Clearway creates a worktree pastes the After create hook wrapped
in `/bin/sh -c '…'`, with the app's whole `PATH` exported and a red failure banner, and the text
appears twice: once raw under `Last login`, then again on the prompt line. This change types the
interpolated hook into the Setup tab's login shell exactly as configured, with no wrapper, and
moves the shared "shell is at a prompt" wait off the first OSC 7 and onto the prompt mark, which
is what stops the duplicate. The Before remove sheet keeps its wrapper unchanged.

## Decisions

| # | Question | Decision | Why |
| --- | --- | --- | --- |
| D1 | What does the Setup tab type? | The interpolated hook string returned by `WorktreeManager.hookCommand(\.afterCreate, …)`, unchanged, through the existing `sendPaste` (trim ends, paste, Enter). | Brief, In scope. `sendPaste` is the one path that already submits (`Sources/App/CLAUDE.md:381-383`); the hook is single-line (brief, Constraints), so trimming changes nothing a user typed. |
| D2 | Does the Setup tab still await `ShellEnvironment.awaitPath()`? | No. The call goes. | It only fed `hookShellCommand`'s `export PATH=` (`TerminalManager+Setup.swift:11-13`). The brief makes the login shell's `PATH` the authority. |
| D3 | What happens to `hookShellCommand`? | Unchanged. Before remove is its only caller after this change (`ContentView.swift:762`), and `HookShellCommandTests` stays as is. | Brief, Out of scope: Before remove keeps the wrapper, `PATH` export and banner. |
| D4 | Why does the existing readiness wait let the paste through? | Root cause, reproduced in a scratchpad probe: the gate is "first non-`nil` `pwd`" (`TerminalManager+Commands.swift:106-111`), and zsh emits that OSC 7 from the **first** `precmd` hook, before the remaining `precmd` hooks run, before the prompt is drawn, and before ZLE switches the tty out of cooked mode. Text written in that window is echoed by the kernel line discipline (the raw copy under `Last login`) and then read by ZLE as typeahead and redrawn on the prompt line (the second copy). | See A1-A4. The window measured 3.6-4.2 ms on the operator's shell setup (oh-my-zsh, `mise activate`), against a gate whose detection latency is a main-queue hop plus a 0-10 ms poll, so the race is lost some of the time, and every time when another await (here `awaitPath`) returns after `pwd` is already set and the loop exits without sleeping. The length of a command does not matter: the probe reproduced it with `echo HOOKTEXT_MARKER`. |
| D5 | What is the fix? | `awaitShellPrompt` waits until `pwd != nil` **and** `!surface.needsConfirmQuit`, under the same 750 ms deadline and 10 ms poll. | `ghostty_surface_needs_confirm_quit` returns `!cursorIsAtPrompt()` under the default `confirm-close-surface = true` (A5). Ghostty's zsh integration puts the `133;A` prompt mark inside `PS1` for the first prompt (A3), so the cursor is "at prompt" only once ZLE draws the prompt, and the probe found ECHO already off every time `133;A` reached the master (A4). It is a change to one function, already-exposed C API, no libghostty patch. Keeping `pwd` in the condition means a config that makes `needsConfirmQuit` constant can only make the wait as good as today's, never shorter (D6). |
| D6 | What about a user whose Ghostty config sets `confirm-close-surface`? | Accepted. `false`: `needsConfirmQuit` is always `false`, so the gate is today's `pwd` gate. `always`: it is always `true`, so every prompt wait runs to the 750 ms fallback, which is how a shell without integration already behaves. The operator's config does not set the key (A6). | Clearway loads the user's Ghostty config files (`Ghostty.Config.swift:25-26`), so the key is theirs. The only exact signal, a C export of `cursorIsAtPrompt`, needs a patch to the upstream `ghostty` submodule and a framework rebuild; that is not a contained change and buys correctness only for those two non-default settings. |
| D7 | Are the other callers of `awaitShellPrompt` changed? | They get the new gate with no code change: saved shell commands (`TerminalManager+Commands.swift:17`), the staged plan launch in the task terminal (`:72`), and `startAgentTab`'s staged prompt (`TerminalManager+Agent.swift:111`). | For the two login-shell callers the wait grows by the ~4 ms window and their text now lands on a ready prompt. An agent tab `exec`s over the shell and never reports `pwd`, so it still pays the full fallback, exactly as today (`TerminalManager+Commands.swift:100-102`). |
| D8 | Bash and fish | Not fixed by this change and not made worse. | Ghostty's bash integration prints `133;A` and OSC 7 from `PROMPT_COMMAND` with `printf` (`ghostty/src/shell-integration/bash/ghostty.bash:243,251`), before readline takes the terminal, so for bash both signals arrive equally early. Not probed. Reported as a follow-up. |
| D9 | Is the readiness fix split into its own task? | No. It is a contained change to one function plus its doc comment. | Brief, Open risks, third bullet: split only if the fix needs more than a contained change. |
| D10 | Tests | No new unit test. Verified by `./scripts/ci.sh` and the operator's manual check of the acceptance criteria. | Nothing on `Ghostty.SurfaceView` is reachable from XCTest (`Sources/App/CLAUDE.md:389-391`), and the gate is a two-term condition over two surface reads. Agents do not launch the app (memory: no screenshot verification by agents). |

## Assumptions

Checked against the tree at `be4a80f`. Two probes ran in the session scratchpad, never in the
repo: `probe.py` and `gap.py` spawn `zsh -il` on a pty with `ZDOTDIR` pointing at the
submodule's `ghostty/src/shell-integration/zsh`, the operator's own `~/.zshrc` loading, and
record when OSC 7 and `133;A` reach the master and when the tty's `ECHO` flag clears.

| # | Assumption | Evidence |
| --- | --- | --- |
| A1 | The current gate is the first non-`nil` `pwd`, set from libghostty's PWD action. | `TerminalManager+Commands.swift:106-111`; `Ghostty.App.swift:268-270`. |
| A2 | Ghostty's zsh integration registers its `precmd` before the user's `.zshrc` runs, and reports the pwd at the start of the first `precmd`. | `ghostty/src/shell-integration/zsh/.zshenv` sources the integration before `.zshrc`; `ghostty-integration:89-90` appends `_ghostty_deferred_init` to `precmd_functions`; `:229-235` emits OSC 7 immediately inside it. User hooks added later (`~/.zshrc:118`, `eval "$(mise activate zsh)"`; oh-my-zsh at `:75`) run after it. |
| A3 | On the first prompt the `133;A` mark is inside `PS1`, not printed from `precmd`. | `ghostty-integration:434-437` moves `_ghostty_precmd` to the end of `precmd_functions` and calls it; `:124-127` then takes the `PS1` branch, `:159-160` sets `PS1=${mark1}${PS1}${markB}`. |
| A4 | Text sent on OSC 7 is double-echoed; text sent once `133;A` is out is not. | Probe, 3 runs each. Send on first OSC 7: the marker appears raw right after the OSC 7 and before the prompt, then again on the prompt line. Send on ECHO-off: no raw copy. Over 15 runs, ECHO cleared 3.6-4.2 ms after OSC 7, and ECHO was already off whenever `133;A` was first seen. |
| A5 | `ghostty_surface_needs_confirm_quit` is `false` exactly when the cursor is at a prompt (default config), and `true` before any prompt mark. | `ghostty/src/apprt/embedded.zig:1592-1593` → `Surface.zig:923-940` (`.true => !self.io.terminal.cursorIsAtPrompt()`); `Terminal.zig:1307-1320`; the cursor's `semantic_content` defaults to `.output` (`Screen.zig:169`). Exposed in Swift as `SurfaceView.needsConfirmQuit` (`Ghostty.SurfaceView.swift:55-58`). |
| A6 | The operator's Ghostty config does not set `confirm-close-surface`. | `grep` over `~/.config/ghostty/` and `~/Library/Application Support/com.mitchellh.ghostty/` found nothing. |
| A7 | Nothing reads the Setup hook's result. | `openSetupTab` (`TerminalManager+Setup.swift:8-15`) returns nothing and keeps no handle; `Sources/App/CLAUDE.md:224-225` "Nothing has ever awaited the hook". |
| A8 | Interpolation happens before the hook reaches `openSetupTab`. | `ContentView.swift:379` → `Worktree.swift:177-185` (`hooks.interpolated`), passed through `markWorktreeCreated` (`ContentView.swift:384`) to `takeSetupHook` (`TerminalManager.swift:389-390`). |
| A9 | The Setup tab opens with `activate: false` after the first tab. | `TerminalManager+Setup.swift:9`; `TerminalManager.swift:389-390`. Untouched by this change. |
| A10 | Before remove builds its surface with `hookShellCommand(cmd)` as `command:`, not through a prompt wait. | `ContentView.swift:760-763`. Untouched. |

## Objective and success criteria

Creating a worktree whose project has an After create hook shows that hook once, as configured,
on the Setup tab's first prompt line, run by the login shell, and leaves the shell usable.

The brief's acceptance criteria are the success criteria, unchanged:

1. A hook of `../../scripts/worktree-post-create.sh` shows that exact text on the Setup tab's prompt line, and the script runs.
2. The Setup tab contains no `/bin/sh -c`, no `export PATH=`, and no `[hook failed …]` text from the app.
3. The hook text appears exactly once. Nothing is echoed between the login banner and the first prompt.
4. The hook runs with the login shell's own environment.
5. When the hook finishes, the Setup tab is still a live login shell.
6. A failing hook shows only what the script and the shell print.
7. Branch, worktree path and primary worktree path are still substituted.
8. The Setup tab still opens in the background, after the first tab, without stealing focus.
9. Before remove behaves exactly as before, including its red banner and exit status.
10. Saved shell commands, the staged plan launch and staged agent prompts still deliver their text once and intact.

## Commands

From `CLAUDE.md`, `## Pipeline`:

| Step | Command |
| --- | --- |
| Regression check (every build task, simplify) | `./scripts/ci.sh` |
| Full gate (sign-off, once) | `./scripts/ci.sh` |

## Files touched

| File | Change |
| --- | --- |
| `Sources/App/TerminalManager+Setup.swift` | Drop `ShellEnvironment.awaitPath()`; `sendPaste(hook)` instead of `sendPaste(hookShellCommand(hook, path:))`. |
| `Sources/App/TerminalManager+Commands.swift` | `awaitShellPrompt`: loop while `pwd == nil || needsConfirmQuit` before the deadline. Rewrite its doc comment: the gate is the prompt mark, why OSC 7 alone was early (D4), and the `confirm-close-surface` dependency (D6). |
| `Sources/App/CLAUDE.md` | The Setup-tab note (`:337-341`): the hook is typed verbatim into the login shell; Before remove alone keeps `hookShellCommand`. |

No new files, so the Xcode project needs no regeneration beyond what `ci.sh` already does.

## Testing

- `./scripts/ci.sh`, green after the last edit. `HookShellCommandTests` keeps covering the Before remove wrapper.
- The operator checks criteria 1-10 by hand in a Debug build: create a worktree in this repo, read the Setup tab, then remove one with a failing Before remove hook.

## Boundaries

- Always: run `./scripts/ci.sh` before each commit; keep `hookShellCommand` and its tests as they are.
- Ask first: any change to the `ghostty` submodule or a new C export.
- Never: a fixed sleep or a longer fallback in place of the prompt gate; launching the app from an agent.

## Out of scope

- Before remove, its wrapper, `PATH` export and banner.
- Any failure indicator for the Setup tab; awaiting the hook.
- Hook settings UI, storage and interpolation.
- Readiness for bash and fish (D8), and for a `confirm-close-surface` other than the default (D6).
