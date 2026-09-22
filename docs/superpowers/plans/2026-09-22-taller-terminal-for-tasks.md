# Plan: Taller terminal for tasks

Breaks down `docs/superpowers/specs/2026-09-22-taller-terminal-for-tasks.md`.

**Date:** 2026-09-22
**Base:** 66145eb (Release v2.0.0)

## Architecture decisions carried from the spec

- `available` is the height of the split region only: the editor/preview, the grabber and the
  terminal inside `TaskDetailView`. It excludes the title row, frontmatter error line, agent
  metadata row, the divider under them, and the path bar (D1).
- `available` is read from a `GeometryReader` wrapping that split region, in the same layout pass
  that sizes the terminal. Not `onGeometryChange` (D2).
- The grabber counts against the editor's half: terminal = `available / 2`, the editor/preview gets
  the rest (D3).
- `TerminalManager.taskTerminalHeights` keeps its type `[UUID: CGFloat]`. An entry means "the user
  dragged, and this is the absolute height"; no entry means "follow 50%". Only a drag writes it (D4).
- `taskTerminalHeight(for:)` returns `CGFloat?`, the stored value or nil. The `?? 200` default is
  deleted (D5).
- Constants: `minimumHeight = 80`, `minimumEditorHeight = 120` (D6).
- Allowed range is `[80, max(80, available - 120)]`. It never inverts; below 200 pt of `available`
  it collapses to 80 (D7).
- The 50% default and the stored value both go through the same clamp (D8).
- The clamp applies at render time only. A window resize never rewrites the stored value; a drag
  stores the clamped value (D9).
- A drag starts from the rendered (resolved, clamped) height:
  `draggedHeight(from: rendered, translation: value.translation.height, available:)`, stored with
  `setTaskTerminalHeight`. The `DragGesture` keeps its default `.local` coordinate space (D10).
- The logic lives in a new caseless `enum TaskTerminalLayout` in
  `Sources/App/TaskTerminalLayout.swift` with the two constants and two pure static functions:
  `height(stored: CGFloat?, available: CGFloat) -> CGFloat` and
  `draggedHeight(from current: CGFloat, translation: CGFloat, available: CGFloat) -> CGFloat` (D11).
- The worktree bottom terminal (`secondaryHeight`, `ContentView`, `TerminalManager+Panels.swift`)
  is not touched and does not use the new type (D12).
- Reset points are unchanged: `closeTaskTerminal`, `replaceSurface`, `closeAllSurfaces` and
  promotion still remove the entry; `openTaskTerminal` does not touch it (D13).
- Do not change the grabber's look (capsule, divider, hover cursor) or the 80 pt floor.

## Dependency graph

```
T1 TaskTerminalLayout + unit tests
 └── T2 Wire TaskDetailView and TerminalManager to TaskTerminalLayout
```

T2 needs T1's type to compile. T2's two files must change together: making
`taskTerminalHeight(for:)` optional breaks both of its callers in `TaskDetailView`.

## Tasks

### T1: Add TaskTerminalLayout with unit tests

**Files:**
- `Sources/App/TaskTerminalLayout.swift` (new)
- `Tests/TaskTerminalLayoutTests.swift` (new)

**What it does:** Adds the caseless `enum TaskTerminalLayout` described above.

- `static let minimumHeight: CGFloat = 80`
- `static let minimumEditorHeight: CGFloat = 120`
- `height(stored:available:)`: returns `clamp(stored ?? available / 2, available)`.
- `draggedHeight(from:translation:available:)`: returns `clamp(current - translation, available)`.
- The clamp is `min(max(value, minimumHeight), max(minimumHeight, available - minimumEditorHeight))`,
  a private static helper. No other API.

Nothing calls the type yet; the app behaves exactly as before.

Tests are XCTest, `@testable import Clearway`, in the style of `Tests/TaskEditorBuffersTests.swift`.
New files are picked up because `ci.sh` runs `xcodegen generate`.

**Acceptance criteria:**
- `TaskTerminalLayoutTests` covers each of these as its own test method:
  1. Default is half: `height(stored: nil, available: 800) == 400`.
  2. Stored wins over the default: `height(stored: 300, available: 800) == 300`.
  3. Stored above the ceiling is clamped at render: `height(stored: 900, available: 800) == 680`,
     and the input value is unchanged (a `let` passed in stays 900; the function is pure).
  4. Default on a short pane is floored: `height(stored: nil, available: 150) == 80`.
  5. The range does not invert below 200: for `available` of 150 and 199, both `height(stored: 500, …)`
     and `height(stored: 10, …)` return 80.
  6. `draggedHeight` clamps at both ends and starts from `current`:
     `draggedHeight(from: 400, translation: 50, available: 800) == 350` (drag down shrinks),
     `draggedHeight(from: 400, translation: -50, available: 800) == 450` (drag up grows),
     `draggedHeight(from: 100, translation: 500, available: 800) == 80`,
     `draggedHeight(from: 600, translation: -500, available: 800) == 680`.
- No comments restating what the code does.

**Verification:** `./scripts/ci.sh` exits 0, and its output lists `TaskTerminalLayoutTests` with
all methods passing. `swiftlint lint --quiet` reports nothing new for the two files.

### T2: Wire TaskDetailView and TerminalManager to TaskTerminalLayout

**Files:**
- `Sources/App/TerminalManager+TaskTerminals.swift`
- `Sources/App/TaskDetailView.swift`

**What it does:**

1. `TerminalManager+TaskTerminals.swift`: `taskTerminalHeight(for:)` returns `CGFloat?`, the body is
   `taskTerminalHeights[taskId]`. Update its doc comment to say it returns the height the user
   dragged to, or nil when the terminal should follow the default. `setTaskTerminalHeight` is
   unchanged.
2. `TaskDetailView.swift` (currently lines ~85-124): wrap the split region, meaning the editor/preview
   `Group` and the `if terminalVisible, let surface = …` block (grabber + `TaskTerminalSurface`), in a
   `GeometryReader { geo in VStack(spacing: 0) { … } }`. The `pathBar(for: task)` call and everything
   above the `Divider()` under the header rows stay outside it. The editor/preview `Group` takes the
   remaining height (`.frame(maxHeight: .infinity)`) so the terminal's fixed height plus the grabber
   fit inside `geo.size.height`.
3. Compute the rendered height once inside the reader:
   `let terminalHeight = TaskTerminalLayout.height(stored: terminalManager.taskTerminalHeight(for: taskId), available: geo.size.height)`.
   Use it for `TaskTerminalSurface`'s `.frame(height:)`.
4. The grabber's `DragGesture(minimumDistance: 1).onChanged` stores
   `TaskTerminalLayout.draggedHeight(from: terminalHeight, translation: value.translation.height, available: geo.size.height)`
   via `terminalManager.setTaskTerminalHeight(_:for:)`. Keep the default coordinate space. Replace
   the `max(80, …)` literal; no other `80` or `200` literal for the task terminal remains.
5. Leave the grabber's visuals, the hover cursor code, `ContentView`, `secondaryHeight` and
   `TerminalManager+Panels.swift` untouched.

**Acceptance criteria:**
- `grep -n "?? 200" Sources/App/TerminalManager+TaskTerminals.swift` finds nothing, and
  `taskTerminalHeight(for:)` returns `CGFloat?`.
- `TaskDetailView` reads `available` from a `GeometryReader` around exactly the editor/preview,
  grabber and terminal; the path bar is outside it.
- Both the frame and the drag go through `TaskTerminalLayout`; `grep -n "max(80" Sources/App/TaskDetailView.swift`
  finds nothing.
- `git diff --stat` touches no file outside T1's and T2's lists.
- Existing tests that seed `taskTerminalHeights` (`WorkTaskCoordinatorTests.swift:185-191`,
  `:422-430`) pass unmodified.

**Verification:** `./scripts/ci.sh` exits 0. The build agent does not launch the app. The operator
checks by hand: open a task terminal by the path-bar toggle, Cmd+J, and Start Now; it opens at half
of the split region and tracks half on window resize; after a drag it keeps the dragged height
across resize and hide/show; dragging stops at 80 pt and 120 pt short of the top; closing the
terminal and reopening returns to half; the worktree bottom terminal still opens at 120 pt.

## Risks

| Risk | Impact | Mitigation |
| --- | --- | --- |
| The `GeometryReader` changes the editor's layout (top-leading alignment, or a zero-height proposal). | Medium | The split region already takes all remaining vertical space; the inner `VStack` fills the reader and the editor `Group` takes `maxHeight: .infinity`. Operator checks by hand. |
| The drag jitters because the base is the rendered height and `translation` is cumulative. | Low | Same shape as today's code, which re-reads the height on each event in `.local` space (D10). Operator checks by hand. |

## Build log

### T1: Add TaskTerminalLayout with unit tests

| File | State |
| --- | --- |
| `Sources/App/TaskTerminalLayout.swift` | New. Caseless enum with `minimumHeight = 80`, `minimumEditorHeight = 120`, `height(stored:available:)`, `draggedHeight(from:translation:available:)`, and a private `clamp`. Nothing calls it yet. |
| `Tests/TaskTerminalLayoutTests.swift` | New. Six test methods, one per acceptance criterion 1–6. |
| `Clearway.xcodeproj/project.pbxproj` | Regenerated by `xcodegen generate` (in `ci.sh`) to include the two new files. |

**Evidence (RED).** The tests were written first against a stub whose two functions returned `0`.
`./scripts/ci.sh` exited 65 with every new method failing:

```
testDefaultIsHalfOfAvailable, XCTAssertEqual failed: ("0.0") is not equal to ("400.0")
testDefaultOnShortPaneIsFlooredAtMinimum, XCTAssertEqual failed: ("0.0") is not equal to ("80.0")
testDraggedHeightStartsFromCurrentAndClampsAtBothEnds, XCTAssertEqual failed: ("0.0") is not equal to ("350.0")
testRangeDoesNotInvertBelowTwoHundred, XCTAssertEqual failed: ("0.0") is not equal to ("80.0")
testStoredAboveCeilingIsClampedWithoutMutatingInput, XCTAssertEqual failed: ("0.0") is not equal to ("680.0")
testStoredWinsOverDefault, XCTAssertEqual failed: ("0.0") is not equal to ("300.0")
Executed 846 tests, with 12 failures (0 unexpected)
```

**Deviations.** None.

**Gate.** `./scripts/ci.sh` after the last code edit: exit 0, "Test Succeeded", 846 passed / 0 failed
(from the xcresult summary); all six `TaskTerminalLayoutTests` methods reported Passed.
`swiftlint lint --quiet` on the two new files: no output, exit 0.

### T2: Wire TaskDetailView and TerminalManager to TaskTerminalLayout

| File | State |
| --- | --- |
| `Sources/App/TerminalManager+TaskTerminals.swift` | `taskTerminalHeight(for:)` returns `CGFloat?` (`taskTerminalHeights[taskId]`); `?? 200` removed; doc comment updated. |
| `Sources/App/TaskDetailView.swift` | Editor/preview `Group` (now `.frame(maxHeight: .infinity)`), grabber and terminal wrapped in `GeometryReader { geo in VStack(spacing: 0) { … } }`. `terminalHeight = TaskTerminalLayout.height(stored:available: geo.size.height)` drives the terminal frame; the drag stores `TaskTerminalLayout.draggedHeight(from: terminalHeight, …)`. Path bar and header rows stay outside. Grabber visuals, hover cursor and default coordinate space unchanged. |

**Evidence.** No new test: the wiring needs a `ghostty_app_t` surface, which XCTest cannot build
(spec, Testing strategy). The height logic is covered by T1's `TaskTerminalLayoutTests`. Acceptance
greps: `grep -n "?? 200" Sources/App/TerminalManager+TaskTerminals.swift` and
`grep -n "max(80" Sources/App/TaskDetailView.swift` both empty. The only caller of
`taskTerminalHeight(for:)` is `TaskDetailView.swift:87`. `git diff --stat` touches only the two
listed files. `WorkTaskCoordinatorTests` unmodified and passing.

**Deviations.** None.

**Gate.** `./scripts/ci.sh` after the last code edit: exit 0, "Test Succeeded", 846 tests, 0 failures.
`swiftlint lint --quiet` on the two files: no output, exit 0.
