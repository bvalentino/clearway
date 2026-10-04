# Plan: cway task list skips detached-HEAD worktrees like the app does

Breaks down `docs/superpowers/specs/2026-10-03-cway-task-list-skip-detached-head-worktrees.md`.

**Date:** 2026-10-03
**Base:** 8a11de5 (Add cway CLI: create, list, and show tasks, #265)

## Architecture decisions carried from the spec

- The CLI changes to match the app. The app's behaviour does not change (D1).
- The rule: a worktree carries a visible `TASK.md` when, after head resolution, it has both a
  branch and a path. `.attached`, `.rebasing`, `.bisecting` count; `.detached` and `.inProgress`
  do not. The main worktree follows the same rule (D2).
- `gitdir(forWorktreeAt:)`, `inProgressOp(gitdir:)` and `applyHeadResolution(to:)` move unchanged
  (bodies and doc comment) from `WorktreeManager` in `Sources/App/Worktree.swift` to `Worktree`
  statics in `Sources/Shared/WorktreeModel.swift`. Drop the `nonisolated` keyword: `Worktree` is a
  plain struct in a target with no default actor isolation, and `Sources/Shared` carries no
  isolation (D3).
- The rule lives once, as `static func taskCarriers(_ worktrees: [Worktree]) -> [(branch: String, path: String)]`
  on `Worktree` in `Sources/Shared/WorktreeModel.swift`. It takes head-resolved worktrees. The name
  is this plan's choice (D4 left it open).
- `WorktreeManager.taskResolverPairs()` returns `Worktree.taskCarriers(worktrees)`; its body does
  no filtering of its own (D4).
- `WorktreeManager.fetchWorktrees` and `TaskCommand.resolveProject` both compute
  `Worktree.applyHeadResolution(to: Worktree.parseList(output))` (D3).
- `resolveProject`'s `mainPath` stays the first `parseList` entry's path, whatever its head state;
  only `worktreePaths` comes from `taskCarriers(...).map(\.path)` (D5).
- A `TASK.md` in a skipped worktree whose id also has a central `<UUID>.md` shows the central
  copy as `location: "backlog"`. This is a consequence of the path list, not new code (D6).
- The hand-split bare-main guard in `resolveProject` is untouched (D7).

## Dependency graph

```
T1 shared head resolution + taskCarriers, app rewired
 └── T2 CLI filters TASK.md candidates through taskCarriers
      └── T3 docs name the shared home
```

T2 needs T1's statics to compile. T3 documents the final shape of both, so it goes last.

## Tasks

Every task is verified by `./scripts/ci.sh` exiting 0 (the regression check from `CLAUDE.md`
`## Pipeline`). Do not hand-write an `xcodebuild` line.

### T1: Move head resolution and the task-carrier rule into Sources/Shared

**Files:**
- `Sources/Shared/WorktreeModel.swift`
- `Sources/App/Worktree.swift`
- `Tests/WorktreeTests.swift`

**What it does:**
- Cut `gitdir(forWorktreeAt:)`, `inProgressOp(gitdir:)` (with its doc comment) and
  `applyHeadResolution(to:)` out of `WorktreeManager` (`Worktree.swift`, the `// MARK: - Process
  helpers` block) and add them to `Sources/Shared/WorktreeModel.swift` as `static` members of
  `Worktree` (an `extension Worktree` beside the `parseList` one is fine). Bodies unchanged;
  `nonisolated` dropped.
- Add `static func taskCarriers(_ worktrees: [Worktree]) -> [(branch: String, path: String)]`
  to `Worktree`, returning the entries that have both a branch and a path, in input order. Its doc
  comment says the input must be head-resolved and that this is the one rule both the app's Tasks
  list and `cway task` use.
- `WorktreeManager.fetchWorktrees` returns `Worktree.applyHeadResolution(to: Worktree.parseList(output))`.
- `WorktreeManager.taskResolverPairs()` becomes `Worktree.taskCarriers(worktrees)`. Keep its doc
  comment's point that every window's resolver goes through it; drop the part that restates the
  filter.
- In `Tests/WorktreeTests.swift`, rename every `WorktreeManager.gitdir`, `WorktreeManager.inProgressOp`
  and `WorktreeManager.applyHeadResolution` call to `Worktree.` (lines ~257-482). If the file or a
  test is `@MainActor` only for those calls, leave the annotation alone; the build decides.
- Add `testTaskCarriersKeepsOnlyWorktreesWithABranch` (or one test per case, author's choice) in
  `WorktreeTests`: an input with one `Worktree` per `HeadStatus` built directly with
  `Worktree(branch:path:isMain:headStatus:)` — `.attached`, `.rebasing`, `.bisecting` with a branch;
  `.inProgress` and `.detached` with `branch: nil` (the shapes `applyHeadResolution`/`parseList`
  produce) — plus a detached main worktree. Assert the result is exactly the three branched
  entries' `(branch, path)` in input order, and that the detached main is excluded.

**Acceptance criteria:**
- `grep -rn "WorktreeManager\.\(gitdir\|inProgressOp\|applyHeadResolution\)" Sources Tests` finds nothing.
- `grep -n "func gitdir\|func inProgressOp\|func applyHeadResolution\|func taskCarriers" Sources -r`
  finds each exactly once, in `Sources/Shared/WorktreeModel.swift`.
- `taskResolverPairs()` contains no `guard`/`compactMap` of its own.
- The new rule test and every existing `WorktreeTests` case pass.

**Verify:** `./scripts/ci.sh` exits 0; run the two `grep`s above.

### T2: cway task list and show load TASK.md only from task carriers

**Depends on:** T1.

**Files:**
- `Sources/Shared/TaskCommand.swift`
- `Tests/TaskCommandTests.swift`

**What it does:**
- Write the tests first and watch the detached one fail on the T1 tree (it should list the
  detached worktree's task before the change).
- In `resolveProject`: keep the `git worktree list --porcelain` call and the bare-main guard as
  they are. Parse once with `Worktree.parseList(output)`. `mainPath` is the first parsed entry's
  `path` (unchanged "git listed no worktrees" failure when there is none). `worktreePaths` is
  `Worktree.taskCarriers(Worktree.applyHeadResolution(to: parsed)).map(\.path)`. No branch check
  of its own.
- In `TaskCommandTests`, add tests in the `// MARK: - task list, task show` area, reusing
  `makeRepo()`, `run(_:in:)`, `jsonObject`, `TaskFiles.write` and `GitRepoFixture.git`:
  1. **Bare-detached:** `GitRepoFixture.git(["worktree", "add", "-q", "--detach", <root>/.worktrees/loose], in: repo.root)`,
     write a `WorkTask` to `TaskFiles.taskMarkdownPath(inWorktree:)` there. `task list` (run from
     `repo.root`) does not contain its id; `task show <id>` exits 1 with stderr
     `cway: no task <ID>\n` (match the exact stderr format the existing "no task" test asserts).
  2. **Mid-rebase:** add a detached worktree the same way, then write `refs/heads/feature\n` to
     `<gitDir(ofWorktreeAt:)>/rebase-merge/head-name` (create `rebase-merge/`). Write a
     `WorkTask` to its `TASK.md`. `task list` contains its id with `location` `"worktree"`;
     `task show <id>` exits 0 and returns it.
  3. **D6, central copy wins:** a bare-detached worktree whose `TASK.md` holds a task with the
     same id as a central `<UUID>.md` but a different title. `task show <id>` returns the central
     title with `location` `"backlog"`.
- Resolve paths through symlinks as the existing tests do (`canonical`, fixture paths) when
  comparing `path`.

**Acceptance criteria:**
- `task list` omits a bare-detached worktree's `TASK.md`; `task show <its id>` exits 1 with
  `cway: no task <ID>`.
- `task list` and `task show` both return a mid-rebase worktree's `TASK.md`.
- A same-id central file is reported as `location: "backlog"` when its worktree copy sits in a
  skipped worktree.
- `resolveProject` filters only through `Worktree.taskCarriers`; existing `TaskCommandTests`
  (including the bare-main and main-path cases) pass unchanged.

**Verify:** `./scripts/ci.sh` exits 0. Record in the build log that test 1 failed before the
`resolveProject` change.

### T3: Docs name the shared head resolution and task-carrier rule

**Depends on:** T2.

**Files:**
- `CLAUDE.md`
- `Sources/App/CLAUDE.md`

**What it does:**
- `CLAUDE.md` line ~115, the `Sources/Shared/` bullet: add head resolution
  (`Worktree.applyHeadResolution`) and the task-carrier rule (`Worktree.taskCarriers`, which the
  app's Tasks list and `cway task list`/`show` both use) to the list of what lives there.
- `Sources/App/CLAUDE.md` line ~460: `WorktreeManager.inProgressOp` becomes `Worktree.inProgressOp`.
  Grep both files for any other `WorktreeManager.gitdir`/`applyHeadResolution`/`taskResolverPairs`
  description that now misstates where the filter lives, and fix only those.

**Acceptance criteria:**
- `grep -rn "WorktreeManager\.\(gitdir\|inProgressOp\|applyHeadResolution\)" --include=*.md .`
  (excluding `docs/` and `ghostty/`) finds nothing.
- The `Sources/Shared/` bullet names both new members.

**Verify:** the grep above; `./scripts/ci.sh` exits 0.

## Risks

| Risk | Mitigation |
| --- | --- |
| A moved static still carries `nonisolated` or picks up isolation and fails in the CLI target. | `ci.sh` builds both targets; T1 drops the keyword. |
| The detached-worktree test passes for the wrong reason (task hidden, wrong cwd). | T2 writes the test first and confirms it fails before the `resolveProject` change. |
| A "skip every `.detached` entry" shortcut passes the detached test. | T2's mid-rebase test fails for that shortcut. |

## Build log

### T1: Move head resolution and the task-carrier rule into Sources/Shared

| File | State |
| --- | --- |
| `Sources/Shared/WorktreeModel.swift` | New `extension Worktree` with `gitdir(forWorktreeAt:)`, `inProgressOp(gitdir:)` (doc comment kept), `applyHeadResolution(to:)` (bodies unchanged, `nonisolated` dropped) and `taskCarriers(_:)`. |
| `Sources/App/Worktree.swift` | The three statics removed. `fetchWorktrees` returns `Worktree.applyHeadResolution(to: Worktree.parseList(output))`. `taskResolverPairs()` is `Worktree.taskCarriers(worktrees)`; its doc comment keeps the "every window's resolver points here" point. |
| `Tests/WorktreeTests.swift` | All `WorktreeManager.gitdir/inProgressOp/applyHeadResolution` calls now `Worktree.`. New `testTaskCarriersKeepsOnlyWorktreesWithABranch`: one entry per `HeadStatus` plus a detached main; asserts exactly the `.attached`, `.rebasing`, `.bisecting` pairs in input order. |

**Evidence.** The rule test was written first and `./scripts/ci.sh` exited 65 on the unchanged tree:

```
Tests/WorktreeTests.swift:507:33: type 'Worktree' has no member 'taskCarriers'
```

After the move it passes (`testTaskCarriersKeepsOnlyWorktreesWithABranch() Passed` in the xcresult).
This is a move plus a new function, so the red is a compile failure, not a behavioural one; the
filter body is the one `taskResolverPairs()` already had.

**Acceptance greps.** `grep -rn "WorktreeManager\.\(gitdir\|inProgressOp\|applyHeadResolution\)" Sources Tests`
finds only `Sources/App/CLAUDE.md:460`, a doc line T3 owns; no Swift hits. The second grep finds
each of the four functions once, in `Sources/Shared/WorktreeModel.swift`.

**Deviations.** None. No `@MainActor` annotation in `WorktreeTests` needed touching.

**Gate.** `./scripts/ci.sh`, exit 0: 916 tests, 0 failures.
