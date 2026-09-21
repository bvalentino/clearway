# Scope the Close terminal sessions prompt to the closing window

**Date:** 2026-09-21
**Base:** 6afcc8d5a07022b79dc988c4716ae516460481ad (Move per-file CLAUDE.md notes into Sources/App and Sources/Ghostty (#248))

Closing a project window asks "Close terminal sessions?" whenever *any* window in the process has a
running foreground process, because `CloseConfirmationDelegate` reads the process-wide
`TerminalManager.needsConfirmQuit`. So a running agent in window A makes closing window B prompt,
and answering "Close" there closes nothing in A. This change gives the delegate the closing window's
own `TerminalManager` — the one `ProjectContentView` owns — so each window answers for its own
surfaces, and rewords the prompt to say so. Cmd+Q keeps the process-wide aggregate.

## Decisions

| # | Question | Decision | Why |
| --- | --- | --- | --- |
| D1 | How does the delegate reach the closing window's `TerminalManager`, given it is installed a layer above where the manager exists? | Move the `CloseConfirmation()` installer out of `ClearwayApp`'s `WindowGroup` (`ClearwayApp.swift:170`) and into `ProjectContentView.body`, beside the `WindowCloseHandler` that is already there (`ProjectWindow.swift:168-170`). | `ProjectContentView` is the layer that creates the per-window `TerminalManager` (A5). It already proves that a window-scoped `NSViewRepresentable` installed from there reaches the hosting window — that is how PR #247 wired surface retirement. No new plumbing, no environment key, no static. |
| D2 | Does the delegate hold the manager, or a closure? | A closure: `CloseConfirmationDelegate(needsConfirm: @escaping @MainActor () -> Bool)`, wired at the call site as `[weak terminalManager] in terminalManager?.needsConfirmClose ?? false`. | This is the project's established injection idiom (`openSecondaryOnStartProvider`, `mainCommandProvider`, `worktreeResolver` — A9), and it is the only shape that makes the regression testable: a test can construct a delegate that answers `true` without a `ghostty_app_t`, which it cannot do by building surfaces (A10). |
| D3 | Weak or strong capture of the manager, and what does a deallocated manager answer? | Weak, defaulting to `false` (close without asking). | A manager that is gone owns no live surfaces, so there is nothing a prompt could save. Matches `openSecondaryOnStartProvider`'s documented "unwired provider defaults to the opt-in-safe `false`" (`TerminalManager.swift:248`, `TerminalManagerTests.swift:63-69`) and the `[weak wm]` / `[weak agentActivity]` captures already in these two files. |
| D4 | Where does the per-window rule live? | A new instance property `TerminalManager.needsConfirmClose` — `allSurfaces.contains(where: \.needsConfirmQuit)` — placed beside the existing static. The static `needsConfirmQuit` is then re-expressed over it: `allInstances.allObjects.contains(where: \.needsConfirmClose)`. | One definition of "this manager is busy", two scopes reading it. It also names consistently with the per-worktree `worktreeNeedsConfirmClose(_:)` that already exists at `TerminalManager.swift:495-499`. |
| D5 | Does `applicationShouldTerminate` change? | No. It keeps the static `TerminalManager.needsConfirmQuit` (`ClearwayApp.swift:65-66`). | The brief states it outright. Cmd+Q ends the process, so the aggregate is the correct scope there, and its guard on a visible window already prevents a double prompt when the last window closes. |
| D6 | Wording of the prompt. | Title stays "Close terminal sessions?". Body becomes "There are processes still running in this window's terminals." | The brief asks that the prompt name only that window's sessions. Today both this alert and the Cmd+Q alert say "your terminals" (`ClearwayApp.swift:70,92`); after this change their scopes genuinely differ, so the copy has to differ. The Cmd+Q body is left alone. |
| D7 | Does the alert body enumerate *which* sessions are running? | No. | The brief asks for scope, not an inventory. Listing worktree or tab names is a visible UI change with its own truncation and ordering questions, and the per-tab close door already names its tab (`ContentView.swift:939-947`). Recorded under Out of scope. |
| D8 | Is the wording pinned by a test? | Yes — `messageText` and `informativeText` become `static let`s on `CloseConfirmationDelegate`, read by the alert and asserted in the new test file. | `WorktreeGroupWriteAlertTests` is the project's precedent for pinning user-visible copy while leaving `present()` uncovered because it runs a modal (A11). Two constants also make the deliberate divergence from the Cmd+Q copy legible at the definition rather than only in a diff. |
| D9 | Do `CloseConfirmationDelegate` and `CloseConfirmation` move to their own file? | No — they stay in `ClearwayApp.swift`, next to the Cmd+Q alert they are now deliberately worded against. | Surgical edit; the two confirmations read as a pair. Only the installation point moves. |
| D10 | Now that the delegate slot is reachable from `ProjectContentView`, should `WindowCloseHandler`'s retirement fold into it as `windowWillClose`? | No. Both stay. | The delegate is installed once through `DispatchQueue.main.async` and retained by an associated object on the window, so it never re-scopes; `WindowCloseHandlerView` re-scopes with the view's tenancy in a window, which is a behavior its suite pins (`WindowCloseHandlerTests.swift:36-48`). Merging them would trade a working, tested door for a refactor the task did not ask for. The `Sources/App/CLAUDE.md` note that justifies the split by the managers being "out of reach" becomes false and is rewritten (A12). |
| D11 | Which test file? | A new `Tests/CloseConfirmationDelegateTests.swift`, beside `WindowCloseHandlerTests.swift`. | `WindowCloseHandlerTests` is scoped to one type by name. A new file means `ci.sh` must run for `xcodegen generate` to see it — which it does anyway. |

## Assumptions

Each verified by reading the source at the base commit. No probe scripts were written, in the repo or
in the scratchpad; every check below is a read.

**A1 — The prompt's gate is process-wide.** `CloseConfirmationDelegate.windowShouldClose` reads
`TerminalManager.needsConfirmQuit` and nothing else (`Sources/App/ClearwayApp.swift:87-88`).

**A2 — That static aggregates every live manager.**
`allInstances.allObjects.flatMap(\.allSurfaces).contains(where: \.needsConfirmQuit)`
(`Sources/App/TerminalManager.swift:537-539`), over a process-wide weak table every manager adds
itself to in `init` (`TerminalManager.swift:12,79`). So window B's delegate sees window A's surfaces.

**A3 — Closing is the only thing the prompt gates, and it closes just the one window.**
`windowShouldClose` returns `false` and calls `sender.close()` from the sheet completion
(`ClearwayApp.swift:97-102`). Nothing in that path touches another window's manager, which is why
answering "Close" in B kills nothing in A.

**A4 — The installer is one layer above the manager.** `CloseConfirmation()` is attached to
`ProjectWindow` inside the `WindowGroup` closure (`ClearwayApp.swift:169-170`); `ProjectWindow`
renders `ProjectContentView` (`ProjectWindow.swift:27-28`).

**A5 — `ProjectContentView` owns the per-window `TerminalManager`.** It builds one in `init`
(`ProjectWindow.swift:130`) and holds it as a `@StateObject` (`ProjectWindow.swift:119,138`),
publishing it into the environment for the window's subtree (`ProjectWindow.swift:153`).

**A6 — A window-scoped `NSViewRepresentable` installed from `ProjectContentView` reaches the hosting
window.** `.background(WindowCloseHandler { [terminalManager] in terminalManager.retireAllSurfaces() })`
already does exactly this (`ProjectWindow.swift:168-170`), and it shipped in #247.

**A7 — Only project windows own terminals.** The Task and Prompt scenes render `WorkTaskWindow` and
`PromptWindow` (`ClearwayApp.swift:228-245`); `grep` for `TerminalManager`, `CloseConfirmation` and
`WindowCloseHandler` in `Sources/App/WorkTaskWindow.swift` returns nothing. Neither scene applies
`CloseConfirmation` today, so moving it down changes nothing for them.

**A8 — The welcome path needs no confirmation.** With `projectPath == nil`, `ProjectWindow` renders
`WindowHider`, which closes the window immediately (`ProjectWindow.swift:29-37,59-66`). No
`TerminalManager` exists on that path, so a window with no delegate closing straight through is
correct, not a regression.

**A9 — Injected-closure providers are the established idiom on `TerminalManager`.**
`openSecondaryOnStartProvider: () -> Bool = { false }` (`TerminalManager.swift:248`), wired from the
view layer as `terminalManager.openSecondaryOnStartProvider = { [settings] in settings.openSecondaryOnStart }`
(`ContentView.swift:399`), and `taskMgr.worktreeResolver = { [weak wm] in … }` (`ProjectWindow.swift:134`).

**A10 — The suite cannot build surfaces, so the rule must be injectable to be tested.**
`Ghostty.SurfaceView.needsConfirmQuit` calls `ghostty_surface_needs_confirm_quit` on a live surface
pointer (`Sources/Ghostty/Ghostty.SurfaceView.swift:55-58`), and every surface needs a
`ghostty_app_t`. `Tests/TerminalManagerTests.swift` constructs `TerminalManager()` freely but never a
surface; it drives every rule through injected providers instead.

**A11 — Pinning alert copy while leaving `present()` uncovered is the project's precedent.**
`WorktreeGroupWriteAlert` holds `messageText`/`informativeText` and builds the `NSAlert` in
`present()` (`Sources/App/WorktreeGroupWriteAlert.swift:37`); its suite asserts the strings and states
"`present()` is not covered: it runs a modal" (`Tests/WorktreeGroupWriteAlertTests.swift:4-5`).

**A12 — A per-file note asserts the thing this change falsifies.** `Sources/App/CLAUDE.md:420-424`
justifies hanging retirement off `WindowCloseHandler` rather than the window delegate because "the
delegate slot already holds `CloseConfirmationDelegate`, installed a layer up where the window's
managers are out of reach." After this change the delegate is installed from `ProjectContentView`, so
that sentence is wrong and must be replaced with D10's reason.

**A13 — No concurrency trap is introduced.** The injected closure is a plain Swift function type, not
`@convention(c)` or `@convention(block)`, so a literal written inside a `@MainActor` view stays
statically checked — the `DispatchSource`/callback-table rule in the project's CLAUDE.md does not
apply. `CloseConfirmationDelegate` is already `@MainActor` (`ClearwayApp.swift:85-86`) and gains no
`deinit`.

## Objective

Each project window's close prompt answers for that window's terminals only, so closing a quiet
window never asks about a busy one, and a prompt the operator does answer is about sessions that
window is actually going to end.

### Success criteria

1. Two project windows open, an agent running in A only. Closing B closes it immediately with no
   prompt. Closing A prompts.
2. Closing A and confirming ends A's sessions and leaves B untouched, as today.
3. Cancelling the prompt leaves the window open and its sessions running, as today.
4. The prompt body reads "There are processes still running in this window's terminals."
5. Cmd+Q with a busy window still prompts once with "Quit Clearway?" and its unchanged body,
   whichever window is frontmost, including when the busy window is not the frontmost one.
6. Closing the last window still runs its own per-window prompt and does not prompt twice.
7. A window whose close is confirmed still retires its surfaces through `WindowCloseHandler`, so the
   agent activity dots and subagent rows it owned clear — PR #247's behavior is unchanged.
8. The welcome window (no project selected) closes with no prompt.
9. `Tests/CloseConfirmationDelegateTests.swift` pins: a delegate whose provider answers `false`
   returns `true` from `windowShouldClose` and attaches no sheet; two delegates on two windows answer
   independently, so a busy one vetoing its own close does not veto the quiet one's; the provider is
   consulted on each close rather than cached at init; and the two copy constants.
10. `./scripts/ci.sh` is green and `swiftlint lint --quiet` reports no new warnings.

## Verification

Per the project's `## Pipeline` section, one command serves as both regression check and full gate:

```bash
./scripts/ci.sh
```

It regenerates the Xcode project (required here — this change adds a test file), lints, builds and
runs the test suite. Do not hand-write an `xcodebuild` line. Before any CI stamp or sign-off, also
run:

```bash
git status --porcelain
```

and report untracked or ignored files; expect `default.profraw` if the Debug app was launched.

Per memory, build agents do not launch the app or take screenshots — success criteria 1–8 are
checked by the operator by hand.

## Files this change touches

| File | Change |
| --- | --- |
| `Sources/App/TerminalManager.swift` | Add the instance `needsConfirmClose`; re-express the static `needsConfirmQuit` over it. |
| `Sources/App/ClearwayApp.swift` | `CloseConfirmationDelegate` gains the `needsConfirm` provider and the two copy constants, and uses the new body text; `CloseConfirmation` carries the provider through; drop `.background(CloseConfirmation())` from the `WindowGroup`. |
| `Sources/App/ProjectWindow.swift` | `ProjectContentView.body` installs `CloseConfirmation` with `[weak terminalManager]`, beside the existing `WindowCloseHandler`. |
| `Tests/CloseConfirmationDelegateTests.swift` | New. Criterion 9. |
| `Sources/App/CLAUDE.md` | Rewrite the sentence at 420-424 per A12/D10, and note that the close prompt is per window while Cmd+Q is process-wide. |
| `docs/superpowers/specs/2026-09-21-scope-close-prompt-to-window.md` | This file. |
| `docs/superpowers/plans/2026-09-21-scope-close-prompt-to-window.md` | The plan. |

## Out of scope

- `applicationShouldTerminate` and the Cmd+Q alert, including its wording (D5, D6).
- Enumerating the running sessions in the prompt body (D7).
- Merging `WindowCloseHandler` into the window delegate, or changing how the delegate is installed
  and retained (D10).
- The per-tab close confirmation in `ContentView.beginCloseTab` and its `tabCloseQueue`
  (`ContentView.swift:939-947`).
- `worktreeNeedsConfirmClose(_:)` and the worktree-close door (`TerminalManager.swift:495-499`).
- `TerminalManager.closeAllManagers` and `applicationWillTerminate` cleanup.
- Task and Prompt windows, and the project selector window (A7, A8).
- Surface retirement itself; #247's behavior is preserved, not revisited (criterion 7).
