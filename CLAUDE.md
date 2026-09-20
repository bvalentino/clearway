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
  the only one left (`FileWatchers.swift:1`) predates the RAII holder.
- `MainActor.assumeIsolated` asserts, it does not dispatch. Use it only where arrival on main is
  already guaranteed — never on a `DispatchSource` callback path. Even where arrival *is* guaranteed
  (a `NotificationCenter` observer registered with `queue: .main`), prefer `Task { @MainActor in }`
  unless the call has to stay synchronous: it keeps the check static instead of runtime.
- A nonisolated `deinit` may not *read* an isolated non-`Sendable` property, but releasing one is not
  reading it. So an RAII holder whose own `deinit` does the cleanup needs no suppression at all —
  `NotificationObservation` deregisters a `NotificationCenter` token, `ScheduledWork` cancels a
  `DispatchWorkItem`, and `Ghostty`'s `AppHandle` / `SurfaceHandle` reach `ghostty_app_free` /
  `ghostty_surface_free`, and `AgentActivityMonitor`'s `HookSocketListener` cancels a
  `DispatchSourceRead` whose cancel handler closes the listening descriptor — so turning the agent
  hooks off is `listener = nil` and no teardown call of its own. Reach for this before a lock.
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
  file-system `DispatchSource` goes through `FileWatchers.makeWatcher`, which is `nonisolated static`
  and takes the handler as a plain `() -> Void`. Never call `setEventHandler`/`setCancelHandler` from
  an isolated method. The one source that is not a file watcher — `HookSocketListener`'s read source
  over the hook socket — keeps the rule rather than the door: its whole socket path is a
  `nonisolated static` factory, because an `AF_UNIX` listener shares nothing with `O_EVTONLY` on a
  path but the trap.
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
    `SurfaceView.agentEnvironment` is the second such provider, wired in the same two lines of
    `ClearwayApp.init` to `AgentHookIdentity.environment`. It returns the env vars to stamp on a
    surface's child process from its `surfaceId` and `worktreeId`, and it exists so this layer never
    learns the names: `Sources/Ghostty` wraps libghostty and must not import the hook feature, and a
    provider makes the names testable without a `ghostty_app_t`. Its default is `{ _, _ in [] }`, so
    a missing wiring line compiles, launches and silently ships a dead feature —
    `AgentHookIdentityTests.testTheSurfaceProviderIsWiredAtLaunch` is the pin, and it works because
    the unit-test bundle is hosted by the app, so `ClearwayApp.init` has already run.
    The pairs are `strdup`ed into a `[ghostty_env_var_s]` and freed in a `defer` after
    `ghostty_surface_new`: `Surface.init` `dupeZ`s both key and value into the surface config's arena
    synchronously (`ghostty/src/apprt/embedded.zig`), so the Swift copies need to outlive that one
    call and nothing more.
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
    A nested view's toolbar content merges **after** the enclosing view's, so its items land behind
    the enclosing view's: a nested view puts the break that separates the two groups **before** its
    own items. A break between two groups a single view owns simply goes between them — which is
    every call site in the tree today, so none of them is precedent for the nested case.
    Every such break is a `ToolbarGroupBreak` (`Sources/App/ToolbarGroupBreak.swift`), which holds
    the macOS 26 availability check `ToolbarSpacer` needs in one place.
    `.navigationTitle` goes the other way: `ContentView`'s sits **outside** the split view and
    overrides anything a column sets, so a per-destination window title is resolved in its
    `navigationTitle` property, not by a `.navigationTitle` inside the detail column.
  - **A button never hand-builds its glass.** Buttons take the system styles — `.glass` /
    `.glassProminent`, with `.bordered` / `.borderedProminent` below macOS 26 — through
    `GlassButtonStyles.swift`, which owns that availability split. `.glassEffect` plus a stroke is
    for non-button containers such as the aside tab strip and the main terminal tab strip; on a
    button it drops the system font, padding, shape and hover/press treatment, so the control reads
    as foreign beside stock buttons like Create Task.
  - Task start-up logic lives on `WorkTaskCoordinator`, never in a view: a view resolves no worktree
    and awaits nothing, it calls a coordinator method (`resolveStart`, `confirmCreate`,
    `completePendingCreate`, `planTask`). This is what lets one behavior carry several entry points
    without the decision being written once per door. Start Now **writes nothing**: `resolveStart`
    returns a `StartPrefill` carrying the branch — `task.worktree` if set, else `deriveBranchName` —
    and `ContentView` presents it as the Start Task sheet, which is `CreateWorktreeSheet` with a
    prefill rather than a second sheet; a task whose branch already has a live worktree is focused
    with no sheet. The frontmatter write is the sheet's Create button: `confirmCreate` writes
    `status = in_progress` and `worktree = <branch as confirmed>`, so a cancelled sheet leaves the
    task on its backlog marker and the branch recorded is the one the operator confirmed. It
    also records `pendingCreate`, which carries the agent command to run once the worktree is live
    and a `TaskLink?` — **one** optional, not a task id beside an optional prior-fields snapshot,
    so a link `abandonPendingCreate` cannot unwind is unrepresentable. It is `nil` for a hand-made
    worktree, which goes through the same call, and also when `updateFields` refuses because the
    task's file vanished between Start Now and Create: the worktree the operator confirmed is still
    created, but nothing was written, so there is nothing to unwind and nothing to relocate. The
    slot is `private(set)`; `confirmCreate` is the only thing that can build a well-formed record.
    `ContentView`'s single `onChange(of: lastCreatedBranch)` handler then runs, in order:
    `completePendingCreate` (relocate `TASK.md`, return its command with `{{ task_path }}` resolved
    to the relocated file), the shadow task, the creation mark — which **carries that command** —
    the selection, and the afterCreate hook. The handler launches nothing itself: the command rides
    the mark into `TerminalManager.pane(for:)` and becomes the worktree's **first** tab, in place of
    the Settings → Main Terminal tab a created worktree otherwise opens. Running it from the handler
    instead opened both, since `markWorktreeCreated` had already claimed the first tab for the Main
    Terminal agent. Relocation still precedes the launch — the mark is read only when the pane is
    built, which cannot happen before the handler reaches `markWorktreeCreated`. Nothing has ever
    awaited the hook, and nothing does now. That handler clears `lastCreatedBranch` **before** its worktree lookup, not after: the
    signal is an edge, and one left standing through a silent failure makes a retry that assigns
    the same branch not a change, so the create that did succeed would never be handled at all.
    The path `completePendingCreate` substitutes comes from `relocateTaskToWorktree` **returning
    that it landed**, never from the destination being where the file was meant to go — the
    relocation refuses a worktree that already carries a `TASK.md`, which a branch can, since
    `.clearway` is committed, and naming the destination regardless handed the agent a different
    task's brief. `WorkTaskListView` offers both doors as **one** control labelled "Start Now": its primary
    action opens the Start Task sheet, its items plan the task with one of the project's agent-kind
    saved commands. There is no remembered pick — the plan slot that once drove the primary action
    was retired with it, so `command-defaults.json` carries the after-create id alone.
    Its menu (`startNowItems`) lists the agent commands first and always **ends with
    "Add Agent Command…"**, which presents `CommandEditorSheet(command: nil, newCommandKind: .agent)`
    — the `newCommandKind` parameter exists for this one call. That item is unconditional: a project
    with none saved yet would otherwise open an empty menu, which AppKit draws as nothing happening
    at all. The `Divider()` above it is gated on the list being non-empty so it never leads the menu.
    The command items are **omitted**, never rendered `.disabled`, when there is no task or
    `ghosttyApp.readiness != .ready`: a macOS toolbar menu updates an existing `NSMenuItem`'s
    enabled flag unreliably, and a menu first built with nothing selected kept its commands greyed
    out after a task was selected, while the unconditional editor door beside them stayed live.
    Changing the item set changes the content's structural identity, which rebuilds the menu.
    The terminal half of that gate is `readiness` and not `ghosttyApp.app` for the same reason the
    sibling toolbar buttons use it: `app` is a computed property over `appHandle` with no
    `@Published` change to re-evaluate against. `app` stays the guard inside `plan`, where the
    launch actually needs the pointer.
    That is also why the toolbar control carries **no `.disabled`**: it would take the chevron with
    it and put the editor out of reach, so the unstartable case is guarded inside the primary
    action instead, against `startableTask`. It is the one knowingly click-and-nothing-happens
    control in the app.
    On the toolbar it is a split button in its **own** `ToolbarGroupBreak` capsule, between the `+`
    and the copy/terminal/`…` group; in the row context menu it cannot be a split button, because
    an AppKit menu item carrying a submenu has no body to click — SwiftUI's `Menu` documents the
    primary action as firing "when the user taps or clicks on the body of the control" — so there
    the same action is the submenu's first item, ahead of the shared `startNowItems`. Either way
    `plan` selects the task first: the terminal a plan opens is the one `TaskDetailView` renders
    for the selection.
    Plan (`planTask`, in `WorkTaskCoordinator+TaskTerminal.swift`) runs the chosen command in the
    **task's own bottom terminal**, working directory `planWorkingDirectory` — the `isMain`
    worktree, where a backlog task's file still lives, falling back to `projectPath` for the window
    before the first `git worktree list` returns. It writes nothing at all: no status, no branch
    link, no relocation. It must not go back to `TerminalManager.run`: that appends a tab to the
    primary worktree's pane, and the Tasks destination renders no pane, so the agent ran where
    nobody could see it and Plan read as a dead button. `autoRun` still decides submit-or-stage,
    but nothing holds a staged draft, so staging opens a login shell and leaves
    `buildAgentPromptLine`'s invocation on its prompt line for the operator to send, through
    `TerminalManager.stagedText` like every other staged delivery. Either branch refuses on a
    prompt file that could not be written, and refuses **before** opening the surface:
    `openTaskTerminal` closes the task's current one to open the new one, so a downgraded launch
    would take away what was already running there.
    **Clearway launches no agent of its own**, and nothing advances the status afterwards — every
    agent either path starts is a command the user saved and picked. `status` is frontmatter
    Clearway writes and round-trips but **never renders** — there is no badge and no label table, so
    an unrecognized slug needs no handling beyond being carried through untouched.
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
    list too long" — typical agent prompts sit well under that. It returns **`nil`** when the prompt
    file cannot be written: the recipe's `$(cat)` over a missing file would seed the agent with an
    empty prompt, so the caller refuses the launch instead. `startAgentTab`'s `.argv` case ends its
    in-flight claim when it owns it, runs an `NSAlert` naming the command and the temp directory,
    and opens no tab. There is deliberately no fallback to a bare tab — silently downgrading "run
    this prompt" to "type it in for me" is the same defect as the empty start it replaces.
    `buildAgentPromptLine` is the same launch staged rather than run, for a surface that has to show
    the invocation instead: same temp file, but the line is `agent "$(cat 'file')"`, which `sendText` puts
    on an interactive prompt for the operator to press Enter on. There is no `$1` and no parameter
    expansion on this path — the command text is concatenated in as typed and the operator's own
    shell parses it as source, the same contract as `buildOpenInScript`; only the file path is
    escaped, because Clearway chose that one. It welds no `rm` onto that line — the file is the
    prompt the operator may re-run or edit, and removing it on first exit would take it away. It
    carries the same `nil` refusal, because an unwritten file empties the prompt the moment the
    operator presses Enter — both writers go through one `writeAgentPromptFile`, whose failure is
    the single source of that `nil`. The refusal reaches the plan launch through
    `presentPromptFileFailure`, internal rather than `private` so `TerminalManager+Commands.swift`
    can run the same alert.
    `CommandPlaceholders.substituted` resolves `{{ task_path }}` in a saved command's text **raw**,
    and that is a consequence of the above: the text becomes the prompt, the prompt reaches the
    agent as one argv element read out of the temp file, and no shell ever parses it — so a path
    with spaces or metacharacters arrives intact and quoting it would deliver the quotes. This is
    the opposite of `WorktreeHooks.interpolated`, whose placeholders do land in a shell line and are
    escaped. A `nil` path leaves the token verbatim rather than blanking it: a command that names no
    task has nothing to say about one, and an empty argument reads as a malformed path.
  - `TerminalManager.appendTab` is the one door every main tab goes through: it builds the
    `Ghostty.SurfaceView` with its command up front, appends, activates and focuses. No tab is ever
    an intermediate screen — ⌘T and the `+` menu's New Terminal row pass no command and get a login
    shell; ⌥⌘T, the `+` menu's agent rows and the first tab of a worktree Clearway itself just
    created pass an agent command built by
    `buildBareCommand` (`TerminalManager+Agent.swift`).
    A worktree's first tab is chosen once, by `TerminalManager.firstTabSource(afterCreateCommand:mainCommand:)`,
    which `takeFirstTabSource` consumes the creation mark to reach when `pane(for:)` builds the
    pane: the create sheet's "Run after create" pick wins and goes through `run`, else the Main
    Terminal command opens an agent tab, else a login shell. A pick **replaces** the Main Terminal
    tab rather than adding one — two agents on a fresh worktree is the bug the rule exists to
    prevent — and the rule is `static`, so the truth table is testable without a `ghostty_app_t`.
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
    The staged case (`submit` off) goes through `stagedText` + **`sendText`**, the one staging rule,
    shared with `sendToActiveMainTab(asCommand: false)` — the Prompts aside's play button, which
    often targets a plain shell, so the rule lives beside it in `TerminalManager.swift` rather than
    in this agent-only extension. Neither uses `sendPaste`, which appends Enter and would run the
    prompt staging exists to leave unrun.
    The trim `stagedText` does is load-bearing, not cosmetic: outside bracketed paste libghostty
    rewrites every `\n` to `\r` (`ghostty/src/input/paste.zig`), so an untrimmed trailing newline is
    itself an Enter. Trimming the ends is the **whole** guarantee — an interior newline still
    arrives as an Enter on a target without bracketed paste, as it did under `sendPaste`, and
    closing that needs a bracketed-paste query the C API does not expose. `sendPaste` survives only
    for `TerminalManager+Panels.swift`'s hook command, where Enter is wanted; no prompt-delivery
    path names it.
    `promptDelivery`, `stagedText` and `proceedsWithLaunch` are `static` so all three rules are
    testable without a `ghostty_app_t`.
  - Running a saved command is `TerminalManager.run` (`TerminalManager+Commands.swift`), not the
    `RunCommandMenu` view: the view resolves no worktree and awaits nothing, so the shell-readiness
    wait and the shell-vs-agent branch live on the coordinator with the rest of the tab logic.
    The Enter placement a terminal command needs is `ShellSend.steps`, not a surface method —
    nothing on `Ghostty.SurfaceView` is reachable from XCTest, and staging rather than running the
    last line is the rule most worth pinning.
  - `SavedCommandStore.swift` owns `<projectPath>/.clearway/commands.json`, one saved-command list
    per project, shared by every worktree of that repo. The store takes the project path and owns the
    `.clearway` component itself, and the list is always
    read from the project root rather than the selected worktree — a `commands.json` checked out differently on
    a branch must not change what the Run dropdown shows. Array order **is** display order — nothing
    sorts it, and a reorder rewrites the file. There is deliberately no watcher: `SavedCommandManager`
    is a `@StateObject` on `ProjectContentView`, built from `projectPath`, and reads the file once —
    an edit made outside the app, in a text editor or by `git pull`, is picked up when the window
    reopens.
    The file is a `SavedCommandsPayload` document — `{"commands":[…],"lastRunId":"…"}` — not a bare
    array. `load()` tries the payload first, a bare `[SavedCommand]` array second, and only then
    moves the file aside to `commands.json.corrupt`. That legacy branch is **required**, not a
    courtesy: `load()` treats anything it cannot decode as corruption, so without it every file
    written before the payload would have its list renamed away and logged as corrupt. The same
    asymmetry runs the other way and is not fixable from here: an **older build** decodes only a
    bare array, so rolling Clearway back renames every project's list to `.corrupt`. It is
    recoverable by hand, which is the whole reason `load()` moves a file aside instead of
    overwriting it.
    The payload's `init(from:)` decodes `commands` strictly and `lastRunId` leniently: absence and
    an unparseable id both read as nothing remembered, because throwing on the one field the user
    never asked for would send a list of working commands down that corrupt path over a preference
    whose loss costs nothing. The memberwise init deliberately carries no defaults — a field added
    later is then a compile error at `save()` rather than a silent erase. When a document decodes as
    neither shape, the warning carries **both** errors: a bare array fails the payload decode at the
    top level with nothing but "found an array instead", so on a legacy-shaped file it is the second
    one that names the offending key and index, which is what makes the file hand-repairable.
    `SavedCommandManager.lastRunCommand` resolves the id against the live list on every read, so an
    id naming a deleted command reads as nothing remembered. No delete path cleans it up, and none
    should. `primaryCommand` is that value or `commands.first` — what the Run button's label half
    runs, resolved on the manager so it is unit-tested rather than decided in the view.
    `runButtonTitle` (`primaryCommand?.name ?? "Run"`) and `menuCommands` (`commands` minus the
    primary) live beside it for the same reason: the label names what a click will do and the
    dropdown omits it, and both rules are pinned by `SavedCommandManagerTests` rather than read out
    of a SwiftUI body.
    Beside it the same store owns `command-defaults.json`, one optional command id: the Start Task
    sheet's "Run after create" slot. A `plan` key shipped there briefly and was retired with the
    Plan menu; a file still carrying it decodes fine, since an unknown key is ignored. Both files
    go through one `write` on the store and one `enqueue` chain on the manager, so a defaults write
    and a commands write cannot reach the queue out of order. The id is only ever read through
    `CommandDefaults.resolve`, which answers for a **live `.agent`-kind** command and nothing else:
    an id naming a deleted command, or one retyped to terminal, shows None and is **not** rewritten
    away, and a missing or undecodable file reads as unset and is left exactly where it is — losing
    an id the user cannot repair by hand costs one re-pick, which beats quarantining a file. Keeping
    it is `setAfterCreateDefault`'s job, not the sheet's: **clearing the slot is refused while it
    resolves to nothing**, because the picker is seeded from `afterCreateCommand` and so an
    untouched picker on a stale id is indistinguishable from the operator choosing None — without
    that guard the next successful create wrote the id away, which is the opposite of the sentence
    above. Clearing a slot that does resolve is a real pick and goes through. The after-create slot
    is written back only on the `.apply` branch of the sheet's outcome, so a cancelled or failed
    create changes no default. No watcher, for the same reason `commands.json` has none.
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
  - `AgentHookEvent.swift` / `AgentHookScript.swift` / `AgentHookSettings.swift` /
    `AgentHookInstaller.swift` / `AgentActivityStore.swift` / `AgentActivityMonitor.swift` — the
    agent-activity pipeline: the wire model, the forwarder text and `AgentHookPaths`, the pure
    settings merge, the disk half, the state machine, and the one process-wide owner. The first five
    are `import Foundation` only, which is what makes every rule below reachable from XCTest; the
    monitor does socket plumbing and publishing and decides nothing.
    **The transport is a `SOCK_STREAM` Unix socket at `~/.clearway/hook.sock`**, one connection per
    hook invocation, read to EOF. Not a port: the app would need no entitlement either way, but a
    port can collide, can be reached from off the machine, and has no `0700` directory standing in
    for access control — which is the whole of it here, since the app is unsandboxed and binds under
    `$HOME`. `bind` unlinks a stale path first, or one crash leaves an inode that makes every later
    launch fail `EADDRINUSE` and no dot ever lights again.
    **The forwarder is `/usr/bin/nc -U -w 1`, absolute, and never carries `-N`.** macOS reads `-N` as
    a probe count, not OpenBSD's shutdown flag, so a script using it fails on every hook with no
    diagnostic; `nc` already shuts the write side on stdin EOF, which is what lets the server read to
    EOF. `curl` would need a URL and an HTTP server for a payload that is already framed. A shadowed
    `nc` on `PATH` is why the path is absolute.
    **Framing is two preamble lines — surface id, worktree id — then the agent's raw JSON to EOF.**
    `AgentHookEnvelope.parse` takes the first two newlines off the byte buffer and hands the
    untouched remainder to `JSONDecoder`. Never split the payload on every newline: agents send the
    body pretty-printed, so that truncates it to `{` and the event vanishes with no trace. The
    script's three guards — surface id, worktree id, a socket that exists — are what make a `claude`
    started in Terminal.app, the hook sheet and the debug terminal cost nothing, and it always
    `exit 0`s, because a non-zero hook can block or deny a tool call and Clearway decides nothing.
    **Two ids, not one.** The surface id does not survive a relaunch; the worktree id is the path and
    does. An agent still running after Clearway restarts arrives with a surface id this process never
    minted and still lights its worktree's dot and draws its subagent rows.
    **The managed block is reconciled by content, not versioned.** Recognition is `type == "command"`
    plus containment of `/.clearway/hooks/clearway-hook.sh` — never equality with the command string,
    or a user's hand-edit and an older spelling of the same path both leave a live hook forwarding to
    a socket nobody listens on. There is no marker key to go stale. The entry carries **no**
    `matcher`: omitted matches everything, and `"*"` is not a valid regex. Writing is gated on the
    re-serialised document differing, not on the bytes: the merge re-emits the file `.prettyPrinted`
    and `.sortedKeys`, so a byte comparison rewrites every user's `settings.json` on a toggle that
    changed nothing. `uninstall` collapses only the containers it emptied, so it is an identity on a
    file that never carried the block, and it leaves the script on disk — with nothing listening its
    own first guard makes it inert.
    **One backup, `settings.json.clearway-backup`, taken before the first modification and never
    refreshed** — it is the user's only copy of the file as they wrote it, so a second modification
    that overwrote it would destroy exactly what it exists to keep. A backup that cannot be taken
    cancels the write: the merge is acceptable *because* of the backup. An unparseable file is logged
    and left alone, never quarantined or renamed.
    **Both agents are gated on their config directory already existing.** Clearway writes
    `~/.claude/settings.json` and `~/.codex/hooks.json` and creates neither directory: an absent one
    means that agent was never run here. Codex additionally does nothing until the user runs `/hooks`
    to trust the entries, which no API can pre-empt, so the Settings toggle carries one line naming
    that step — the deliberate exception to the no-helper-text rule above.
    **Nothing in the pipeline has a clock.** No timer, no expiry, no mtime heuristic: a surface
    leaves a state only because an event said so. A `SIGKILL`ed session therefore pins a dot until
    its next `SessionStart`, which is accepted — the expiring heuristic this replaced guessed wrong
    in both directions. `publish()` is change-gated because `PreToolUse`/`PostToolUse` fire around
    every tool call and assigning an unchanged value to a `@Published` still re-renders every
    observer.
    **One owner**: a `@StateObject` on `ClearwayApp`, injected on the project `WindowGroup` only, so
    a standalone Task or Prompt window reaching for it would fault. Surface retirement is
    `TerminalManager.retireSurface`, the same process-scoped static provider shape as
    `claimsShortcut`, reported from every door that drops a surface — never reconciled against a list
    of live ones. `AgentHookPaths(home:)` and `install(home:)` exist so the suite can drive the whole
    feature, forwarder and socket included, under a temp root; every call site outside the tests
    takes the default.
    **The dot is `waiting > working > idle`** over every surface carrying the worktree id, where
    working also means holding a live subagent — a lead between turns while subagents run must not go
    dark. Waiting on a permission prompt is a static 7 pt purple dot: orange is working, blue the
    plain-shell notification, red failure, green success and yellow a status badge, so purple is the
    only hue left, and not pulsing separates it by shape as well. `isMain` no longer suppresses the
    dot; `isOpen` still gates it, and the subagent rows with it, since a closed worktree's surfaces
    are already retired.
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
    Unlike `RunCommandMenu`, which stays visible whatever its list holds, the toolbar item
    disappears: an empty list is a configuration the user chose, not a momentarily unavailable
    action. The sidebar passes
    the right-clicked worktree's path, not the selection's. Both toolbar items are **text** labels
    with the system chevron and no `.help()` tooltip, and each names its own primary action rather
    than its category: Open in reads `"Open in \(app.label)"` — "Open in Cursor" — from
    `SettingsManager.openInButtonTitle`, and Run reads the primary command's name from
    `SavedCommandManager.runButtonTitle`. They are split buttons, so the label half acts on a click
    and has to say what that click will do; the remaining toolbar items act on a click too and stay
    icon-only, named by their symbol. The generic word survives only where nothing resolves: Run
    reads "Run" on an empty list. **Neither label is passed in.** `OpenInMenu` takes no label at all
    — the split-button variant renders `openInButtonTitle` and the submenu variant the constant
    lowercase `Text("Open in")`, the way Reveal in Finder reads, since a submenu has no primary to
    name. A label handed in from the call site could name an app that is not the one the label half
    opens, which is what `ContentView` was doing.
    The chevron's list **omits the primary** on both toolbar buttons (`menuCommands`,
    `menuOpenInApps`), since the label half already runs it; the sidebar submenu lists `openInApps`
    whole. Both toolbar lists therefore end with an unconditional door, separated by a `Divider()`
    only when there are items above it — without it a one-item list would draw an empty menu, which
    AppKit renders as a click that does nothing. Run's door is "Add Command…", presenting the same
    `CommandEditorSheet(command: nil)` the Commands view's `+` opens; the sheet hangs off
    `RunCommandMenu`'s own body, **outside** the `.disabled(…)` so the editor's controls never
    inherit a disabled environment, rather than off `ContentView`, whose `file_length` budget is
    spent. Open in's door is "Edit Apps…", opening the Settings window where this list is edited:
    `SettingsLink` under `#available(macOS 14, *)` — both it and `@Environment(\.openSettings)` are
    macOS 14.0+ against a 13.0 target — falling back to
    `NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)`. Nothing selects a
    section on arrival: `SettingsView` is one `Form`, not a `TabView`. The sidebar's submenu carries
    neither door.
    A split button is `Menu(content:label:primaryAction:)`, declared **unconditionally against the
    state**: both draw as split buttons whenever their list is non-empty, including before anything
    has been picked, because the primary action falls back to the first item in display order. That
    resolution is `SavedCommandManager.primaryCommand` and `SettingsManager.primaryOpenInApp` — the
    remembered item or the list's first — so it is unit-tested off the view, and the `primaryAction:`
    closure only unwraps it. It unwraps it **inside the closure**, on the click, never as a value the
    branch's `if let` bound for it: the realized control keeps whatever its actions captured (see the
    `.id` rule below), and Run's key omits the primary, so editing the primary command's text rebuilt
    nothing and the label half went on running the old text (operator change C5). `RunCommandMenu`
    therefore reads `savedCommandManager.primaryCommand` in the action and branches on that same
    value only to choose the declaration; `OpenInMenu` reads `settings.primaryOpenInApp` in the
    action but branches on `remembersLastUsed` (below), never on the resolved app.
    Do not go back to declaring the `Menu` twice on whether something was
    **picked**: that drew a plain dropdown in the fresh state, which is what this replaced. Both
    record the pick rather than a successful launch — `RunCommandMenu.run(_:)` records before its
    `ghosttyApp.app` guard — or an app or command that fails to launch could never become the
    primary action again.
    **A split button in a toolbar keeps the dropdown it was built with**, so each one carries
    `.id(<its own dropdown's contents>)` — `.id(settings.menuOpenInApps)` on `OpenInMenu`,
    `.id(savedCommandManager.menuCommands)` on `RunCommandMenu`. SwiftUI realizes a toolbar `Menu`
    that carries a `primaryAction:` as an `NSSegmentedControl` whose `NSMenu` is filled once, when
    the control is built, and never refilled: later renders update the label segment and leave the
    menu items — and the values their actions captured — as they were. A plain `Menu` has no such
    problem, because it is an `NSPopUpButton` whose menu starts empty and is filled by its
    coordinator each time it opens, which is why the sidebar's submenu and Run's empty-list menu
    need no key. Keying the view on what the dropdown draws is what rebuilds the control. Do not
    narrow the key to the items' labels: an edit that changes only a command would then leave the
    old one behind the same title. Without this, adding an app in Settings → Open In left the
    toolbar's dropdown showing the list from launch (operator change C4).
    Each view does still declare its `Menu` twice, on a condition that cannot change while the menu
    is open, and neither is the one above. `OpenInMenu` switches on `remembersLastUsed`: the
    sidebar's context submenu is not a split button, and a `primaryAction:` on a submenu row would
    give it a click the sidebar has nothing to do with. `RunCommandMenu` switches on whether the
    project has any saved command at all — with none there is nothing for a label half to run, so it
    is a plain menu reading "Run" over the "Add Command…" door alone, and it is `.disabled` only on
    `ghosttyApp.app == nil`. Disabling it on an empty list instead, as it once did, put the only door
    to a first command out of reach of exactly the user who has none.
    Open in's memory is `SettingsManager.lastUsedOpenInAppId`, a `UserDefaults` string under
    `clearway.lastUsedOpenInApp` beside the list itself, because the list it names is a global
    preference rather than per-project the way Run's `lastRunId` is. `lastUsedOpenInApp` resolves it
    against `openInApps` on every read, so a deleted app falls back to the first in the list with
    nothing cleaned up. Both ids are `private(set)` with one writer each — `recordOpenInUse` and
    `recordLastRun` — so the no-op guard those two carry cannot be stepped around by assigning the
    property, which on an app-wide `EnvironmentObject` would re-evaluate every view observing
    settings for no change. Only the toolbar remembers: `OpenInMenu` takes `remembersLastUsed`,
    defaulting to off, and `ContentView`'s call is the one that passes true — picking from the
    sidebar's submenu neither reads nor writes it. The menu and the settings section are
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

The test host launches the app, so on a developer machine **every** `ci.sh` run installs the agent
hook block into the real `~/.claude/settings.json` — the toggle defaults on — and takes the one-time
`settings.json.clearway-backup` beside it. That is the feature, not a test artefact. GitHub's runner
has no `~/.claude`, and the installer's directory gate makes it a no-op there.

### Merge model

The pipeline never merges; the operator merges by hand once CI is green. Squash and rebase merges
are allowed, merge commits disabled, branch deletion on merge on. Auto-merge is disabled at the repo
level, so there is no command to enable it. The `Main` ruleset blocks only deletion and
non-fast-forward pushes — GitHub requires no status check, so `.github/workflows/ci.yml` (jobs
`SwiftLint`, `Build & Test`) gates by convention, not enforcement.

`ci.sh` does not itself refuse on a dirty tree, so before any CI stamp or sign-off run
`git status --porcelain` and report untracked/ignored files; they block sign-off. Expect the
un-gitignored `default.profraw` noted above after any Debug launch.
