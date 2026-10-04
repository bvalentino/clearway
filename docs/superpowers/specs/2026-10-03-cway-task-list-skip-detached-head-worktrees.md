# cway task list: skip detached-HEAD worktrees like the app does

**Date:** 2026-10-03
**Base:** 8a11de5 (Add cway CLI: create, list, and show tasks, #265)

`cway task list` and `cway task show` read a `TASK.md` from every path `git worktree list`
reports, including a worktree whose HEAD is detached. The app's Tasks list does not: it loads
`TASK.md` only from worktrees that have a branch after head resolution, so a worktree in the middle
of a rebase or bisect counts (its branch is recovered from git's state files) and a bare-detached
worktree, or one in the middle of a cherry-pick, revert, merge or `git am`, does not. This change
moves that rule, and the head resolution it depends on, into `Sources/Shared/`, and has both the app
and the CLI use it, so the CLI sees exactly the tasks the app shows.

## Decisions

| # | Question | Decision | Why |
| --- | --- | --- | --- |
| D1 | Which side changes: should the app start showing detached-HEAD `TASK.md` files, or should the CLI stop? | The CLI stops. The app's shipped behaviour is the rule. | The brief's stated default ("The app's current behaviour is the shipped one, so the default is to make the CLI match it"), confirmed by the operator. |
| D2 | What exactly is the app's rule? | A worktree carries a visible `TASK.md` when, after `applyHeadResolution`, it has both a branch and a path. So `.attached`, `.rebasing` and `.bisecting` worktrees count; `.detached` and `.inProgress` (cherry-pick, revert, merge, `git am`) do not. The main worktree follows the same rule. | `taskResolverPairs` keeps only entries with a branch and a path (`Sources/App/Worktree.swift:40-45`), and its input is the head-resolved list (`fetchWorktrees`, `Worktree.swift:266-271`). `inProgressOp` returns a branch only for rebase and bisect (`Worktree.swift:219-250`). `reload()` loads `TASK.md` only from `worktreeResolver()` paths (`WorkTaskManager.swift:317-321`). |
| D3 | Does the CLI need head resolution too, or is "skip `detached` entries from `parseList`" enough? | It needs head resolution. `gitdir(forWorktreeAt:)`, `inProgressOp(gitdir:)` and `applyHeadResolution(to:)` move unchanged from `WorktreeManager` to `Sources/Shared/WorktreeModel.swift` as `Worktree` statics. The app's `fetchWorktrees` and the CLI's `resolveProject` both call `Worktree.applyHeadResolution(to: Worktree.parseList(output))`. | `parseList` reports a mid-rebase worktree as `detached` with no branch (`WorktreeModel.swift:72-82`). Skipping it would hide a task the app shows, which fails acceptance criterion 1. All three functions are `nonisolated static` and use only Foundation (`Worktree.swift:193-264`), so they compile in the CLI target, which already compiles all of `Sources/Shared` (`project.yml:315-318`). |
| D4 | Where does the rule itself live? | One `Worktree` static in `Sources/Shared/WorktreeModel.swift` that takes head-resolved worktrees and returns the `(branch, path)` pairs that carry a task. `WorktreeManager.taskResolverPairs()` returns it applied to `worktrees`; the CLI's `resolveProject` uses its paths as `worktreePaths`. The plan picks the exact name. | Acceptance criterion 2: one place both use. `WorktreeModel.swift` already holds the other shared worktree rule, `Worktree.visible` (`WorktreeModel.swift:34-39`). Rejected: keeping the filter in `WorktreeManager` and copying it into `TaskCommand`, which is the two-copies shape the brief forbids. Rejected: filtering inside `TaskFiles.loadPool`, which takes paths, not worktrees, and is also the app's merge-load. |
| D5 | Where does the CLI's main worktree path come from? | Unchanged: the first entry of `parseList`, whatever its head state. Only the `TASK.md` candidates are filtered. | The backlog is `<main>/.clearway/tasks` regardless of the main worktree's HEAD (`TaskCommand.swift:160-169`, prior spec D4). The app likewise uses `projectPath` for the backlog, not the resolver (`WorkTaskManager.swift:36`). |
| D6 | What does the CLI report for a task whose `TASK.md` sits in a skipped worktree and whose id also has a central `<UUID>.md`? | The central copy, as `location: "backlog"`, the same task the app shows. | A consequence of D2, not an extra rule: `loadPool` lets a worktree copy win only when that worktree is in the path list (prior spec D3). Stated so a reviewer does not read it as a regression. |
| D7 | The bare-main guard in `resolveProject` splits the porcelain text by hand. Does it change? | No. | Out of the brief's scope and unaffected by the rule. |
| D8 | Tests | `TaskCommandTests` gains a test with a real detached-HEAD worktree (`git worktree add --detach`) holding a `TASK.md`: `task list` omits it and `task show <id>` exits 1 with `no task <ID>`. A second case covers a mid-rebase worktree (detached, with `rebase-merge/head-name` written into its gitdir) whose `TASK.md` both commands still return. A unit test on the shared rule in `WorktreeTests` covers each `HeadStatus`. Existing `WorktreeManager.gitdir`/`inProgressOp`/`applyHeadResolution` call sites in `WorktreeTests` move to `Worktree.`. | Acceptance criterion 3. The rebase case is what proves D3; without it a "skip every `detached` entry" implementation passes. |

## Assumptions

Verified against the tree at `8a11de5`. No probes were run.

| # | Assumption | Evidence |
| --- | --- | --- |
| A1 | The CLI loads `TASK.md` from every listed worktree, detached or not. | `TaskCommand.swift:166` (`Worktree.parseList(output).compactMap(\.path)`) feeds `TaskFiles.loadPool` at `:155`. |
| A2 | The app loads `TASK.md` only from resolver pairs, which require a branch. | `Worktree.swift:40-45`; `WorkTaskManager.swift:317-321`; wired in `ProjectWindow.swift:136` and `WorkTaskWindow.swift:54`. |
| A3 | The app's worktree list is head-resolved before the resolver sees it. | `fetchWorktrees` returns `applyHeadResolution(to: parsed)` (`Worktree.swift:266-271`); `refresh` stores that list (`:52-57`). |
| A4 | Head resolution is pure Foundation file reads and can move to `Sources/Shared`. | `Worktree.swift:193-264`: `FileManager`, `String(contentsOfFile:)`, `NSString`/`URL` path APIs; all `nonisolated static`; no call into `GitResolver` or a process. |
| A5 | Nothing else calls `gitdir`, `inProgressOp` or `applyHeadResolution`. | `grep` over `Sources` and `Tests`: only `Worktree.swift:193-270` and `Tests/WorktreeTests.swift:257-482`. |
| A6 | The CLI target compiles everything in `Sources/Shared`. | `project.yml:315-318`. |
| A7 | Tests can build a real repo with linked worktrees. | `GitRepoFixture.make`/`addWorktree` (`Tests/TestHelpers.swift:103-141`); used by `TaskCommandTests.makePool` (`Tests/TaskCommandTests.swift:243-270`). A detached worktree needs one extra `GitRepoFixture.git(["worktree", "add", "--detach", …])` call. |
| A8 | `list` filters hidden tasks and `show` searches the whole pool; neither changes here. | `TaskCommand.swift:137-150`; prior spec D11, D12. |

## Objective and success criteria

`cway task list`, `cway task show` and the app's Tasks list agree on which worktree `TASK.md` files
exist.

- A `TASK.md` in a bare-detached worktree is absent from `cway task list`, and `cway task show <its id>`
  exits 1 with `cway: no task <ID>`, matching the app, which does not load it.
- A `TASK.md` in a worktree mid-rebase is present in both, as it is in the app.
- The rule (D2) exists once, in `Sources/Shared/WorktreeModel.swift`; `WorktreeManager.taskResolverPairs`
  and `TaskCommand.resolveProject` both call it, and neither filters by branch on its own.
- `./scripts/ci.sh` exits 0.

## Verification

From the project's `## Pipeline` section:

| Step | Command |
| --- | --- |
| Every build task, and simplify (regression check) | `./scripts/ci.sh` |
| Sign-off (full gate), once | `./scripts/ci.sh` |

## Files touched

- `Sources/Shared/WorktreeModel.swift`: gains `gitdir(forWorktreeAt:)`, `inProgressOp(gitdir:)`,
  `applyHeadResolution(to:)` and the task-carrier rule (D3, D4).
- `Sources/App/Worktree.swift`: drops the three moved functions; `fetchWorktrees` and
  `taskResolverPairs` call the shared ones.
- `Sources/Shared/TaskCommand.swift`: `resolveProject` head-resolves and filters the `TASK.md`
  candidates through the shared rule.
- `Tests/TaskCommandTests.swift`: detached and mid-rebase worktree cases (D8).
- `Tests/WorktreeTests.swift`: call sites renamed to `Worktree.`; unit test for the rule.
- `Sources/App/CLAUDE.md`: the sidebar-visibility note names `WorktreeManager.inProgressOp`
  (`Sources/App/CLAUDE.md:459-460`); update the reference.
- `CLAUDE.md`: the `Sources/Shared/` bullet lists what lives there; add head resolution and the rule.

## Out of scope

- The sidebar's `Worktree.visible` and the Show detached worktrees setting. They decide which rows
  render, not which tasks load.
- `task create`, which writes only to the main worktree's backlog.
- Whether the app should show tasks from detached worktrees (D1 settles it).
- The hand-split bare-main check in `resolveProject` (D7).
