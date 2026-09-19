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
  isolated method.
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
    monitor, `ClearwayApp`'s menu commands (the view hierarchy is offered a key equivalent
    before the main menu, so menu shortcuts need an entry too), and the tab strip's `+` menu rows.
    Those rows declare ⌘T and ⌥⌘T a **second** time on purpose: `.keyboardShortcut` is the only way
    SwiftUI renders the glyph beside a menu row. Unlike the `PanelCommands.swift` case below, the
    duplicate is harmless — both declarations run the same action on the same worktree, so whichever
    layer wins is correct. Claim **exactly** what the app
    handles: a claimed combo no handler answers is taken from the shell and then dropped.
    A shortcut Clearway itself retires gets a not-claimed pin in `AppKeyboardShortcutsTests`
    (⌘⌃2, ⌘⌃3, ⌘⇧T); a SwiftUI default dropped as collateral does not (⌃⌘S). The pins cover keys the
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
    `newTabAction` / `newAgentTabAction` still split the two and are the known exceptions.
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
  - `AgentLaunch.swift` — `agentAllowlist` (`claude`, `codex`, `grok`) is display order and has three
    readers: Settings → Main Terminal's picker rows in `SettingsView`; `agentMenuRows`, the tab
    strip `+` menu's row rule, which lives in this file beside the list so the two orders cannot
    disagree; and `CommandEditorSheet`, which renders a saved agent command's picker from it **and**
    takes `agentAllowlist.first` as a new saved command's default agent. That default makes the head
    of the list behaviour rather than presentation — a reorder changes what every new agent command
    is created with — so `AgentMenuRowTests` pins it. `agentMenuRows` is pure — it marks the row
    matching the configured Main Terminal command as the one carrying ⌥⌘T, and marks none when that
    command is nil or unlisted. No launch is gated against the allowlist, so adding a name there only
    offers it in those three pickers.
    `buildAgentPromptCommand` backs a saved agent command's prompt. It writes the prompt to a
    mode-`0o600` temp file and builds `/bin/sh -c` around `$1 "$(cat "$2")"`, where `$1` — the agent
    command — is **unquoted on purpose** so a multi-word command word-splits. Unquoted parameter
    expansion is never re-scanned for shell operators, so `claude; rm -rf /` arrives as the literal
    argv words `claude;`, `rm`, `-rf`, `/` and nothing executes. Do not "fix" this by quoting `$1`:
    multi-word commands would then be looked up as a single filename. The prompt reaches the agent as
    one argv element, so a prompt near the OS `ARG_MAX` (~1 MB on recent macOS) fails with "Argument
    list too long" — typical agent prompts sit well under that.
  - `TerminalManager.appendTab` is the one door every main tab goes through: it builds the
    `Ghostty.SurfaceView` with its command up front, appends, activates and focuses. No tab is ever
    an intermediate screen — ⌘T and the `+` menu's New Terminal row pass no command and get a login
    shell; ⌥⌘T, the `+` menu's agent rows and the first tab of a worktree Clearway itself just
    created pass an agent command built by
    `buildBareCommand` (`TerminalManager+Agent.swift`).
    An agent tab goes through `startAgentTab`, which is **synchronous** even though its body is a
    `Task`: it has to take the per-worktree `agentLaunchesInFlight` claim in the caller's runloop
    turn, because the `await ShellEnvironment.awaitPath()` that follows leaves the pane with no tabs
    and `detailView` would render the "⌘T for a new tab" empty state for that frame. A login-shell tab
    awaits nothing — the shell resolves its own PATH — so ⌘T never defers a frame and takes no claim.
    The marker is a **rendering gate first**. Refusing on it is `refuseWhenInFlight`, a property of
    the **door** rather than of the launch, so it carries no default and every call site states it.
    Only ⌥⌘T passes `true` — the File menu item and the one `+` row that carries the same key —
    because a second press during the wait is a repeat of the first. The `+` menu's other agent
    rows, a saved `.agent` command and a created worktree's first tab pass `false`: each names a tab
    the user asked for by itself, and two of them started within the same cold-launch PATH wait must
    both open. Only the launch that owns the marker ends it, so a passing launch cannot clear the
    gate out from under its owner.
    Across the await the pane may be gone — closed, pruned, or the worktree deleted — so the `Task`
    re-checks `hasPane` before appending. Without it `appendTab`'s pane-creation branch rebuilds the
    pane and re-registers a worktree the user just tore down. The check sits *ahead* of building the
    command so the argv path allocates no orphan prompt file. Nothing cancels the `Task`, which is
    why the owner ends its claim on that path too rather than leaving the gate set.
    The staged case (`submit` off) sends the prompt with **`sendText`, never `sendPaste`** —
    `sendPaste` appends Enter, which runs the prompt the user's toggle said to stage.
    `promptDelivery` and `proceedsWithLaunch` are `static` so both rules are testable without a
    `ghostty_app_t`.
  - Running a saved command is `TerminalManager.run` (`TerminalManager+Commands.swift`), not the
    `RunCommandMenu` view: the view resolves no worktree and awaits nothing, so the shell-readiness
    wait and the shell-vs-agent branch live on the coordinator with the rest of the tab logic.
    The Enter placement a terminal command needs is `ShellSend.steps`, not a surface method —
    nothing on `Ghostty.SurfaceView` is reachable from XCTest, and staging rather than running the
    last line is the rule most worth pinning.
  - `SavedCommandStore.swift` owns `<projectPath>/.clearway/commands.json`, one saved-command list
    per project, shared by every worktree of that repo. The store takes the project path and owns the
    `.clearway` component itself — `commands.json` is the only file under it — and the list is always
    read from the project root rather than the selected worktree — a `commands.json` checked out differently on
    a branch must not change what the Run dropdown shows. Array order **is** display order — nothing
    sorts it, and a reorder rewrites the file. There is deliberately no watcher: `SavedCommandManager`
    is a `@StateObject` on `ProjectContentView`, built from `projectPath`, and reads the file once —
    an edit made outside the app, in a text editor or by `git pull`, is picked up when the window
    reopens.
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
  - `OpenInApp.swift` / `OpenInAppLauncher.swift` / `OpenInMenu.swift` /
    `OpenInAppsSettingsSection.swift` — the "Open In" list: the model and its `Draft` validation, the
    launcher, the one menu view both entry points render, and the Settings section that edits the
    list. The list lives on `SettingsManager.openInApps` as JSON in a single `UserDefaults` value; an
    absent or undecodable key reseeds `[Finder]`, a stored `[]` stays genuinely empty. The seed is
    **written back only for a genuinely absent key** — an undecodable value is left on disk, because
    `Kind` is an associated-value enum whose synthesized JSON carries its case names and `_0` as
    persisted form, so a rename or a version rollback makes the whole array throw and overwriting it
    would destroy the user's list irrecoverably. `OpenInAppTests`' wire-format case decodes those
    literal bytes; a round-trip test cannot catch a rename. It is a
    preference, not a saved-command list, so it belongs there rather than in a `~/.clearway` JSON
    file the way `SavedCommandStore` holds commands.
    `buildOpenInScript` interpolates the command text **raw** and escapes only the appended folder —
    the same contract as `WorktreeHooks.interpolated`: the command is the user's and the shell reads
    it as typed. Do not "fix" this by escaping it; a command carrying flags or shell operators is the
    point. The script carries no `export PATH=`: `process.environment =
    ShellEnvironment.processEnvironment` already hands the child the resolved PATH, the way
    `WorktreeManager.runCommand` does, so exporting it inside the script injected the same value
    twice.
    The launcher is `nonisolated` throughout and uses **no** `Process.terminationHandler`: that is a
    bridged ObjC block property, so a `@convention(block)` literal written in a `@MainActor` member
    traps the moment it is invoked off-main (see Concurrency above). The 2-second failure window is
    a `Task.sleep` poll of `process.isRunning` on the cooperative pool — still running at the
    deadline counts as launched, and the child is simply abandoned.
    The child's stdout **and** stderr go to one **unlinked temp file**, never a `Pipe`. A pipe's
    verdict arrives at EOF, and any grandchild inheriting the descriptor — the editor a command
    backgrounds — holds the write end open for its whole life, so `readDataToEndOfFile()` hid the
    shell's exit status behind it: a command like `myeditor &` failed in milliseconds and the user
    saw no alert, while a `DispatchQueue.global` worker stayed parked for the editor's session
    (libdispatch caps that pool, and `ShellPathStore` resolves PATH on the same queue and QoS, so
    enough parked launches hung new agent tabs with no diagnostic). Do not go back to a pipe:
    a regular file has no 64KB buffer, so nothing has to be drained, and unlinking at once means
    the space is reclaimed when the last descriptor closes. `standardInput` is `nullDevice` so a
    command that reads stdin gets EOF instead of the app's.
    A `run()` throw is about the working directory, not the command — the shell has not looked the
    command up yet — so `spawnFailureMessage` names the folder rather than letting the alert's
    "Couldn't open in Cursor" title imply the app is missing.
    Both entry points — a `.primaryAction` item in `detailView`'s toolbar, in its own
    `ToolbarGroupBreak` capsule beside Run, and `SidebarView`'s worktree context submenu — are gated
    on a non-empty list **and** a non-nil worktree path, so emptying the list in Settings hides them.
    Unlike `RunCommandMenu`, which stays visible and disabled, the toolbar item disappears: an empty
    list is a configuration the user chose, not a momentarily unavailable action. The sidebar passes
    the right-clicked worktree's path, not the selection's. The toolbar item is the **text** label
    `Text("Open in")` with the system chevron and no `.help()` tooltip — the sidebar submenu carries
    that same label, lowercase preposition included, the way Reveal in Finder does. `RunCommandMenu`
    beside it carries the same shape — `Text("Run")` with the system chevron and no `.help()` — because
    both open a menu rather than acting on a click, which an icon-only button reads as. The remaining
    toolbar items do act on a click and stay icon-only. The menu and the settings section are
    separate files because `ContentView.swift` sits at SwiftLint's 1000-line `file_length` limit and
    only carries on via the file-wide `swiftlint:disable` at its first line; the next addition there
    needs a split first.
    The menu claims **no** keyboard shortcut, so `AppKeyboardShortcuts` has no entry for it.
  - `WorktreeGroupManager.swift` — sidebar grouping, stored entirely in git config through
    `WorktreeConfigStore`. Four keys: repo-level `clearway.grouping` (the sectioning axis) and
    `clearway.groupOrder` (a multivar, one value per group name in creation order — the registry),
    and per worktree `clearway.group` and `clearway.position` in its own `config.worktree`. A group
    is identified by its name; the registry is the only source of which groups exist, so a worktree
    naming a group the registry does not list renders ungrouped. Nothing prunes a stale membership
    or position, and nothing watches git config — values are re-read when the worktree list changes.
    **The registry is written last**: a rename rewrites every member's `clearway.group` and a delete
    unsets it, and either abandons the registry write if a member did not land, so a half-applied
    rename never empties the group. **Positions are numbered per section from zero**, so every
    gesture that moves a worktree between sections renumbers it at the target's maximum plus one —
    `addWorktree`, `removeWorktreeFromGroup` and `deleteGroup` alike. A delete that skipped this
    dropped its members onto slots the ungrouped rows already held, and they stayed interleaved
    across relaunches because nothing renumbers a worktree that already has a position.
    The two worktree keys must stay **single lowercase words** —
    `git config --list` lowercases key names and `WorktreeConfigStore.parseList` keys its dictionary
    on what git printed; the repo-level keys are read with `--get`/`--get-all`, which return values
    only, so `clearway.groupOrder` keeps its camel case.
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
