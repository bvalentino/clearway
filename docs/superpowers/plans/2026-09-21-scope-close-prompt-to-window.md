# Plan: Scope the Close terminal sessions prompt to the closing window

Breaks down `docs/superpowers/specs/2026-09-21-scope-close-prompt-to-window.md`.

**Date:** 2026-09-21
**Base:** 6afcc8d5a07022b79dc988c4716ae516460481ad (Move per-file CLAUDE.md notes into Sources/App and Sources/Ghostty (#248))

## Architecture decisions carried from the spec

- The `CloseConfirmation()` installer moves out of `ClearwayApp`'s `WindowGroup` and into
  `ProjectContentView.body`, beside the `WindowCloseHandler` already there. That is the layer that
  owns the per-window `TerminalManager`, and #247 already proved a window-scoped
  `NSViewRepresentable` installed from there reaches the hosting window. No environment key, no
  static (D1).
- The delegate holds a **closure**, not the manager: `CloseConfirmationDelegate(needsConfirm:
  @escaping @MainActor () -> Bool)`, wired at the call site as
  `[weak terminalManager] in terminalManager?.needsConfirmClose ?? false`. This is the project's
  injection idiom (`openSecondaryOnStartProvider`, `worktreeResolver`) and the only shape the suite
  can drive, because building a real surface needs a `ghostty_app_t` (D2, A9, A10).
- The capture is **weak** and a deallocated manager answers `false` — close without asking. A
  manager that is gone owns no live surfaces (D3).
- The per-window rule is a new instance property `TerminalManager.needsConfirmClose` =
  `allSurfaces.contains(where: \.needsConfirmQuit)`. The existing static `needsConfirmQuit` is
  re-expressed over it as `allInstances.allObjects.contains(where: \.needsConfirmClose)` — one
  definition, two scopes (D4).
- `applicationShouldTerminate` does **not** change. Cmd+Q ends the process, so the process-wide
  static stays the right scope there, and its existing guard on a visible window still prevents a
  double prompt when the last window closes (D5).
- The alert title stays `"Close terminal sessions?"`. The body becomes
  `"There are processes still running in this window's terminals."` The Cmd+Q body is left alone,
  so the two now read differently on purpose (D6).
- The body does **not** enumerate which sessions are running (D7).
- Both strings become `static let`s on `CloseConfirmationDelegate`, read by the alert and asserted
  in the test. `present()`-style modal code stays uncovered, per `WorktreeGroupWriteAlertTests`
  (D8, A11).
- `CloseConfirmationDelegate` and `CloseConfirmation` stay in `ClearwayApp.swift`, next to the
  Cmd+Q alert they are now deliberately worded against. Only the installation point moves (D9).
- `WindowCloseHandler` and the window delegate stay two separate installers. The delegate is
  installed once via `DispatchQueue.main.async` and never re-scopes; `WindowCloseHandlerView`
  re-scopes with the view's tenancy in a window, which its suite pins. Merging them is out of
  scope (D10, operator-confirmed).
- No concurrency trap is introduced: the injected closure is a plain Swift function type, not
  `@convention(c)` / `@convention(block)`, so a literal written inside a `@MainActor` view stays
  statically checked. `CloseConfirmationDelegate` is already `@MainActor` and gains no `deinit`
  (A13).
- Out of scope: the Cmd+Q alert and its wording, enumerating sessions, merging the two installers,
  the per-tab close confirmation in `ContentView.beginCloseTab`, `worktreeNeedsConfirmClose(_:)`,
  `closeAllManagers`, Task/Prompt/welcome windows, and surface retirement itself.

## Dependency graph

```
T1 (TerminalManager.needsConfirmClose)
      │
      └── T2 (move + scope the delegate, + its test file)
                │
                └── T3 (rewrite the two now-false prose notes)
```

T1 must land first: T2's call site reads `needsConfirmClose`. T3 describes the shape T2 creates, so
it is written last.

### T1: Add the per-manager close rule to TerminalManager

**Files:** `Sources/App/TerminalManager.swift`

**What it does.** Adds an instance property beside the existing static at line 537:

```swift
/// Whether any surface this manager owns has a running foreground process.
var needsConfirmClose: Bool {
    allSurfaces.contains(where: \.needsConfirmQuit)
}
```

and re-expresses the static over it:

```swift
/// Whether any surface across all managers has a running foreground process.
static var needsConfirmQuit: Bool {
    allInstances.allObjects.contains(where: \.needsConfirmClose)
}
```

`allSurfaces` is already internal (`TerminalManager.swift:549`), so no visibility change is needed.
Nothing else in this file changes; `worktreeNeedsConfirmClose(_:)` (line 495) is untouched.

**Acceptance criteria.**
1. `TerminalManager.needsConfirmClose` exists as an instance property and reads only that
   manager's `allSurfaces`.
2. The static `needsConfirmQuit` is defined in terms of `needsConfirmClose` and still answers for
   every live manager — same result as the old `flatMap(\.allSurfaces).contains(...)`.
3. No call site of `TerminalManager.needsConfirmQuit` changes in this task.

**Verification.** `./scripts/ci.sh` is green — it covers the existing `TerminalManagerTests`, which
exercise the manager's rules through injected providers. Criteria 1 and 2 are also read off the
source: the instance property must not mention `allInstances`, and the static must not mention
`allSurfaces`.

### T2: Scope the close prompt to the closing window

**Files:** `Sources/App/ClearwayApp.swift`, `Sources/App/ProjectWindow.swift`,
`Tests/CloseConfirmationDelegateTests.swift` (new)

**Depends on:** T1.

**What it does.**

In `ClearwayApp.swift`:

- `CloseConfirmationDelegate` (line 85) gains `static let messageText = "Close terminal sessions?"`
  and `static let informativeText = "There are processes still running in this window's terminals."`,
  a stored `private let needsConfirm: @MainActor () -> Bool`, and
  `init(needsConfirm: @escaping @MainActor () -> Bool)` (calling `super.init()`).
  `windowShouldClose` guards on `needsConfirm()` instead of `TerminalManager.needsConfirmQuit`, and
  the alert reads `Self.messageText` / `Self.informativeText`. Everything else in
  `windowShouldClose` — `alertStyle`, the two buttons, `beginSheetModal`, returning `false` and
  calling `sender.close()` from the completion — is unchanged.
- `CloseConfirmation` (line 107) gains `let needsConfirm: @MainActor () -> Bool` and passes it to
  the delegate it constructs. The `DispatchQueue.main.async`, the associated-object retention and
  the `window.delegate =` assignment are unchanged (D10: how it is installed and retained does not
  change, only from where).
- `.background(CloseConfirmation())` is removed from the `WindowGroup` closure (line 170).

In `ProjectWindow.swift`:

- `ProjectContentView.body` gains, beside the existing `WindowCloseHandler` at lines 168-170:

  ```swift
  .background(CloseConfirmation { [weak terminalManager] in
      terminalManager?.needsConfirmClose ?? false
  })
  ```

- `WindowCloseHandler`'s doc comment (lines 69-74) currently says no window delegate of Clearway's
  own is free because `CloseConfirmationDelegate` is "installed a layer up where the window's
  managers are out of reach". That sentence is false after this edit. Replace the justification
  with D10's: the delegate is installed once and never re-scopes, while this observer re-scopes
  with the view's tenancy in a window — a behavior `WindowCloseHandlerTests` pins.

In `Tests/CloseConfirmationDelegateTests.swift` (new file, beside `WindowCloseHandlerTests.swift`,
`@MainActor final class ... : XCTestCase`):

- Build `NSWindow`s the way `WindowCloseHandlerTests.makeWindow()` does, including
  `isReleasedWhenClosed = false` — a code-created `NSWindow` releases itself on close and ARC would
  then over-release it.
- A delegate whose provider answers `false` returns `true` from `windowShouldClose` and leaves
  `window.attachedSheet` nil.
- Two delegates on two separate windows answer independently: the busy one returns `false` for its
  own window while the quiet one still returns `true` for its own. This is the regression: today
  both would veto.
- The provider is consulted on each close, not cached at init: flip a captured `var` between two
  `windowShouldClose` calls on the same delegate and assert the answer changes.
- The two copy constants equal their expected strings, including the `"this window's terminals"`
  wording that distinguishes them from the Cmd+Q body.
- Driving a `true` provider presents a sheet on that window. End it before the test returns
  (`if let sheet = window.attachedSheet { window.endSheet(sheet) }`) and close the windows, so no
  modal leaks into a later test. `beginSheetModal` is non-blocking, so nothing here needs a
  run-loop spin. `present()`-equivalent modal paths stay otherwise uncovered, per
  `WorktreeGroupWriteAlertTests`.

**Acceptance criteria.**
1. Nothing in `Sources/App` constructs a `CloseConfirmationDelegate` or `CloseConfirmation` without
   a `needsConfirm` provider, and `grep -n "CloseConfirmation" Sources/App/ClearwayApp.swift
   Sources/App/ProjectWindow.swift` shows the only installation is the one in
   `ProjectContentView.body`.
2. `CloseConfirmationDelegate.windowShouldClose` no longer references
   `TerminalManager.needsConfirmQuit`; `applicationShouldTerminate` still does, unchanged.
3. The alert body text lives in `CloseConfirmationDelegate.informativeText` and reads
   "There are processes still running in this window's terminals."
4. `Tests/CloseConfirmationDelegateTests.swift` covers all four points of spec criterion 9 and
   passes.
5. No now-false prose is left in `ProjectWindow.swift`.

**Verification.** `./scripts/ci.sh` — required, not optional: this task adds a Swift file, which is
invisible to the build until `xcodegen generate` runs, and `build.sh`'s `PRODUCT_NAME` override
breaks `TEST_HOST`. Then `swiftlint lint --quiet` reports no new warnings. Criteria 1-3 and 5 are
read off the source; criterion 4 is the new test passing inside that run. Spec success criteria 1-8
are hand-checks the operator runs; per memory, build agents do not launch the app.

### T3: Rewrite the per-file note that this change falsifies

**Files:** `Sources/App/CLAUDE.md`

**Depends on:** T2.

**What it does.** `Sources/App/CLAUDE.md:420-424` justifies hanging surface retirement off
`WindowCloseHandler` rather than the window delegate because "the delegate slot already holds
`CloseConfirmationDelegate`, installed a layer up where the window's managers are out of reach".
After T2 the delegate is installed from `ProjectContentView` and does reach the window's manager,
so that clause is wrong. Replace it with D10's reason: both installers live in
`ProjectContentView.body` and stay separate because the delegate is installed once through
`DispatchQueue.main.async` and never re-scopes, while `WindowCloseHandlerView` re-scopes with the
view's tenancy in a window — behavior `WindowCloseHandlerTests` pins.

Add, in the same passage, that the close prompt is scoped per window
(`TerminalManager.needsConfirmClose`, injected as a closure into `CloseConfirmationDelegate`) while
Cmd+Q's `applicationShouldTerminate` keeps the process-wide `TerminalManager.needsConfirmQuit` —
which is why the two alert bodies differ.

Edit surgically. Do not restructure the surrounding passage or the rest of the file.

**Acceptance criteria.**
1. No sentence in `Sources/App/CLAUDE.md` claims the window's managers are out of reach from the
   delegate, or that the delegate is installed a layer above `ProjectContentView`.
2. The passage states both the reason the two installers stay separate and the per-window vs.
   process-wide split of the two confirmations.
3. Only that passage changed.

**Verification.** `grep -n "out of reach" Sources/App/CLAUDE.md` returns nothing, and
`git diff --stat Sources/App/CLAUDE.md` shows a change confined to that passage. Documentation
only — no build is required, but `./scripts/ci.sh` must still be green at the end of the task.

## Build log

### T1: Add the per-manager close rule to TerminalManager

| File | State |
| --- | --- |
| `Sources/App/TerminalManager.swift` | Instance `needsConfirmClose` added at line 536; static `needsConfirmQuit` re-expressed over it. |
| `project.yml` | `**/*.md` excluded from the `Sources` target sources. Unplanned — see the deviation below. |
| `docs/superpowers/specs/2026-09-21-scope-close-prompt-to-window.md` | Committed with this task; it was untracked. |
| `docs/superpowers/plans/2026-09-21-scope-close-prompt-to-window.md` | Committed with this task, carrying this log. |

The instance property reads only `allSurfaces` and never mentions `allInstances`; the static reads
only `allInstances` and never mentions `allSurfaces` (T1 criteria 1 and 2). No call site changed —
`grep -rn "needsConfirmQuit\|needsConfirmClose" Sources Tests` still shows
`ClearwayApp.swift:66` and `:88` on the static, `ContentView.swift:941` and
`TerminalManager+TaskTerminals.swift:12` on the surface property, and
`worktreeNeedsConfirmClose` untouched at line 495 (criterion 3).

No test was added. Per A10 the suite cannot build a `Ghostty.SurfaceView`, so the only value
`needsConfirmClose` can be driven to from XCTest is `false` on an empty manager, which asserts
nothing. The rule is covered where it becomes observable, through the injected provider in T2.

**Deviation: `project.yml`.** `./scripts/ci.sh` was already red at the base commit, before any edit
of this task:

```
error: Multiple commands produce '…/Clearway.app/Contents/Resources/CLAUDE.md'
    note: Target 'Clearway' has copy command from 'Sources/App/CLAUDE.md' to '…/Resources/CLAUDE.md'
    note: Target 'Clearway' has copy command from 'Sources/Ghostty/CLAUDE.md' to '…/Resources/CLAUDE.md'
** TEST FAILED **
```

`#248` added a second `CLAUDE.md` under `Sources`, and the target's `sources: - path: Sources`
bundles every non-source file it finds, so the two flatten onto one bundle path. GitHub CI on `main`
fails identically at that commit (run 35613723428, job `Build & Test`, exit 65) — so this is
pre-existing, not caused by T1. The plan's verification command could not run at all until it was
fixed, so it was fixed here rather than reported: the `Sources` target now excludes `**/*.md`. Those
are the only two markdown files under `Sources` and neither is read at runtime, so nothing else
changes. Whoever picks up T2 or T3 inherits a green gate.

**Gate.** `./scripts/ci.sh` — green, `==> CI passed.`, 779 tests, 0 failures. `swiftlint lint
--quiet` — exit 0, no output. `git status --porcelain` before the commit showed only this task's own
files: `M Sources/App/TerminalManager.swift`, `M project.yml`, and the two untracked planning
documents, all four of which this commit carries. No `default.profraw`: the Debug app was not
launched.

### T2: Scope the close prompt to the closing window

| File | State |
| --- | --- |
| `Sources/App/ClearwayApp.swift` | `CloseConfirmationDelegate` gained `static let messageText` / `informativeText`, a stored `private let needsConfirm: @MainActor () -> Bool` and its `init`; `windowShouldClose` guards on `needsConfirm()` and reads the two constants. `CloseConfirmation` gained `let needsConfirm: @MainActor @Sendable () -> Bool` and passes it through. `.background(CloseConfirmation())` removed from the `WindowGroup`. |
| `Sources/App/ProjectWindow.swift` | `ProjectContentView.body` installs `.background(CloseConfirmation { [weak terminalManager] in terminalManager?.needsConfirmClose ?? false })` beside the existing `WindowCloseHandler`. `WindowCloseHandler`'s doc comment rewritten per D10. |
| `Tests/CloseConfirmationDelegateTests.swift` | New. Four tests covering spec criterion 9. |
| `Clearway.xcodeproj/project.pbxproj` | Regenerated by `xcodegen` to pick up the new test file (+4 lines). |

`grep -n "CloseConfirmation" Sources/App/ClearwayApp.swift Sources/App/ProjectWindow.swift` shows
the only installation is `ProjectWindow.swift:173` (criterion 1). `windowShouldClose` no longer
mentions `TerminalManager.needsConfirmQuit`; the only remaining reader of the static is
`applicationShouldTerminate` at `ClearwayApp.swift:66`, unchanged (criterion 2). The body text
lives in `CloseConfirmationDelegate.informativeText` (criterion 3). `grep -n "out of reach"
Sources/App/ProjectWindow.swift` returns nothing (criterion 5); the same clause still stands in
`Sources/App/CLAUDE.md:423`, which is T3's file.

**Evidence: the regression watched red.** With the API change in place but the one-line fix
reverted — `guard TerminalManager.needsConfirmQuit else { return true }` back in
`windowShouldClose` — `./scripts/ci.sh` exited 65:

```
Test Suite 'CloseConfirmationDelegateTests' started at 2026-09-21 16:13:04.378.
    ✖ testEachWindowAnswersForItsOwnTerminals, XCTAssertFalse failed
    ✖ testTheRuleIsAskedOnEveryCloseRatherThanCachedAtInit, XCTAssertFalse failed
** TEST FAILED **
```

That is exactly the shipped defect: with no manager owning a live surface in the test host the
process-wide static answers `false`, so a delegate told its own window is busy still waved the
close through — and, symmetrically, a busy window in the running app vetoed every window's close.
The fix was restored from a scratchpad copy of the file, not with `git checkout`.

**Deviations from the plan.**

1. `CloseConfirmation.needsConfirm` is typed `@MainActor @Sendable () -> Bool` rather than the
   plan's `@MainActor () -> Bool`. The struct is captured by the `DispatchQueue.main.async` closure
   in `makeNSView`, whose `execute` parameter is `@Sendable`, so every stored property has to be
   `Sendable` for the struct to be. `WindowCloseHandler.perform` in the same layer carries the same
   pair of attributes for the same reason. The delegate's own stored property keeps the plan's
   plain `@MainActor () -> Bool`; a `@Sendable` function converts to it implicitly.
2. The "asked on every close" test drives a one-property reference box (`Terminals`) rather than
   flipping a captured `var`. The red run warned
   `'busy' mutated after capture by sendable closure` at
   `Tests/CloseConfirmationDelegateTests.swift:60`, and the project's bar is no new warnings. The
   box is what the closure would hold in production anyway — a reference whose value changes
   between calls.

**Gate.** `./scripts/ci.sh` — exit 0, `==> CI passed.`, `Executed 783 tests, with 0 failures
(0 unexpected)`, up from T1's 779 by this task's four. `swiftlint lint --quiet` — exit 0, no
output. `git status --porcelain` before the commit listed only this task's files:
`M Clearway.xcodeproj/project.pbxproj`, `M Sources/App/ClearwayApp.swift`,
`M Sources/App/ProjectWindow.swift`, `?? Tests/CloseConfirmationDelegateTests.swift`. No
`default.profraw`: the Debug app was not launched.

### T3: Rewrite the per-file note that this change falsifies

| File | State |
| --- | --- |
| `Sources/App/CLAUDE.md` | The "Closing a project window is a door of its own" passage (419-433) rewritten: the "installed a layer up where the window's managers are out of reach" justification replaced with D10's, plus the per-window vs. process-wide split of the two confirmations. |
| `docs/superpowers/plans/2026-09-21-scope-close-prompt-to-window.md` | This log. |

The passage now reads: the retirement hangs off `WindowCloseHandler` and not off the window
delegate, "whose slot holds `CloseConfirmationDelegate`. Both installers sit in
`ProjectContentView.body` and stay separate: the delegate is installed once through
`DispatchQueue.main.async` and never re-scopes, while `WindowCloseHandlerView` re-scopes with the
view's tenancy in a window — behavior `WindowCloseHandlerTests` pins. That delegate's prompt is
scoped to the closing window, off the instance `TerminalManager.needsConfirmClose` injected as a
closure, while Cmd+Q's `applicationShouldTerminate` keeps the process-wide static
`TerminalManager.needsConfirmQuit` — which is why the two alert bodies differ." No sentence claims
the managers are out of reach or that the delegate is installed above `ProjectContentView`
(criteria 1 and 2). `git diff --stat Sources/App/CLAUDE.md` is `12 insertions(+), 7 deletions(-)`,
all inside that one passage; four of the twelve are re-wraps of unchanged text pushed across the
file's ~100-column line width (criterion 3). Documentation only — no test, and none is possible.

**Deviation: the `grep -n "out of reach"` check.** The plan's verification says that grep must
return nothing in `Sources/App/CLAUDE.md`. It still returns two hits, at lines 123 and 549 — "put
the editor out of reach" (the unstartable-editor guard) and "out of reach of exactly the user who
has none" (the first-command path). Both are unrelated prose that predates this branch and neither
concerns the window delegate, so the criterion as written (criterion 1: no sentence claims the
window's managers are out of reach from the delegate) is met while the grep as written is not. The
targeted check is `grep -n "installed a layer up"`, which returns nothing.

**Gate.** `./scripts/ci.sh` — exit 0, `==> CI passed.`, `Executed 783 tests, with 0 failures
(0 unexpected)`, unchanged from T2 as expected for a documentation-only task. `swiftlint lint
--quiet` — exit 0, no output. `git status --porcelain` before the commit listed only
`M Sources/App/CLAUDE.md` plus this log's own file. No `default.profraw`: the Debug app was not
launched.

### Simplify

`Tests/CloseConfirmationDelegateTests.swift` arrived with a private `makeWindow()` copied verbatim
from `WindowCloseHandlerTests`, comment included; both copies were replaced by one `@MainActor`
helper in `Tests/TestHelpers.swift`, beside the existing `makeWorktree`. Nothing else was changed —
the two `NSViewRepresentable` installers stay separate per D10, and D8's copy constants stay.

**Gate.** `./scripts/ci.sh` — exit 0, `==> CI passed.`, `Executed 783 tests, with 0 failures
(0 unexpected)`. `swiftlint lint --quiet` — exit 0, no output.
