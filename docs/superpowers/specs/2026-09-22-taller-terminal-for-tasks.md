# Taller terminal for tasks

**Date:** 2026-09-22
**Base:** 66145eb (Release v2.0.0)

A task's terminal currently opens as a 200 pt strip under the editor/preview, and users drag it up
every time. This change makes it open at half the height of the region it shares with the
editor/preview, and keep tracking half while the window is resized, until the user drags the
grabber. After a drag the dragged height sticks as an absolute value, as it does today. Dragging
also gets a ceiling, so the editor/preview above always keeps a 120 pt strip. The height decision
moves into a small pure type so the default-versus-dragged rule and the clamping can be unit-tested.

## Decisions

| # | Question | Decision | Why |
| --- | --- | --- | --- |
| D1 | What is "the task detail pane's height" that the 50% is taken from? | The height of the region that the editor/preview, the grabber and the terminal share inside `TaskDetailView`. It excludes the title row, the frontmatter error line, the agent metadata row, the divider under them, and the path bar. | Brief: "the task detail column that holds editor/preview plus terminal, not the whole window". Measuring only the split region means 50% gives the terminal exactly half of the space being divided. Including the title and path bar would leave the editor visibly shorter than the terminal. |
| D2 | How is that height measured? | A `GeometryReader` wrapping the split region (editor/preview, grabber, terminal). The terminal's height is computed from `geo.size.height` in the same layout pass. | `GeometryReader` gives the size during layout, so the first frame is already at 50%. The alternative, `onGeometryChange(for:of:action:)`, is available on macOS 13 (Apple docs, fetched 2026-09-22: `introducedAt: 13.0` for macOS), but its documentation says only that the action "is called whenever the data type changes". It does not say whether the initial value is delivered before the first frame, so a terminal could flash at a fallback height. The split region already takes all remaining vertical space, so a `GeometryReader` that fills its proposal changes no layout. `ContentView.columnWidthReader` already uses the same tool (`ContentView.swift:816`). |
| D3 | Is the grabber part of the 50%? | No. The grabber counts against the editor's half: terminal height = `available / 2`, and the editor/preview gets the remainder minus the grabber (about 12 pt). | The terminal is the element the brief sizes. Splitting the grabber's height between both halves adds arithmetic and changes nothing a user can see. |
| D4 | What does the stored per-task value mean now? | "The user dragged, and this is the absolute height they chose." No entry means "not dragged: follow 50%". `taskTerminalHeights: [UUID: CGFloat]` keeps its type. Only a drag writes to it. | Brief: in-memory storage on `TerminalManager` stays the source of truth for a dragged height. Absence already works as the "not dragged" marker, so no extra flag is needed. |
| D5 | What does `TerminalManager.taskTerminalHeight(for:)` return? | `CGFloat?`: the stored dragged height, or nil. The `?? 200` default goes away. The view resolves nil through the new layout type. | `TerminalManager` has no pane geometry and must not invent a default. The resolution needs `available`, which only the view knows. |
| D6 | Minimum editor strip | 120 pt. | Brief suggests about 120 pt. It matches the worktree bottom terminal's 120 pt default (`TerminalManager+Panels.swift:56`), and I found no reason to use another value. |
| D7 | Floor versus ceiling on a short pane | Allowed range is `[80, max(80, available − 120)]`. When the pane is shorter than 200 pt, the 80 pt terminal floor wins and the editor gets less than 120 pt. The range never inverts, so the grabber never gets stuck. | Brief's open risk. The floor stays unchanged per the brief. A terminal under 80 pt is unusable, while a squeezed editor in a tiny window is still scrollable. |
| D8 | Is the 50% default also clamped? | Yes. Both the default and the stored value pass through the same clamp. | One rule for every height. For example, `available = 150` gives a default of 75, which is raised to 80. |
| D9 | When the window shrinks below a dragged height, is the stored value rewritten? | No. The clamp applies at render time only. The stored value is written only by a drag, and a drag stores the clamped value. | Acceptance: a dragged height "survives window resizes". Shrinking and then re-growing the window should restore the height the user chose, not a squeezed one. |
| D10 | What is the base height for a drag? | The height currently rendered (resolved and clamped), not the stored value. New height = `clamp(rendered − translation.height)`, written with `setTaskTerminalHeight`. | Before the first drag nothing is stored, so the old `stored − translation` base (`TaskDetailView.swift:117`) would jump to the default. Starting from the rendered value makes the first drag continue from exactly what is on screen. The gesture keeps its default `.local` coordinate space: the grabber moves as the terminal grows, and this is what keeps the per-event `translation` incremental in the existing code. |
| D11 | Where does the height logic live? | A new caseless `enum TaskTerminalLayout` in `Sources/App/TaskTerminalLayout.swift` with the constants (`minimumHeight = 80`, `minimumEditorHeight = 120`) and two pure static functions: `height(stored: CGFloat?, available: CGFloat) -> CGFloat` and `draggedHeight(from current: CGFloat, translation: CGFloat, available: CGFloat) -> CGFloat`. | This is the only unit-testable piece. The acceptance criteria ask for a test of the default-versus-dragged decision, and `TaskDetailView` needs a `ghostty_app_t` surface, which XCTest cannot build. A caseless enum carries no state and no instance. |
| D12 | Worktree bottom terminal (`secondaryHeight`) | Not touched. It keeps its own `max(80, …)` drag and its 120 pt default (`ContentView.swift:915`, `TerminalManager+Panels.swift:56`). The new type is not shared with it. | Out of scope per the brief. Sharing the type now would change its behavior (it would get a ceiling). |
| D13 | Reset points | Unchanged. `closeTaskTerminal`, process exit (`replaceSurface`), `closeAllSurfaces` and promote-to-worktree still remove the entry, so the next open is back at 50%. `openTaskTerminal` does not touch the height, so a re-launch into the same terminal keeps a dragged height. | Out of scope per the brief, and it already behaves as the acceptance criteria require. See A5. |

## Assumptions

Each was checked against the tree at `66145eb`. No probe scripts or temp files were written into the
repo. The only external lookup was the Apple documentation JSON for `onGeometryChange`, fetched with
`curl` from the shell, with nothing saved.

| # | Assumption | Evidence |
| --- | --- | --- |
| A1 | The 200 pt default is a single literal, read in one place. | `TerminalManager+TaskTerminals.swift:36-38` (`taskTerminalHeights[taskId] ?? 200`). The only callers of `taskTerminalHeight(for:)` are `TaskDetailView.swift:117` and `:123`. |
| A2 | Every entry point shows the task terminal through the same view and the same height read. | Visibility is written only by `toggleTaskTerminal` (`TerminalManager+TaskTerminals.swift:50`: path-bar toggle and Cmd+J) and `openTaskTerminal` (`:101`: agent auto-launch, Start Now, Plan). The terminal is rendered only in `TaskDetailView.swift:98-124`, which `ContentView.swift:975` mounts for the selected task. |
| A3 | The drag floor is 80 pt and there is no ceiling today. | `TaskDetailView.swift:117`: `max(80, terminalManager.taskTerminalHeight(for: taskId) - value.translation.height)`. |
| A4 | Storage is in memory and per task. | `TerminalManager.swift:63`: `@Published var taskTerminalHeights: [UUID: CGFloat]`. No persistence code references it. |
| A5 | The height is forgotten on close, on process exit, on project switch and on promotion, and is kept across a re-launch. | `closeTaskTerminal` (`TerminalManager+TaskTerminals.swift:61`), `replaceSurface` (`TerminalManager.swift:445`), `closeAllSurfaces` (`TerminalManager.swift:136`). Promotion is covered by `WorkTaskCoordinatorTests.swift:185-192`. `openTaskTerminal` (`TerminalManager+TaskTerminals.swift:82-103`) does not touch `taskTerminalHeights`. |
| A6 | The existing tests seed and read the dictionary directly, so the new optional return type does not break them. | `WorkTaskCoordinatorTests.swift:185-191`, `:422-430` use `setTaskTerminalHeight` and `taskTerminalHeights[...]`. Neither calls `taskTerminalHeight(for:)`. |
| A7 | A new file in `Tests/` or `Sources/App/` is compiled once `xcodegen generate` runs, which `ci.sh` does. | `project.yml:25-26` (`sources: - path: Sources`). Project `CLAUDE.md`, "Verifying a change". |
| A8 | The deployment target is macOS 13, so every API used must be available there. | `project.yml:11` `MACOSX_DEPLOYMENT_TARGET: "13.0"`. `GeometryReader` is available from macOS 10.15. |

## Objective and success criteria

A user who opens a task terminal by any route sees a terminal as tall as the editor/preview above
it. The work is done when:

1. The path-bar toggle, Cmd+J, the agent-command auto-launch and Start Now / Plan all show the
   terminal at `TaskTerminalLayout.height(stored: nil, available:)`, which is half of the split
   region, clamped per D7.
2. Resizing the window before any drag keeps the terminal at half of the split region.
3. After a drag, the stored absolute height survives window resizes (render-time clamp only, D9),
   hide/show of the panel, and re-launching a command into the same terminal.
4. Closing the task terminal or its process exiting drops the stored height, and the next open is
   back at 50%.
5. Dragging stops at 80 pt at the bottom and at `available − 120` at the top. On a pane shorter
   than 200 pt the range collapses to 80 pt and does not invert.
6. The worktree bottom terminal still opens at 120 pt and drags as before.
7. `./scripts/ci.sh` exits 0 with the new `Tests/TaskTerminalLayoutTests.swift` covering:
   default = half; stored wins over the default; stored above the ceiling is clamped at render
   without being mutated; the default on a short pane is floored at 80; the range does not invert
   when `available < 200`; `draggedHeight` clamps at both ends and starts from the current height.

## Commands

From the project's `## Pipeline` section:

| Step | Command |
| --- | --- |
| Regression check (every build task, simplify) | `./scripts/ci.sh` |
| Full gate (sign-off, once) | `./scripts/ci.sh` |
| Lint (also run by `ci.sh`) | `swiftlint lint --quiet` |

Before sign-off, run `git status --porcelain`. Expect `default.profraw` after any Debug launch.

## Files touched

| File | Change |
| --- | --- |
| `Sources/App/TaskTerminalLayout.swift` | New. Constants and the two pure functions (D11). |
| `Sources/App/TaskDetailView.swift` | Wrap the editor/preview, grabber and terminal in a `GeometryReader`. The terminal frame uses `TaskTerminalLayout.height`, and the drag uses `TaskTerminalLayout.draggedHeight`. |
| `Sources/App/TerminalManager+TaskTerminals.swift` | `taskTerminalHeight(for:)` returns `CGFloat?` with no default (D5), and its doc comment is updated. |
| `Tests/TaskTerminalLayoutTests.swift` | New. Unit tests per success criterion 7. |

## Testing strategy

XCTest, in `Tests/`, run by `./scripts/ci.sh`. The pure `TaskTerminalLayout` functions are
unit-tested directly. The view wiring (the `GeometryReader` and the gesture) cannot be exercised in
XCTest because a task terminal needs a `ghostty_app_t`. The operator checks it by hand, per memory:
build agents never launch the app or take screenshots.

## Boundaries

- Always: run `./scripts/ci.sh` after the last edit; keep the stored value absolute and written only by a drag.
- Ask first: any change to reset points, persistence, or the worktree bottom terminal.
- Never: touch `secondaryHeight` / `ContentView`'s bottom panel; change the grabber's look or the 80 pt floor.

## Out of scope

- The worktree bottom terminal in the main view (`secondaryHeight`, 120 pt default).
- Persisting the dragged height across app relaunch.
- Changing when a remembered height is forgotten.
- The grabber's look, the 80 pt floor, and the main terminal tabs.
- Converting the other `GeometryReader` in `ContentView` or sharing `TaskTerminalLayout` with the worktree panel.
