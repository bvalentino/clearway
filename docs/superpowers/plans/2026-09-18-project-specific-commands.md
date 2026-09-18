# Project-specific saved commands — implementation plan

**Date:** 2026-09-18
**Base:** 7ae81c1fca4c52beaf290a2035746c975ff95c69

Breaks down `docs/superpowers/specs/2026-09-18-project-specific-commands.md`. Every design decision
below is carried from that spec; this document only orders the work and says how each piece is
verified.

## Architecture decisions carried from the spec

- A project's saved commands live at `<projectPath>/.clearway/commands.json`, beside `groups.json`.
  One list per repo, shared by every worktree of it.
- `SavedCommandStore` takes a **project path**, not a directory, and owns the `.clearway` component
  itself — the shape `WorktreeGroupStore` already uses (`WorktreeGroupStore.swift:67-78`). There is
  no default value: every caller names a project.
- `projectPath` is the project's identity — `WorktreeManager.projectPath`, the repo root the window
  was opened for. No new id, name, or git-config metadata.
- The store is always read from the **project root**, never from the selected worktree. Nothing in
  the command path passes a worktree path, so this needs no guard: it is a property of where the
  manager is constructed.
- `SavedCommandManager` is owned by `ProjectContentView` as a `@StateObject` built in its `init`
  from `projectPath`, alongside `WorktreeManager`, `WorkTaskManager` and `WorktreeGroupManager`
  (`ProjectWindow.swift:83-102`). Not by `ClearwayApp`: a scene-level `@StateObject` is one instance
  for the process, which is what is being removed.
- The manager keeps `hasLoaded`. Its original job (several windows racing one process-wide read) is
  gone, but `.task` can re-run when a view disappears and reappears, and a second read landing while
  a save is in flight would replace the live list with the pre-save file.
- No watcher. The app is the only writer; an edit made in a text editor or by `git pull` shows after
  the window is reopened.
- `~/.clearway/commands.json` is ignored outright: no migration, no read, no deletion. The feature
  is unreleased.
- Load, save, temp-file, permission and move-aside logic are unchanged. Only the paths change.
- `init(store:)` stays on the manager as the test seam. Tests pass `tempRoot` as the project path,
  exactly as `WorktreeGroupStoreTests.swift:13` does.
- No view layer changes beyond doc comments. `CommandsView`, `RunCommandMenu`, `CommandEditorSheet`
  and `NewCommandMenuItem` already resolve the manager from the environment or a focused value, so
  scoping the injection per window scopes them with no call-site change.

## Dependency graph

```
T1: move manager ownership to ProjectContentView (still the global file)
      │
      ▼
T2: store + manager take a project path; tests reconstructed
      │
      ▼
T3: doc comments and CLAUDE.md
```

The order is forced by what compiles. `SavedCommandManager()` and `SavedCommandStore()` both carry
default initializers today, and `ClearwayApp.swift:130` uses the first of them. Removing those
defaults in the same step that moves ownership would touch six files at once. T1 moves ownership
while the initializers still have defaults; T2 then removes the defaults with every remaining caller
already inside `ProjectContentView`. Each task leaves the app building and running.

## Task list

### T1: Move SavedCommandManager ownership into ProjectContentView

**Files touched**

- `Sources/App/ClearwayApp.swift`
- `Sources/App/ProjectWindow.swift`

**What it does**

Removes `@StateObject private var savedCommandManager = SavedCommandManager()`
(`ClearwayApp.swift:130`) and the `.environmentObject(savedCommandManager)` /
`.task { await savedCommandManager.load() }` pair on the project `WindowGroup`
(`ClearwayApp.swift:163-164`).

Adds `@StateObject private var savedCommandManager` to `ProjectContentView`. In this task it is
still built with the no-argument `SavedCommandManager()` — the project path is wired in T2 — and it
is declared as a plain property initializer (`= SavedCommandManager()`) rather than through `init`,
the way `todoManager` and `claudeActivityMonitor` already are (`ProjectWindow.swift:77,80`). In
`body`, inject it with `.environmentObject(savedCommandManager)` and load it with
`.task { await savedCommandManager.load() }` on `ContentView()`.

After this task each project window owns its own manager, but every manager still reads and writes
the same `~/.clearway` file, so behaviour is unchanged. That is intentional: it isolates the
ownership move from the path change.

**Acceptance criteria**

- `ClearwayApp.swift` no longer names `SavedCommandManager` anywhere.
- `ProjectContentView` declares, injects and loads the manager.
- The Commands view and the Run dropdown still list saved commands, and adding one still persists.

**Verification**

- `./scripts/ci.sh` passes. No test changes; the existing `SavedCommandStoreTests` and
  `SavedCommandManagerTests` must stay green unmodified.
- `grep -n 'savedCommandManager\|SavedCommandManager' Sources/App/ClearwayApp.swift` returns nothing.

### T2: Store and manager take a project path

**Files touched**

- `Sources/App/SavedCommandStore.swift`
- `Sources/App/SavedCommandManager.swift`
- `Sources/App/ProjectWindow.swift`
- `Tests/SavedCommandStoreTests.swift`
- `Tests/SavedCommandManagerTests.swift`

**What it does**

`SavedCommandStore`: replace `init(directory: String = "~/.clearway")` with
`init(projectPath: String)` — no default. Store `projectPath` and add a private `clearwayDir`
computed property joining `.clearway` onto it; `commandsFile`, `commandsTempFile` and
`commandsCorruptFile` hang off `clearwayDir`. Drop the tilde expansion: a project path is absolute.
The `directory` value captured by `save()` becomes `clearwayDir`, so the `0o700` directory creation
now creates `<projectPath>/.clearway`. Load, save, temp-file, permission and move-aside logic are
otherwise untouched. Restate the type's doc comment for the per-project file and drop the
"test seam" note on the initializer, which no longer describes it.

`SavedCommandManager`: replace `init(store: SavedCommandStore = SavedCommandStore())` with
`init(projectPath: String)` building its own store, plus a separate `init(store: SavedCommandStore)`
kept as the test seam. Restate the type doc comment ("the process-wide ordered list") as the
project's ordered list, one manager per project window, and restate `load()`'s comment: `hasLoaded`
is justified by `.task` re-running when a view disappears and reappears, not by several windows
racing one process-wide read.

`ProjectWindow.swift`: build the manager in `init` from `projectPath` alongside the other
per-project managers — `_savedCommandManager = StateObject(wrappedValue: SavedCommandManager(projectPath: projectPath))`
— replacing the property initializer T1 added.

`Tests/SavedCommandStoreTests.swift`: `SavedCommandStore(projectPath: tempRoot)`; `commandsFile`,
`corruptFile` and the inline `commands.json.tmp` path move to `<tempRoot>/.clearway/`;
`writeCommandsFile` creates `<tempRoot>/.clearway`.
`testSaveCreatesDirectoryAndFileWithRestrictivePermissions` asserts existence and `0o700` on
`<tempRoot>/.clearway` rather than on `tempRoot`, which `TempRootTestCase` creates itself.
Add one new case: two stores over two different project paths do not see each other's commands —
save a list through a store on `<tempRoot>/a`, then `load()` a store on `<tempRoot>/b` and assert it
is empty, and assert the first still loads its own list. This is the one behaviour the change exists
for and nothing else pins it.

`Tests/SavedCommandManagerTests.swift`: `SavedCommandStore(projectPath: tempRoot)`; every asserted
file path gains the `.clearway/` component. `testASecondLoadDoesNotRereadTheFile` stays as is — the
`hasLoaded` guard is kept, so the case keeps its subject.

**Acceptance criteria**

- `SavedCommandStore` has no default initializer argument and no `~/.clearway` literal.
- Saving in a project creates `<projectPath>/.clearway` at `0o700` and `commands.json` at `0o600`,
  via a temp file renamed into place.
- Two stores on different project paths are isolated; the new test case proves it.
- Corrupt-file move-aside, older-`.corrupt` replacement and empty-load behaviour are unchanged,
  pinned by the existing cases at their new paths.
- With projects A and B open, A's Commands view and Run dropdown show A's list only, and editing A
  writes only `<A>/.clearway/commands.json`.

**Verification**

- `./scripts/ci.sh` passes, including the reconstructed `SavedCommandStoreTests` /
  `SavedCommandManagerTests` and the new cross-project isolation case.
- `grep -rn 'SavedCommandStore(' Sources Tests` shows only `projectPath:` call sites.
- The two-project behaviour is operator-verified by hand; no view test is added. `CommandsView` and
  `RunCommandMenu` gain no logic, and the per-window wiring is `@StateObject` ownership in
  `ProjectContentView`, which XCTest cannot exercise without a running scene — the same split the
  project already makes for `Ghostty.SurfaceView`.

### T3: Restate the doc comments and the CLAUDE.md bullet

**Files touched**

- `Sources/App/CommandsView.swift`
- `Sources/App/RunCommandMenu.swift`
- `CLAUDE.md`

**What it does**

`CommandsView.swift:3-4`: "the global, ordered list of saved commands" becomes the project's ordered
list.

`RunCommandMenu.swift:3-4`: "every saved command" becomes the project's saved commands.

`CLAUDE.md` lines 201-204, the `SavedCommandStore` bullet: the file is
`<projectPath>/.clearway/commands.json`, one list per project shared by that repo's worktrees, always
read from the project root rather than the selected worktree; array order is display order and a
reorder rewrites the file; and the no-watcher reasoning is restated for a per-window manager — the
app is still the only writer, and an outside edit is picked up when the window reopens.

No behaviour changes in this task.

**Acceptance criteria**

- No source file, test or document under `Sources`, `Tests` or `CLAUDE.md` references
  `~/.clearway/commands.json`, a "global" command list, or a process-wide `SavedCommandManager`.
- The CLAUDE.md bullet names the per-project path and the project-root rule.

**Verification**

- `grep -rn 'clearway/commands.json' Sources Tests CLAUDE.md` returns nothing, and
  `grep -rni 'global' Sources/App/CommandsView.swift Sources/App/RunCommandMenu.swift Sources/App/SavedCommandStore.swift Sources/App/SavedCommandManager.swift`
  returns nothing.
- `./scripts/ci.sh` passes.

## Risks

| Risk | Impact | Handling |
| --- | --- | --- |
| A team that commits `.clearway/commands.json` gets merge conflicts when two people edit it in the app | Low | Accepted by the spec. |
| A `git pull` that changes the file is not reflected until the window reopens | Low | Accepted (Decision 2). No watcher. |
| Two windows on the same project each own a manager; the later save wins | Low | Same exposure the app already carries for `groups.json`. Accepted. |
| T1 leaves the app briefly per-window over a global file | None user-visible | Intentional and short-lived; T2 lands the path change immediately after. |

## Build log

### T1: Move SavedCommandManager ownership into ProjectContentView

**What landed**

| File | State |
| --- | --- |
| `Sources/App/ClearwayApp.swift` | `@StateObject private var savedCommandManager = SavedCommandManager()` removed, along with the `.environmentObject(savedCommandManager)` / `.task { await savedCommandManager.load() }` pair on the project `WindowGroup`. The file no longer names `SavedCommandManager`. |
| `Sources/App/ProjectWindow.swift` | `ProjectContentView` declares `@StateObject private var savedCommandManager = SavedCommandManager()` as a plain property initializer, the shape `todoManager` and `claudeActivityMonitor` use. `body` injects it with `.environmentObject(savedCommandManager)` and loads it with `.task { await savedCommandManager.load() }` on `ContentView()`. |

Each project window now owns its own manager. Every manager still reads and writes
`~/.clearway/commands.json`, so behaviour is unchanged — the path change is T2.

**Evidence**

No test was added or changed, and none failed. T1 adds no logic: the change is `@StateObject`
ownership in `ProjectContentView`, which XCTest cannot exercise without a running scene — the split
the spec records under "Test coverage this requires" and the same one the project already makes for
`Ghostty.SurfaceView`. The behaviour T1 could break is that saved commands still load and persist,
which `SavedCommandStoreTests` and `SavedCommandManagerTests` pin unmodified; both stayed green.

Acceptance criterion, run after the last edit:

```
$ grep -n 'savedCommandManager\|SavedCommandManager' Sources/App/ClearwayApp.swift
$ echo $?
1
```

**Deviations from the plan**

None.

**Gate**

`./scripts/ci.sh` — passed after the last edit. `Executed 457 tests, with 0 failures (0 unexpected)`,
`Test Succeeded`, `==> CI passed.` `git status --porcelain` showed only the two modified sources and
the untracked spec and plan, which this commit adds.

### T2: Store and manager take a project path

**What landed**

| File | State |
| --- | --- |
| `Sources/App/SavedCommandStore.swift` | `init(projectPath:)` replaces `init(directory: String = "~/.clearway")`; no default, no tilde expansion. A private `clearwayDir` joins `.clearway` onto `projectPath`, and `commandsFile`, `commandsTempFile` and `commandsCorruptFile` hang off it. `save()` captures `clearwayDir` as its `dir`, so the `0o700` creation now makes `<projectPath>/.clearway`. Load, save, temp-file, permission and move-aside logic untouched. Type doc comment restated for the per-project file; the "test seam" note on the initializer is gone. |
| `Sources/App/SavedCommandManager.swift` | `init(projectPath:)` builds its own store; `init(store:)` stays as the test seam. Type doc comment restated as one project's list owned by that project's window, with the no-watcher reasoning; `load()`'s comment and the `hasLoaded` note now cite `.task` re-running when a view disappears and reappears. |
| `Sources/App/ProjectWindow.swift` | `@StateObject private var savedCommandManager: SavedCommandManager`, built in `init` as `SavedCommandManager(projectPath: projectPath)` alongside the other per-project managers, replacing T1's property initializer. |
| `Tests/SavedCommandStoreTests.swift` | `SavedCommandStore(projectPath: tempRoot)`; a `clearwayDir` helper carries the `.clearway` component for `commandsFile`, `corruptFile`, the inline `commands.json.tmp` path and `writeCommandsFile`. `testSaveCreatesDirectoryAndFileWithRestrictivePermissions` asserts absence-before and `0o700` on `<tempRoot>/.clearway`, not on `tempRoot`. New case `testStoresOnDifferentProjectPathsDoNotSeeEachOther`. |
| `Tests/SavedCommandManagerTests.swift` | `SavedCommandStore(projectPath: tempRoot)`; `testASecondLoadDoesNotRereadTheFile` kept, its doc comment restated off "process-wide manager". |

**Evidence**

The new case was watched red against the unfixed behaviour. The fix is that the paths derive from
`projectPath`, so the revert was to make `clearwayDir` ignore it and return one shared directory
(under `NSTemporaryDirectory()` rather than `~/.clearway`, so the probe could not touch a real home
directory):

```
Test Case '-[ClearwayTests.SavedCommandStoreTests testStoresOnDifferentProjectPathsDoNotSeeEachOther]' started.
Tests/SavedCommandStoreTests.swift:138: error: -[ClearwayTests.SavedCommandStoreTests testStoresOnDifferentProjectPathsDoNotSeeEachOther] : XCTAssertEqual failed: ("[Clearway.SavedCommand(id: 11111111-1111-1111-1111-111111111111, name: "Dev server", kind: Clearway.SavedCommand.Kind.terminal, text: "bin/dev", agent: "claude", autoRun: true)]") is not equal to ("[]") - Project B must not see project A's commands
Test Case '-[ClearwayTests.SavedCommandStoreTests testStoresOnDifferentProjectPathsDoNotSeeEachOther]' failed (0.083 seconds).
```

`clearwayDir` was restored and the probe directory removed before the gate ran.

Acceptance greps, run after the last edit:

```
$ grep -rn 'SavedCommandStore(' Sources Tests
Sources/App/SavedCommandManager.swift:22:        self.store = SavedCommandStore(projectPath: projectPath)
Tests/SavedCommandStoreTests.swift:13:        store = SavedCommandStore(projectPath: tempRoot)
Tests/SavedCommandStoreTests.swift:132:        let storeA = SavedCommandStore(projectPath: projectA)
Tests/SavedCommandStoreTests.swift:133:        let storeB = SavedCommandStore(projectPath: projectB)
Tests/SavedCommandManagerTests.swift:14:        store = SavedCommandStore(projectPath: tempRoot)
$ grep -rn '~/.clearway' Sources/App/SavedCommandStore.swift Sources/App/SavedCommandManager.swift; echo $?
1
```

The two-project behaviour itself is operator-verified: the per-window wiring is `@StateObject`
ownership in `ProjectContentView`, which XCTest cannot exercise without a running scene.

**Deviations from the plan**

None.

**Gate**

`./scripts/ci.sh` — passed after the last edit. `Executed 458 tests, with 0 failures (0 unexpected)`,
`Test Succeeded`, `==> CI passed.` `git status --porcelain` showed only the five modified files this
commit carries; no untracked or ignored files.

### T3: Restate the doc comments and the CLAUDE.md bullet

**What landed**

| File | State |
| --- | --- |
| `Sources/App/CommandsView.swift` | Type doc comment: "the global, ordered list of saved commands" becomes "the project's ordered list of saved commands". |
| `Sources/App/RunCommandMenu.swift` | Type doc comment: "every saved command" becomes "the project's saved commands"; the rest of the sentence (saved order, selected worktree's main terminal) is unchanged. |
| `Sources/App/SavedCommandManager.swift` | `move(fromOffsets:toOffset:filter:)`'s comment said a move computed against a visible subset "would rewrite the wrong global positions". That "global" means the unfiltered array, not the removed process-wide list, but it is one of the four files the task's grep covers, so it now reads "the wrong positions in the full array". |
| `CLAUDE.md` | The `SavedCommandStore` bullet names `<projectPath>/.clearway/commands.json`, one list per project shared by that repo's worktrees, the store owning the `.clearway` component as `WorktreeGroupStore` does, and the project-root rule with its reason (a `commands.json` checked out differently on a branch must not change the Run dropdown). Array order as display order is kept verbatim. The no-watcher reasoning is restated for a per-window manager: `SavedCommandManager` is a `@StateObject` on `ProjectContentView` built from `projectPath`, the app is still the only writer, and an outside edit is picked up when the window reopens. |

**Evidence**

No test was added or changed and none failed: this task changes no behaviour, only comments and a
document, so there is nothing a test could watch go red. The acceptance criteria are greps, run
after the last edit:

```
$ grep -rn '~/\.clearway' Sources Tests CLAUDE.md
Sources/App/PromptManager.swift:3:/// Manages reusable prompt files stored in a configurable directory (default `~/.clearway/prompts/`).
Sources/App/SettingsManager.swift:91:    static let defaultPromptsDirectory = "~/.clearway/prompts"
CLAUDE.md:229:    preference, not a saved-command list, so it belongs there rather than in a `~/.clearway` JSON
$ grep -rni 'global\|process-wide' Sources/App/CommandsView.swift Sources/App/RunCommandMenu.swift Sources/App/SavedCommandStore.swift Sources/App/SavedCommandManager.swift; echo $?
1
```

The three surviving `~/.clearway` hits are the prompts directory and the `OpenInApp` bullet
contrasting a `UserDefaults` preference with a `~/.clearway` JSON file. Neither is the commands
file, and both are out of scope.

**Deviations from the plan**

The plan's verification line reads `grep -rn 'clearway/commands.json' Sources Tests CLAUDE.md`
returns nothing. It cannot: the plan and the spec both require `SavedCommandStore`'s doc comment and
the CLAUDE.md bullet to *name* `<projectPath>/.clearway/commands.json`, and T2 already wrote the
first of them. The criterion the grep was standing in for is the acceptance bullet above it — no
reference to `~/.clearway/commands.json` — so that is what was checked.

The plan listed two source files; `SavedCommandManager.swift` is a third, because the task's own
`global` grep covers it and it carried an unrelated use of the word.

**Gate**

`./scripts/ci.sh` — passed after the last edit. `Executed 458 tests, with 0 failures (0 unexpected)`,
`Test Succeeded`, `==> CI passed.` `git status --porcelain` showed only the four modified files this
commit carries; no untracked or ignored files.
