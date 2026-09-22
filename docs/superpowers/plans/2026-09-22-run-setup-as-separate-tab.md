# Plan: Run the After create hook in a separate Setup tab

Breaks down `docs/superpowers/specs/2026-09-22-run-setup-as-separate-tab.md`.

**Date:** 2026-09-22
**Base:** 66145eb214d293794647be6d0599737c1dc00220 (Release v2.0.0)

## Architecture decisions carried from the spec

- The After create hook runs in a second **main** tab titled "Setup". The secondary panel is never
  revealed or written to by the hook, and its visibility follows only "Open secondary terminal on
  start" (D1, D12).
- The Setup tab's chip and close-dialog title read "Setup" for the tab's whole lifetime; the
  shell's OSC title never replaces it (D2, D11).
- The Setup tab is a **login shell** in the worktree directory. The hook is pasted into it once the
  prompt is up, so the tab sits at a live prompt when the hook ends. Nothing auto-closes it (D3).
- The hook line is `hookShellCommand(hook, path:)`, the same PATH export and red
  `[hook failed: exit N]` banner Before remove uses. Its **output is unchanged**: the banner prints
  on failure only, and a zero exit prints nothing (D4, operator-confirmed).
- Tab 1 stays active and first responder. The Setup tab never sets `activeId` and never calls
  `transferFirstResponder` (D5).
- Ordering is structural: `appendTab` itself appends the Setup tab when it adds the **first** tab
  to a pane with a pending Setup hook. This covers the login-shell, saved-command, and async agent
  first-tab paths alike, so Setup is always tab 2 (D6).
- `appendTab` stays the one door for main tabs. It gains `name: String? = nil` and
  `activate: Bool = true`; Setup calls it with `name: "Setup", activate: false`. No second append
  path (D7).
- The pending hook lives in its own map, `pendingSetupHooks: [String: String]`, set by
  `markWorktreeCreated(_:afterCreateCommand:setupHook:)` (required label) and removed in
  `cleanupState`. It is **not** folded into `createdWorktrees`, which `takeFirstTabSource` consumes
  before an agent first tab lands (D8).
- The hook line is built **after** `await ShellEnvironment.awaitPath()`, and that resolved path is
  passed to `hookShellCommand(_:path:)`, whose new `path` parameter defaults to
  `ShellEnvironment.path` so the Before remove call site is untouched (D9).
- Delivery is `await TerminalManager.awaitShellPrompt(on:)` then `surface.sendPaste(line)`.
  `sendCommand` is wrong here: it drops everything after the first newline (D10).
- One static display-title rule on `TerminalTab`: the name if set, else the surface title if
  non-empty, else "Terminal". The chip and `ContentView.beginCloseTab` both use it (D11).
- `runHookInSecondary`, `revealSecondaryForHook`, and the test pinning them are deleted (D12).
- Accepted edge case: if a saved `.agent` first tab refuses to launch, no first tab lands, the hook
  stays pending, and it runs as tab 2 when the user next opens a tab in that worktree. Teardown
  drops it. No special failure path (D13).
- Unchanged: Before remove and its sheet, the create sheet's "Run agent command after create"
  picker, hook storage and interpolation, ⌘T / ⌥⌘T / `+`, task terminals (D14).
- Never: reveal or write to the secondary panel from the hook; activate or focus the Setup tab; add
  a second tab-append path; change `hookShellCommand`'s output.

## Regression check

Every task verifies with the project's one command, from `CLAUDE.md`'s `## Pipeline` section:

```
./scripts/ci.sh
```

It regenerates the Xcode project (new Swift files, including new test files, are invisible to the
build without it), lints, builds, and runs the suite. Do not hand-write an `xcodebuild` line.
`swiftlint lint --quiet` must report zero errors and no new warnings.

Tab order, focus, the live transcript, and the running-process close confirmation need a real
`ghostty_app_t`. Build agents do not launch the app; the operator checks those by hand. No task
claims them.

## Dependency graph

```
T1 (TerminalTab.name + display-title rule)    T2 (hookShellCommand path:)    T3 (pendingSetupHooks state)
        │                                            │                               │
        └────────────────────────────────────────────┴───────────────────────────────┘
                                                     │
                                  T4 (Setup tab through appendTab; retire the secondary hook)
                                                     │
                                  T5 (CLAUDE.md notes and README)
```

T1, T2, and T3 are independent and each leaves behaviour unchanged. They run in order T1 → T2 → T3
only because T1 and T3 both edit `ContentView.swift`. T4 is the slice that switches the behaviour
and needs all three. T5 describes the shape T4 leaves.

### T1: Give a main tab an optional name and one display-title rule

**Files:** `Sources/App/TerminalTab.swift`, `Sources/App/MainTerminalTabStrip.swift`,
`Sources/App/ContentView.swift`, `Tests/TerminalTabTests.swift` (new)

**What it does.**

- `TerminalTab` gains `let name: String?`. Every existing construction site passes `nil` (today the
  only one is `appendTab` in `TerminalManager.swift`: `TerminalTab(id: UUID(), surface: surface)`).
  A memberwise default is fine if it keeps that call unchanged; either way no call site gains a
  name in this task.
- Add `static func displayTitle(name: String?, surfaceTitle: String) -> String` on `TerminalTab`:
  `name` if non-nil, else `surfaceTitle` if non-empty, else `"Terminal"`.
- `TerminalTabChip` (`MainTerminalTabStrip.swift:~75-96`) takes `let name: String?` and passes
  `TerminalTab.displayTitle(name: name, surfaceTitle: surface.title)` as `title:`. The chip keeps
  `@ObservedObject var surface` so an unnamed chip still follows the shell's title. The call site
  at `MainTerminalTabStrip.swift:264` passes `name: tab.name`.
- `ContentView.beginCloseTab` (`ContentView.swift:~983-990`) builds `title` with
  `TerminalTab.displayTitle(name: tab.name, surfaceTitle: tab.surface.title)` instead of repeating
  the rule inline.

**Acceptance criteria.**
1. `grep -n '"Terminal"' Sources/App/MainTerminalTabStrip.swift Sources/App/ContentView.swift`
   finds no inline fallback; the literal lives only in `TerminalTab.displayTitle`.
2. `Tests/TerminalTabTests.swift` pins three cases: a name wins over a non-empty surface title; no
   name and an empty title gives "Terminal"; no name and a title gives the title.
3. No tab in the app has a name yet, so rendering is unchanged.

**Verification.** `./scripts/ci.sh` green, with the three new tests in the run. Criterion 1 by grep.

### T2: Let `hookShellCommand` take the PATH it exports

**Files:** `Sources/App/ContentViewHelpers.swift`, `Tests/HookShellCommandTests.swift` (new)

**What it does.** Change the signature to
`func hookShellCommand(_ cmd: String, path: String = ShellEnvironment.path) -> String` and export
`path` instead of reading `ShellEnvironment.path` inside the body. Nothing else in the body
changes: the subshell, the `printf` failure banner, `exit $s`, the `/bin/sh -c` wrap, and both
`hookLogger` lines stay byte-for-byte. The Before remove call site (`ContentView.swift:747`,
`hookShellCommand(cmd)`) is not edited.

**Acceptance criteria.**
1. `hookShellCommand("make setup", path: "/opt/bin:/usr/bin")` returns a string that starts with
   `/bin/sh -c '`, contains `export PATH=` followed by the escaped path, contains `(make setup)`,
   and contains `[hook failed: exit %d]`. A path with a single quote in it comes out escaped per
   `shellEscape`. Pinned in `Tests/HookShellCommandTests.swift`.
2. `git diff` of `ContentView.swift` for this task is empty.

**Verification.** `./scripts/ci.sh` green, with the new tests in the run.

### T3: Record the pending Setup hook per created worktree

**Files:** `Sources/App/TerminalManager.swift`, `Sources/App/ContentView.swift`,
`Tests/TerminalManagerTests.swift`

**What it does.** Adds the state only; nothing consumes it until T4, so behaviour is unchanged
(the hook still runs in the secondary panel after this task).

- `TerminalManager` gains `private var pendingSetupHooks: [String: String] = [:]`, beside
  `createdWorktrees` (`TerminalManager.swift:~231`).
- `markWorktreeCreated(_ worktree: Worktree, afterCreateCommand: SavedCommand?, setupHook: String?)`:
  `setupHook` is a **required** label with no default. A non-nil hook is stored under
  `worktree.id`; a nil hook stores nothing (and leaves no stale entry: assign
  `pendingSetupHooks[worktree.id] = setupHook`).
- Add `func takeSetupHook(for worktreeId: String) -> String?`, internal (not private) so tests
  reach it, that removes and returns the entry.
- `cleanupState(for:)` (`TerminalManager.swift:~531`) also does
  `pendingSetupHooks.removeValue(forKey: worktreeId)`, next to `createdWorktrees`.
- `ContentView`'s `onChange(of: worktreeManager.lastCreatedBranch)` handler
  (`ContentView.swift:~363-376`): compute `projectHookCmd` via `worktreeManager.hookCommand(\.afterCreate, ...)`
  **before** `markWorktreeCreated`, and pass it as `setupHook: projectHookCmd`. Leave the
  `runHookInSecondary` call in place for now; T4 removes it. `hookCommand` already returns `nil`
  for a blank or whitespace-only template, so no extra check.
- Update every test call of `markWorktreeCreated` in `Tests/TerminalManagerTests.swift` to pass
  `setupHook: nil`.

**Acceptance criteria.** New tests in `Tests/TerminalManagerTests.swift`:
1. `markWorktreeCreated(wt, afterCreateCommand: nil, setupHook: "x")` then `takeSetupHook(for:)`
   returns `"x"`, and a second call returns `nil`.
2. `setupHook: nil` records nothing: `takeSetupHook` returns `nil`.
3. `removeSurface(for:)` and `closeWorktree(_:)` each clear a pending hook (mirror
   `test_removeSurface_clearsTheCreationMark`).
4. Panel independence: with a setup hook marked, after `setInitialPanelVisibility(for:)`,
   `isSecondaryVisible(for:)` equals `openSecondaryOnStartProvider()` for both `true` and `false`.
5. Taking the setup hook does not disturb the creation mark: `takeFirstTabSource` still returns
   what it did before for the same mark.

**Verification.** `./scripts/ci.sh` green, with the new tests in the run.

### T4: Open the Setup tab through `appendTab` and retire the secondary-panel hook

**Files:** `Sources/App/TerminalManager.swift`, `Sources/App/TerminalManager+Setup.swift` (new),
`Sources/App/TerminalManager+Panels.swift`, `Sources/App/ContentView.swift`,
`Tests/TerminalManagerTests.swift`

**Depends on:** T1, T2, T3.

**What it does.**

- `appendTab(for:app:command:name: String? = nil, activate: Bool = true)`
  (`TerminalManager.swift:~336`):
  - Build `TerminalTab(id:surface:name:)` with `name`.
  - Existing-pane branch: append always; set `activeId = newTab.id` only when `activate`.
  - New-pane branch: `activeId` is `newTab.id` only when `activate`, else `nil`.
  - Call `transferFirstResponder(to:)` only when `activate`.
  - Record, before appending, whether the pane had no tabs: `existingPane == nil` or
    `existingPane?.main.tabs.isEmpty == true` (both branches can build a first tab; spec A5). After
    the append and `objectWillChange.send()`, if that was the first tab and
    `takeSetupHook(for: key)` returns a hook, call `openSetupTab(for: worktree, app: app, hook: hook)`.
    The recursion is safe: the Setup append is not a first tab, and the hook is already taken.
  - Rewrite the doc comment: "Append a tab ... and activate it" is no longer always true, and the
    first-tab append now opens the Setup tab. Keep it short, per the project's comment rule.
- `Sources/App/TerminalManager+Setup.swift`: an `extension TerminalManager` with
  `func openSetupTab(for worktree: Worktree, app: ghostty_app_t, hook: String)` that:
  1. `let surface = appendTab(for: worktree, app: app, name: "Setup", activate: false)` (no
     `command:`, so it is a login shell in the worktree directory).
  2. Starts a `Task { @MainActor in ... }` that does `let path = await ShellEnvironment.awaitPath()`,
     `await Self.awaitShellPrompt(on: surface)`, then
     `surface.sendPaste(hookShellCommand(hook, path: path))`.
  `awaitPath()` returns `String`; do not add a second PATH source. No `DispatchSource`, C callback, or `asyncAfter` here (see the Concurrency rules in
  `CLAUDE.md`).
- `Sources/App/TerminalManager+Panels.swift`: delete `runHookInSecondary` and
  `revealSecondaryForHook` with their doc comments and the `// MARK: - Secondary Hook Run` header.
  Drop `import GhosttyKit` if nothing left in the file needs it.
- `ContentView.swift` post-create handler: delete the `if let cmd = projectHookCmd, let app = ghosttyApp.app { terminalManager.runHookInSecondary(...) }`
  block and its "The hook runs in the secondary terminal" comment. `projectHookCmd` is still passed
  as `setupHook:` (from T3).
- `Tests/TerminalManagerTests.swift`: delete
  `test_runHookInSecondary_forcesSecondaryVisible_overridingOpenOnStartOff` and its
  `// MARK: - runHookInSecondary visibility` header.

**Acceptance criteria.**
1. `grep -rn "runHookInSecondary\|revealSecondaryForHook" Sources Tests` returns nothing (the
   `Sources/Ghostty/CLAUDE.md` mention is T5's).
2. `grep -rn "TerminalTab(" Sources/App` shows construction only inside `appendTab`; the Setup tab
   is made through `appendTab`, never a second path.
3. `openSetupTab` never touches `secondaryVisible`, `pane.secondary`, `activeId`, or
   `transferFirstResponder`.
4. The hook line is built after `awaitPath()` returns and is delivered with `sendPaste`, after
   `awaitShellPrompt(on:)`.
5. Every existing `appendTab` caller compiles unchanged and still activates and focuses its tab
   (defaults `name: nil`, `activate: true`).

**Verification.** `./scripts/ci.sh` green. Criteria 1 and 2 by grep; 3, 4, and 5 by reading the
diff. Ordering and non-activation need a surface, so they are operator hand-checks.

### T5: Update the notes and README that describe the old hook path

**Files:** `Sources/App/CLAUDE.md`, `Sources/Ghostty/CLAUDE.md`, `README.md`

**Depends on:** T4.

**What it does.**

- `Sources/App/CLAUDE.md`, the `onChange(of: lastCreatedBranch)` step list (~lines 210-219): the
  creation mark now also carries the After create hook, and the handler no longer runs the hook.
  `appendTab` runs it in a Setup tab after the worktree's first tab.
- `Sources/App/CLAUDE.md`, the `appendTab` door paragraph (~line 323): it activates and focuses by
  default, the Setup tab passes `activate: false` and `name: "Setup"`, and the first-tab append of a
  pane with a pending Setup hook appends the Setup tab right after it. Note that
  `pendingSetupHooks` is separate from `createdWorktrees` because `takeFirstTabSource` consumes the
  mark before an agent first tab lands.
- `Sources/App/CLAUDE.md` (~lines 362-364): "`sendPaste` survives only for
  `TerminalManager+Panels.swift`'s hook command" now names `TerminalManager+Setup.swift`'s Setup
  hook.
- `Sources/Ghostty/CLAUDE.md:6`: replace the `TerminalManager.revealSecondaryForHook` example with
  `TerminalManager.firstTabSource`.
- `README.md:58`: Start Now runs the after-create hook in a "Setup" tab beside the worktree's first
  tab, not in the secondary terminal.

**Acceptance criteria.**
1. `grep -rn "revealSecondaryForHook\|runHookInSecondary\|TerminalManager+Panels.swift's hook\|secondary terminal" Sources/App/CLAUDE.md Sources/Ghostty/CLAUDE.md README.md`
   returns no line that describes the hook running in the secondary panel.
2. Each edited passage matches the code T4 left: the method names, the file name, and the
   `name:` / `activate:` parameters exist as written.

**Verification.** Criteria by grep and by reading each passage against the T4 code.
`./scripts/ci.sh` green (docs-only, but the regression check runs after every build task).

## Risks

| Risk | Impact | Mitigation |
| --- | --- | --- |
| `appendTab`'s first-tab detection misses one branch, so Setup never opens or opens as tab 1. | High | T4 computes "first tab" from the pane state before the append on both branches (spec A5); operator hand-checks all three first-tab kinds. |
| Setup's `awaitShellPrompt` runs on an unmounted surface. | Medium | Spec A8: `pwd` comes from an app action, not rendering, and the 750 ms fallback backstops it. |

## Build log

### T1: Give a main tab an optional name and one display-title rule

| File | State |
| --- | --- |
| `Sources/App/TerminalTab.swift` | `TerminalTab` gains `var name: String?`; `static func displayTitle(name:surfaceTitle:)` holds the only `"Terminal"` fallback. |
| `Sources/App/MainTerminalTabStrip.swift` | `TerminalTabChip` takes `let name: String?` and titles itself through `displayTitle`; `chip(for:)` passes `tab.name`. |
| `Sources/App/ContentView.swift` | `beginCloseTab` builds the close-dialog title through `displayTitle`. |
| `Tests/TerminalTabTests.swift` | New: the three cases from criterion 2. |
| `Clearway.xcodeproj/project.pbxproj` | Regenerated by `xcodegen` to include the new test file. |

**Evidence.** RED: `./scripts/ci.sh` with only the test file added exited 65:

```
Tests/TerminalTabTests.swift:6:36: type 'TerminalTab' has no member 'displayTitle'
Tests/TerminalTabTests.swift:10:36: type 'TerminalTab' has no member 'displayTitle'
Tests/TerminalTabTests.swift:14:36: type 'TerminalTab' has no member 'displayTitle'
```

GREEN: the xcresult lists `TerminalTabTests/testNameWinsOverSurfaceTitle()`,
`testNoNameAndEmptyTitleFallsBackToTerminal()`, and `testNoNameUsesSurfaceTitle()` as Passed.
Criterion 1: `grep -n '"Terminal"' Sources/App/MainTerminalTabStrip.swift Sources/App/ContentView.swift`
prints nothing (exit 1).

**Deviations.** The plan wrote `let name: String?`. It is `var name: String?` because only a `var`
optional gets a `nil` default in the memberwise initializer, which keeps
`TerminalTab(id: UUID(), surface: surface)` in `TerminalManager.appendTab` unchanged as the plan
asks. Nothing mutates it.

**Gate.** `./scripts/ci.sh` exit 0, 843 tests, 0 failures; `swiftlint lint --quiet` reported nothing.
