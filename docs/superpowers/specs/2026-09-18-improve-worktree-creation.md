# Improve worktree creation

**Date:** 2026-09-18
**Base:** 7ae81c1e (`Add worktree statuses and three sidebar view modes (#220)`)
**PR:** #226

The New Worktree sheet takes a branch name, a base branch and a fetch toggle — three pieces of git
plumbing and nothing about the work. This change puts a **Name** and a **Status** at the top of the
sheet, derives the branch from the name until the user takes the branch field over, and folds base
branch and fetch into a collapsed **Advanced** disclosure. Name and status are stored in the
worktree's own git config (`clearway.name`, `clearway.status` in `config.worktree`) rather than in
Clearway's `groups.json`, so they are deleted with the worktree, readable by any tool, and need no
reconcile, no pruning and no watcher. Statuses already in `groups.json` migrate across once and the
key stops round-tripping. Groups, order and grouping mode stay in `groups.json` for the follow-up
task that deletes it.

## Decisions

| # | Question | Decision | Source |
| --- | --- | --- | --- |
| 1 | Where do name and status live? | Per-worktree git config: `clearway.name` and `clearway.status` written with `git config --worktree`, which lands in `$GIT_DIR/config.worktree`. Clearway enables `extensions.worktreeConfig` on the repo when absent, following git-worktree(1): if `core.bare` or `core.worktree` are in `$GIT_DIR/config` they move to the main worktree's `config.worktree` first. | Operator |
| 2 | Does anything watch git config for external edits? | No. There is no watcher for worktree config. Values are re-read when the worktree list changes (decision 12). | Operator |
| 3 | What is a sidebar row's primary text? | The stored name, when there is one. The TASK.md title fills the slot only when no name is stored; the branch is the subtitle in both cases, and the whole row falls back to the branch when neither exists. | Operator |
| 4 | What is the slug rule, and when does a name touch the branch field? | Lowercase; ASCII letters and digits kept; every other run of characters becomes one hyphen; leading and trailing hyphens trimmed; no prefix. `"Fix login Bug!"` → `fix-login-bug`. Typing a name regenerates the branch only while the branch field has never been edited by hand; editing it by hand stops that, and clearing it back to empty resumes it. | Operator |
| 5 | Is the name required, and can it be changed later? | Optional — Branch name stays the only required field. A "Rename…" item in the non-main worktree row's context menu edits it later. The main worktree gets no name, no status and no Rename item. | Operator |
| 6 | What does the Status picker default to, and which icons does it use? | In progress. The picker, the section headers and the row badge use the SF Symbols from the `status-with-icons` branch (`circle`, `circle.lefthalf.filled`, `circle.inset.filled`, `checkmark.circle.fill`, `pause.circle`) and its repainted colours, which reach `main` before the build phase starts. This branch invents no symbol and touches no colour. | Operator |
| 7 | What is in the Advanced disclosure? | Base branch and "Fetch before creating", collapsed by default. The sheet keeps its fixed 320pt width and grows in height when expanded. | Operator |
| 8 | Who owns the published `names` and `statuses`? | `WorktreeGroupManager`, alongside the `statuses` it already publishes — only the backing store changes. The alternative, a second `@MainActor` observable injected into it, loses: the sidebar rows, the search predicate, the status badge, the `⌘N` badge and `ContentView`'s `⌘1…9` list must all read one object (decision 12 of the status spec), so a split would add an observation edge plus a third `@EnvironmentObject` at three call sites for no user-visible gain, and the follow-up task will collapse the two back together when it deletes `groups.json`. The manager is not renamed, on the precedent of that spec's decision 13. | Spec author |
| 9 | Where does the git plumbing live? | A new `WorktreeConfigStore` (`Sources/App/WorktreeConfigStore.swift`), `nonisolated` and `Sendable`, owning the extension bootstrap, the read, the write and the unset. This is the reusable seam the follow-up needs; the manager holds the published state, the store holds the commands. Its argument building and output parsing are pure `static` functions so XCTest can pin them without a repository. | Spec author |
| 10 | The extension must be enabled **before** the first write, not after. | `git config --worktree` is documented as "the same as `--local`" when `extensions.worktreeConfig` is off, and a scratchpad probe confirms the write lands in the shared `.git/config`, where every worktree would then read one name. So `WorktreeConfigStore` enables the extension (and performs the `core.bare`/`core.worktree` move) before any write, and reads return empty when the extension is off rather than falling back to `--local`. That also means a project that has never used the feature costs zero `git config` processes per refresh. | Spec author |
| 11 | How are the two keys read, and how is git's own `core.bare` line kept out? | One process per worktree: `git config --worktree --list --null`, whose output is NUL-separated records of `key\nvalue`, so a value containing a newline survives. The parser keeps only keys with the `clearway.` prefix — `git worktree add` seeds `core.bare = false` into a new worktree's `config.worktree` once the extension is on, and a prefix filter is what stops that from reaching the app. | Spec author |
| 12 | What triggers a re-read? | `ContentView`'s existing `.onChange(of: worktreeManager.worktrees)`, inside the guard that already skips a failed or empty refresh (`ContentView.swift:337-342`). `reconcile(knownWorktreeIds:)` widens to `reconcile(_ worktrees: [Worktree])` and both prunes group membership and reloads the config, so the call site changes rather than grows: `ContentView.swift` is past SwiftLint's 1000-line `file_length` error and lives on a file-wide `swiftlint:disable`, and CLAUDE.md says the next addition there needs a split first. | Spec author |
| 13 | Is `WorktreeManager.runCommand` made `nonisolated`? | Yes, as part of this change. It is `static` on a `@MainActor` class and carries no `nonisolated`, so under `SWIFT_VERSION: "6.0"` it is main-actor isolated and every `git` subprocess — `run()`, two blocking `readDataToEndOfFile()` calls and `waitUntilExit()` — executes on the main actor; `Task.detached { try await Self.runCommand(…) }` hops straight back. It touches only locals, `GitResolver`'s statics and `ShellEnvironment.processEnvironment` (a plain `enum`), so the keyword is the whole change. Without it this task multiplies main-actor subprocess spawns by the worktree count on every refresh. The pre-existing freeze it also fixes is recorded as a follow-up finding, not claimed as this task's objective. | Operator |
| 14 | How does `groups.json` stop carrying statuses? | `statuses` leaves `WorktreeGroupsPayload`'s `CodingKeys`, so `save()` can no longer write it, and `init(from:)` decodes the old key into a separate `legacyStatuses` property through its own key type. On load, a non-empty `legacyStatuses` is written to each recorded path's worktree config and then `save()` is called at once, which rewrites the file without the key. Writing to a path that no longer exists fails and is skipped. | Spec author |
| 15 | Does the migration need to know which worktree is main? | No. A status key is already the worktree's path (`Worktree.id`), so the migration writes with `git -C <path>` and never needs the live list. Main's own entry, if a hand-edited file carries one, is harmless: `status(for:)` already refuses to report a status for main and documents why (`WorktreeGroupManager.swift:163-170`). | Spec author |
| 16 | Is a vanished worktree's name or status pruned? | Nothing to prune. `git worktree remove` deletes `$GIT_COMMON_DIR/worktrees/<id>/`, and its `config.worktree` with it — verified by probe. So `reconcile` loses its status-pruning branch and gains no name-pruning branch. | Spec author |
| 17 | Where does the branch-field ownership rule live? | In a pure `WorktreeDraft` value type (`Sources/App/WorktreeDraft.swift`) holding `name`, `branch` and whether the branch has been hand-edited, with `setName` and `setBranch` as the only mutators. A SwiftUI `.onChange(of: branchName)` cannot tell a user keystroke from the name-driven write it would itself trigger, so the branch `TextField` binds to a `Binding` whose setter is `setBranch` — the user-edit path — while `setName` writes the state directly. Nothing in a SwiftUI body is reachable from XCTest, which is why the rule is a type and not a closure. | Spec author |
| 18 | Does the branch field keep today's space→hyphen sanitising? | Yes, on the hand-edit path only. A branch may legitimately contain `/`, `_` and `.`, so `setBranch` sanitises exactly what the sheet sanitises today (`SidebarSheets.swift:23-26`) and does not run the full slug rule over the user's typing. | Spec author |
| 19 | Where is `rowTexts` decided? | Lifted out of `SidebarView`'s `private func rowTexts(for:titles:)` (`SidebarView.swift:470-480`) into a pure `static` that takes the worktree, the stored name and the task title, so decision 3's precedence is testable. Same lift the status spec made for `matches` (its decision 20). | Spec author |
| 20 | Does search match the name? | Yes. `WorktreeGroupManager.matches(_:query:taskTitle:)` gains the stored name beside the branch, task title, group name and status name it already tries. Its signature does not change: the name comes from the manager's own map, as the status already does. | Spec author |
| 21 | How is git-backed storage tested without making every test spawn git? | Split. The argument builders, the `--list --null` parser, the slug rule, the draft's ownership truth table, the row-text precedence and the payload's wire format are pure and tested directly. One integration suite builds a real repository in a temp directory — `git init`, a commit, `git worktree add` — and pins the extension bootstrap, the `core.bare` move and the name/status round trip. It is the first suite in the project to spawn `git`; CI runs on `macos-26` where `/usr/bin/git` is what checks the repository out. | Spec author |
| 22 | Does any of this get a menu command or keyboard shortcut? | No. `AppKeyboardShortcuts` is untouched, on the same terms as the status spec's decision 23. | Operator |
| 23 | How is each field in the New Worktree sheet labelled? | A persistent label above the control, for Name, Branch name, Status and Advanced's Base branch. The text fields lose their placeholders, the Status picker's inline label is hidden with `.labelsHidden()` and keeps its symbols, and the "(new branches only)" parenthetical is dropped. No helper copy. "Fetch before creating" stays a plain toggle and the Advanced full-row button is unchanged. `CommandEditorSheet`'s private `field(_:content:)` is lifted into a shared `LabeledField` (`Sources/App/LabeledField.swift`) so the two sheets cannot drift. The treatment then covers all four sheets in `SidebarSheets.swift`: `RenameWorktreeSheet`, `RenameGroupSheet` and `NewGroupSheet` each put a persistent "Name" label above their single text field and drop its placeholder, with no helper copy and their title, buttons, width and behaviour unchanged. | Operator |

## Assumptions

Each verified against the codebase at base `7ae81c1`, against git-scm.com documentation fetched
2026-09-18, or by probe. The probes were shell scripts run in the session scratchpad against
throwaway repositories; nothing was written into the repo.

1. **`git config --worktree` silently degrades to `--local` when the extension is off.**
   git-config(1), fetched 2026-09-18: "Similar to `--local` except that `$GIT_DIR/config.worktree`
   is read from or written to if `extensions.worktreeConfig` is enabled. If not it's the same as
   `--local`." Probe: `git config --worktree clearway.name hello` on a fresh repo exited 0 and the
   value appeared under `[clearway]` in `.git/config`. This is what decision 10 guards.
2. **git-worktree(1) prescribes the `core.bare` / `core.worktree` move.** Fetched 2026-09-18: "Note
   that in this file, the exception for `core.bare` and `core.worktree` is gone. If they exist in
   `$GIT_DIR/config`, you must move them to the `config.worktree` of the main worktree."
3. **The main worktree's `config.worktree` is `$GIT_COMMON_DIR/config.worktree`, reachable from any
   worktree.** Probe: from a linked worktree, `git rev-parse --git-common-dir` returned the main
   `.git`, and `git config --file "$common/config.worktree" core.bare false` followed by
   `git config --local --unset core.bare` left `git status` working in both worktrees, with the
   linked worktree's `git config --get core.bare` exiting 1. So the bootstrap never needs main's
   worktree path — which matters, because `projectPath` is not necessarily main's path: Clearway is
   routinely opened on a linked worktree.
4. **`core.bare` is present in `$GIT_DIR/config` of essentially every non-bare repository**, so the
   move in decision 1 fires on nearly every project rather than as a rare special case. Probe: a
   plain `git init` wrote `bare = false` under `[core]`. Moving `core.bare = false` is harmless —
   a worktree with no `core.bare` defaults to false — but the bootstrap is a write to the user's
   `.git/config`, which the brief accepts.
5. **A worktree's config does not leak to its siblings.** Probe: with `clearway.name = "MAIN NAME"`
   in main's `config.worktree`, a linked worktree's `git config --worktree --get clearway.name`
   exited 1. What a fresh linked worktree does inherit is git's own `core.bare = false`, seeded into
   `.git/worktrees/<id>/config.worktree` by `git worktree add` once the extension is on — decision
   11's prefix filter is what excludes it.
6. **`--list --null` gives a parseable record even for a multi-line value.** Probe: a value of
   `"line1\nline2"` came back as `clearway.name\nline1\nline2\0`, i.e. one NUL-terminated record
   whose first newline separates key from value. `--get` on a missing key exits 1 (git-config(1),
   "Returns error code 1 if key is not present"), and `--unset` on a missing key exits 5.
7. **Removing a worktree removes its config.** Probe: after `git worktree remove --force`,
   `.git/worktrees` was gone. Decision 16 rests on this.
8. **A worktree's identity is its path, and that is the key `statuses` already uses.**
   `Worktree.id` is `path ?? branch ?? ""` (`Worktree.swift:19`), and `setStatus` keys `statuses`
   by it (`WorktreeGroupManager.swift:174-179`). So the migration in decision 14 can use a stored
   key directly as a `git -C` directory.
9. **`Worktree` is the `List` selection tag, so name and status must not become its properties.**
   `DetailSelection.worktree(Worktree)` is `Hashable` (`ContentView.swift:18-22`) and rows carry
   `.tag(DetailSelection.worktree(wt))` (`SidebarView.swift:506`); `ContentView.swift:346-348`
   already has to re-seed the selection whenever a refreshed instance differs. Adding a mutable
   `name` would drop the sidebar selection on every rename. Decision 8's shared-map shape avoids it.
10. **`WorktreeManager.runCommand` is main-actor isolated today.** The class is `@MainActor`
    (`Worktree.swift:77-78`) and `runCommand` (`Worktree.swift:362-363`) and `fetchWorktrees`
    (`Worktree.swift:355`) carry no `nonisolated`, unlike `parseWorktreeListOutput`, `gitdir`,
    `inProgressOp`, `applyHeadResolution` and `fetchPRStatus`, which do. Under Swift 6 a `static`
    member of a `@MainActor` type inherits that isolation. Decision 13.
11. **`ShellEnvironment` is a plain `enum` with `static` computed properties**
    (`ShellEnvironment.swift:8,14,23`), so making `runCommand` `nonisolated` needs nothing else.
12. **The one guarded refresh hook decision 12 uses already exists and already skips a bad
    refresh.** `ContentView.swift:337-342` gates `reconcile`, `seedDefaultOrder`, `pruneStale` and
    `prunePRStatuses` on `!newWorktrees.isEmpty && worktreeManager.error == nil`.
13. **`WorktreeGroupsPayload.init(from:)` is already hand-written and already lenient**
    (`WorktreeGroupStore.swift:39-47`), so decision 14's separate legacy key type drops into a file
    that is already shaped for it, and the existing wire-format test keeps its job.
14. **`SidebarView.swift` has room, `ContentView.swift` does not.** `.swiftlint.yml` sets
    `file_length` warning 700 / error 1000; `SidebarView.swift` is 653 lines and `ContentView.swift`
    is 1028 behind a file-wide disable. The Rename item and its sheet presentation are roughly a
    dozen lines, which keeps `SidebarView.swift` under the warning; the sheet itself goes in
    `SidebarSheets.swift` (152 lines).
15. **`status-with-icons` is two commits of symbol and colour work over `main` and touches four
    source files**, `WorktreeStatus.swift` among them (`git diff --stat main...status-with-icons`).
    Its `WorktreeStatus.symbol` is the property decision 6 refers to. This branch reads it and does
    not redefine it.
16. **A new Swift file is invisible to the build until `xcodegen generate` runs.** `project.yml`
    globs `Sources` and `Tests` by path and `./scripts/ci.sh` regenerates the project, which is why
    it is the only verification command here.

## Objective

Creating a worktree should be a sentence about the work — a name, a status — with the git details
available but out of the way, and what the operator wrote should live with the worktree in git's own
storage rather than in a Clearway file that has to be reconciled against reality.

### Success criteria

1. The New Worktree sheet shows Name, Branch name, Status, then a collapsed Advanced disclosure
   holding Base branch and Fetch before creating. Create is disabled while Branch name is empty.
2. Typing `Fix login Bug!` into Name fills Branch name with `fix-login-bug`. Editing Branch name by
   hand stops further name-driven changes; clearing Branch name to empty resumes them.
3. Creating a worktree with a name and a status writes both: from the new worktree,
   `git config --worktree --get clearway.status` prints the slug and `--get clearway.name` prints
   the name. Leaving Name empty writes no `clearway.name`.
4. `extensions.worktreeConfig` is set on the repository on first need, and a repository with
   `core.bare` or `core.worktree` in `.git/config` has them moved to the main worktree's
   `config.worktree`, with `git status` still working in the main worktree and in a linked one.
5. Changing a status from the row's context menu, or by dragging a row onto a status section header,
   lands in that worktree's `config.worktree` and nowhere in `groups.json`.
6. A `groups.json` carrying `statuses` loads once: the statuses appear in the matching worktrees'
   config, the file is rewritten without the key, and the sidebar shows the same statuses it showed
   before. A `groups.json` without the key still loads its groups and default order.
7. A sidebar row for a named worktree shows the name over the branch. With no name and a linked
   TASK.md it shows the task title over the branch. With neither it shows the branch alone.
8. Typing part of a stored name into the sidebar filter matches that worktree.
9. "Rename…" in a non-main worktree's context menu opens a sheet pre-filled with the current name;
   saving changes the row and the config, and saving an empty field clears the name.
10. The main worktree has no name, no status and no Rename item, and its `config.worktree` is not
    written by any of these gestures.
11. Removing a worktree removes its name and status with it; nothing prunes and nothing is left
    behind in `groups.json`.
12. `./scripts/ci.sh` is green and `swiftlint lint --quiet` reports no new warnings or errors.

### Test coverage this requires

Criteria 1, 5's drag half, 7 and 9's sheet are SwiftUI view state, confirmed by hand in the running
app. Everything else is pinned by XCTest:

- The slug rule: the worked example, an all-punctuation input, a leading/trailing-punctuation input,
  a non-ASCII input (`"Café Ausflug"` → `caf-ausflug`, not a transliteration), an empty input.
- `WorktreeDraft`'s truth table: name drives branch before any hand edit; a hand edit stops it; a
  subsequent name change leaves the branch alone; clearing the branch resumes generation; the
  hand-edit path sanitises spaces and leaves `/`, `_` and `.` alone.
- `WorktreeConfigStore`'s pure halves: the argument arrays for read, write and unset, and the
  `--list --null` parser over a single record, two records, a record whose value contains a
  newline, and a record for `core.bare` that must be dropped.
- The row-text precedence: name over task title over branch, including a worktree with a name and
  no task and one with a task and no name.
- `matches` returns true for a name query and keeps its branch, task-title, group-name and
  status-name behaviour.
- `WorktreeGroupsPayload`: the pre-change wire format's literal bytes decode their statuses into
  `legacyStatuses`, and an encode of a payload omits the `statuses` key entirely — asserted over
  bytes, not a round trip, for the reason CLAUDE.md records for `OpenInAppTests`.
- One integration suite over a real temp repository: enabling the extension moves `core.bare` out of
  `.git/config` into main's `config.worktree` and leaves both worktrees usable; a name and a status
  written to a linked worktree read back and are invisible from its sibling; an unset clears one
  key and leaves the other; `git worktree remove` takes the config with it.

## Verification

```bash
./scripts/ci.sh
```

Regenerates the Xcode project, lints, builds and runs the test suite — the regression check for
every build task and the full gate at sign-off, per CLAUDE.md's `## Pipeline` section. It is the
only test runner; do not hand-write an `xcodebuild` line, and new Swift files make
`xcodegen generate` mandatory.

The view-only criteria are confirmed against the running app (`./scripts/run.sh`) on a project with
at least one named worktree, one unnamed worktree with a TASK.md, and the main worktree. Expect the
un-gitignored `default.profraw` in the repo root after any Debug launch; report it before sign-off
and never `git add -A`.

The build phase starts only after `status-with-icons` has merged to `main` and this branch has been
rebased onto it, so that decision 6's symbols exist.

## Files touched

| File | Change |
| --- | --- |
| `Sources/App/WorktreeConfigStore.swift` (new) | The git-config seam: pure `static` argument builders and `--list --null` parser, plus async enable/read/write/unset over `WorktreeManager.runCommand`. Owns the `extensions.worktreeConfig` bootstrap and the `core.bare`/`core.worktree` move. |
| `Sources/App/WorktreeDraft.swift` (new) | The slug rule and the branch-field ownership rule as a pure value type (decisions 4, 17, 18). |
| `Sources/App/SidebarSheets.swift` | `CreateWorktreeSheet` gains Name, Status and the Advanced disclosure, and drives its fields through a `WorktreeDraft`; a new `RenameWorktreeSheet` joins it. |
| `Sources/App/SidebarView.swift` | "Rename…" in the non-main worktree context menu and its sheet presentation; `rowTexts` moves out (decision 19) and the row is handed the stored name. |
| `Sources/App/WorktreeRow.swift` | The pure row-text precedence helper lands here beside the view it feeds. |
| `Sources/App/WorktreeGroupManager.swift` | Publishes `names` beside `statuses`, both backed by `WorktreeConfigStore`; `setName`, `name(for:)`; `setStatus` writes config; `matches` tries the name; `reconcile` widens to take `[Worktree]`, reloads the config and drops its status-pruning branch; the one-shot `legacyStatuses` migration. |
| `Sources/App/WorktreeGroupStore.swift` | `WorktreeGroupsPayload` stops encoding `statuses` and decodes the old key into `legacyStatuses` (decision 14). |
| `Sources/App/Worktree.swift` | `runCommand` becomes `nonisolated` (decision 13). |
| `Sources/App/ContentView.swift` | One changed line: the `reconcile` call in the guarded `onChange` passes the worktrees (decision 12). No addition. |
| `Tests/WorktreeDraftTests.swift` (new) | Slug rule and branch-ownership truth table. |
| `Tests/WorktreeConfigStoreTests.swift` (new) | Argument builders, `--list --null` parsing, and the real-repository integration suite (decision 21). |
| `Tests/WorktreeGroupManagerStatusTests.swift` | Status cases re-pointed at worktree config; the `groups.json` probe assertions become "writes no status". |
| `Tests/WorktreeGroupManagerTests.swift` | `reconcile`'s new signature; `matches` with a name query. |
| `Tests/WorktreeGroupStoreTests.swift` | Legacy `statuses` decodes into `legacyStatuses`; an encode omits the key. |
| `Tests/WorktreeRowTests.swift` (new) | Row-text precedence. |
| `docs/superpowers/specs/2026-09-18-improve-worktree-creation.md` | This document. |
| `docs/superpowers/plans/2026-09-18-improve-worktree-creation.md` | The plan, written by the next stage. |

## Out of scope

- Moving groups, `defaultOrder` and the grouping mode out of `groups.json`. That is the follow-up
  task, which deletes the file, its store and its watchers.
- Any watcher for worktree config, and any reaction to an external edit of it (decision 2).
- Any change to TASK.md, `WorkTaskCoordinator` or the `status` frontmatter CLAUDE.md records as
  written but never rendered.
- A configurable or per-project branch prefix.
- Menu commands and keyboard shortcuts; `AppKeyboardShortcuts` is untouched (decision 22).
- Showing the name anywhere but the sidebar row and the sidebar filter — no toolbar, window title,
  task window or status bar surface.
- New statuses, renamed statuses, custom colours, and the symbols themselves, which arrive on
  `main` from `status-with-icons` (decision 6).
- Validating that a name is unique, or deriving anything else from it.
- Making `fetchWorktrees` `nonisolated`, or any other main-actor audit beyond the single keyword
  decision 13 needs.
- The known `WorktreeGroupStore.openFileWatcher` fd leak recorded in CLAUDE.md.
