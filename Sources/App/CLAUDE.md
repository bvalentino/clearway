# Sources/App

- `AppKeyboardShortcuts.swift` — the combos the app claims from focused terminal surfaces, plus the
  layout-independent key codes its `NSEvent` monitor matches on. Add a shortcut here in the same
  change that declares it — declaration sites are `ContentView`'s hidden buttons and `NSEvent`
  monitor, `ClearwayApp`'s menu commands together with the two files holding their rows,
  `PanelCommands.swift` and `WorktreeCommands.swift` (the view hierarchy is offered a key
  equivalent before the main menu, so menu shortcuts need an entry too), and the tab strip's `+`
  menu rows.
  Those rows declare ⌘T and ⌥⌘T a **second** time on purpose: `.keyboardShortcut` is the only way
  SwiftUI renders the glyph beside a menu row. Unlike the `PanelCommands.swift` case below, the
  duplicate is harmless — both declarations run the same action on the same worktree, so whichever
  layer wins is correct. Claim **exactly** what the app
  handles: a claimed combo no handler answers is taken from the shell and then dropped.
  A shortcut Clearway itself retires gets a not-claimed pin in `AppKeyboardShortcutsTests`
  (⌘⌃2, ⌘⌃3, ⌘⇧T); a SwiftUI default dropped as collateral does not (⌃⌘S). The pins cover keys the
  app once owned, not every combo it declines. The Ctrl+digit claim therefore spans `"1"…"3"` —
  the sidebar's three destinations.
  The Worktree menu's four keys — ⌘R, ⌥⌘R, ⌘O, ⌥⌘O — are all claimed. ⌥⌘O was pinned as declined
  until "Open in…" was added on 2026-09-21; a neighbouring-modifier pin that flips like that is
  flipped in the same change as the declaration, never left disagreeing with the table. ⌃⌘R, ⇧⌘R,
  ⌃⌘O and ⇧⌘O stay pinned declined: nothing declares any of them, and a letter claimed under one
  modifier set gets its neighbouring sets pinned the way ⌘B's four variants are — the guard against
  a later feature folding `letter == "o"` into the `[.command, .shift]` case beside New Group.
- `PanelCommands.swift` — the View menu's three panel toggles: sidebar ⌘B, bottom panel ⌘J,
  aside ⌥⌘B, each a `PanelToggle` (`isVisible` + `toggle`) that `ContentView` publishes as a
  focused **scene** value. A `nil` value greys the item out, which is also how all three grey out
  on a standalone Task/Prompt/Settings window. Each key is declared **only** on its menu item —
  a hidden `.keyboardShortcut` button would declare it a second time, in a layer that silently
  wins. The rule is not local to this file: the Worktree menu's ⌘R, ⌥⌘R, ⌘O and ⌥⌘O are declared on its
  rows and nowhere else, and in particular not on the toolbar's Run and Open In buttons, which are
  what those rows act on. The tab strip's ⌘T / ⌥⌘T rows are the one deliberate second declaration,
  and only because both run the same action.
  ⌘⌃3 (aside) and ⌃⌘S (sidebar) were retired here with no alias.
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
- `WorktreeCommands.swift` / `ToolbarSplitButtonMenu.swift` — the Worktree menu, which `ClearwayApp`
  declares as one `CommandMenu("Worktree")` holding six rows in this order: "Run \<name>" ⌘R,
  "Run…" ⌥⌘R, a Run submenu, "Open in \<app>" ⌘O, "Open in…" ⌥⌘O, an Open in submenu. Each row is
  its own small `View` in `WorktreeCommands.swift`, which is also where all four keys are declared
  and the only place they are.
  **Six rows and not four**, because neither ⌥⌘R nor ⌥⌘O can live on the submenu it pops: AppKit's
  key-equivalent dispatch fires a menu item's action, and a SwiftUI `Menu` used as a submenu row has
  none — the same no-body rule the Plan split button hits in the sidebar's context menu. So "Run…"
  and "Open in…" are real rows with real actions, and the submenus below them carry no key.
  Like the panel toggles above, the rows reach per-window state through focused **scene** values
  and a `nil` greys the row out. There are two values, not one, because they gate on different
  preconditions: `WorktreeRunActions` is nil with no selected worktree or no `ghosttyApp.app`,
  `WorktreeOpenInActions` with no worktree path or no `primaryOpenInApp`, which resolves for every
  non-empty list — each gate mirroring its toolbar counterpart's. That is also why its `primary` is
  **not** optional while Run's is: an Open in row that exists has an app to open, so there is no
  unreachable `guard` behind an enabled row, and the two `.disabled` spellings state the gate
  difference instead of hiding it. Both carry the **whole** list (`commands`, `apps`), not the
  toolbar's `menuCommands` / `menuOpenInApps`: the toolbar omits the primary because its label half
  runs it, and the menu bar has no label half. **Each primary row writes its own title** rather than
  reusing the toolbar's: `runButtonTitle` is the bare command name, which is what a label half
  wants and what a menu row cannot be, so the row renders `"Run \(name)"` and keeps the bare "Run"
  for the empty list. `openInButtonTitle` already carries its verb, but the row builds the same
  string off `primary` for symmetry, so neither struct holds a title that could disagree with the
  app or command beside it. "Run \<name>" is the one row gated on `primary` rather than
  on the value itself, so an empty command list greys it while "Run…" and the Run submenu stay
  live and keep the "Add Command…" door reachable; all three Open in rows grey together, since their
  value is already nil on an empty app list — and an empty list draws no toolbar button, so "Open
  in…" would have no dropdown to pop anyway.
  `WorktreeRunActions.runner` and `WorktreeOpenInActions.opener` are the **one** implementation of
  each action, shared with `RunCommandMenu` and `OpenInMenu`, so record-then-launch and the Open In
  failure alert exist once in the tree.
  The submenu's "Add Command…" sets `ContentView`'s `showCommandEditor`, the same `@State` the Run
  dropdown's own door sets — `RunCommandMenu` takes it as a `@Binding` and stays the one presenter
  of `CommandEditorSheet` in a project window. Owning the flag one level up is what keeps this
  per-window: a broadcast `Notification` would reach every open window's menu and need an `===`
  identity guard to undo that (the `.clearwayNewGroup` shape in `SidebarView`), and
  `@FocusedObject` reads nil because nothing in the tree calls `.focusedObject(_:)`.
  **⌥⌘R and ⌥⌘O pop the toolbar's own dropdowns through AppKit** rather than drawing a second list
  that could drift from them. SwiftUI cannot present a `Menu` programmatically, so
  `ToolbarSplitButtonMenu.popUp(labelled:)` walks the view tree depth first for an
  `NSSegmentedControl` whose segment 0 label equals the one it was given and pops its
  `menu(forSegment: 1)` below the control. The label is the **only** thing separating the two
  buttons, so each closure reads its own title inside the closure — `runButtonTitle` for ⌥⌘R,
  `openInButtonTitle` for ⌥⌘O — and tracks the primary rather than capturing a stale name.
  **Both labels are user text, so the walk collects every match and pops nothing unless exactly
  one control answers.** `runButtonTitle` is a saved command's name verbatim, so a command named
  "Open in Fork" carries the Open In button's own label and matched the Run button first — ⌥⌘O
  then opened the Run dropdown, and the operator picking what they read as an app ran a shell
  command instead. An ambiguous label is now a non-match like any other, which is the rule the
  paragraph below states rather than an exception to it.
  **It looks for two controls, not one**, because the Run button is not always a split button: with
  no saved commands `RunCommandMenu` drops the `primaryAction:` and SwiftUI realizes the `Menu` as
  a `SwiftUIPopupButton` (an `NSPopUpButton`, `pullsDown = true`) whose `title` is the `Menu`'s own
  label — the same string segment 0 would have carried. So one depth-first walk collects both
  shapes, as a `Match` carrying either control, and a matched pop-up is opened with
  `performClick(nil)`. Not `popUp(positioning:)`: a plain `Menu`'s `NSMenu` is **empty** until
  SwiftUI's coordinator fills it on open (the split-button note further down), so there is nothing
  to position, and `performClick` is what runs the coordinator. Without this branch ⌥⌘R was a
  silent no-op in exactly the state its row exists for — the one holding "Add Command…" alone.
  All of this is measured, not assumed: a SwiftUI probe declaring both shapes as toolbar items
  printed `SwiftUIPopupButton POPUP title="Run" pullsDown=true items=[] menuItems=[]` for the plain
  `Menu` and `SwiftUISegmentedControl SEG count=2 labels=["Open in Fork", nil]` for the one with a
  `primaryAction:`, and `performClick(nil)` on the pop-up posted
  `NSPopUpButton.willPopUpNotification`.
  **The walk starts at `NSApp.keyWindow?.toolbar?.visibleItems`, at each item's `view`, and not at
  `contentView`.** A toolbar item's view is no descendant of the content view: the realized chain is
  `SwiftUISegmentedControl` ← `AppKitPlatformViewHost` ← `ToolbarItemHostingView` ←
  `NSToolbarItemViewer` ← `NSToolbarView` ← `NSTitlebarView` ← `NSTitlebarContainerView` ←
  `NSThemeFrame`, a branch beside `contentView` rather than below it, so a walk rooted at
  `contentView` finds nothing and ⌥⌘R silently does nothing — which is exactly what it did when it
  first shipped. Rooting the walk in the toolbar does **not** put `CommandsView`'s segmented filter
  picker out of the search space — that picker is a `ToolbarItem` too (the toolbar-on-the-detail-
  column rule below), so it realizes beside the Run and Open In controls and the toolbar holds
  three segmented shapes, not two. What keeps it from ever being popped is the segment 0 label
  match plus the rows being disabled on the Commands destination, where `detailSelection.worktree`
  is nil and both focused values with it — a runtime gate, not construction. Segment 0 of that
  picker reads "All", so a primary command named `All` would match it, and the one-match rule below
  is what makes that a no-op rather than a wrong pop. `segmentCount > 1` is
  checked before either segment is read, because `NSSegmentedControl` raises on an out-of-range
  index. An item scrolled into the toolbar's overflow menu is absent from `visibleItems` and has no
  on-screen control to hang a menu under, so it is a non-match like any other. When nothing matches
  — or when more than one control does — it **does nothing** and logs one line naming the label and
  the match count, because the key is claimed and so the press leaves no other trace: falling back
  to another control would open a dropdown the operator did not ask for. This is knowingly fragile.
  It holds only while SwiftUI keeps realizing a toolbar `Menu` with
  a `primaryAction:` as an `NSSegmentedControl` with a readable segment label, and one without as
  an `NSPopUpButton` with a readable title — the split-button note further down — and the operator
  took that over a fallback behaviour. If ⌥⌘R or ⌥⌘O ever stops opening anything, this is where to
  look.
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
- **A picker that has to fill its column goes through `FullWidthPicker`**
  (`Sources/App/FullWidthPicker.swift`). A SwiftUI `Picker` clamps to the AppKit intrinsic width
  of the `NSPopUpButton` it wraps — 80pt for these lists — and `.frame(maxWidth: .infinity)`
  **centers** that 80pt control rather than stretching it, so the create sheet's fixed-width
  column cannot be filled with one; `Form`, an exact `.frame(width:)` and frames on the option
  rows all measure 80pt too. The wrapper is an `NSViewRepresentable` whose `sizeThatFits` adopts
  the proposed width, and it is generic over the selection with rows carrying a title and an
  optional tinted SF Symbol, so the Status and after-create pickers cannot drift. Three of its
  lines are load-bearing and read as removable: the menu is rebuilt **only** when `rows` changes,
  or an open menu closes on every keystroke elsewhere in the sheet; `menu.autoenablesItems =
  false`, because items carrying no action of their own are validated against the responder chain
  and the whole list greys out; and `isTemplate = false` on the configured symbol, or AppKit
  recolors it to the menu's own text color and the status tint is lost. An `NSMenu` cannot host a
  SwiftUI view, which is why the rows are built from `WorktreeStatus`'s `displayName` / `symbol` /
  `color` rather than from `WorktreeStatusLabel` — the sidebar's Status submenu is that view's one
  remaining renderer.
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
  The terminal half of that gate is `readiness` and not `ghosttyApp.app`: `readiness` is
  `@Published`, while `app` is a computed property over `appHandle` with no
  `@Published` change to re-evaluate against. `app` stays the guard inside `plan`, where the
  launch actually needs the pointer.
  That is also why the toolbar control carries **no `.disabled`**: it would take the chevron with
  it and put the editor out of reach, so the unstartable case is guarded inside the primary
  action instead, against `startableTask`. It is the one knowingly click-and-nothing-happens
  control in the app.
  On the toolbar it is a split button in its **own** `ToolbarGroupBreak` capsule, between the `+`
  and the copy/`…` group; in the row context menu it cannot be a split button, because
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
  pane: the create sheet's "Run agent command after create" pick wins and goes through `run`, else the Main
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
  view that offers it: neither `RunCommandMenu` nor the Worktree menu resolves a worktree or awaits
  anything — both call the one closure `WorktreeRunActions.runner` builds — so the shell-readiness
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
  sheet's "Run agent command after create" slot. A `plan` key shipped there briefly and was retired with the
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
  is written back only on the `.apply` branch of the sheet's outcome **and only by the Start Task
  variant**, so a cancelled or failed create changes no default and neither does a hand-made
  worktree. Which variant is in front of the operator is `CreateWorktreeSheet.afterCreateSlot`,
  a pure static keyed on the sheet's own `startPrefill?.taskId`: `.hidden` for New Worktree, which
  draws no field, resolves no command and calls `setAfterCreateDefault` not at all, or
  `.offered(SavedCommand?)` for Start Task. It is an enum rather than a flag beside a command so
  a hidden slot carrying one cannot be built, which is what lets the `confirmCreate` call read
  `slot.command` without re-asking whether the field was drawn. The hidden case is not the
  manager's guard doing its job — the guard only refuses a clear while the stored id resolves to
  nothing, so a New Worktree sheet writing its untouched None back would clear a slot that does
  resolve, and the sheet is the only layer that knows a picker was never shown. A worktree created
  from the sidebar links no task, so there is no brief for a saved agent command to act on, and
  its first tab is the Main Terminal tab. No watcher, for the same reason `commands.json` has
  none.
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
  **`Stop` reduces the subagent roster to the background subagents it names, and never empties
  it.** A background `Agent` launch is exactly the case where the lead finishes its turn — and so
  fires `Stop` — while its subagents are still working, so the blind `removeAll` this replaced took
  both rows away a second after they appeared. `Stop` carries `background_tasks`, each entry an
  `id`, a `status`, its `agent_type` and a `description`; keeping the `running` ones is still the
  sweep a missed `SubagentStop` needs, and a `Stop` that names none clears the roster as before.
  Every event that carries an `agent_id` carries its `agent_type` beside it —
  `SubagentStart`/`Stop` and a subagent's own `PreToolUse` alike — so a row first seen through its
  tool traffic is named rather than left on `SubagentRow`'s fallback label. **`background_tasks`
  is the only payload carrying the prompt's own summary**, so `keepOnly` carries both the type and
  the description over from the row it already holds when the entry omits them: a later `Stop`
  must not blank what an earlier one named, and no other event can restore it. `SubagentRow` draws
  that summary beside the type on one line, the way Claude Code's own status line does, and that
  is the whole row. It is the **same `Label` over the same `SidebarIcon` slot** every sidebar row
  is built from, so its text starts on the worktree row's title column with no padding of its
  own; the slot carries `SidebarChildConnector`, the `└` a terminal draws before a child line,
  drawn as a `Path` because the character's shape belongs to the font. The status section headers
  are that same `Label` over that same slot for the same reason — `SidebarRowMetrics` is down to
  `iconWidth` and `headerLeadingInset`, the 6 pt a `Section` header is inset short of a row, and
  no header owns an icon-to-title gap of its own. **A subagent's in-flight tool is not recorded**: it had one reader, the second
  line of that row, so it went with it rather than staying as state nothing reads. `tool_name`
  still lands on `leadToolName`, which the tab chip renders, and the rule that keeps the two apart
  is the whole of `startTool`/`finishTool` — a subagent's tool traffic names its row and touches
  the lead's label never. **It does not touch the lead's `phase` either**, which is why those two
  methods carry the phase rather than the `apply` switch setting it first: `effectivePhase`
  already reads a non-empty roster as working, so a phase written from a subagent's event says
  nothing the roster was not already saying and outlives the row that justified it. A background
  subagent runs on past the lead's `Stop`, so its `PreToolUse` pinned an idle lead at working and
  its `SubagentStop` then took the roster away and left the dot lit with nothing running and no
  event left to clear it — the stale dot this whole change exists to retire. The same write took
  the lead off a `PermissionRequest`, which is the one state that needs the user.
  **Nothing in the pipeline has a clock.** No timer, no expiry, no mtime heuristic: a surface
  leaves a state only because an event said so. A `SIGKILL`ed session therefore pins a dot until
  its next `SessionStart`, which is accepted — the expiring heuristic this replaced guessed wrong
  in both directions. `publish()` is change-gated because `PreToolUse`/`PostToolUse` fire around
  every tool call and assigning an unchanged value to a `@Published` still re-renders every
  observer.
  **The monitor publishes two values, not three.** `worktreePhases` and `worktreeSubagents` are
  `@Published` on it and the sidebar observes them; the tab chip's tool label is
  `AgentActivityMonitor.ToolNames`, a nested `ObservableObject` the monitor holds as a plain `let`
  and `ClearwayApp` injects beside it. Change gating is not enough on its own here: a tool name
  changes twice per tool call while the sidebar's two values change about once a turn, so on the
  monitor it invalidated every observer of *any* of the three, in every window — including the
  whole of `MainTerminalTabStrip`, which is the rebuild its chip-scoped `@ObservedObject` exists
  to prevent. Only `TerminalTabChip` observes it, and the strip itself now reads nothing off the
  monitor at all.
  **One owner**: a `@StateObject` on `ClearwayApp`, injected on the project `WindowGroup` only, so
  a standalone Task or Prompt window reaching for it would fault. Surface retirement is
  `TerminalManager.retireSurface`, the same process-scoped static provider shape as
  `claimsShortcut`, reported from every door that drops a surface **and every door that learns its
  child is gone** — never reconciled against a list of live ones. `replaceSurface` reports a dead
  main tab before it branches on the exit code, not inside the clean-exit arm: a tab kept so the
  user can read its crash output holds a surface no further hook can name, and leaving it counted
  pinned its worktree's dot for the rest of the session.
  **Closing a project window is a door of its own.** It drops the whole `TerminalManager` without
  passing through `closeWorktree` or `removeSurface`, and its surfaces are freed by ARC, which
  reports nothing — so an agent working when the operator closed the window kept its dot and its
  subagent rows for the rest of the session. `ProjectContentView` hangs
  `TerminalManager.retireAllSurfaces` — main tabs, the secondary shell and every task terminal in
  one pass — off `WindowCloseHandler` (`ProjectWindow.swift`), an `NSWindow.willCloseNotification`
  observer scoped to the view's own window, and not off an isolated `deinit` or the window
  delegate, whose slot holds `CloseConfirmationDelegate`. Both installers sit in
  `ProjectContentView.body` and stay separate: the delegate is installed once through
  `DispatchQueue.main.async` and never re-scopes, while `WindowCloseHandlerView` re-scopes with the
  view's tenancy in a window — behavior `WindowCloseHandlerTests` pins. That delegate's prompt is
  scoped to the closing window, off the instance `TerminalManager.needsConfirmClose` injected as a
  closure, while Cmd+Q's `applicationShouldTerminate` keeps the process-wide static
  `TerminalManager.needsConfirmQuit` — which is why the two alert bodies differ. The observation
  holds the closure rather than the view, so the retirement still runs once the close has released
  the view hierarchy. Retirement is permanent per surface id, which costs a reopened project
  nothing: its surfaces are new ones with new ids. `AgentHookPaths(home:)` and `install(home:)`
  exist so the suite can drive the whole feature, forwarder and socket included, under a temp root;
  every call site outside the tests takes the default.
  **The dot is `waiting > working > idle`** over every surface carrying the worktree id, where
  working also means holding a live subagent — a lead between turns while subagents run must not go
  dark. Waiting on a permission prompt is a static 7 pt purple dot: orange is working, blue the
  plain-shell notification, red failure, green success and yellow a status badge, so purple is the
  only hue left, and not pulsing separates it by shape as well. `isMain` no longer suppresses the
  dot. That precedence is `WorktreeRow.dot(phase:hasNotification:isOpen:)`, a pure static beside
  `rowTexts` for the same reason — nothing in a SwiftUI body is reachable from XCTest — and
  `isOpen` gates the **phase** alone, along with the subagent rows, since a closed worktree's
  surfaces are already retired; the blue notification dot survives it, because a notification
  raised before the worktree closed is still unread.
- `OpenInApp.swift` / `OpenInAppLauncher.swift` / `OpenInMenu.swift` /
  `OpenInAppsSettingsSection.swift` — the "Open In" list: the model and its `Draft` validation, the
  launcher, the one menu view the toolbar and the sidebar both render, and the Settings section
  that edits the list. The list lives on `SettingsManager.openInApps` as JSON in a single `UserDefaults` value; an
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
  action. The Worktree menu's two Open in rows are the third entry point and the exception, since
  a menu bar row cannot vanish — they grey out instead. The sidebar passes
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
  inherit a disabled environment, while the `isPresented` flag it binds lives on `ContentView`.
  That stays the one presenter: the Worktree menu's Run submenu carries the same door and sets the
  same flag rather than raising a sheet of its own. Open in's door is
  "Edit Apps…", opening the Settings window where this list is edited:
  `SettingsLink` under `#available(macOS 14, *)` — both it and `@Environment(\.openSettings)` are
  macOS 14.0+ against a 13.0 target — falling back to
  `NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)`. Nothing selects a
  section on arrival: `SettingsView` is one `Form`, not a `TabView`. It is a shared
  `EditOpenInAppsButton`, rendered by this dropdown and by the Worktree menu's Open in submenu,
  rather than written twice. The sidebar's submenu carries neither door.
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
  record the pick rather than a successful launch — `WorktreeRunActions.runner`'s closure records
  before its `ghosttyApp.app` guard — or an app or command that fails to launch could never become
  the primary action again.
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
  needs a split first. `SidePanelTabStrip.swift` is the most recent one, moved out to make room for
  the Worktree menu's two `focusedSceneValue` lines.
  Both actions do carry keyboard shortcuts — ⌘R runs the primary command, ⌘O opens in the primary
  app, and ⌥⌘R / ⌥⌘O pop these very dropdowns — but every one of them is declared on the Worktree
  menu's rows and none on these buttons, and all four are claimed in `AppKeyboardShortcuts`. See the
  `WorktreeCommands.swift` entry near the top of this file.
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
