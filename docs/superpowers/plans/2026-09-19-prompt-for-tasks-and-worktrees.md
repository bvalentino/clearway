# Plan: Run an Agent Command When a Worktree Is Created, and to Plan a Task

**Date:** 2026-09-19
**Base:** 484482d3fe5e7e539176c4c1f8ae5720d5414836

Breaks down `docs/superpowers/specs/2026-09-19-prompt-for-tasks-and-worktrees.md`. Every design
question is settled there; this file only orders the work, fixes the signatures the tasks share, and
says how each piece is verified.

## Decisions carried from the spec

- The unit that runs is a saved command of kind `.agent`. Global Prompts are untouched (D1).
- Start Now opens `CreateWorktreeSheet` titled "Start Task", prefilled from the task; a task whose
  branch already has a live worktree is focused with no sheet (D2).
- The sheet's Advanced disclosure gains a "Run after create" picker over None plus the project's
  agent-kind commands only (D3).
- Plan runs a chosen agent command against a backlog task in the **primary** (`isMain`) worktree
  through `TerminalManager.run`, changing no task status (D4).
- `{{ task_path }}` is substituted **raw**, no shell escaping — the prompt travels as one argv
  element through `AgentLaunch`'s `0o600` temp file (D5, assumption 7).
- It resolves to `<worktree>/.clearway/TASK.md` after create, to the central
  `<project>/.clearway/tasks/<uuid>.md` for Plan, and is left **verbatim** when there is no task
  (D6). Always absolute (D7, operator-confirmed).
- Defaults live in `<projectPath>/.clearway/command-defaults.json`, two optional ids, owned by
  `SavedCommandStore` — no second store class (D8, D9). `commands.json` stays a plain array.
- A default id resolves only against a **live `.agent`-kind** command; anything else reads as None
  and the file is not rewritten (D10).
- With no plan default the Plan `Menu` is declared without `primaryAction:`, so the first click
  opens the list (D11).
- The task's `status`/`worktree` frontmatter is written at **Create**, not at Start Now (D12).
- `pendingLaunch` becomes `pendingCreate`, holding `taskId: UUID?`, `branch: String`,
  `command: SavedCommand?` (D13).
- The single `onChange(of: worktreeManager.lastCreatedBranch)` handler keeps its shape and runs the
  command **last**, after relocation, shadow task, selection and the afterCreate hook (D14).
- `WorkTaskCoordinator` owns both runs; views resolve nothing (D15).
- `SavedCommand.filter(_:by: .agent)` is reused for both surfaces; no new predicate (D16).
- The Start Task sheet is presented from `ContentView`, beside `.sheet(item: $hookSheet)`;
  `SidebarView` keeps presenting the plain sheet from its own `activeSheet` (D17).
- The Status picker is unchanged and still defaults to `.inProgress` (D18).

## Two shapes the spec left to the breakdown

Both are recorded here rather than left to a build agent to invent:

1. **The sheet takes the prefill, not the `WorkTask`.** `CreateWorktreeSheet` gains
   `var startPrefill: WorkTaskCoordinator.StartPrefill?` (defaulted `nil`, so `SidebarView`'s
   existing construction compiles unchanged) instead of `task: WorkTask?`. The prefill carries the
   task id, the title for the read-only Task row, and the branch — which means branch derivation
   stays in the coordinator, where `WorkTaskManager.deriveBranchName` already lives, instead of the
   view re-deriving it. Consequence for the spec's test list: the "saved branch vs. derived branch"
   cases land in `WorkTaskCoordinatorTests` (where `resolveStart` lives) and
   `CreateWorktreeOutcomeTests` keeps the draft-shape cases.
2. **Plan's resolution is a separate pure method.** `planTask` needs a `ghostty_app_t`, which XCTest
   cannot produce, so the decision rule is lifted into
   `planCommand(for:using:) -> SavedCommand?` — the same split `CLAUDE.md` mandates for
   `Ghostty.SurfaceView` and `TerminalManager.revealSecondaryForHook`. `planTask` is then the
   untestable three lines: resolve `isMain`, call `planCommand`, call `TerminalManager.run`.

## Shared signatures

```swift
// Sources/App/CommandPlaceholders.swift
enum CommandPlaceholders {
    static let taskPath = "{{ task_path }}"
    static func substituted(_ command: SavedCommand, taskPath: String?) -> SavedCommand
}

// Sources/App/SavedCommand.swift
struct CommandDefaults: Codable, Equatable {
    var afterCreate: UUID?
    var plan: UUID?
    static func resolve(_ id: UUID?, in commands: [SavedCommand]) -> SavedCommand?
}

// Sources/App/SavedCommandStore.swift
func loadDefaults() async -> CommandDefaults
func saveDefaults(_ defaults: CommandDefaults) async throws

// Sources/App/SavedCommandManager.swift
@Published private(set) var defaults: CommandDefaults
var afterCreateCommand: SavedCommand? { get }
var planCommand: SavedCommand? { get }
func setAfterCreateDefault(_ id: UUID?)
func setPlanDefault(_ id: UUID?)

// Sources/App/WorkTaskCoordinator.swift
struct StartPrefill: Equatable, Identifiable { let taskId: UUID; let title: String; let branch: String
                                               var id: UUID { taskId } }
struct PendingCreate: Equatable { let taskId: UUID?; let branch: String; let command: SavedCommand? }
enum StartResult { case ignored; case reuse(Worktree); case prefill(StartPrefill) }

var pendingCreate: PendingCreate?
func resolveStart(_ task: WorkTask) -> StartResult                        // writes nothing
func confirmCreate(taskId: UUID?, branch: String, command: SavedCommand?) // writes frontmatter, records pendingCreate
@discardableResult
func completePendingCreate(branch: String, worktree: Worktree) -> SavedCommand?
func planCommand(for task: WorkTask, using command: SavedCommand) -> SavedCommand?
func planTask(_ task: WorkTask, using command: SavedCommand, app: ghostty_app_t)

// Sources/App/SidebarSheets.swift
extension CreateWorktreeSheet {
    static func prefill(name: String, branch: String) -> WorktreeDraft
}
```

## Dependency graph

```
T1 CommandPlaceholders ──┬──────────────► T5 pendingCreate + substituted return ──► T6 Start Task sheet ──► T7 Run-after-create picker
                         │                                                                                          ▲
                         └──────────────────────────────────────► T8 Plan menu                                      │
T2 CommandDefaults ──► T3 store defaults ──► T4 manager defaults ─────────┴──────────────────────────────────────────┘

T9 CLAUDE.md  (after T7 and T8)
```

T1 and T2 are independent and can run in parallel. T5 needs only T1; T3/T4 are the defaults chain.
T7 needs T4 and T6. T8 needs T1 and T4.

Every task leaves the tree building and the suite green: `./scripts/ci.sh` is the acceptance gate on
each one, and no task leaves an intermediate behaviour that a later task has to undo.

### T1: Substitute `{{ task_path }}`

**Files:** `Sources/App/CommandPlaceholders.swift` (new),
`Tests/CommandPlaceholdersTests.swift` (new).

Add the one pure helper. `substituted(_:taskPath:)` returns a `SavedCommand` with only `text`
changed: every occurrence of `{{ task_path }}` replaced by the given path, raw — no quoting, no
escaping, no trimming. A `nil` path returns the command unchanged, token and all (D6): a command
that names no task has nothing to say about one, and a blank argument reads to the agent as a
malformed path.

**Acceptance criteria**

- One token is replaced with the given path; several occurrences are all replaced.
- `taskPath: nil` leaves every token verbatim and returns an equal command.
- Text with no token is returned unchanged.
- A path containing a space is substituted raw, with no quotes or backslashes added.
- Only `text` differs from the input command; `id`, `name`, `kind`, `agent`, `autoRun` are equal.

**Verification:** `./scripts/ci.sh` — the new cases in `Tests/CommandPlaceholdersTests.swift` pass.

### T2: The `CommandDefaults` value and its resolution rule

**Files:** `Sources/App/SavedCommand.swift`, `Tests/SavedCommandTests.swift`.

Add `CommandDefaults` beside the model it indexes: `afterCreate: UUID?`, `plan: UUID?`, `Codable`,
`Equatable`. Add `static func resolve(_ id: UUID?, in commands: [SavedCommand]) -> SavedCommand?`,
which returns the command with that id **only when** its `kind == .agent` (D10), and nil for a nil
id, an unknown id, or an id naming a terminal-kind command.

**Acceptance criteria**

- `resolve(nil, in:)` is nil.
- An id naming a live agent command resolves to that command.
- An id naming no command in the list resolves to nil.
- An id naming a **terminal**-kind command resolves to nil.
- `CommandDefaults()` round-trips through `JSONEncoder`/`JSONDecoder` as both-nil, and a populated
  value round-trips equal.

**Verification:** `./scripts/ci.sh` — the new cases in `Tests/SavedCommandTests.swift` pass.

### T3: Persist the defaults file

**Files:** `Sources/App/SavedCommandStore.swift`, `Tests/SavedCommandStoreTests.swift`.

**Depends on:** T2.

Add `defaultsFile` / `defaultsTempFile` (`command-defaults.json`, `command-defaults.json.tmp`) under
the store's existing `clearwayDir`, plus `loadDefaults()` and `saveDefaults(_:)` mirroring the
existing `load`/`save`: the same `writeQueue`, the same `0o700` directory creation, the same
`createFile` at `0o600` then `replaceItemAt`. A missing, unreadable or undecodable defaults file
loads as `CommandDefaults()` and is **not** moved aside — unlike `commands.json` it holds two ids
the user cannot repair by hand, and losing them costs one re-pick.

**Acceptance criteria**

- Defaults round-trip through `saveDefaults` / `loadDefaults`.
- An absent file loads as both-nil; a garbage file loads as both-nil and no `.corrupt` file appears.
- `command-defaults.json` is mode `0o600` inside a `0o700` `.clearway`, asserted the way the existing
  commands cases assert it.
- Two stores on different project paths do not see each other's defaults.
- Saving defaults leaves an existing `commands.json` byte-identical, and saving commands leaves
  `command-defaults.json` byte-identical.

**Verification:** `./scripts/ci.sh` — the new cases in `Tests/SavedCommandStoreTests.swift` pass.

### T4: Hold and mutate the defaults on the manager

**Files:** `Sources/App/SavedCommandManager.swift`, `Tests/SavedCommandManagerTests.swift`.

**Depends on:** T3.

Add `@Published private(set) var defaults = CommandDefaults()`, read inside the existing `load()` so
there is still one read behind one `hasLoaded` guard (assumption 9). Add `setAfterCreateDefault(_:)`
and `setPlanDefault(_:)`, each updating `defaults` and persisting. Both writes go onto the **same**
`pendingSave` chain the command writes use, so a defaults write and a command write cannot reach the
store's queue out of order. Add the resolved accessors `afterCreateCommand` / `planCommand`, each
`CommandDefaults.resolve(_:in: commands)`.

**Acceptance criteria**

- `load()` publishes the defaults found on disk; a project with no defaults file publishes both-nil.
- `setPlanDefault(id)` persists: a fresh `SavedCommandManager` over the same project path loads it.
- `setAfterCreateDefault(nil)` persists the cleared slot.
- `afterCreateCommand` is nil for an unset slot, for an id naming nothing, and for an id naming a
  terminal-kind command; it is the command for an id naming a live agent command.
- The persistence assertions poll the file the way the existing manager cases do, rather than
  sleeping a fixed span.

**Verification:** `./scripts/ci.sh` — the new cases in `Tests/SavedCommandManagerTests.swift` pass.

### T5: Carry the after-create command on the pending create

**Files:** `Sources/App/WorkTaskCoordinator.swift`, `Sources/App/WorkTaskManager.swift`,
`Sources/App/ContentView.swift`, `Tests/WorkTaskCoordinatorTests.swift`.

**Depends on:** T1.

Rename `pendingLaunch` to `pendingCreate` and widen it to `PendingCreate` (`taskId: UUID?`,
`branch`, `command: SavedCommand?`). Rename `completePendingLaunch(branch:worktree:)` to
`completePendingCreate(branch:worktree:)` and give it a return value: it still relocates `TASK.md`
only for the branch it is holding and still consumes the record, and it now returns its command with
`{{ task_path }}` substituted — to the worktree's `.clearway/TASK.md` when the record carries a task
id, and left verbatim when it does not (D6). Make `WorkTaskManager.taskMarkdownPath(inWorktree:)`
internal (it is `private static` today) so the coordinator can name the destination from
`worktree.path` directly rather than depending on the resolver having caught up.

`startTask` keeps its current shape and behaviour in this task — it sets `pendingCreate` with
`command: nil`. In `ContentView`, the `lastCreatedBranch` handler keeps the returned command in a
local and runs it with `terminalManager.run(command, in: wt, app: app)` as the **last** step, after
the afterCreate hook call (D14). Until T7 that local is always nil, so behaviour is unchanged.

**Acceptance criteria**

- A non-matching branch neither relocates nor consumes the pending create (the existing case, renamed).
- The matching branch relocates into `<worktree>/.clearway/TASK.md`, consumes the record, and returns
  the command with `{{ task_path }}` equal to that absolute path.
- A pending create with no task id returns its command with the token left verbatim and relocates
  nothing.
- A pending create with no command returns nil.
- `ContentView`'s handler order is unchanged except for the appended run: relocate, shadow task,
  selection, hook, then the command.

**Verification:** `./scripts/ci.sh` — the updated `Tests/WorkTaskCoordinatorTests.swift` passes,
including the renamed existing cases.

### T6: Start Now opens a prefilled Start Task sheet

**Files:** `Sources/App/WorkTaskCoordinator.swift`, `Sources/App/SidebarSheets.swift`,
`Sources/App/ContentView.swift`, `Tests/WorkTaskCoordinatorTests.swift`,
`Tests/CreateWorktreeOutcomeTests.swift`.

**Depends on:** T5.

Split `startTask` in two (D12). `resolveStart(_:)` re-resolves the task by id, refuses anything that
is neither `new` nor `canceled`, returns `.reuse(wt)` for a live branch, and otherwise returns
`.prefill(StartPrefill(taskId:title:branch:))` with the branch taken from `task.worktree` if set else
`workTaskManager.deriveBranchName(from:existingBranches:)` — and **writes nothing**.
`confirmCreate(taskId:branch:command:)` carries the write that moved out: when `taskId` is non-nil it
sets `status = in_progress` and `worktree = <branch>` through `updateFields`, keeping the
`canceled → attempt + 1` rule; it then records `pendingCreate`. It is called by both sheet
presentations, which is why `taskId` is optional (D13).

`CreateWorktreeSheet` gains `var startPrefill: WorkTaskCoordinator.StartPrefill?` defaulted to `nil`,
so `SidebarView`'s existing construction is untouched. When it is non-nil the headline reads "Start
Task" and a read-only Task row sits above Name carrying the prefill's title; the draft starts from
`CreateWorktreeSheet.prefill(name:branch:)`, a static that applies `setName` then `setBranch` so the
branch is marked hand-edited and a later Name keystroke cannot overwrite a collision-resolved branch
(assumption 14). On the Create path the sheet calls `confirmCreate` **before** `createWorktree`, and
the Status picker keeps working exactly as it does for a hand-made worktree (D18).

In `ContentView`, `startWorkTask` calls `resolveStart` and `handleStartResult` presents the sheet for
`.prefill` (a `@State` plus one `.sheet(item:)` beside `.sheet(item: $hookSheet)`, D17) instead of
creating. Keep the addition to roughly a dozen lines — the file is past `file_length` on a file-wide
disable.

**Acceptance criteria**

- `resolveStart` on a `new` task writes nothing: the file still reads `status: new` with no
  `worktree` line afterwards, and it returns a prefill whose title is the task's.
- The prefill's branch is `task.worktree` when the task has one, and `deriveBranchName`'s output when
  it does not.
- `resolveStart` returns `.reuse` for a task whose branch has a live worktree and `.ignored` for a
  task that is neither `new` nor `canceled`.
- `confirmCreate` writes `status = in_progress` and `worktree = <branch as passed>`, counts the
  attempt on a previously `canceled` task, and records a `pendingCreate` carrying the task id, the
  branch and the command.
- `confirmCreate(taskId: nil, …)` writes no task file and still records the pending create.
- `prefill(name:branch:)` produces a draft whose name is the given name, whose branch is the given
  branch, and whose branch survives a subsequent `setName`.

**Verification:** `./scripts/ci.sh` — the new cases in `Tests/WorkTaskCoordinatorTests.swift` and
`Tests/CreateWorktreeOutcomeTests.swift` pass, and `swiftlint lint --quiet` reports zero errors.

### T7: The "Run after create" picker

**Files:** `Sources/App/SidebarSheets.swift`.

**Depends on:** T4, T6.

Add a "Run after create" `Picker` to the Advanced disclosure, listing None plus
`SavedCommand.filter(savedCommandManager.commands, by: .agent)` — terminal-kind commands never appear
(D3). Its selection starts from `savedCommandManager.defaults.afterCreate` resolved through
`CommandDefaults.resolve`, so a stale or terminal-kind id shows None (D10). The picked command is
passed to `confirmCreate` and written back with `setAfterCreateDefault` **only on the `.apply`
branch** of `Self.outcome` — a cancelled or failed create changes no default. Reach the manager with
`@EnvironmentObject`; a sheet inherits it from the presenting view (assumption 10).

**Acceptance criteria**

- The picker lists None plus the project's agent-kind commands, in saved order, and no terminal-kind
  command.
- It preselects the project's after-create default, and shows None when the stored id resolves to
  nothing or to a terminal-kind command.
- Confirming with a command picked hands it to `confirmCreate` and persists it as the new default;
  confirming with None persists a cleared slot.
- Cancelling the sheet, or a creation that returns no worktree, writes no default.
- The picker is present in both presentations, since it is the same sheet.

**Verification:** `./scripts/ci.sh` builds and the suite stays green; `swiftlint lint --quiet`
reports zero errors. The picker itself is SwiftUI wiring XCTest cannot exercise without a running
scene — the rules it applies are `CommandDefaults.resolve` (T2) and `SavedCommand.filter` (already
pinned by `SavedCommandTests.testAgentReturnsOnlyAgentCommandsInInputOrder`).

### T8: The Plan menu

**Files:** `Sources/App/WorkTaskCoordinator.swift`, `Sources/App/WorkTaskListView.swift`,
`Tests/WorkTaskCoordinatorTests.swift`.

**Depends on:** T1, T4.

On the coordinator, add `planCommand(for:using:)`, which re-resolves the task by id, takes
`workTaskManager.filePath(for:)` as the task path and returns the substituted command; and
`planTask(_:using:app:)`, which resolves `worktreeManager.worktrees.first(where: \.isMain)` and calls
`terminalManager.run(substituted, in: main, app: app)`, doing nothing when the primary worktree is
absent. `WorkTaskCoordinator.swift` gains `import GhosttyKit` for the `ghostty_app_t` parameter.
Nothing writes to the task: status, `worktree` and file location are untouched (D4).

In `WorkTaskListView`, declare the Plan `Menu` once and use it from both the toolbar and the row
context menu. Its items are the agent commands; choosing one calls `planTask` **and**
`setPlanDefault`. It is declared with `primaryAction:` only while the plan default resolves to
non-nil, so with no default the first click opens the list (D11). Disabled when the project has no
agent commands, when `ghosttyApp.app` is nil, or — for the toolbar item — when no task is selected.
It claims no keyboard shortcut, so `AppKeyboardShortcuts` gains no entry.

**Acceptance criteria**

- `planCommand` returns the command with `{{ task_path }}` equal to the task's central
  `<project>/.clearway/tasks/<uuid>.md`, absolute.
- For a task already linked to a live worktree, `planCommand` resolves the token to whatever
  `filePath(for:)` returns for it — the rule stays `filePath(for:)`, not a second path convention.
- `planCommand` returns nil when the task is not resolvable by id.
- Running Plan writes nothing to the task file: `status`, `worktree` and the file's location are
  unchanged afterwards.
- The Plan menu appears on the task list toolbar and on the row context menu, disabled under the
  three conditions above.

**Verification:** `./scripts/ci.sh` — the new cases in `Tests/WorkTaskCoordinatorTests.swift` pass,
including a case asserting the task file is untouched; `swiftlint lint --quiet` reports zero errors.

### T9: Record the new rules in CLAUDE.md

**Files:** `CLAUDE.md`.

**Depends on:** T7, T8.

Update the three bullets the spec names, in the Architecture → `Sources/App` section:

- The `SavedCommandStore` bullet gains the sibling `command-defaults.json`, its two slots, that a
  stale or terminal-kind id reads as None and is not rewritten away, and that it has no watcher for
  the same reason `commands.json` has none.
- The task start-up bullet is rewritten: Start Now opens the prefilled Start Task sheet and writes
  nothing; the frontmatter write happens at Create; `pendingCreate` carries an optional task id and
  an optional command; the after-create command runs last in the `lastCreatedBranch` handler, after
  the afterCreate hook is **started** rather than finished; Plan runs in the primary worktree and
  changes no status. Keep the existing statement that Clearway launches no agent **of its own** and
  that nothing advances a task's status — both still hold: every agent launched here is a command the
  user saved and chose.
- The `AgentLaunch` bullet gains why `{{ task_path }}` is substituted raw: the prompt reaches the
  agent as one argv element through the `0o600` temp file, so a path with spaces or metacharacters
  arrives intact and quoting it would be wrong.

**Acceptance criteria**

- Each of the three bullets states the rule above, in the file's existing voice, with no new section
  and no restatement of what the code already says plainly.
- No source file changes in this task.

**Verification:** `./scripts/ci.sh` stays green (no source change), and the three bullets read
correctly against the shipped behaviour of T1–T8.

## Risks

| Risk | Impact | Handling |
| --- | --- | --- |
| The after-create tab opens after the afterCreate hook is *started*, not finished | Medium | Accepted in the spec's Open risks; the hook has never been awaited. |
| `ContentView.swift` is past `file_length` on a file-wide disable | Low | T5 and T6 add roughly a dozen lines between them. A split is the next change that should land there, not this one. |
| Two windows on one project each own a `SavedCommandManager`, so the later default write wins | Low | Accepted; the same exposure `commands.json` and `groups.json` already carry. |
| A `{{ task_path }}` inside a shell snippet the agent runs is re-scanned by that shell | Low | Accepted; same contract as `buildOpenInScript` and `WorktreeHooks.interpolated`. |

## Changelog

Operator-requested changes made after T1–T9 were committed. Recorded here so no later step reverts
them as unintentional.

### C1: Start Now becomes a split button, and Plan runs where it can be seen

**Reported:** after running the app, "I click Plan and commands in the menu and nothing is
happening."

**Diagnosis.** The launch was not failing — it was invisible. `planTask` called
`TerminalManager.run(_:in: main, app:)`, whose `.agent` branch appends a launcher tab to the
**primary worktree's** pane. `ContentView.readinessDetailView` renders a pane only when
`detailSelection?.worktree != nil`; on the Tasks destination it renders `TaskDetailView`, so the
tab, its promotion and the agent all happened off-screen. `ghosttyApp.app` is a process-wide
`Ghostty.App` and is non-nil on every destination, so the menu was never disabled and nothing
refused; with `autoRun` off the run did not even start, it only set `launcherDrafts` on a tab the
operator could not reach. A secondary effect: the primary worktree's active main tab was hijacked,
so switching to it later showed a surprise tab.

**Changes.**

1. The Plan menu and the separate Start Now button are replaced by one "Start Now" control. Its
   primary action opens the Start Task sheet (`resolveStart`, unchanged); its items are the
   project's agent-kind saved commands, and picking one plans the task. The toolbar gets a split
   button; the row context menu gets the same action as the submenu's first item, because an
   AppKit menu item carrying a submenu has no body to click and SwiftUI documents the primary
   action as firing "when the user taps or clicks on the body of the control".
2. The plan default slot is **removed**, not kept. With the primary action now Start Now, nothing
   read `planCommand` or `setPlanDefault`; keeping them would have cost a persisted field, a
   setter, an accessor and five tests for no reader. `CommandDefaults` keeps `afterCreate` alone,
   and a `command-defaults.json` still carrying `plan` decodes fine (unknown keys are ignored) —
   pinned by `SavedCommandTests.testDefaultsDecodeIgnoringARetiredSlot`.
3. `planTask` moves to `WorkTaskCoordinator+TaskTerminal.swift` and runs in the **task's** bottom
   terminal instead of a main-terminal tab, working directory
   `WorkTaskCoordinator.planWorkingDirectory` — the `isMain` worktree's path, falling back to
   `projectPath` for the window before the first `git worktree list` returns (the old code returned
   early there and did nothing). `plan` in the view selects the task first, so a plan started from
   a right-clicked row opens the terminal the operator is looking at.
4. `autoRun` is respected the way `TerminalManager.run` respects it, adapted to a surface with no
   launcher: submit runs `buildAgentPromptCommand` directly; stage opens a login shell, waits on
   `TerminalManager.awaitShellPrompt` (now internal, not private) and `sendText`s
   `buildAgentPromptLine`'s invocation without Enter.

**Files**

| File | State |
| --- | --- |
| `Sources/App/AgentLaunch.swift` | `buildAgentPromptLine` added; the temp-file write it shares with `buildAgentPromptCommand` extracted to `writeAgentPromptFile`. |
| `Sources/App/TerminalManager+TaskTerminals.swift` | `openTaskTerminalWithCommand` → `openTaskTerminal`, taking `command: String?` and returning the surface. |
| `Sources/App/TerminalManager+Commands.swift` | `awaitShellPrompt` internal. |
| `Sources/App/WorkTaskCoordinator.swift` | `planTask` removed; `planWorkingDirectory` added. |
| `Sources/App/WorkTaskCoordinator+TaskTerminal.swift` | `planTask` re-landed against the task terminal. |
| `Sources/App/WorkTaskListView.swift` | One Start Now control; `planMenu` / `planIsUnavailable` gone. |
| `Sources/App/SavedCommand.swift`, `SavedCommandManager.swift`, `SavedCommandStore.swift` | Plan slot removed. |
| `Tests/TerminalManagerTests.swift` | Three `buildAgentPromptLine` cases. |
| `Tests/WorkTaskCoordinatorTests.swift` | Two `planWorkingDirectory` cases. |
| `Tests/SavedCommand*Tests.swift` | Plan-slot cases removed; the retired-key decode case added. |
| `CLAUDE.md` | Task start-up, `AgentLaunch` and `command-defaults.json` bullets rewritten to the shipped shape. |

**Evidence.** The defect is not unit-testable: `planTask` takes a `ghostty_app_t` and the
visibility rule lives in `ContentView`'s view hierarchy, neither of which XCTest can reach — the
same limit `CLAUDE.md` records for `Ghostty.SurfaceView`. What is testable was lifted out and
pinned: `planWorkingDirectory` and `buildAgentPromptLine`. The fallback case was watched failing
first — with the body reverted to the old rule's "no primary worktree, nowhere to go"
(`worktrees.first(where: \.isMain)?.path ?? ""`), `./scripts/ci.sh` reported:

```
✖ testPlanWorkingDirectoryFallsBackToTheProjectPath, XCTAssertEqual failed: ("") is not equal to ("/repo")
Executed 584 tests, with 2 failures (0 unexpected)
```

The fix was restored from the scratchpad copy and the gate re-run. The re-target itself is on the
operator's Try list.

**Gate**

`./scripts/ci.sh` — passed, exit 0: 584 tests, 0 failures; SwiftLint zero errors.

### C2: Start Now's menu always has a door, and its own toolbar capsule

**Reported:** on the Tasks destination with no agent commands saved, "clicking the chevron opens
nothing", and the Start Now split button shares one capsule with copy / task-terminal / `…`.

**Diagnosis.** `planItems` was `ForEach(agentCommands)` and nothing else, so on a project that has
saved no `.agent` command the `Menu`'s content is empty — AppKit opens no menu for an empty
`NSMenu`, so the chevron reads as dead on exactly the project that most needs a way in. The grouping
was the second half of the same screenshot: the toolbar declared a `ToolbarGroupBreak` between the
`+` and Start Now and none after it, so every following `.primaryAction` item joined Start Now's
group.

**Changes.**

1. `planItems` becomes `startNowItems`, led by an **"Add Agent Command…"** button and then, only
   when the list is non-empty, a `Divider()` and the agent commands. Gating the divider keeps it
   from trailing the last item on an empty list. The button presents `CommandEditorSheet` with
   `command: nil`; a saved command is in the menu on the next render, because `SavedCommandManager`
   is the same `@StateObject` both views read.
2. `CommandEditorSheet.init` gains `newCommandKind: SavedCommand.Kind = .terminal`, used for the
   create case's `kind` seed. The default keeps `CommandsView` byte-identical; `WorkTaskListView`
   passes `.agent`. The sheet's kind picker stays editable — preselection, not a lock.
3. The row context submenu drops its `if !agentCommands.isEmpty { Divider(); … }` and calls the
   same `startNowItems` after its own "Start Task…", so the two surfaces cannot drift.
4. The toolbar's Start Now loses its `.disabled(selectedTask == nil || selectedTask?.worktree !=
   nil)`. **`.disabled` on a `Menu` disables the chevron with the body**, which would hide the
   editor door behind having a startable selection. The gate moves inside `primaryAction:`, onto a
   new `startableTask` computed property. The consequence is accepted and recorded in `CLAUDE.md`:
   this is the one control in the app that can render enabled and do nothing on a click.
5. A second `ToolbarGroupBreak()` after the Start Now item, giving it its own capsule. The `+` group
   and the edit/preview picker are untouched.

**Files**

| File | State |
| --- | --- |
| `Sources/App/WorkTaskListView.swift` | `startableTask` and `showCommandEditor` added; `planItems` → `startNowItems` with the editor item; the `.disabled` off the split button; a `ToolbarGroupBreak` after it; the `CommandEditorSheet` sheet attached beside the delete alert. |
| `Sources/App/CommandEditorSheet.swift` | `newCommandKind` init parameter, defaulted. |
| `CLAUDE.md` | The Start Now paragraph names the editor item, the no-`.disabled` rule and the own-capsule grouping. |
| `docs/superpowers/specs/2026-09-19-prompt-for-tasks-and-worktrees.md` | Decisions 21–23. |

**Evidence.** No test. Both defects are SwiftUI/AppKit rendering rules — an empty `NSMenu` opening
nothing, `.disabled` propagating to a `Menu`'s chevron, and which `.primaryAction` items share a
capsule — none of which XCTest can observe; the app has no view-hierarchy test host, the same limit
`CLAUDE.md` records for `Ghostty.SurfaceView`. The decision content that could be lifted out already
is: `SavedCommand.filter(_:by: .agent)` is pinned by `SavedCommandTests`. Verification is the
operator's hands-on check below.

**Gate**

`./scripts/ci.sh` — passed, exit 0: 584 tests, 0 failures; SwiftLint zero errors.

### C3: Add Agent Command… moves to the bottom of Start Now's menu

**Reported:** after running the app, the editor door should sit at the **bottom** of the Start Now
menu rather than the top, so the agent commands are what the menu opens onto.

**Changes.** `startNowItems` now emits the agent commands first, then a `Divider()` — still gated on
the list being non-empty, so it never leads the menu — and finally "Add Agent Command…". The item
stays unconditional for the reason C2 gave: an empty `NSMenu` opens nothing at all, so a project
with no agent commands saved still needs the door. The row context submenu keeps "Start Task…"
first and calls the same helper, so the two surfaces stay identical below it.

**Files**

| File | State |
| --- | --- |
| `Sources/App/WorkTaskListView.swift` | `startNowItems` reordered; its doc comment follows. |
| `CLAUDE.md` | The Start Now paragraph states the new order. |
| `docs/superpowers/specs/2026-09-19-prompt-for-tasks-and-worktrees.md` | Decisions 20 and 21. |

**Evidence.** No test. This is menu item order inside a SwiftUI `Menu`'s `@ViewBuilder`, which
XCTest cannot observe — the app has no view-hierarchy test host, the same limit `CLAUDE.md` records
for `Ghostty.SurfaceView`. Verification is the operator's hands-on check.

**Gate**

`./scripts/ci.sh` — passed, exit 0: 584 tests, 0 failures; SwiftLint zero errors.

### C4: Start Now's agent commands are omitted, not disabled

**Reported:** on the Tasks destination with a backlog task selected and its detail showing, the
Start Now chevron opens a menu whose two agent commands ("Work the task", "Plan the task") are
greyed out, while "Add Agent Command…" below them is live.

**Diagnosis.** The split difference between the greyed items and the live one is
`.disabled(task == nil || ghosttyApp.app == nil)`, which `startNowItems` stacked onto each command
`Button` inside the `Menu`'s content. Neither operand is true when the operator sees the menu:
`selection` is `ContentView`'s `selectedTaskId`, non-nil because `TaskDetailView` renders for it,
and `selectedTask` resolves it out of `workTaskManager.tasks`, which still holds the backlog task;
`Ghostty.App.init` assigns `appHandle` and `readiness = .ready` in the same synchronous run, so
`app` is non-nil on every destination — C1 already recorded that. What is stale is the rendered
`NSMenuItem`: the toolbar's menu is first built with nothing selected, and macOS does not reliably
push a later change of an existing item's enabled flag back into it. The unconditional editor door
never carried a `.disabled`, so it was never wrong.

`ghosttyApp.app` compounds it. It is a computed property over `appHandle`, not `@Published`, so a
menu built before the handle existed has no published change to re-evaluate against; the sibling
toolbar buttons gate on `readiness` for exactly that reason.

**Changes.** `startNowItems` renders the commands only under
`if let task, ghosttyApp.readiness == .ready, !agentCommands.isEmpty`, with no `.disabled` on the
items. Changing the item set changes the content's structural identity, so SwiftUI rebuilds the
menu instead of trying to re-enable items already in it. `plan` takes a non-optional `WorkTask` now
that the call site has unwrapped it, and keeps its `guard let app = ghosttyApp.app` — the launch is
the one place that genuinely needs the pointer. The editor door stays unconditional for the reason
C2 gave.

**Files**

| File | State |
| --- | --- |
| `Sources/App/WorkTaskListView.swift` | `startNowItems` gates the command items structurally on `task` + `readiness`; the per-item `.disabled` gone; `plan(_:using:)` takes a non-optional task. |
| `CLAUDE.md` | The Start Now paragraph records the omit-don't-disable rule and why the gate is `readiness`, not `app`. |

**Evidence.** No test. The defect is a macOS toolbar-menu rendering rule — an `NSMenuItem`'s
enabled flag not tracking a later view update — which XCTest cannot observe: the app has no
view-hierarchy test host, the same limit `CLAUDE.md` records for `Ghostty.SurfaceView`, and the
decision content that could be lifted out already is (`SavedCommand.filter(_:by: .agent)`, pinned
by `SavedCommandTests`). Verification is the operator's hands-on check.

**Gate**

`./scripts/ci.sh` — passed, exit 0: 584 tests, 0 failures; SwiftLint zero errors.

### C5: Four review findings — a failed create unwinds, a plan asks before replacing

**Reported:** the review step on `c5b68bb` raised four findings, each verified against the code.

**Changes.**

1. **A failed worktree create no longer leaves the task unstartable.** `CreateWorktreeSheet` calls
   `confirmCreate` — which writes `status = in_progress` and `worktree = <branch>` — before
   `createWorktree`, and on failure only reset `isCreating`. The task was left naming a branch with
   no worktree, which `resolveStart` refuses, so Start Now became a no-op on it for good.
   `PendingCreate` now carries `priorFields` (the prior `status`, `worktree` and `attempt`, captured
   inside the `updateFields` closure, so they are the values that were actually overwritten), and
   `abandonPendingCreate()` restores them through `updateFields` and clears the pending create. Both
   failure branches call it; the sheet still stays open. A hand-made worktree carries no
   `priorFields`, so its unwind clears the pending create and writes nothing.
2. **Planning over a running process asks first.** `planTask` → `openTaskTerminal` closes the task's
   existing surface unconditionally. `WorkTaskListView.plan` now routes through
   `WorkTaskCoordinator.planNeedsConfirmation(hasActiveProcess:)`; when it answers yes the view
   holds the request in `planToConfirm` and presents a destructive **Replace** `confirmationDialog`
   shaped like `SidebarView`'s worktree-remove (title with the task name, `titleVisibility: .visible`,
   the system Cancel, the same "processes still running" message as the force-delete dialog beside
   it). Otherwise it plans immediately. The selection is set in `runPlan`, not in `plan`, so a
   cancelled confirmation moves nothing. Cmd+J's own replacement is untouched — pre-existing
   follow-up.
3. **A successful start clears the task selection.** Added to `ContentView`'s
   `onChange(of: worktreeManager.lastCreatedBranch)` handler, immediately before
   `completePendingCreate` consumes the pending create (which is what makes the prior fields
   readable there at all). That handler is the one point every successful create lands on, whichever
   door opened the sheet, and it already owns the `detailSelection` move that follows; the sheet
   itself cannot do it, because `selectedTaskId` is `ContentView` state and the `.apply` branch runs
   inside `CreateWorktreeSheet`. It clears only when the pending create's branch matches this one
   **and** its task id is the current selection, so starting task A while B is selected leaves B
   selected.
4. **`buildAgentPromptLine`'s doc comment corrected.** It claimed "same unquoted `$1` contract",
   which is `buildAgentPromptCommand`'s. There is no `$1` on that path: the command text is
   concatenated into a line `sendText` stages on an interactive prompt, and the operator's own shell
   parses it as source. The comment and the matching `CLAUDE.md` sentence now say that — staged,
   visible and user-owned rather than run, the same contract as `buildOpenInScript`, with only the
   file path escaped — and say nothing about parameter expansion.

**Files**

| File | State |
| --- | --- |
| `Sources/App/WorkTaskCoordinator.swift` | `PendingCreate.PriorFields` added and captured by `confirmCreate`; new `abandonPendingCreate()`. |
| `Sources/App/SidebarSheets.swift` | Both create-failure branches call `abandonPendingCreate()`. |
| `Sources/App/WorkTaskCoordinator+TaskTerminal.swift` | New `static planNeedsConfirmation(hasActiveProcess:)` beside `planTask`. |
| `Sources/App/WorkTaskListView.swift` | `planToConfirm` state + `PlanRequest`; `plan` gates on the rule, `runPlan` does the launch; Replace confirmation dialog. |
| `Sources/App/ContentView.swift` | The `lastCreatedBranch` handler clears `selectedTaskId` for the started task. |
| `Sources/App/AgentLaunch.swift` | `buildAgentPromptLine`'s contract paragraph rewritten. |
| `CLAUDE.md` | The matching `buildAgentPromptLine` sentence rewritten. |
| `Tests/WorkTaskCoordinatorTests.swift` | Three `abandonPendingCreate` cases; existing `PendingCreate` literals carry `priorFields`. |
| `Tests/TaskTerminalLaunchCommandTests.swift` | `testPlanNeedsConfirmationOnlyWhenAProcessIsRunning`. |
| `docs/superpowers/specs/2026-09-19-prompt-for-tasks-and-worktrees.md` | Decisions 24–27. |

**Evidence**

The unwind body was stubbed out (the guard kept, the three restoring assignments removed) and
`./scripts/ci.sh` run — 588 tests, 7 failures, all in the two new cases:

```
✖ testAbandonPendingCreateRestoresTheTaskExactlyAsItWas, XCTAssertEqual failed: ("Optional("in_progress")") is not equal to ("Optional("new")")
✖ testAbandonPendingCreateRestoresTheTaskExactlyAsItWas, XCTAssertNil failed: "ship-it" - no branch link survives a failed create
✖ testAbandonPendingCreateRestoresTheTaskExactlyAsItWas, failed - the task must still be startable
✖ testAbandonPendingCreateRestoresABumpedAttempt, XCTAssertEqual failed: ("Optional(3)") is not equal to ("Optional(2)") - the unwind puts the attempt count back
✖ testAbandonPendingCreateRestoresABumpedAttempt, XCTAssertEqual failed: ("Optional("in_progress")") is not equal to ("Optional("canceled")")
✖ testAbandonPendingCreateRestoresABumpedAttempt, XCTAssertNil failed: "retry-me"
```

(The seventh is the same test's byte-for-byte file comparison, whose message is the whole file.)
Restoring the three assignments turned all 588 green.

Findings 2 and 3 have no watched failure of their own: the confirmation is an AppKit dialog and the
selection lives in `ContentView`, and neither is reachable from XCTest — the same limit C4 recorded.
What is liftable is lifted: `planNeedsConfirmation` is pure and pinned both ways. Verification of
the dialog and the selection is the operator's hands-on check.

**Deviations from the brief**

None. The selection clear went where the brief's first suggestion pointed — the
`completePendingCreate` call site — rather than an `onDismiss`-with-result, because the pending
create still holds the task id there and no new plumbing is needed to read it.

**Gate**

`./scripts/ci.sh` — passed, exit 0: 588 tests, 0 failures; SwiftLint zero errors (the three
pre-existing warnings in `WorktreeConfigStore.swift` and `WorktreeDraft.swift`, neither file
touched). `git status --porcelain` before the commit listed only the modified files above — no
untracked or ignored files.

## Build log

### T1: Substitute `{{ task_path }}`

**What landed**

| File | State |
| --- | --- |
| `Sources/App/CommandPlaceholders.swift` | New. `CommandPlaceholders.taskPath` plus `substituted(_:taskPath:)`, which replaces every occurrence raw and returns the command unchanged for a `nil` path. |
| `Tests/CommandPlaceholdersTests.swift` | New. Eight cases covering the acceptance criteria. |

**Evidence**

The tests were written first and watched fail against the absent helper — `./scripts/ci.sh` stopped
at the test target's compile:

```
❌ Tests/CommandPlaceholdersTests.swift:20:22: cannot find 'CommandPlaceholders' in scope
❌ Tests/CommandPlaceholdersTests.swift:26:22: cannot find 'CommandPlaceholders' in scope
❌ Tests/CommandPlaceholdersTests.swift:34:22: cannot find 'CommandPlaceholders' in scope
❌ Tests/CommandPlaceholdersTests.swift:42:13: cannot find 'CommandPlaceholders' in scope
❌ Tests/CommandPlaceholdersTests.swift:51:22: cannot find 'CommandPlaceholders' in scope
❌ Tests/CommandPlaceholdersTests.swift:66:22: cannot find 'CommandPlaceholders' in scope
❌ Tests/CommandPlaceholdersTests.swift:76:41: cannot find 'CommandPlaceholders' in scope
❌ Tests/CommandPlaceholdersTests.swift:78:13: cannot find 'CommandPlaceholders' in scope
```

**Deviations from the plan**

None. The signature is the one fixed under Shared signatures. `Self.taskPath` disambiguates the
token constant from the parameter of the same name.

**Gate**

`./scripts/ci.sh` — passed: 542 tests, 0 failures, SwiftLint zero errors.

### T2: The `CommandDefaults` value and its resolution rule

**What landed**

| File | State |
| --- | --- |
| `Sources/App/SavedCommand.swift` | Gains a `Defaults` section: `CommandDefaults` (`afterCreate`/`plan`, `Codable`, `Equatable`) and `resolve(_:in:)`, which matches on id **and** `kind == .agent`. |
| `Tests/SavedCommandTests.swift` | Gains a `Command defaults` section: six cases covering the acceptance criteria. |

**Evidence**

The six cases were written first and watched fail against the absent type — `./scripts/ci.sh`
stopped at the test target's compile:

```
❌ Tests/SavedCommandTests.swift:203:22: cannot find 'CommandDefaults' in scope
❌ Tests/SavedCommandTests.swift:209:24: cannot find 'CommandDefaults' in scope
❌ Tests/SavedCommandTests.swift:214:22: cannot find 'CommandDefaults' in scope
❌ Tests/SavedCommandTests.swift:221:22: cannot find 'CommandDefaults' in scope
❌ Tests/SavedCommandTests.swift:225:45: cannot find 'CommandDefaults' in scope
❌ Tests/SavedCommandTests.swift:232:24: cannot find 'CommandDefaults' in scope
```

**Deviations from the plan**

None. The signature is the one fixed under Shared signatures. Both slots are optional `var`s, so the
synthesized memberwise initializer supplies `CommandDefaults()` and the synthesized `Codable`
decodes a missing key as nil — neither needs writing out.

**Gate**

`./scripts/ci.sh` — passed: 548 tests, 0 failures, SwiftLint zero errors.

### T3: Persist the defaults file

**What landed**

| File | State |
| --- | --- |
| `Sources/App/SavedCommandStore.swift` | Gains `defaultsFile` / `defaultsTempFile` (`command-defaults.json`, `.tmp`), `loadDefaults()` and `saveDefaults(_:)`. A missing, unreadable or undecodable defaults file reads as `CommandDefaults()` and is left in place — it is never moved aside. |
| `Tests/SavedCommandStoreTests.swift` | Gains a `Defaults` section: six cases covering the acceptance criteria. |

**Evidence**

The six cases were written first and watched fail against the absent methods — `./scripts/ci.sh`
stopped at the test target's compile:

```
❌ Tests/SavedCommandStoreTests.swift:262:34: value of type 'SavedCommandStore' has no member 'loadDefaults'
❌ Tests/SavedCommandStoreTests.swift:267:25: value of type 'SavedCommandStore' has no member 'saveDefaults'
❌ Tests/SavedCommandStoreTests.swift:276:34: value of type 'SavedCommandStore' has no member 'loadDefaults'
❌ Tests/SavedCommandStoreTests.swift:286:34: value of type 'SavedCommandStore' has no member 'loadDefaults'
❌ Tests/SavedCommandStoreTests.swift:300:25: value of type 'SavedCommandStore' has no member 'saveDefaults'
❌ Tests/SavedCommandStoreTests.swift:317:26: value of type 'SavedCommandStore' has no member 'saveDefaults'
```

**Deviations from the plan**

The plan said the two saves mirror each other. Rather than a second copy of the thirty-line atomic
write, `save` and `saveDefaults` each encode their value and hand it to one private
`write(_:to:via:)` carrying the existing `writeQueue`, `0o700` directory creation, `0o600`
`createFile` and `replaceItemAt` — so both files are written by the same code and cannot drift.
`loadDefaults` does not mirror `load`'s `fileExists`-then-`contents` split: missing and unreadable
take the same branch there, because neither is quarantined.

**Gate**

`./scripts/ci.sh` — passed: 555 tests, 0 failures, SwiftLint zero errors.

### T4: Hold and mutate the defaults on the manager

**What landed**

| File | State |
| --- | --- |
| `Sources/App/SavedCommandManager.swift` | Gains `@Published private(set) var defaults`, read inside the existing `load()` behind the one `hasLoaded` guard; `setAfterCreateDefault(_:)` / `setPlanDefault(_:)`; and the resolved accessors `afterCreateCommand` / `planCommand`, each `CommandDefaults.resolve(_:in: commands)`. |
| `Tests/SavedCommandManagerTests.swift` | Gains a `Defaults` section: eight cases plus a `persistedDefaults(matching:)` poll helper mirroring the existing `persistedCommands(matching:)`. |

**Evidence**

The eight cases were written first and watched fail against the absent members — `./scripts/ci.sh`
stopped at the test target's compile:

```
❌ Tests/SavedCommandManagerTests.swift:202:33: value of type 'SavedCommandManager' has no member 'planCommand'
❌ Tests/SavedCommandManagerTests.swift:208:17: value of type 'SavedCommandManager' has no member 'setAfterCreateDefault'
❌ Tests/SavedCommandManagerTests.swift:213:30: value of type 'SavedCommandManager' has no member 'defaults'
❌ Tests/SavedCommandManagerTests.swift:225:30: value of type 'SavedCommandManager' has no member 'afterCreateCommand'
❌ Tests/SavedCommandManagerTests.swift:226:30: value of type 'SavedCommandManager' has no member 'planCommand'
❌ Tests/SavedCommandManagerTests.swift:232:17: value of type 'SavedCommandManager' has no member 'setAfterCreateDefault'
❌ Tests/SavedCommandManagerTests.swift:241:17: value of type 'SavedCommandManager' has no member 'setAfterCreateDefault'
❌ Tests/SavedCommandManagerTests.swift:251:17: value of type 'SavedCommandManager' has no member 'setAfterCreateDefault'
```

**Deviations from the plan**

The plan said both writes go onto the same `pendingSave` chain. Rather than a second copy of the
chaining block, the body moved into one private `enqueue(_:_:)` that both `save()` and
`saveDefaults()` hand a snapshot-capturing closure to — so the two files cannot drift apart on
ordering, which is the whole point of sharing the chain.

**Gate**

`./scripts/ci.sh` — passed: 563 tests, 0 failures, SwiftLint zero errors.

### T5: Carry the after-create command on the pending create

**What landed**

| File | State |
| --- | --- |
| `Sources/App/WorkTaskCoordinator.swift` | `pendingLaunch` is now `pendingCreate: PendingCreate?` (`taskId: UUID?`, `branch`, `command: SavedCommand?`). `completePendingLaunch` is now `@discardableResult completePendingCreate(branch:worktree:) -> SavedCommand?`: it consumes the record on a branch match, relocates only when the record names a task, and returns its command with `{{ task_path }}` resolved to the relocated `TASK.md` — verbatim when there is no task. `startTask` is otherwise unchanged and records `command: nil`. |
| `Sources/App/WorkTaskManager.swift` | `taskMarkdownPath(inWorktree:)` is internal, so the coordinator names the destination from `worktree.path` without waiting on the resolver. |
| `Sources/App/ContentView.swift` | The `lastCreatedBranch` handler keeps the returned command in a local and runs it with `terminalManager.run(_:in:app:)` as the last step, after relocate, shadow task, selection and the afterCreate hook. Until T7 that local is always nil. |
| `Tests/WorkTaskCoordinatorTests.swift` | The pending-launch case is renamed to `testCompletePendingCreateRelocatesOnlyForTheBranchItIsHolding`; three cases added for the token resolving to the relocated file, the no-task token staying verbatim, and a command-less record returning nil while still relocating. |

**Evidence**

`completePendingCreate` was reverted to `substituted(command, taskPath: nil)` and the suite watched
fail:

```
Tests/WorkTaskCoordinatorTests.swift:110: error: -[ClearwayTests.WorkTaskCoordinatorTests testCompletePendingCreateResolvesTheTokenToTheRelocatedTaskFile] : XCTAssertEqual failed: ("Optional("plan {{ task_path }} now")") is not equal to ("Optional("plan /var/folders/…/wt-resolve-me/.clearway/TASK.md now")")
```

Restoring `taskPath:` turned it green.

**Deviations from the plan**

`completePendingCreate` consumes the record on a branch match alone, where the old
`completePendingLaunch` guard also required the task to still be in the pool — a record whose task
has vanished must not survive to move a file on the next unrelated create. Relocation still requires
both the task and a worktree path.

**Gate**

`./scripts/ci.sh` — passed: 566 tests, 0 failures, SwiftLint zero errors.

### T6: Start Now opens a prefilled Start Task sheet

**What landed**

| File | State |
| --- | --- |
| `Sources/App/WorkTaskCoordinator.swift` | `startTask` is split. `StartPrefill` (`taskId`, `title`, `branch`, `Identifiable` on `taskId`) is the new `StartResult.prefill` payload, replacing `.createWorktree(String)`. `resolveStart(_:)` re-resolves by id, refuses anything that is neither `new` nor `canceled`, returns `.reuse` for a live branch and otherwise a prefill — and writes nothing. `confirmCreate(taskId:branch:command:)` carries the write that moved out (the `canceled → attempt + 1` rule included) and records `pendingCreate`. |
| `Sources/App/SidebarSheets.swift` | `CreateWorktreeSheet` gains `startPrefill`, defaulted `nil` through an explicit initializer so `SidebarView`'s construction is untouched. Non-nil retitles the headline to "Start Task", adds a read-only Task row above Name, and seeds `draft` from the new `static func prefill(name:branch:)`. Both presentations call `confirmCreate` before `createWorktree`. |
| `Sources/App/ContentView.swift` | `startWorkTask` calls `resolveStart`; `handleStartResult` sets a `startPrefill` `@State`, and one `.sheet(item:)` beside `.sheet(item: $hookSheet)` presents `CreateWorktreeSheet(targetGroupId: nil, startPrefill:)`. Ten lines net. |
| `Tests/WorkTaskCoordinatorTests.swift` | Four `resolveStart` cases (writes nothing and returns the task's title; saved branch preferred over derived; derived when absent; `.reuse`; `.ignored`), three `confirmCreate` cases (status + confirmed branch + pending record; the canceled attempt count, renamed from the `startTask` case; no task id writes no file and still records). The two cases that used `startTask` for setup now drive `resolveStart` + `confirmCreate`. |
| `Tests/CreateWorktreeOutcomeTests.swift` | Two `prefill(name:branch:)` cases: the draft carries the given name and branch, and the branch survives a later `setName`. |

**Evidence**

`resolveStart` was reverted to write the frontmatter the way `startTask` did, and the suite watched
fail:

```
✖ testResolveStartWritesNothing, XCTAssertTrue failed - resolving leaves the task on its backlog marker
✖ testResolveStartWritesNothing, XCTAssertFalse failed - resolving writes no branch link
Executed 574 tests, with 2 failures (0 unexpected)
```

Removing the write again turned it green.

**Deviations from the plan**

- The plan wrote `startPrefill` as a `var` with a `nil` default. It is a `let` fed by an explicit
  initializer instead, because `@State private var draft` has to be seeded from it — the same shape
  `NameEntrySheet` already uses in this file. The default argument keeps `SidebarView`'s call site
  unchanged.
- The plan justified `prefill`'s `setName`-then-`setBranch` order as what marks the branch
  hand-edited. A probe with the order reversed did **not** fail: `setBranch` marks the flag either
  way, so the two orders produce an identical draft. The comment and the test now say what is
  actually load-bearing — that the branch goes through `setBranch` at all.

**Gate**

`./scripts/ci.sh` — passed: 574 tests, 0 failures, SwiftLint zero errors.

### T7: The "Run after create" picker

**What landed**

| File | State |
| --- | --- |
| `Sources/App/SidebarSheets.swift` | `CreateWorktreeSheet` reaches `SavedCommandManager` through `@EnvironmentObject` and holds the picked id in `@State afterCreateCommandId`. The Advanced disclosure gains a "Run after create" `LabeledField` + `Picker` listing None plus `SavedCommand.filter(savedCommandManager.commands, by: .agent)`, tagged `UUID?`. `.onAppear` seeds the selection from `savedCommandManager.afterCreateCommand?.id`, so a stored id that now names nothing or a terminal-kind command shows None without being rewritten. Create resolves the selection through `CommandDefaults.resolve` and hands the command to `confirmCreate`; `setAfterCreateDefault(command?.id)` is written back only on the `.apply` branch of `Self.outcome`. |

**Evidence**

No new test. The picker is SwiftUI wiring XCTest cannot exercise without a running scene, which is
what the plan's verification for this task says. The two rules it applies are already pinned:
`SavedCommandTests.testResolve*` for the None-on-stale-or-terminal-id behaviour (T2) and
`SavedCommandTests.testAgentReturnsOnlyAgentCommandsInInputOrder` for the list contents and their
order.

**Deviations from the plan**

None.

**Gate**

`./scripts/ci.sh` — passed: 574 tests, 0 failures. `swiftlint lint --quiet` — exit 0, zero errors
(three pre-existing warnings, none in the changed file).

### T8: The Plan menu

**What landed**

| File | State |
| --- | --- |
| `Sources/App/WorkTaskCoordinator.swift` | `import GhosttyKit`, plus `planCommand(for:using:)` (pure: re-resolves by id, substitutes `{{ task_path }}` with `filePath(for:)`) and `planTask(_:using:app:)` (resolves `isMain`, calls `TerminalManager.run`). Neither writes to the task. |
| `Sources/App/WorkTaskListView.swift` | `@EnvironmentObject savedCommandManager`, plus `planMenu(for:)` / `planItems(for:)` / `planIsUnavailable(for:)` / `plan(_:using:)`. The menu is rendered from the toolbar (`selectedTask`) and the row context menu (the right-clicked task). |
| `Tests/WorkTaskCoordinatorTests.swift` | Four new cases under a `// MARK: - Plan` section. |

**Evidence**

The four cases were written first and watched fail against the absent method — `./scripts/ci.sh`
stopped at the test target's compile:

```
❌ Tests/WorkTaskCoordinatorTests.swift:295:36: value of type 'WorkTaskCoordinator' has no member 'planCommand'
❌ Tests/WorkTaskCoordinatorTests.swift:320:36: value of type 'WorkTaskCoordinator' has no member 'planCommand'
❌ Tests/WorkTaskCoordinatorTests.swift:329:36: value of type 'WorkTaskCoordinator' has no member 'planCommand'
❌ Tests/WorkTaskCoordinatorTests.swift:348:25: value of type 'WorkTaskCoordinator' has no member 'planCommand'
Testing cancelled because the build failed.
```

**Deviations from the plan**

One shape the plan left open: the menu takes the task as an **optional** parameter rather than
carrying a separate "no selection" gate for the toolbar. The toolbar passes `selectedTask` and the
context menu passes its row's task, so the plan's three disable conditions collapse into one
expression (`task == nil || agentCommands.isEmpty || ghosttyApp.app == nil`) shared by both entry
points — the same parameterisation `OpenInMenu` uses so the sidebar can act on a worktree that is
not the selection.

`primaryAction:` cannot be applied conditionally to a `Menu`, so `planMenu(for:)` declares the two
shapes in an `if`/`else`. The alternative — always declaring `primaryAction:` and making it a no-op
without a default — is the behaviour D11 rules out.

**Gate**

`./scripts/ci.sh` — passed: 578 tests, 0 failures. `swiftlint lint --quiet` — zero errors (three
pre-existing warnings, none in the changed files).

### T9: Record the new rules in CLAUDE.md

**What landed**

| File | State |
| --- | --- |
| `CLAUDE.md` | Three bullets in Architecture → `Sources/App` rewritten or extended. No source change. |

The task start-up bullet now names the shipped methods (`resolveStart`, `confirmCreate`,
`completePendingCreate`, `planTask`), states that Start Now writes nothing and only opens the
prefilled Start Task sheet — `CreateWorktreeSheet` with a prefill, not a second sheet — that the
frontmatter write is Create's, that `pendingCreate` carries an optional task id and an optional
command, that the command runs **last** in the `lastCreatedBranch` handler after the afterCreate
hook is *started* rather than after it exits, and that Plan runs in the primary worktree and writes
nothing at all. It keeps the existing statements that Clearway launches no agent of its own and that
nothing advances a task's status, with the clause that every agent either path starts is a command
the user saved and picked. It also records the `primaryAction:`-cannot-be-conditional gotcha behind
the Plan menu's two `Menu` declarations.

The `SavedCommandStore` bullet gains `command-defaults.json`: its two slots, the shared `write` /
`enqueue` chain that keeps the two files ordered, that an id is only read through
`CommandDefaults.resolve` so a dead or terminal-kind id shows None and is not rewritten away, that a
missing or undecodable file reads as both-unset and is left in place, that the after-create slot is
written back only on the `.apply` branch, and that it has no watcher for the same reason
`commands.json` has none.

The `AgentLaunch` bullet gains why `{{ task_path }}` is substituted raw — the substituted text
becomes the prompt, which reaches the agent as one argv element out of the `0o600` temp file and is
never parsed by a shell, the opposite of `WorktreeHooks.interpolated`, whose placeholders do land in
a shell line and are escaped — and that a `nil` path leaves the token verbatim.

**Evidence**

No test. This task changes documentation only; there is no behaviour to watch fail. Each bullet was
written against the shipped code rather than the plan's first draft: `WorkTaskCoordinator.swift`
(`resolveStart` / `confirmCreate` / `completePendingCreate` / `planCommand` / `planTask`),
`ContentView.swift`'s `onChange(of: lastCreatedBranch)` ordering, `SidebarSheets.swift`'s picker and
its `.apply`-only `setAfterCreateDefault`, `SavedCommandStore.swift`'s `loadDefaults` /
`saveDefaults` / `write`, `SavedCommandManager.swift`'s `enqueue`, `WorkTaskListView.planMenu` and
`WorktreeHooks.interpolated`'s `shellEscape`.

**Deviations from the plan**

Two additions the plan did not list, both rules a reader would otherwise have to rediscover from the
build log: the `primaryAction:`-cannot-be-conditional constraint that shapes `planMenu`, and that
the after-create default is written back only on a successful create.

**Gate**

`./scripts/ci.sh` — passed, exit 0: 578 tests, 0 failures; SwiftLint zero errors (three pre-existing
warnings, none in a file this task touched). `git status --porcelain` before the commit showed only
`M CLAUDE.md` — no untracked or ignored files.

### Simplify pass

`planTask`'s terminal work moved onto `TerminalManager.run(_:inTaskTerminalFor:app:directory:)`
beside `run(_:in:app:)`, so the coordinator no longer drives a surface and `awaitShellPrompt` goes
back to `private`. `SavedCommandManager.agentCommands` now answers "which commands may run as an
agent" for both the Start Now menu and the Start Task picker; `load()` reads the two files
concurrently; `setAfterCreateDefault` skips a no-op write. Dropped an unused `import GhosttyKit`,
a stale two-slot comment on `loadDefaults`, and two narrating paragraphs on `startNowItems`.

Skipped: swapping `taskMarkdownPath(inWorktree:)` for `filePath(for:)` in `completePendingCreate`
(reviewers' top finding) — tried, and
`testCompletePendingCreateResolvesTheTokenToTheRelocatedTaskFile` failed: the relocation moves the
file to a path it is handed, while `filePath(for:)` re-derives one from frontmatter and the
resolver, which is a different question.

**Gate**

`./scripts/ci.sh` — exit 0: 584 tests, 0 failures; SwiftLint zero errors (three pre-existing
warnings, none in a changed file).
