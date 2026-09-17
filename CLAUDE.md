# Clearway

Native macOS terminal app built on libghostty.

## Setup

```bash
./scripts/setup.sh
```

Requires: `zig`, `xcodegen`, `swiftlint`

## Build & Run (Debug)

```bash
./scripts/build.sh   # build only
./scripts/run.sh     # build + launch
```

`build.sh` names the product per worktree (`Clearway (<worktree>).app`) while `ci.sh` builds the
default `Clearway.app` into the same `BUILT_PRODUCTS_DIR`, so the two overwrite each other. Resolve
the bundle the way `run.sh` does — newest `.app` in `BUILT_PRODUCTS_DIR`, executable name from
`CFBundleExecutable` — rather than hardcoding a DerivedData path, or you will run a stale binary.

Running the Debug build drops `default.profraw` in the repo root and it is **not** gitignored, so
`git status` goes dirty after every launch. Never `git add -A` without reading the list.

## Verifying a change

```bash
./scripts/ci.sh
```

Regenerates the Xcode project, lints, builds, and runs the test suite — the same gate `.github/workflows/ci.yml` applies to a PR. Use it instead of a hand-written `xcodebuild` line: new Swift files are invisible to the build until `xcodegen generate` runs, and `build.sh`'s `PRODUCT_NAME` override breaks `TEST_HOST`, so the tests fail to launch.

## Linting

SwiftLint runs as a post-build script phase. To lint manually:

```bash
swiftlint lint --quiet
```

All new code must pass `swiftlint lint` with zero errors before committing. Warnings are acceptable for now but should not be introduced in new code.

## Concurrency

- **Never use `isolated deinit` (SE-0371) while the deployment target is macOS 13.** It typechecks
  and emits object code with no availability diagnostic, but references `_swift_task_deinitOnExecutor`
  — a Swift 6.2 runtime symbol. The SDK's `libswift_Concurrency.tbd` back-deploys to `@rpath` only
  below macOS 12.0, so a 13.0 target links the OS copy and the app fails at launch on older systems.
  The compiler will not warn you. Make the `deinit` genuinely nonisolated instead.
- Prefer an **isolated conformance** (`@MainActor SomeDelegate`) over `@preconcurrency` whenever the
  compiler reports `#ConformanceIsolation`. `@preconcurrency` downgrades the check to a runtime trap;
  an isolated conformance keeps it static. Applies to the unannotated AppKit delegate protocols —
  `NSTextStorageDelegate` is one; `NSTextViewDelegate` is already `NS_SWIFT_UI_ACTOR` and needs neither.
- `DispatchSourceFileSystemObject` is `Sendable`, so a nonisolated `deinit` can cancel one directly.
  `DispatchWorkItem` is not — hold it in a `ScheduledWork` (`Sources/App/ScheduledWork.swift`) whose own
  `deinit` cancels it. `@preconcurrency import Dispatch` also silences the diagnostic, but file-wide;
  the only one left (`ClaudeSessionFiles.swift:1`) predates the RAII holder.
- `MainActor.assumeIsolated` asserts, it does not dispatch. Use it only where arrival on main is
  already guaranteed — never on a `DispatchSource` callback path. Even where arrival *is* guaranteed
  (a `NotificationCenter` observer registered with `queue: .main`), prefer `Task { @MainActor in }`
  unless the call has to stay synchronous: it keeps the check static instead of runtime.
- A nonisolated `deinit` may not *read* an isolated non-`Sendable` property, but releasing one is not
  reading it. So an RAII holder whose own `deinit` does the cleanup needs no suppression at all —
  `NotificationObservation` deregisters a `NotificationCenter` token, `ScheduledWork` cancels a
  `DispatchWorkItem`, and `Ghostty`'s `AppHandle` / `SurfaceHandle` reach `ghostty_app_free` /
  `ghostty_surface_free`. It scales to collections: `ClaudeActivityMonitor.WatcherState` is a class
  for this reason, so releasing the dictionary cancels every watcher. Reach for this before a lock.
- **The load-bearing `[weak self]` is the outer one.** On a closure that `NotificationCenter` retains
  — or a `DispatchWorkItem` the object itself owns — the *outer* capture list is what breaks the
  cycle. An inner `Task { @MainActor [weak self] }` nested inside it is redundant: a nested closure
  keeps an outer weak capture weak. Drop the inner one, never the outer. Doing the reverse is exactly
  how `WorkTaskCoordinator` leaked through `.ghosttyChildExited`, and a code review has since
  recommended it a second time, so the shape reads as interchangeable and is not. The exception is an
  outer block that does `guard let self`: there `self` is strong again and the inner `[weak self]`
  earns its place (`TerminalManager`'s `.ghosttyCloseSurface` observer is the one such site).
- `OpaquePointer` and `UnsafeMutableRawPointer` carry an *unavailable* `Sendable` conformance, so no
  wrapper holding a `ghostty_*_t` can be checked-`Sendable`. With the RAII shape above it usually
  does not need to be.
- **Never form a C or block callback inside a `@MainActor` context.** A `@convention(c)` *or*
  `@convention(block)` closure literal written inside a `@MainActor` member is main-actor isolated:
  its prologue calls `swift_task_isCurrentExecutor` and traps when the callback is invoked from any
  other thread. The compiler reports nothing — unlike a plain Swift function-typed parameter, which
  infers the literal `nonisolated` and checks it statically. `Ghostty.App.makeRuntimeConfig` is
  `nonisolated static` for exactly this reason — build the callback table there, never in `init`.
  Marking the callee `static func`s `nonisolated` is also required but is **not** sufficient on its own.
- **`DispatchSource` handlers are that same block trap**, and cost a shipped release (v1.9.3) a
  crash on every worktree switch: `setEventHandler`/`setCancelHandler` take
  `DispatchSourceHandler = @convention(block) () -> Void`, so a literal written in a `@MainActor`
  method traps in `dispatch_assert_queue` the moment libdispatch runs it on the source's queue —
  the cancel handler included, which fires on teardown rather than on any file event. Swift 5.10
  converted these silently; `SWIFT_VERSION: "6.0"` turns them into hard traps. So **every**
  `DispatchSource` goes through `ClaudeSessionFiles.makeWatcher`, which is `nonisolated static` and
  takes the handler as a plain `() -> Void`. Never call `setEventHandler`/`setCancelHandler` from an
  isolated method. `WorktreeGroupStore` builds its own sources safely only because the type is
  `Sendable` rather than `@MainActor`, so its methods are already nonisolated.
- A minimal probe of that shape does not reproduce the trap; it runs the body off-main silently.
  Verify by disassembling the built binary (`lldb -b -o "disassemble -a <addr>"`) and looking for
  `MainActor.shared` / `swift_task_isCurrentExecutor` in the closure's prologue.
- libghostty installs its **own** crash handler, so a crash writes no macOS `.ips`. Reports land in
  `~/.local/state/ghostty/crash/*.ghosttycrash` (a Sentry envelope; the minidump is the
  `event.minidump` attachment, loadable with `lldb --core`). A directly-exec'd crash surfaces as
  exit code 6, not a signal.

## Architecture

- **ghostty/** — upstream ghostty submodule, built into `GhosttyKit.xcframework`
- **Sources/Ghostty/** — first-party Swift wrappers around the libghostty C API. Excluded from SwiftLint (`.swiftlint.yml`), but **not** vendored and not an upstream mirror — only `ghostty/` is a submodule. Held to the same engineering bar as `Sources/App`.
  - `Ghostty.swift` — namespace + logger
  - `Ghostty.Config.swift` — wraps `ghostty_config_t`
  - `Ghostty.App.swift` — wraps `ghostty_app_t`, runtime callbacks
  - `Ghostty.SurfaceView.swift` — `NSView` hosting a `ghostty_surface_t` (input, rendering).
    Nothing on it is reachable from XCTest: an instance is needed to call anything, and the
    initializer needs a real `ghostty_app_t`. So any decision rule here is lifted out into a pure
    helper that gets tested instead — the same split `TerminalManager.revealSecondaryForHook` makes
    for panel visibility.
    A focused surface swallows **every** Cmd/Ctrl combo, encoding it for the shell, unless the app
    claims it via `SurfaceView.claimsShortcut` — one **static** provider wired in `ClearwayApp.init`
    to `AppKeyboardShortcuts.claims`. Process-scoped, not per-window: the value must stay
    window-independent, so wire it there rather than beside the per-window seams in
    `ContentView.onAppear`. A SwiftUI `.keyboardShortcut` declared without a matching entry is
    unreachable whenever a terminal has focus, which is why the table and the declarations live in
    the same layer.
  - `TerminalSurface.swift` — SwiftUI `NSViewRepresentable` wrapper
- **Sources/App/** — SwiftUI app entry point + task/worktree logic
  - `AppKeyboardShortcuts.swift` — the combos the app claims from focused terminal surfaces, plus the
    layout-independent key codes its `NSEvent` monitor matches on. Add a shortcut here in the same
    change that declares it — declaration sites are `ContentView`'s hidden buttons and `NSEvent`
    monitor, and `ClearwayApp`'s menu commands (the view hierarchy is offered a key equivalent
    before the main menu, so menu shortcuts need an entry too). Claim **exactly** what the app
    handles: a claimed combo no handler answers is taken from the shell and then dropped.
    A shortcut Clearway itself retires gets a not-claimed pin in `AppKeyboardShortcutsTests`
    (⌘⌃2, ⌘⌃3); a SwiftUI default dropped as collateral does not (⌃⌘S). The pins cover keys the
    app once owned, not every combo it declines. The Ctrl+digit claim therefore spans `"1"…"3"` —
    the sidebar's three destinations.
  - `PanelCommands.swift` — the View menu's three panel toggles: sidebar ⌘B, bottom panel ⌘J,
    aside ⌥⌘B, each a `PanelToggle` (`isVisible` + `toggle`) that `ContentView` publishes as a
    focused **scene** value. A `nil` value greys the item out, which is also how all three grey out
    on a standalone Task/Prompt/Settings window. Each key is declared **only** on its menu item —
    a hidden `.keyboardShortcut` button would declare it a second time, in a layer that silently
    wins. ⌘⌃3 (aside) and ⌃⌘S (sidebar) were retired here with no alias.
    `ClearwayApp` declares them with `CommandGroup(replacing: .sidebar)`: SwiftUI generates that
    group's Show Sidebar item on ⌃⌘S and offers no way to retitle or re-key it, and `replacing:` is
    the only removal. Show Frontmatter moved inside that group so it stays above Full Screen.
    Despite Apple documenting the group as carrying Enter/Exit Full Screen too, **the stock
    full-screen item survives the replacement** — verified against the running app. So the app
    declares no full-screen command and claims no ⌃⌘F; re-declaring one produced a duplicate menu
    item, and the system's own key for it is not ⌃⌘F on macOS 26.
    A `PanelToggle`'s `nil` gate must carry **every** precondition its action would guard, or the
    item renders enabled and silently does nothing: the Tasks bottom panel needs `ghosttyApp.app`
    as well as a `selectedTaskId`, since only `detailView` switches on readiness, so a failed
    `ghostty_app_new` still leaves the task list rendering and setting a selection.
    `newTabAction` / `newShellTabAction` still split the two and are the known exceptions.
  - **A `.toolbar` for the detail column goes on the detail column's own content.** Attached to the
    `NavigationSplitView` in `ContentView`, SwiftUI routes the `ToolbarItem`s into the detail section
    but hoists every `ToolbarSpacer` into the leading sidebar section, ignoring the spacer's
    `placement:` — which is why the worktree toolbar now hangs off `detailView` rather than the split
    view, and why `CommandsView` declares its own `+` and filter picker on its own root view.
    A nested view's toolbar content merges **after** the enclosing view's, so the aside panels'
    (`PromptsView`, `TodosPanelView`) items arrive behind `detailView`'s four worktree buttons: the
    spacer that separates their `+` from those buttons precedes it, where every other view's follows.
    Every such break is a `ToolbarGroupBreak` (`Sources/App/ToolbarGroupBreak.swift`), which holds
    the macOS 26 availability check `ToolbarSpacer` needs in one place.
    `.navigationTitle` goes the other way: `ContentView`'s sits **outside** the split view and
    overrides anything a column sets, so a per-destination window title is resolved in its
    `navigationTitle` property, not by a `.navigationTitle` inside the detail column.
  - Task start-up logic lives on `WorkTaskCoordinator`, never in a view: a view resolves no worktree
    and awaits nothing, it calls a coordinator method (`startTask`, `completePendingLaunch`). This is
    what lets one behavior carry several entry points without the decision being written once per
    door. Starting a task creates the worktree, relocates its `TASK.md` into it and writes
    `status = in_progress`; if the task's branch already has a live worktree it is focused instead,
    and that branch writes nothing. **Clearway launches no agent of its own**, and nothing advances
    the status afterwards. `status` is frontmatter Clearway writes and round-trips but **never
    renders** — there is no badge and no label table, so an unrecognized slug needs no handling
    beyond being carried through untouched.
  - `AgentLaunch.swift` — `agentAllowlist` (`claude`, `grok`, `codex`) has exactly one reader: it
    renders Settings → Main Terminal's picker rows in `SettingsView`. No launch is gated against it,
    so adding a name there only offers it in the picker.
    `buildAgentPromptCommand` backs the prompt launcher's submit. It writes the prompt to a
    mode-`0o600` temp file and builds `/bin/sh -c` around `$1 "$(cat "$2")"`, where `$1` — the agent
    command — is **unquoted on purpose** so a multi-word command word-splits. Unquoted parameter
    expansion is never re-scanned for shell operators, so `claude; rm -rf /` arrives as the literal
    argv words `claude;`, `rm`, `-rf`, `/` and nothing executes. Do not "fix" this by quoting `$1`:
    multi-word commands would then be looked up as a single filename. The prompt reaches the agent as
    one argv element, so a prompt near the OS `ARG_MAX` (~1 MB on recent macOS) fails with "Argument
    list too long" — the launcher's prompts sit well under that.
  - `TerminalManager.appendLauncherTab` promotes the new tab straight to a login shell when
    `startsAsLoginShell` is true — neither its `agentOverride` nor `mainCommandProvider()` names an
    agent. Otherwise the tab stays a launcher and its view focuses the prompt input. The override is
    what keeps an agent command's tab a launcher with Settings → Main Terminal at "None", where the
    agent would otherwise be swallowed into a bare shell; the rule is `static` so the truth table is
    testable without a `ghostty_app_t`.
  - Running a saved command is `TerminalManager.run` (`TerminalManager+Commands.swift`), not the
    `RunCommandMenu` view: the view resolves no worktree and awaits nothing, so the shell-readiness
    wait and the stage-vs-promote branch live on the coordinator with the rest of the tab logic.
    The Enter placement a terminal command needs is `ShellSend.steps`, not a surface method —
    nothing on `Ghostty.SurfaceView` is reachable from XCTest, and staging rather than running the
    last line is the rule most worth pinning.
  - `SavedCommandStore.swift` owns `~/.clearway/commands.json`, the one global list of saved
    commands. Array order **is** display order — nothing sorts it, and a reorder rewrites the file.
    There is deliberately no watcher: the app is the only writer and `SavedCommandManager` is
    process-wide, so the case a watcher would cover cannot arise.
  - Sidebar visibility is `Worktree.visible(_:showingDetached:openIds:)`, applied inside
    `WorktreeGroupManager.sidebarOrderedWorktrees` before it orders anything, so the rows, the ⌘N
    badge and the ⌘1…9 buttons cannot disagree about which worktrees exist. It hides a bare-detached
    worktree that is neither main nor open unless Settings → Appearance → Show detached worktrees is
    on; a worktree whose HEAD is detached because a git operation is in progress never reaches it as
    `.detached`, because `applyHeadResolution` has already rewritten it — to `.rebasing`/`.bisecting`
    with the branch `WorktreeManager.inProgressOp` recovered, or to `.inProgress` for cherry-pick,
    revert, merge and `git am`, which record no branch, so those rows keep the "(detached)" name and
    are hidden by nothing. Only rendering paths go through that method, and only they should:
    this is a display rule, not a change to what the app tracks.
  - `WorktreeGroupStore.openFileWatcher` has a known, deliberate leak: the `fileGone` reopen path
    installs a new source over the old one without cancelling it, so the old cancel handler never
    runs and its `O_EVTONLY` fd stays open for the process lifetime. Preserved as-is through the
    Swift 6 migration because fixing it is a behaviour change; it needs its own task.
- **project.yml** — xcodegen spec (generates `Clearway.xcodeproj`)
- **Sources/App/Clearway-Bridging-Header.h** — the only route to cmark-gfm's GFM extension API; the SPM package's umbrella header exposes just `cmark.h`, so `import cmark` cannot see it. Its four prototypes are hand-copied, so the package is pinned with `exactVersion` — a signature change in a later 2.x would not fail the build.
- swift-markdown was evaluated and rejected for the Markdown preview: it is parse-only, ships no HTML renderer, and wraps the same cmark-gfm already vendored.

## Rebuilding GhosttyKit

```bash
cd ghostty && zig build -Demit-xcframework=true -Doptimize=ReleaseFast
```

## Key APIs

The libghostty C API (defined in `ghostty.h`) uses opaque pointer types:
- `ghostty_app_t` — one per process, manages config + surfaces
- `ghostty_surface_t` — one per terminal view
- `ghostty_config_t` — configuration

Key patterns:
- To run a command in a terminal without a login shell, pass `command:` to `Ghostty.SurfaceView(app, workingDirectory:, command:)`. Do NOT create a bare surface and then `sendCommand()` — that starts a login shell first, making the command visible in the prompt.
- Runtime callbacks are registered via `ghostty_runtime_config_s` when creating the app
- Surface userdata is set via `ghostty_surface_config_s.userdata` and retrieved via `ghostty_surface_userdata()`
- Key input uses `ghostty_input_key_s` with `keycode` (macOS virtual key code), not a key enum
- Mods use `GHOSTTY_MODS_*` constants (e.g. `GHOSTTY_MODS_SHIFT`, `GHOSTTY_MODS_CTRL`)

## Pipeline

How the `/work` pipeline runs in this repo. Irrelevant outside it.

### Regression check vs. full gate

One command serves both — `./scripts/ci.sh` is the only runner of the test suite, and it runs
`xcodegen generate`, without which added or deleted Swift files are invisible to the build.

| Step | Command | What it is |
| --- | --- | --- |
| Every `build` task, and `simplify` | `./scripts/ci.sh` | Regression check |
| `sign-off`, once | `./scripts/ci.sh` | Full gate |

### Merge model

The pipeline never merges; the operator merges by hand once CI is green. Squash and rebase merges
are allowed, merge commits disabled, branch deletion on merge on. Auto-merge is disabled at the repo
level, so there is no command to enable it. The `Main` ruleset blocks only deletion and
non-fast-forward pushes — GitHub requires no status check, so `.github/workflows/ci.yml` (jobs
`SwiftLint`, `Build & Test`) gates by convention, not enforcement.

`ci.sh` does not itself refuse on a dirty tree, so before any CI stamp or sign-off run
`git status --porcelain` and report untracked/ignored files; they block sign-off. Expect the
un-gitignored `default.profraw` noted above after any Debug launch.
