# Project-Specific Saved Commands

**Date:** 2026-09-18
**Base:** 7ae81c1fca4c52beaf290a2035746c975ff95c69
**PR:** #225

Saved commands (PR #216) are one global list at `~/.clearway/commands.json`, held by a process-wide
`SavedCommandManager` injected into every project window. A command like "Build & run" only makes
sense for one repo, so seeing it in every project is noise. This change makes commands belong to a
project: each project's list lives at `<projectPath>/.clearway/commands.json` beside `groups.json`,
and the manager becomes per project window. The global list and its code path are removed outright —
nothing reads, migrates or deletes the old file.

## Decisions

| # | Question | Decision | Source |
| --- | --- | --- | --- |
| 1 | Where are a project's commands stored? | `<projectPath>/.clearway/commands.json`, shared by every worktree of the repo. Not the UserDefaults-keyed-by-path-hash shape the hooks use. | Operator |
| 2 | Watch the file for outside edits? | No. Load once per project window; an edit made in a text editor or by `git pull` shows after the window is reopened. | Operator |
| 3 | What happens to the old `~/.clearway/commands.json`? | Ignored. The code path is removed, no migration, no deletion. The feature is unreleased, so there is no backward compatibility to keep. | Operator |
| 4 | What is a project's identity for this? | `WorktreeManager.projectPath` — the repo root the window was opened for. No new id, name, or git-config metadata. | Operator (brief, Constraints) |
| 5 | Which worktree's `.clearway` is read when a secondary worktree is selected? | Always the project root's. A `commands.json` checked out differently on a branch must not change what the Run dropdown shows. | Operator (brief, Constraints) |
| 6 | Does `SavedCommandStore` take a directory or a project path? | A project path, and the store owns the `.clearway` component — the shape `WorktreeGroupStore` already uses (`WorktreeGroupStore.swift:67-78`). Passing a pre-joined directory would put the same knowledge in two places and let a caller point the store anywhere. Tests keep their seam by passing `tempRoot` as the project path, exactly as `WorktreeGroupStoreTests.swift:13` does. | Spec |
| 7 | Who owns the manager? | `ProjectContentView`, as a `@StateObject` built in its `init` from `projectPath` — the same place and shape as `WorktreeGroupManager` and `WorkTaskManager` (`ProjectWindow.swift:85-102`). Not `ClearwayApp`: a scene-level `@StateObject` is one instance for the process, which is exactly what is being removed. | Spec |
| 8 | Does the manager keep its `hasLoaded` guard? | Yes, with its reasoning restated. Its original job (several windows racing one process-wide read) is gone, but `.task` can re-run when a view disappears and reappears, and a second read landing while a save is in flight would replace the live list with the pre-save file. | Spec |
| 9 | Do the view layers change? | Only doc comments. `CommandsView`, `RunCommandMenu`, `CommandEditorSheet` and `NewCommandMenuItem` already resolve the manager from the environment or a focused value, so scoping the injection per window scopes them with no call-site change. | Spec |

## Assumptions

Each verified by reading the codebase at base `7ae81c1`. No probe scripts or temporary files were
written, into the repo or the scratchpad; nothing here needed an empirical probe.

1. **`projectPath` is the repo root a window was opened for, and it is already the per-project file
   root.** `WorktreeManager.projectPath` is a `let` set once in `init` (`Worktree.swift:79,87-89`),
   and `ProjectContentView.init` passes the same string to `WorktreeManager`, `WorkTaskManager` and
   `WorktreeGroupManager` (`ProjectWindow.swift:85-91`). `WorktreeGroupStore` joins `.clearway` onto
   it (`WorktreeGroupStore.swift:78`) and `WorkTaskManager` joins `.clearway/tasks`
   (`WorkTaskManager.swift:36`). Decision 1 puts `commands.json` in the folder those two already
   create.
2. **A secondary worktree never reaches the store.** Nothing in the command path takes a worktree
   path: `RunCommandMenu` passes the selected `Worktree` to `TerminalManager.run`
   (`RunCommandMenu.swift:27`), not to the manager, and the manager's only input will be the
   window's `projectPath`. Decision 5 therefore needs no guard — it is a property of where the
   manager is constructed.
3. **The manager is currently process-wide and that is the only thing making commands global.**
   `ClearwayApp` holds `@StateObject private var savedCommandManager = SavedCommandManager()`
   (`ClearwayApp.swift:130`) and injects it into the project `WindowGroup` with
   `.environmentObject(savedCommandManager)` plus `.task { await savedCommandManager.load() }`
   (`ClearwayApp.swift:163-164`). No other scene injects it; `WorkTaskWindow`, `PromptWindow` and
   `Settings` do not reference it (`ClearwayApp.swift:212-231`).
4. **Every consumer reads the manager out of the environment.** `CommandsView.swift:6`,
   `RunCommandMenu.swift:6` and `CommandEditorSheet.swift:7` each declare
   `@EnvironmentObject private var savedCommandManager: SavedCommandManager`. `CommandEditorSheet`
   is presented by `CommandsView`'s `.sheet` (`CommandsView.swift:50-52`), which inherits the
   presenting view's environment, so it resolves the same per-window instance.
5. **File > New Command is already per window.** `NewCommandMenuItem` reads
   `@FocusedValue(\.newCommandAction)` (`ClearwayApp.swift:365`), published by `CommandsView` with
   `.focusedSceneValue(\.newCommandAction) { openEditor(nil) }` (`CommandsView.swift:49`). The
   action closes over that window's `CommandsView`, so once the manager is per window the menu item
   targets the front window's project with no change.
6. **The corrupt-file and permission behaviours to preserve are concrete and tested.** `load()`
   moves an unreadable or undecodable file to `commands.json.corrupt` before returning `[]`
   (`SavedCommandStore.swift:39-77`); `save()` creates the directory `0o700`, writes a `0o600` temp
   file and `replaceItemAt`s over the final path (`SavedCommandStore.swift:80-118`). Both are pinned
   by `SavedCommandStoreTests` (`testSaveCreatesDirectoryAndFileWithRestrictivePermissions:96`,
   `testLoadMovesACorruptFileAsideWithItsOriginalBytes:177`). Only the paths change.
7. **The test seam survives as a project path.** `SavedCommandStoreTests.swift:13` builds
   `SavedCommandStore(directory: tempRoot)` and `SavedCommandManagerTests.swift:14-15` builds a
   store plus `SavedCommandManager(store:)`. `TempRootTestCase` hands out a fresh
   `NSTemporaryDirectory()` path and deletes it on teardown (`Tests/TestHelpers.swift`), so passing
   it as `projectPath` works unchanged — the asserted file path gains a `.clearway/` component.
8. **`SavedCommand` and its tests are untouched.** `Tests/SavedCommandTests.swift` covers the model
   and the `SavedCommand` → `CommandLaunch` resolver and names neither the store nor the manager.
9. **`.clearway` is not gitignored in this repo and the app does not write a `.gitignore` for it.**
   `.gitignore` lists no `.clearway` entry. Whether a project commits the folder is the user's
   choice, which is what the merge-conflict risk below records.

## Objective

A project's saved commands belong to that project. With projects A and B open, A's Commands view and
A's Run dropdown show A's list only, and editing A writes only A's file.

### Success criteria

1. With projects A and B open in separate windows, a command added in A's Commands view appears in
   A's Commands view and A's Run dropdown, and in neither of B's.
2. Adding the first command in project A creates `<A>/.clearway/` (mode `0o700` if absent) and
   `<A>/.clearway/commands.json` (mode `0o600`), written through a temp file and renamed into place.
   Nothing under `<B>` and nothing under `~/.clearway` is touched.
3. Selecting any worktree of project A in A's window shows the same Run dropdown items, because the
   list is read from A's project root regardless of the selected worktree.
4. Reorder, edit and delete in A's Commands view persist to `<A>/.clearway/commands.json` only, and
   array order stays display order.
5. A corrupt `<A>/.clearway/commands.json` is moved aside to `commands.json.corrupt` and A starts
   with an empty list, replacing any older `.corrupt` file — the behaviour the global store has
   today.
6. With no commands in a project, that window's Run dropdown is disabled and its Commands view shows
   the existing empty state.
7. No source file, test or document references `~/.clearway/commands.json`. An existing file there on
   a dev machine is ignored, not read, not migrated, not deleted.
8. File > New Command adds to the front window's project.

### Test coverage this requires

- `SavedCommandStoreTests` reconstructed against `SavedCommandStore(projectPath: tempRoot)`, with
  every path assertion moved to `<tempRoot>/.clearway/commands.json`, `.tmp` and `.corrupt`. The
  directory-creation case asserts `0o700` on `<tempRoot>/.clearway` rather than on `tempRoot`
  itself, which the test harness creates.
- A new store case: two stores over two different project paths do not see each other's commands —
  saving through one leaves the other's `load()` empty. This is the one behaviour the change exists
  for and nothing else pins it.
- `SavedCommandManagerTests` reconstructed the same way. `testASecondLoadDoesNotRereadTheFile` stays:
  Decision 8 keeps the guard, so the case keeps its subject.
- No new view test. `CommandsView` and `RunCommandMenu` gain no logic; the per-window wiring is
  `@StateObject` ownership in `ProjectContentView`, which XCTest cannot exercise without a running
  scene. This matches the split the project already makes for `Ghostty.SurfaceView`.

## Verification

```bash
./scripts/ci.sh
```

Regenerates the Xcode project, lints, builds and runs the test suite — the same gate
`.github/workflows/ci.yml` applies to a PR. It is the regression check for every build step and the
full gate at sign-off. New Swift files are invisible to the build until `xcodegen generate` runs, so
no hand-written `xcodebuild` line substitutes for it.

```bash
swiftlint lint --quiet
```

Runs as a post-build phase; zero errors required. Note `ContentView.swift` is past SwiftLint's
1000-line `file_length` error and survives only on its file-wide disable — this change adds nothing
to it.

```bash
git status --porcelain
```

Before any CI stamp or sign-off. Expect the un-gitignored `default.profraw` after any Debug launch;
untracked files block sign-off.

## Files touched

- `Sources/App/SavedCommandStore.swift` — `init(projectPath:)` replaces `init(directory:)`; the
  three paths hang off `<projectPath>/.clearway/`. No default value: every caller names a project.
  Load, save, temp-file and move-aside logic unchanged. Doc comment restated for the per-project
  file.
- `Sources/App/SavedCommandManager.swift` — `init(projectPath:)` building its own store, as the only
  initializer: the `init(store:)` test seam is removed, since a test builds its own store on the
  same project path. Doc comments on the type and on `load()` restated: one manager per project
  window, `hasLoaded` justified by Decision 8 rather than by process-wide sharing.
- `Sources/App/ProjectWindow.swift` — `ProjectContentView` gains
  `@StateObject private var savedCommandManager`, built in `init` from `projectPath` alongside the
  other per-project managers, injected with `.environmentObject` and loaded with
  `.task { await savedCommandManager.load() }` in `body`.
- `Sources/App/ClearwayApp.swift` — remove the `@StateObject` at line 130 and the
  `.environmentObject` / `.task` pair at lines 163-164.
- `Sources/App/CommandsView.swift` — doc comment: "the global, ordered list" becomes the project's
  ordered list.
- `Sources/App/RunCommandMenu.swift` — doc comment: "every saved command" becomes the project's
  saved commands.
- `Tests/SavedCommandStoreTests.swift` — construction and path helpers move to the project-path
  shape; the cross-project isolation case is added here.
- `Tests/SavedCommandManagerTests.swift` — construction moves to the project-path shape.
- `CLAUDE.md` — the `SavedCommandStore` bullet (lines 201-204) is rewritten: the file is
  `<projectPath>/.clearway/commands.json`, one list per project shared by that repo's worktrees,
  array order is display order, and the no-watcher reasoning is restated for a per-window manager
  (the app is still the only writer; an outside edit is picked up when the window reopens).

## Out of scope

- Global commands, or commands shared across projects.
- Migrating, reading or deleting the existing `~/.clearway/commands.json`.
- Watching the commands file for outside edits (Decision 2). A follow-up if it turns out to matter.
- Per-worktree commands.
- Any change to how a command runs — `TerminalManager.run`, `TerminalManager+Commands.swift`,
  `ShellSend`, `CommandLaunch` — or to the command editor's fields.
- Any change to the Commands sidebar destination's ⌃3 shortcut, its filter picker, or
  `AppKeyboardShortcuts`.
- Writing or amending a project's `.gitignore` for `.clearway`.

## Open risks

- A team that commits `.clearway/commands.json` can produce merge conflicts when two people edit it
  in the app. Accepted.
- Without a watcher, a `git pull` that changes the file is not reflected until the window is
  reopened. Accepted (Decision 2).
- Two windows open on the same project would each own a manager, and the later save would win. The
  app already carries this exposure for `groups.json` — `WorktreeGroupManager` is likewise built per
  window from `projectPath` (`ProjectWindow.swift:91`) — and covers it with a watcher, which
  Decision 2 declines here. Whether SwiftUI's `openWindow(value:)` can even produce a second window
  for the same value was not verified: the `OpenWindowAction` documentation page returned no body
  when fetched on 2026-09-18. Accepted as the same shape of risk as the `git pull` one.
