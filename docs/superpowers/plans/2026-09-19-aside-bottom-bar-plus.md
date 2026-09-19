# Plan: Aside Bottom Bar `+`

**Date:** 2026-09-19
**Base:** 484482d3fe5e7e539176c4c1f8ae5720d5414836

Breaks down `docs/superpowers/specs/2026-09-19-aside-bottom-bar-plus.md`.

## Architecture decisions carried from the spec

1. The aside's Todos and Prompts tabs stop declaring window toolbar content. Both `.toolbar` blocks
   — `PromptsView.swift:45-61` and `TodosPanelView.swift:84-98`, their `ToolbarGroupBreak()` and
   their three-line comment headers included — are deleted outright, with no replacement in the
   window toolbar.
2. The `+` moves to a bar drawn at the bottom of the aside column: a `Divider()` along the top edge,
   a `.bar` background, the `+` on the leading edge. This is the same chrome `WorktreeStatusBar`
   uses (`ContentViewHelpers.swift:128-129`), so the aside's bottom edge and the window status bar
   below it read as one family.
3. One shared type, `AsideBottomBar`, in a new file `Sources/App/AsideBottomBar.swift`. It is not a
   generic container: it takes `help: String` and `action: () -> Void`, not a `@ViewBuilder`. Its
   one control is the `+`.
4. The `+` is `SidebarHeaderButton(systemImage: "plus")` (`SidebarHeaderControls.swift:17-28`) —
   reused, not re-drawn, despite the type being named for the sidebar header. Renaming that type is
   explicitly out of scope.
5. `.help(help)` **and** `.accessibilityLabel(help)` are both applied inside `AsideBottomBar`. The
   button's label is a bare `Image(systemName:)`, which VoiceOver would otherwise read as "plus".
   Both are ordinary view modifiers; `SidebarHeaderControls.swift` is not edited.
6. Padding: the bar adds 8 leading and 4 vertical and lets `SidebarHeaderButton`'s own 24×24 frame
   set the rest.
7. The bar belongs to the two views, not to the aside host in `ContentView`. Each `+` drives state
   the view owns privately — `TodosPanelView.startCreating()` mutates `@State isCreatingNew` /
   `newTodoGeneration`, and `PromptsView.openPrompt` needs `@Environment(\.openWindow)` and
   `promptManager.directory`. `ContentView.swift` is not edited by this change at all.
8. The bar is appended as the last child of each view's existing root `VStack(spacing: 0)`
   (`PromptsView.swift:14`, `TodosPanelView.swift:44`). Both empty states already carry
   `.frame(maxWidth: .infinity, maxHeight: .infinity)`, so the bar pins to the bottom in the empty
   case exactly as in the populated one. No restructuring of either root stack.
9. The Task tab gets no bar. `TaskAsideView` is not touched; its Create Task CTA stays.
10. No keyboard shortcut is added, changed, claimed or released. `AppKeyboardShortcuts.swift` is not
    edited. The File menu's New Prompt item (`ClearwayApp.swift:324-346`) is not edited.
11. `ToolbarGroupBreak` is **not** dead after the removal — five call sites remain
    (`PromptListView.swift:39`, `CommandsView.swift:37`, `WorkTaskListView.swift:59`,
    `ContentView.swift:199, 206, 217`). The type and its file stay.
12. No new tests (spec decision 18). The change is view chrome with no decision rule to lift into a
    pure helper. The existing suite must stay green **unchanged** — `SidePanelTabTests` and
    `AppKeyboardShortcutsTests` are the pin on "nothing else moved". Do not add, edit or delete any
    file under `Tests/`.
13. `PromptsView`'s doc comment (`PromptsView.swift:4`) is stale — it claims use "in both the
    sidebar detail and worktree aside panel", but the sidebar's Prompts destination is
    `PromptListView` plus `PromptDetailView`. It is corrected in the same change.
14. `CLAUDE.md:161-163` names `PromptsView` / `TodosPanelView` as the example of toolbar content
    merging after the enclosing view's. After this change neither declares any, so that sentence is
    rewritten to state the merge-order rule without them.

## Dependency graph

```
T1: AsideBottomBar + Todos tab
        │
        ├── T2: Prompts tab   (needs AsideBottomBar to exist)
        │
        └── T3: CLAUDE.md     (needs both toolbar blocks gone)
```

T2 and T3 are independent of each other but both depend on T1. T3 additionally requires T2's removal
to have landed, since its sentence names both views — run it last.

## Task list

### T1: Add AsideBottomBar and move the Todos `+` onto it

**Files (2):**
- `Sources/App/AsideBottomBar.swift` (new)
- `Sources/App/TodosPanelView.swift`

**What it does**

Creates `AsideBottomBar`:

```swift
struct AsideBottomBar: View {
    let help: String
    let action: () -> Void

    var body: some View {
        HStack(spacing: 0) {
            SidebarHeaderButton(systemImage: "plus", action: action)
                .help(help)
                .accessibilityLabel(help)
            Spacer()
        }
        .padding(.leading, 8)
        .padding(.vertical, 4)
        .frame(maxWidth: .infinity)
        .background(.bar)
        .overlay(alignment: .top) { Divider() }
    }
}
```

(Shape, not transcription — match the surrounding code's style. `SidebarHeaderButton`'s memberwise
initializer is `(systemImage:action:)`; it is internal and in the same module, so no import beyond
`SwiftUI` is needed. Write no explanatory comments: the type is self-describing and CLAUDE.md treats
comments as a smell.)

Then in `TodosPanelView`: delete lines 84-98 — the three-line comment header, the `.toolbar { … }`
block, its `ToolbarGroupBreak()` and its `ToolbarItem`. Append
`AsideBottomBar(help: "New todo", action: startCreating)` as the last child of the root
`VStack(spacing: 0)` that opens at line 44, after the `if isEmpty { … } else { … }`. The
`.confirmationDialog` modifier that followed the `.toolbar` stays, now attached directly to the
`VStack`. `startCreating()` keeps its current `private` access and body.

**Acceptance criteria**
- `Sources/App/AsideBottomBar.swift` exists and declares `struct AsideBottomBar` taking `help` and
  `action`, applying `.help` and `.accessibilityLabel` to a `SidebarHeaderButton(systemImage:
  "plus")`, with `.background(.bar)` and `.overlay(alignment: .top) { Divider() }`.
- `TodosPanelView` declares no `.toolbar` and contains no `ToolbarGroupBreak`.
- The bar is the last child of `TodosPanelView`'s root `VStack`, so it sits below both the empty
  state and the scrolling list.
- `TodosPanelView`'s `.confirmationDialog` is still attached and unchanged.
- No file under `Tests/` changed; `AppKeyboardShortcuts.swift` and `ContentView.swift` unchanged.

**Verification**
- `./scripts/ci.sh` passes — regenerates the project (without which the new file is invisible to
  the build), lints, builds and runs the suite. Report the command and its exit status.
- `swiftlint lint --quiet` reports no new warnings or errors.
- `grep -n "toolbar\|ToolbarGroupBreak" Sources/App/TodosPanelView.swift` returns nothing.
- `git diff --stat` shows exactly the two files.

### T2: Move the Prompts `+` onto the bar

**Files (1):**
- `Sources/App/PromptsView.swift`

**Depends on:** T1 (uses `AsideBottomBar`).

**What it does**

Delete lines 45-61 — the three-line comment header, the `.toolbar { … }` block, its
`ToolbarGroupBreak()` and its `ToolbarItem`. Append to the root `VStack(spacing: 0)` (line 14), after
the `if promptManager.prompts.isEmpty { … } else { … }`, a bar whose action is the body the deleted
toolbar button carried:

```swift
AsideBottomBar(help: "New prompt") {
    if let prompt = promptManager.createPrompt() {
        openPrompt(prompt)
    }
}
```

Correct the stale doc comment on line 4 so it describes the view's one real call site — the worktree
aside panel — and drops the claim about the sidebar detail. One line, no added prose.

`openPrompt(_:)` and the `onSendToTerminal` parameter are unchanged.

**Acceptance criteria**
- `PromptsView` declares no `.toolbar` and contains no `ToolbarGroupBreak`.
- The bar is the last child of the root `VStack`; its action creates a prompt and opens its window
  via the existing `openPrompt(_:)`, identical to the deleted toolbar button's body.
- The doc comment on line 4 no longer claims sidebar-detail use.
- `ToolbarGroupBreak` still has five call sites and `Sources/App/ToolbarGroupBreak.swift` is
  unchanged.

**Verification**
- `./scripts/ci.sh` passes. Report the command and its exit status.
- `swiftlint lint --quiet` reports no new warnings or errors.
- `grep -rn "ToolbarGroupBreak()" Sources/` lists exactly `PromptListView.swift:39`,
  `CommandsView.swift:37`, `WorkTaskListView.swift:59` and three sites in `ContentView.swift`.
- `git diff --stat` shows exactly the one file.

### T3: Update the toolbar merge-order paragraph in CLAUDE.md

**Files (1):**
- `CLAUDE.md`

**Depends on:** T1 and T2 (the sentence is only wrong once both toolbar blocks are gone).

**What it does**

Rewrites the two sentences at `CLAUDE.md:161-163`:

> A nested view's toolbar content merges **after** the enclosing view's, so the aside panels'
> (`PromptsView`, `TodosPanelView`) items arrive behind `detailView`'s four worktree buttons: the
> spacer that separates their `+` from those buttons precedes it, where every other view's follows.

to state the merge-order rule — a nested view's toolbar content merges after the enclosing view's,
so a nested view's leading break precedes its items where a top-level view's follows — without
naming `PromptsView` or `TodosPanelView`, which no longer declare any toolbar content. Keep it to
roughly the same length and in the surrounding paragraph's voice.

The `ToolbarGroupBreak` sentence that follows it stays verbatim. No other paragraph changes; in
particular the `ContentView.swift` `file_length` sentence further down is still accurate — this
change adds nothing to that file.

**Acceptance criteria**
- `grep -n "PromptsView\|TodosPanelView" CLAUDE.md` returns nothing.
- The merge-order rule is still stated, and the following `ToolbarGroupBreak` sentence is untouched.
- No Swift source changed by this task.

**Verification**
- `grep -n "PromptsView\|TodosPanelView" CLAUDE.md` is empty.
- `git diff CLAUDE.md` shows only the one paragraph.
- `./scripts/ci.sh` passes (unchanged from T2 — this task edits no code, so it is a confirmation
  that the tree is still green, not a new risk).

## Checkpoint: after T1–T3

- `./scripts/ci.sh` green, run after the last edit.
- `git status --porcelain` reported, including the un-gitignored `default.profraw` any Debug launch
  drops in the repo root. Never `git add -A`.
- The operator confirms criteria 1–8 by hand in the running app (`./scripts/run.sh`), on a non-main
  worktree for all three tabs and on main for Todos and Prompts, with each list empty and populated.
  Build agents do not launch the app. Padding numbers (8 leading, 4 vertical) are the operator's to
  confirm; a tweak there is a one-line follow-up, not a redesign.

## Risks

| Risk | Impact | Mitigation |
| --- | --- | --- |
| The bar is appended inside the `else` branch rather than after the `if/else`, so it vanishes when the list is empty | Med | T1 and T2 acceptance both state "last child of the root `VStack`"; criterion 5 of the spec is the empty-list case |
| `.confirmationDialog` accidentally dropped with the `.toolbar` block in `TodosPanelView` — they are adjacent | Med | T1 acceptance names it explicitly |
| A stray `ToolbarGroupBreak` removal leaves an unused type, or removes one of the five surviving call sites | Low | T2 verification greps for exactly the five |
| The new file is invisible to the build because `xcodegen generate` did not run | Low | `./scripts/ci.sh` is the only accepted runner; a hand-written `xcodebuild` line is explicitly refused |

## Open questions

None. Every design decision is settled in the spec.

## Build log

### T1: Add AsideBottomBar and move the Todos `+` onto it

**What landed**

| File | State |
| --- | --- |
| `Sources/App/AsideBottomBar.swift` | New. `struct AsideBottomBar` taking `help: String` and `action: () -> Void`; a leading `SidebarHeaderButton(systemImage: "plus")` carrying `.help(help)` and `.accessibilityLabel(help)`, then a `Spacer()`; 8 leading and 4 vertical padding, `.frame(maxWidth: .infinity)`, `.background(.bar)`, `.overlay(alignment: .top) { Divider() }`. 20 lines. |
| `Sources/App/TodosPanelView.swift` | The three-line comment header, the `.toolbar` block, its `ToolbarGroupBreak()` and its `ToolbarItem` deleted (old lines 84-98). `AsideBottomBar(help: "New todo", action: startCreating)` appended as the last child of the root `VStack(spacing: 0)`, after the `if isEmpty / else`. The `.confirmationDialog` is unchanged and now attaches directly to the `VStack`. `startCreating()` untouched. |
| `Clearway.xcodeproj/project.pbxproj` | Regenerated by `xcodegen generate` inside `ci.sh`, picking up the new source file. |

**Evidence**

No regression test was written: spec decision 18 and plan decision 12 settle that this task adds
none, and the change is view chrome with no decision rule to lift into a pure helper. There is
therefore no watched failure to quote. The pin on "nothing else moved" is the existing suite
staying green unchanged — 535 tests, 0 failures, no file under `Tests/` edited.

Acceptance criteria checked directly:

- `grep -n "toolbar\|ToolbarGroupBreak" Sources/App/TodosPanelView.swift` → no output, exit 1.
- `git diff --name-only` → `Clearway.xcodeproj/project.pbxproj`, `Sources/App/TodosPanelView.swift`
  only; `Tests/`, `AppKeyboardShortcuts.swift` and `ContentView.swift` untouched.
- `swiftlint lint --quiet` → exit 0, three warnings, all pre-existing and in
  `WorktreeConfigStore.swift` and `WorktreeDraft.swift`; none in either file this task touched.

**Deviations from the plan**

None. The bar is the shape the plan sketched, verbatim in structure.

`Clearway.xcodeproj/project.pbxproj` is a third changed file against the plan's "exactly the two
files" — it is the tracked xcodegen output, regenerated by `ci.sh` because a new source file was
added, and is committed with them.

**Gate**

`./scripts/ci.sh` — exit 0. `xcodegen generate`, SwiftLint, build, and 535 tests with 0 failures.

### T2: Move the Prompts `+` onto the bar

**What landed**

| File | State |
| --- | --- |
| `Sources/App/PromptsView.swift` | The three-line comment header, the `.toolbar` block, its `ToolbarGroupBreak()` and its `ToolbarItem` deleted (old lines 45-61). `AsideBottomBar(help: "New prompt")` appended as the last child of the root `VStack(spacing: 0)`, after the `if promptManager.prompts.isEmpty / else`; its action is the deleted button's body verbatim — `promptManager.createPrompt()` then `openPrompt(prompt)`. The doc comment on line 4 now reads "Displays and manages reusable prompts in the worktree aside panel.", dropping the stale sidebar-detail claim (spec decision 8). `openPrompt(_:)` and `onSendToTerminal` untouched. |

**Evidence**

No regression test was written: spec decision 18 and plan decision 12 settle that this task adds
none, and the change is view chrome with no decision rule to lift into a pure helper. There is
therefore no watched failure to quote. The pin on "nothing else moved" is the existing suite staying
green unchanged — 535 tests, 0 failures, no file under `Tests/` edited.

Acceptance criteria checked directly:

- `grep -n "toolbar\|ToolbarGroupBreak" Sources/App/PromptsView.swift` → no output, exit 1.
- `grep -rn "ToolbarGroupBreak()" Sources/` → exactly the five surviving sites the plan names:
  `PromptListView.swift:39`, `CommandsView.swift:37`, `WorkTaskListView.swift:59` and
  `ContentView.swift:199, 206, 217`. `Sources/App/ToolbarGroupBreak.swift` is unchanged.
- `git diff --stat` → `Sources/App/PromptsView.swift` only, 4 insertions and 15 deletions.
- `swiftlint lint --quiet` → exit 0, the same three pre-existing warnings as T1
  (`WorktreeConfigStore.swift`, `WorktreeDraft.swift`); none in `PromptsView.swift`.

**Deviations from the plan**

None. Unlike T1 no source file was added, so `Clearway.xcodeproj/project.pbxproj` is byte-identical
after `xcodegen generate` and the diff is the single file the plan named.

**Gate**

`./scripts/ci.sh` — exit 0. `xcodegen generate`, SwiftLint, build, and 535 tests with 0 failures.
