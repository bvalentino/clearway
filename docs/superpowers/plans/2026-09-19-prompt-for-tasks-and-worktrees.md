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
