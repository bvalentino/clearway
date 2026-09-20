# Run an Agent Command When a Worktree Is Created, and to Plan a Task

**Date:** 2026-09-19
**Base:** 484482d3fe5e7e539176c4c1f8ae5720d5414836

Clearway creates a worktree and then stops: it launches no agent, and Start Now on a task relocates
`TASK.md` into the new worktree with nothing to read it. This change lets a saved **agent** command
run right after a worktree is created — `/work .clearway/TASK.md` for a task-backed worktree, a
PR-review prompt for a scratch one — and adds a Plan action that runs a chosen agent command against
a backlog task in the primary worktree. Start Now stops creating the worktree silently and instead
opens the existing New Worktree sheet, prefilled from the task, where the branch and the
run-after-create command can be seen and changed before anything is written.

## Decisions

| # | Question | Decision | Source |
| --- | --- | --- | --- |
| 1 | What is the unit that gets run? | A saved command of kind `.agent` (`SavedCommand.swift:9-20`). Global Prompts (`~/.clearway/prompts`, `PromptManager`) are untouched and no new prompt concept is added. | Operator |
| 2 | What does Start Now do now? | Opens `CreateWorktreeSheet` prefilled: title "Start Task", a read-only Task row above Name carrying the task title, Name prefilled from the task title, Branch from `task.worktree` if set else `WorkTaskManager.deriveBranchName` (`WorkTaskManager.swift:256`). A task whose branch already has a live worktree still focuses it with no sheet (`.reuse`). | Operator |
| 3 | What does the Advanced disclosure gain? | A "Run after create" picker: None plus the project's `.agent`-kind commands. Terminal-kind commands are excluded — running a shell line after create is what the afterCreate hook is for. Preselected from the per-project after-create default; the picked command is written as the new default only when Create succeeds. | Operator |
| 4 | How is a backlog task planned? | ~~A "Plan" menu whose primary action runs the plan default, as a launcher tab in the primary worktree through `TerminalManager.run`.~~ **Superseded by D19.** | Operator |
| 5 | How does the command reach the task file? | The placeholder `{{ task_path }}` in the command's `text`, substituted raw — no shell escaping, because the prompt travels as one argv element through a `0o600` temp file (`AgentLaunch.swift:21-43`), never through shell word-splitting. One pure helper, tested. | Operator |
| 6 | What does `{{ task_path }}` resolve to? | Plan: the task's file as `WorkTaskManager.filePath(for:)` returns it — the central `<project>/.clearway/tasks/<uuid>.md`. After-create with a task: the relocated `<worktree>/.clearway/TASK.md`. After-create with no task: the token is **left untouched**, not replaced with an empty string — a command that names no task has nothing to say about one, and a blank argument reads as a malformed path the agent then complains about. | Operator |
| 7 | Absolute or relative path? | Absolute. `filePath(for:)` and `taskMarkdownPath(inWorktree:)` already return absolute paths (`WorkTaskManager.swift:275-286`), and an absolute path is correct whatever directory the agent process ends up in. The brief's `/work .clearway/TASK.md` illustrates the intent, not the substituted form. | Spec |
| 8 | Where do the defaults live? | `<projectPath>/.clearway/command-defaults.json`, a sibling of `commands.json`, read and written by `SavedCommandStore` and held by `SavedCommandManager`. One slot, `afterCreate`, an optional command id — the `plan` slot was retired by D19, and a file still carrying it decodes fine because an unknown key is ignored. `commands.json` stays a plain array — the defaults are not part of the list and putting them in it would change its wire format. | Operator |
| 9 | A second store class for the defaults file? | No. `SavedCommandStore` gains `loadDefaults()` / `saveDefaults(_:)` using the same directory, the same `writeQueue`, and the same temp-file-and-`replaceItemAt` shape it already has (`SavedCommandStore.swift:83-120`). A second class would duplicate all of it for one two-field struct. | Spec |
| 10 | What does a stale default id do? | Reads as None. The lookup resolves an id against the live list **and** requires `kind == .agent`, so an id that was deleted, or that now names a terminal-kind command, resolves to nil. The file is not rewritten to drop it — the id may name a command that returns when the user reverts a `commands.json` edit. | Operator (brief) + Spec (the kind clause) |
| 11 | What does the Plan button do with no default set? | ~~Opens the menu, because the `Menu` is declared without `primaryAction:` while the plan default resolves to nil.~~ **Moot under D19:** there is no plan default and the primary action is Start Now. | Spec |
| 12 | When is the task's frontmatter written? | At Create, not at Start Now. `status = in_progress` and `worktree = <branch>` are written when the user confirms the sheet, using the branch actually in the field. Writing at Start Now would leave a cancelled sheet behind an in-progress task pointing at a branch that was never created. | Operator (brief, decision 7) |
| 13 | How does the coordinator carry the command? | `pendingLaunch` becomes `pendingCreate`, holding `taskId: UUID?`, `branch: String` and `command: SavedCommand?`. The task id is optional because decision 3 allows an after-create command on a plain New Worktree with no task at all. | Operator (brief, decision 7) + Spec (optional id) |
| 14 | What runs the pending command, and in what order? | `ContentView`'s single `onChange(of: worktreeManager.lastCreatedBranch)` handler (`ContentView.swift:298-317`), unchanged in shape: `completePendingCreate` relocates `TASK.md` and returns the command with `{{ task_path }}` already substituted; the handler keeps it in a local, runs the shadow-task, selection and afterCreate-hook steps exactly as today, and runs the command last. Running it before relocation would hand `/work` a path with no file behind it. | Operator (brief, decision 7) |
| 15 | Who owns the Plan run and the after-create run? | `WorkTaskCoordinator`. A view resolves no worktree, no primary checkout and no task path — the rule `CLAUDE.md` already states for `startTask` / `completePendingLaunch` and for `TerminalManager.run`. The views call `planTask(_:using:app:)` and read the returned command from `completePendingCreate`. | CLAUDE.md (Architecture, Sources/App) |
| 16 | Is there a new filtering helper for agent-only commands? | No. `SavedCommand.filter(_:by: .agent)` exists and is already pinned by `SavedCommandTests.testAgentReturnsOnlyAgentCommandsInInputOrder` (`Tests/SavedCommandTests.swift:38-46`). Both the picker and the Plan menu call it. | Spec |
| 17 | Where is the Start Task sheet presented? | `ContentView`, beside the existing `.sheet(item: $hookSheet)` (`ContentView.swift:228`). It is the one place both entry points converge: `WorkTaskListView` posts `WorkTaskNotification.start` and `ContentView` observes it (`WorkTaskListView.swift:231-237`, `ContentView.swift:404-418`). `SidebarView` keeps presenting the plain New Worktree sheet from its own `activeSheet` (`SidebarView.swift:90-94`). | Spec |
| 18 | Does the Status picker still apply to a task-started worktree? | Yes, unchanged, defaulting to `.inProgress`. `WorktreeStatus` is the worktree's sidebar status (`WorktreeGroupManager.setStatus`) and is unrelated to `WorkTask.status`; a task-started worktree gets one for the same reason a hand-made one does. | Spec |
| 19 | Where does a plan run, and what launches it? | The **task's own bottom terminal**, not a main-terminal tab: the Tasks destination renders no terminal pane, so a tab appended to the primary worktree's pane ran off-screen and Plan read as a dead button. `planTask` opens the task terminal on the primary worktree (`planWorkingDirectory`: the `isMain` path, else `projectPath`), submitting `buildAgentPromptCommand` when `autoRun` is on and staging `buildAgentPromptLine` on a login shell's prompt when it is off. Nothing is written to the task. | Operator (hands-on check) |
| 20 | What control offers Plan and Start Now? | One control labelled "Start Now". Its primary action opens the Start Task sheet; its items are the project's agent-kind commands and plan the task. The dedicated Start Now button and the Plan label are gone, and with them the plan default — nothing read it once it stopped driving a primary action. The toolbar renders a split button; the row context menu leads with that same action, because a menu item carrying a submenu has no body to click. | Operator (hands-on check) |
| 21 | What does Start Now's menu show when the project has saved no agent commands? | "Add Agent Command…", always, as the menu's last item — below the commands themselves and a `Divider()` that is rendered only when the list is non-empty. It presents `CommandEditorSheet` with the kind preselected to `.agent` (a new `newCommandKind` parameter, defaulting to `.terminal` so `CommandsView` is unchanged), and a saved command appears in the menu at once. An empty `Menu` opens nothing at all in AppKit, so without a permanent item the chevron read as broken on exactly the project that most needed the door. The row context submenu gets the same items behind its own "Start Task…". | Operator (hands-on check) |
| 22 | Is the Start Now split button disabled when the selection cannot be started? | No — `.disabled` on a `Menu` disables its chevron too, which would put "Add Agent Command…" out of reach precisely when no command exists. The control stays enabled and the primary action guards on `startableTask` (selected, `worktree == nil`) inside its closure, so a click on the body of an unstartable Start Now does nothing. This is a deliberate exception to the app's rule that a control which renders enabled must act; the menu items keep their own `.disabled`. | Operator (hands-on check) |
| 23 | Where does Start Now sit in the Tasks toolbar? | In its own capsule: a `ToolbarGroupBreak` after it as well as before it, so it no longer shares a group with copy / task-terminal / `…`. The `+` group and the edit/preview picker are untouched. | Operator (hands-on check) |

## Assumptions

Each verified by reading the codebase at base `484482d`. No probe scripts or temporary files were
written, into the repo or the scratchpad; nothing here needed an empirical probe. No third-party SDK
or API is integrated, configured or upgraded, so no documentation fetch was required.

1. **Start Now today creates the worktree with no sheet.** `WorkTaskListView.startTask` posts
   `WorkTaskNotification.start` (`WorkTaskListView.swift:231-237`); `ContentView.startWorkTask` calls
   `workTaskCoordinator.startTask(task)` and `handleStartResult` runs
   `Task { await worktreeManager.createWorktree(branch: branch) }` directly
   (`ContentView.swift:701-712`). Nothing between the click and the `git worktree add`.
2. **`startTask` writes the frontmatter before the worktree exists.** `updateFields` sets
   `status = in_progress` and `worktree = branch`, and only then is `pendingLaunch` set and
   `.createWorktree(branch)` returned (`WorkTaskCoordinator.swift:47-56`). Decision 12 moves exactly
   this block to the sheet's confirm path; the freshness re-resolve (`freshTask(id:)`,
   `WorkTaskCoordinator.swift:32`) and the `canceled` → `attempt + 1` rule stay with it.
3. **`.reuse` is branch-keyed and needs no sheet.** `startTask` returns `.reuse(wt)` when
   `current.worktree` names a live worktree (`WorkTaskCoordinator.swift:38-40`), and
   `handleStartResult` selects it (`ContentView.swift:707-708`). That path writes nothing and is
   unchanged.
4. **There is exactly one post-create handler.** `worktreeManager.lastCreatedBranch` is written in
   one place (`Worktree.swift:191`) and observed in one place (`ContentView.swift:298`). Its body is
   already the ordered list decision 14 extends: `completePendingLaunch`, `createShadowTask`,
   `detailSelection = .worktree(wt)`, then the afterCreate hook (`ContentView.swift:302-317`).
5. **The afterCreate hook does not block.** `terminalManager.runHookInSecondary` is called and the
   handler returns (`ContentView.swift:313-317`); the hook runs in the persistent secondary login
   shell. So "after the hook" means after the call, not after the hook's exit — recorded under Open
   risks.
6. **`TerminalManager.run` already does everything the Plan action and the after-create run need.**
   For `.agent` it opens a launcher tab with `agentOverride`, and either stages the prompt into
   `launcherDrafts[tabId]` or awaits `promoteLauncherToAgent`, per `autoRun`
   (`TerminalManager+Commands.swift:25-42`). Neither new caller needs a new terminal path; both pass
   a `SavedCommand` whose `text` has already been substituted.
7. **The prompt is never re-scanned by a shell.** `buildAgentPromptCommand` writes it to a `0o600`
   temp file and the recipe reads it with `"$(cat \"$2\")"` as `$1`'s single argument
   (`AgentLaunch.swift:40-42`). A substituted path containing spaces or shell metacharacters
   therefore arrives intact, which is what lets decision 5 skip escaping. The staged path
   (`autoRun == false`) puts the text in a launcher draft the user submits, which reaches the same
   builder.
8. **`SavedCommandStore` owns the `.clearway` component and can hold a second file.** It joins
   `.clearway` onto `projectPath` itself and derives three paths from it
   (`SavedCommandStore.swift:24-38`); `save` creates the directory `0o700` when absent
   (`SavedCommandStore.swift:93-99`). A fourth path for `command-defaults.json` needs no new
   knowledge and no new directory handling.
9. **`SavedCommandManager` is per project window and loads once.** It is a `@StateObject` on
   `ProjectContentView` built from `projectPath` (`ProjectWindow.swift:82,104`) with
   `.task { await savedCommandManager.load() }` (`ProjectWindow.swift:120`), and `load()` is guarded
   by `hasLoaded` (`SavedCommandManager.swift:27-31`). Reading the defaults inside that same `load()`
   keeps one read and one guard.
10. **The picker and the Plan menu can both reach the manager.** `RunCommandMenu` and `CommandsView`
    resolve it with `@EnvironmentObject` (`RunCommandMenu.swift:6`), and `CreateWorktreeSheet` is
    presented from views inside that environment, so a `.sheet` inherits it.
11. **`WorkTaskCoordinator` already holds every dependency the two new methods need.**
    `workTaskManager`, `terminalManager` and `worktreeManager` are stored properties
    (`WorkTaskCoordinator.swift:11-19`), and `TestHelpers.makeCoordinator` builds all three over
    `tempRoot` (`Tests/TestHelpers.swift:43-49`). No new dependency, so the test seam is unchanged.
12. **The primary worktree is `isMain`.** `fetchWorktrees` marks index 0 as `isMain`
    (`Worktree.swift:272-276`) and `Worktree.sorted` puts it first (`Worktree.swift:48`). Its `path`
    is the project root the window was opened for. The Plan action resolves it as
    `worktreeManager.worktrees.first(where: \.isMain)` and does nothing if it or `ghosttyApp.app` is
    absent.
13. **`CreateWorktreeSheet` is presented from one place today.** `SidebarView.swift:94`, inside
    `.sheet(item: $activeSheet)`. Adding a second presentation in `ContentView` does not disturb it;
    the sheet's existing inputs (`targetGroupId`) stay as they are, and the task-backed presentation
    passes `nil`.
14. **`WorktreeDraft` can express the prefill without a new state shape.** `setName` fills the
    branch from the name until the branch is hand-edited (`WorktreeDraft.swift:37-48`). A prefill
    whose branch is `deriveBranchName`'s output is not the same string as `slug(title)` — the derive
    caps at 50 characters and appends a UUID suffix on collision (`WorkTaskManager.swift:256-268`) —
    so the prefill must set the branch through `setBranch`, marking it hand-edited, or a later Name
    keystroke would overwrite the collision-resolved branch.
15. **`ContentView.swift` is at 1022 lines and survives only on a file-wide disable**
    (`ContentView.swift:1` `// swiftlint:disable file_length`, plus `type_body_length` at line 54).
    Decision 14 and decision 17 together add roughly a dozen lines there. Everything else lands in
    new files or in files with room.
16. **`SavedCommand.filter(_:by:)` exists and is tested.** `SavedCommand.swift:34-45` and
    `Tests/SavedCommandTests.swift:38-46`. Decision 16 reuses it rather than adding a predicate.

## Objective

Choosing an agent command once, in the sheet that creates a worktree, is enough to have that agent
running in the new worktree with the task file already in place. Planning a backlog task is one click
from the task list, in the primary checkout, without creating a worktree.

### Success criteria

1. Start Now on a backlog task with no live worktree opens the New Worktree sheet titled "Start
   Task", showing the task's title in a read-only Task row, the Name field prefilled from the task
   title, and the Branch field prefilled from the task's saved branch or the derived slug.
2. Cancelling that sheet writes nothing: the task stays `status: new` with no `worktree` line, no
   branch is created, and clicking Start Now again offers the same prefill.
3. Confirming it writes `status: in_progress` and `worktree: <branch in the field>` into the task
   file, creates the worktree, and relocates the task to `<worktree>/.clearway/TASK.md`.
4. Start Now on a task whose branch already has a live worktree selects that worktree with no sheet
   and writes nothing.
5. The sheet's Advanced disclosure shows a "Run after create" picker listing None and the project's
   agent-kind commands only. A terminal-kind command never appears in it.
6. With a command picked, confirming the sheet creates the worktree and then opens a launcher tab in
   it for that command's agent, with the command's prompt submitted when `autoRun` is on and staged
   in the input when it is off. The tab appears after `TASK.md` is in place.
7. A `{{ task_path }}` in that command's prompt arrives at the agent as the absolute path of the new
   worktree's `.clearway/TASK.md`. On a plain New Worktree with no task, the same command's
   `{{ task_path }}` arrives unchanged, as the literal token.
8. The picked command becomes the project's after-create default: the next New Worktree sheet, in
   the same window or a later one, preselects it. Cancelling the sheet does not change the default.
9. The task list's Plan menu lists every agent command. Choosing one opens a launcher tab in the
   **primary** worktree for that command, with `{{ task_path }}` resolved to the task's central
   `.clearway/tasks/<uuid>.md`, and makes it the plan default. The task's status, `worktree` field
   and file location are unchanged.
10. With a plan default set, clicking the Plan button runs it without opening the menu. With none
    set, clicking it opens the menu.
11. The Plan menu is disabled when the project has no agent commands, when no task is selected (the
    toolbar item), or when `ghosttyApp.app` is nil.
12. A default whose id no longer matches an agent-kind command in the project's list reads as None:
    the picker shows None, the Plan button opens the menu, and nothing crashes or runs.
13. `<projectPath>/.clearway/command-defaults.json` is created `0o600` inside a `0o700` `.clearway`,
    written through a temp file, and holds only the two ids. `commands.json` is still a plain JSON
    array with no wrapper object.
14. Project A's defaults never appear in project B's windows.

### Test coverage this requires

- **`Tests/CommandPlaceholdersTests.swift`** (new) — the substitution helper: a token replaced with
  the given path; several occurrences all replaced; a nil path leaving every token verbatim; text
  with no token returned unchanged; a path containing a space substituted raw, with no quoting or
  escaping added.
- **`Tests/SavedCommandStoreTests.swift`** — defaults round trip through `saveDefaults` /
  `loadDefaults`; an absent file loading as both-nil; the file's mode and its parent's mode, the way
  the commands cases already assert them; two stores on different project paths not seeing each
  other's defaults; saving defaults leaving `commands.json` byte-identical.
- **`Tests/SavedCommandManagerTests.swift`** — resolution: an id naming a live agent command
  resolves to it; an id naming nothing resolves to nil; an id naming a **terminal**-kind command
  resolves to nil; setting a default persists and is visible after a fresh manager loads the same
  project path.
- **`Tests/CreateWorktreeOutcomeTests.swift`** — the sheet's new pure prefill helper: a task with a
  saved `worktree` branch prefills that branch; a task without one prefills `deriveBranchName`'s
  output; the name comes from the task title; the prefilled branch is marked hand-edited, so a
  subsequent name change does not overwrite it.
- **`Tests/WorkTaskCoordinatorTests.swift`** — the split: the resolve step writes nothing and returns
  a prefill for a startable task, `.reuse` for one with a live worktree, and `.ignored` for a task
  that is neither `new` nor `canceled`; the confirm step writes `status`/`worktree` and records the
  pending create including its command; `completePendingCreate` relocates and returns the command
  with `{{ task_path }}` resolved to the worktree's `TASK.md`; a non-matching branch neither
  relocates nor consumes the record; a pending create with no task id returns its command with the
  token left verbatim; a pending create with no command returns nil.
- No new view test. The picker, the Plan menu and the sheet presentation are SwiftUI wiring XCTest
  cannot exercise without a running scene — the same split the project already makes for
  `Ghostty.SurfaceView` and for `RunCommandMenu`. Every rule they apply is lifted into a pure helper
  or a coordinator method above.

## Verification

```bash
./scripts/ci.sh
```

Regenerates the Xcode project, lints, builds and runs the test suite — the same gate
`.github/workflows/ci.yml` applies to a PR. It is the regression check for every build step and the
full gate at sign-off. New Swift files are invisible to the build until `xcodegen generate` runs, and
this change adds several, so no hand-written `xcodebuild` line substitutes for it.

```bash
swiftlint lint --quiet
```

Runs as a post-build phase; zero errors required.

```bash
git status --porcelain
```

Before any CI stamp or sign-off. Expect the un-gitignored `default.profraw` after any Debug launch;
untracked files block sign-off.

## Files touched

- **`Sources/App/CommandPlaceholders.swift`** (new) — the one pure helper: substitutes
  `{{ task_path }}` in a command's `text`, raw, and leaves the token verbatim for a nil path
  (decision 6). Returns a `SavedCommand` with only `text` replaced, so callers hand the result
  straight to `TerminalManager.run`.
- **`Sources/App/SavedCommand.swift`** — a `CommandDefaults` value: `afterCreate: UUID?`,
  `plan: UUID?`, `Codable`, `Equatable`, plus the static resolution rule (an id resolves only to a
  live `.agent`-kind command, decision 10). It belongs beside the model it indexes rather than in the
  store.
- **`Sources/App/SavedCommandStore.swift`** — `defaultsFile` / `defaultsTempFile` paths, and
  `loadDefaults()` / `saveDefaults(_:)` mirroring the existing load/save. A missing or undecodable
  defaults file loads as empty; unlike `commands.json` it is **not** moved aside, because it holds
  two ids the user cannot repair by hand and losing them costs one re-pick.
- **`Sources/App/SavedCommandManager.swift`** — `@Published private(set) var defaults`, read inside
  the existing `load()`; `setAfterCreateDefault(_:)` / `setPlanDefault(_:)` persisting through the
  same chained-save shape; and resolved accessors for the two slots.
- **`Sources/App/SidebarSheets.swift`** — `CreateWorktreeSheet` gains `task: WorkTask?`, the
  read-only Task row and the "Start Task" title when it is non-nil, an Advanced "Run after create"
  picker over `SavedCommand.filter(_:by: .agent)` preselected from the after-create default, and a
  static prefill helper producing the `WorktreeDraft` for a task. On success it hands the branch, the
  task id and the picked command to `WorkTaskCoordinator` **before** calling `createWorktree`, and
  writes the after-create default.
- **`Sources/App/WorkTaskCoordinator.swift`** — `StartResult` loses `.createWorktree` and gains a
  prefill case; the frontmatter write moves into a confirm method (decision 12); `pendingLaunch`
  becomes `pendingCreate` carrying an optional task id and an optional command (decision 13);
  `completePendingLaunch` becomes `completePendingCreate(branch:worktree:)`, returning the
  substituted command; and `planTask(_:using:app:)` resolves the primary worktree and the task path
  and runs the command there.
- **`Sources/App/ContentView.swift`** — `startWorkTask` presents the sheet instead of creating;
  `handleStartResult` loses its create branch; one `@State` and one `.sheet(item:)` beside the hook
  sheet; and the `lastCreatedBranch` handler keeps the returned command in a local and runs it after
  the afterCreate hook (decision 14). Kept to roughly a dozen lines — the file is past
  `file_length`.
- **`Sources/App/WorkTaskListView.swift`** — the Plan menu, declared once and used by the toolbar
  item and the row context menu, over the agent commands, with the primary-action rule of decision 11
  and the disabled rule of success criterion 11.
- **`Tests/CommandPlaceholdersTests.swift`** (new), **`Tests/SavedCommandStoreTests.swift`**,
  **`Tests/SavedCommandManagerTests.swift`**, **`Tests/CreateWorktreeOutcomeTests.swift`**,
  **`Tests/WorkTaskCoordinatorTests.swift`** — as listed under Test coverage.
- **`CLAUDE.md`** — the `SavedCommandStore` bullet gains the sibling defaults file and its two slots;
  the task start-up bullet is rewritten for the sheet, the confirm-time write and the pending-create
  record; the `AgentLaunch` bullet gains why `{{ task_path }}` is substituted raw.

## Out of scope

- Global Prompts: `PromptManager`, `PromptsView`, `PromptLauncherView` and the play button's
  stage-and-paste behaviour are untouched (decision 1).
- Terminal-kind commands in either surface. The afterCreate hook remains the way to run a shell line
  after a create.
- Any new placeholder beyond `{{ task_path }}`, and any change to `WorktreeHooks.interpolated`'s four
  placeholders or their escaping.
- Advancing a task's status after it starts. Nothing does that today and nothing here starts.
- Launching an agent on the primary worktree from anywhere but the Plan menu.
- A watcher for `command-defaults.json`, for the same reason `commands.json` has none: the app is its
  only writer, and an outside edit is picked up when the window reopens.
- Changing `commands.json`'s wire format, the command editor's fields, or `CommandLaunch`.
- Any keyboard shortcut. Neither the Plan menu nor the picker claims one, so `AppKeyboardShortcuts`
  gains no entry.
- Splitting `ContentView.swift`. It stays over `file_length` on its existing file-wide disable; this
  change adds to it, which is the last addition that should go in before a split.

## Open risks

- The after-create command's tab opens immediately after the afterCreate hook is **started**, not
  after it finishes (assumption 5). A command whose agent expects the hook's side effects — installed
  dependencies, a generated file — can begin before they exist. Accepted: the hook has never been
  awaited, and making it awaited is a behaviour change for every existing hook.
- A `{{ task_path }}` placed inside a shell snippet the agent is asked to run would be substituted
  raw and then re-scanned by whatever the agent runs. That is the same contract as
  `buildOpenInScript` and `WorktreeHooks.interpolated`'s command text: the prompt is the user's.
  Accepted.
- A default command id committed in `command-defaults.json` and pulled by a teammate whose
  `commands.json` differs resolves to None for them (decision 10). Accepted; it is the reason the
  stale id is not rewritten away.
- Two windows on the same project each own a `SavedCommandManager`, so the later write of a default
  wins. This is the exposure the project already accepts for `commands.json` and `groups.json`.
  Accepted.
