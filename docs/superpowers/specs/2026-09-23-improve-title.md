# Improve title

**Date:** 2026-09-23
**Base:** 66145eb (Release v2.0.0)

The project window's title reads "Commands" on the Commands destination and the project name
everywhere else, so Tasks, Prompts and every worktree look the same once the sidebar is collapsed.
This change gives each destination its own title: "Tasks", "Prompts", "Commands", and for a
worktree the same text its sidebar row shows on its primary line (stored name, else linked task
title, else branch). The project name leaves the title and remains only as the fallback when no
destination is selected. Both the sidebar row and the window title read one precedence rule, so
they cannot drift apart.

## Decisions

| # | Question | Decision | Why |
| --- | --- | --- | --- |
| D1 | Title on Tasks / Prompts / Commands | "Tasks" / "Prompts" / "Commands". | Task brief, in scope. |
| D2 | Title on a worktree | Stored name, else linked task title, else `Worktree.displayName` (branch, or "(detached)"). Main follows the same rule and resolves to its branch. | Task brief, in scope. |
| D3 | Project name in the window chrome | Dropped from the title on every destination. No subtitle, no "X — project". | Task brief, out of scope. The identical-windows risk is accepted by the operator (task, Open risks). |
| D4 | Title with no destination selected | The project name. | Task acceptance criterion: the window never shows an empty title. |
| D5 | Where the title is resolved | `ContentView.navigationTitle`, which feeds the existing `.navigationTitle` modifier outside the split view. No `.navigationTitle` in any detail view. | Task constraint; `Sources/App/CLAUDE.md:149-151` records that the outer modifier overrides anything a column sets. |
| D6 | How the sidebar and the title share one precedence rule | `WorktreeRow.rowTexts` becomes the single rule and returns a **non-optional** `primaryText` (`name ?? taskTitle ?? wt.displayName`) and an optional `subtitle` (the branch, set only when a name or task title won). `WorktreeRow.primaryText` becomes a non-optional `String`, and the body's own `primaryText ?? worktree.displayName` fallback is deleted. The title reads `rowTexts(...).primaryText`. | Today the precedence lives in two places: `rowTexts` picks name/task title (`WorktreeRow.swift:24`), and the row body adds the `displayName` fallback (`WorktreeRow.swift:47`). A title helper that re-added the fallback would be the second copy the task forbids. Moving the fallback into `rowTexts` makes one function the whole rule. Rejected: a separate `WorktreeRow.title(...)` wrapper (keeps the body's duplicate fallback); moving the rule onto `Worktree` (the name and task title come from two managers the model does not know, and `rowTexts` is already the tested home, `Tests/WorktreeRowTests.swift`). |
| D7 | Where the name and task title come from for the title | `groupManager.name(for: wt)` and `workTaskManager.titlesByBranch[branch]`, the exact inputs `SidebarView.worktreeRowView` passes (`SidebarView.swift:526-530`). | Same inputs into the same function is what makes criterion "title always matches the row's primary text" hold, including main (`name(for:)` returns nil for main) and hidden or empty-titled tasks (filtered by `titlesByBranch`). |
| D8 | Testability of the per-destination switch | Lift it into a pure `static func windowTitle(for selection: DetailSelection?, projectName: String, worktreeTitle: (Worktree) -> String) -> String` on `DetailSelection`, exhaustive over the cases, beside `bottomPanelAction(for:)`. `ContentView.navigationTitle` calls it, passing a closure that runs `rowTexts` with the managers' inputs. | Same pattern and reason as `bottomPanelAction(for:)` (`ContentView.swift:29-38`): `ContentView` reads `@EnvironmentObject` state XCTest cannot build. Exhaustive so a new destination must name its title. |
| D9 | Live updates on rename, task title edit, link/unlink | No extra wiring. `ContentView` already observes `WorktreeGroupManager` and `WorkTaskManager` as environment objects, and both publish the state read (`names`, `tasks`), so `body` and `navigationTitle` re-evaluate. | See A3, A4. |
| D10 | `ContentView.swift` length | Net growth of a few lines is fine; the file-wide `// swiftlint:disable file_length` stays. | File is 996 lines; the disable is kept on purpose (spec 2026-09-21-shortcuts-for-run-command-and-open-in, D15). |

## Assumptions

Each verified against the tree at `66145eb`. No probes were needed or written.

| # | Assumption | Evidence |
| --- | --- | --- |
| A1 | Today's title is "Commands" or the project name. | `Sources/App/ContentView.swift:523-525`. |
| A2 | The row's primary line is `name ?? taskTitle ?? displayName`, split across `rowTexts` and the row body. | `Sources/App/WorktreeRow.swift:19-26` (`guard let primaryText = name ?? taskTitle else { return (nil, nil) }`), `WorktreeRow.swift:40-48` (`Text(primaryText ?? worktree.displayName)`). |
| A3 | Renames publish: `names` is `@Published` on `WorktreeGroupManager`, which `ContentView` holds as `@EnvironmentObject`. | `Sources/App/WorktreeGroupManager.swift:39,259-268`; `ContentView.swift:64`. |
| A4 | Task title edits and link/unlink publish: `tasks` is `@Published` on `WorkTaskManager`, and `titlesByBranch` is derived from it. | `Sources/App/WorkTaskManager.swift:10,117-125`; `ContentView.swift:62`. |
| A5 | The `Worktree` inside `detailSelection` is replaced when the worktree list reloads, so a branch change reaches the title. | `Sources/App/ContentView.swift:394-396`. |
| A6 | Main never carries a name. | `WorktreeGroupManager.name(for:)` returns nil for `isMain` (`WorktreeGroupManager.swift:252-254`). |
| A7 | A detached worktree's `displayName` is "(detached)". | `Sources/App/Worktree.swift:26`. |
| A8 | `WorktreeRow` has one construction site, so making `primaryText` non-optional touches only the sidebar. | `grep "WorktreeRow("` → `Sources/App/SidebarView.swift:531` only. |
| A9 | `rowTexts` is pinned by tests whose "neither" case expects both values nil. | `Tests/WorktreeRowTests.swift:39-47` (`testNeitherLeavesBothNil`). It changes to expect `primaryText == "feature-x"`, `subtitle == nil`; add a detached-with-neither case expecting "(detached)". |
| A10 | The standalone task and prompt windows set their own empty title and are unaffected. | `Sources/App/WorkTaskWindow.swift:81`, `Sources/App/PromptWindow.swift:51`. |

## Objective

With the sidebar collapsed, the window title tells you which destination you are on. Success is
every acceptance criterion in `.clearway/TASK.md`:

1. Tasks shows "Tasks"; Prompts shows "Prompts"; Commands shows "Commands".
2. A worktree with a stored name shows the name, even with a linked task.
3. No name but a linked task: the task title.
4. Neither: the branch; detached shows "(detached)".
5. Main shows its branch.
6. Rename, task-title edit, link and unlink update the title without reselecting.
7. The worktree title always equals its sidebar row's primary text (guaranteed by D6/D7).
8. No destination selected: the project name.

## Testing strategy

XCTest, in the existing suite:

- `Tests/WorktreeRowTests.swift` (`WorktreeRowTextTests`): update the "neither" case to the
  non-optional primary text with a nil subtitle; add detached-with-neither ("(detached)", nil
  subtitle) and main (branch, nil subtitle).
- New `DetailSelection.windowTitle(for:projectName:worktreeTitle:)` tests, in a new
  `Tests/WindowTitleTests.swift` beside `Tests/BottomPanelActionTests.swift`: Tasks, Prompts,
  Commands, `.worktree` returns the closure's value, `nil` returns the project name.
- Live-update behaviour (criterion 6) rests on A3/A4 and is checked by hand by the operator; build
  agents do not launch the app.

## Commands

From `CLAUDE.md` `## Pipeline`:

- Regression check (every build task, and simplify): `./scripts/ci.sh`
- Full gate (sign-off, once): `./scripts/ci.sh`

## Files touched

- `Sources/App/WorktreeRow.swift` — `rowTexts` owns the full rule; `primaryText` non-optional; body drops its fallback.
- `Sources/App/SidebarView.swift` — only if the call site needs adjusting for the non-optional type.
- `Sources/App/ContentView.swift` — `DetailSelection.windowTitle(...)`; `navigationTitle` calls it.
- `Tests/WorktreeRowTests.swift` — updated and added cases.
- `Tests/WindowTitleTests.swift` — new.
- `Sources/App/CLAUDE.md` — one line at the `navigationTitle` note (149-151) saying a worktree's title is `rowTexts`' primary text, so the shared rule is recorded where the next change to either will look.

## Boundaries

- Always: one precedence rule; run `./scripts/ci.sh` after the last edit.
- Never: a `.navigationTitle` inside a detail view; a second copy of the name/task/branch precedence; any change to the text the sidebar row renders.

## Out of scope

- Any project name elsewhere in the window chrome (subtitle, combined title).
- `WorkTaskWindow` and `PromptWindow` titles.
- Any change to sidebar row text. D6 moves where the row's fallback is computed; what the row displays does not change.
- Disambiguating two windows on the same destination (accepted risk).
