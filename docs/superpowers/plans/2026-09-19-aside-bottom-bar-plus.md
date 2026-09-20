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

## Changelog

### C1: The bar's control becomes a titled push button (operator, after the hands-on check)

Operator feedback, verbatim: "why isn't the button at the bottom of the pane shaped as an actual
button? It looks odd. I was expecting a button with + Add Todo or + Add Prompt with glass style."

`AsideBottomBar` now renders a real bordered push button instead of the borderless
`SidebarHeaderButton` glyph T1 chose. Its label is `Label("Add Todo", systemImage: "plus")` /
`Label("Add Prompt", systemImage: "plus")` with `.labelStyle(.titleAndIcon)`, leading-aligned, and
its style is `.glass` on macOS 26 and later, `.bordered` below. The bar's `help` parameter becomes
`title`, so the callers pass the button's words. The `.help` tooltip and the `.accessibilityLabel`
are both dropped: a text-labelled button needs no tooltip and its title is already the
accessibility label. The divider, the `.bar` background and the leading alignment are unchanged;
the padding goes from 8 leading / 4 vertical to 8 horizontal / 6 vertical, because the old numbers
were sized for a 24-pt borderless glyph.

The macOS 26 availability split is not copied into `AsideBottomBar`. The extension that holds it —
`applyPrimaryActionStyle(tint:)`, previously `WorkTaskWindow.swift`'s `// MARK: - Glass Styling` —
moves unchanged into a new `Sources/App/GlassButtonStyles.swift` and gains a sibling
`applyGlassButtonStyle()`, so one file owns the `#available(macOS 26.0, *)` check.

This supersedes spec decisions 11, 12 and 13 and is recorded as spec decisions 19 and 20. Because
the aside no longer uses `SidebarHeaderButton`, that type has only sidebar callers again and the
spec's follow-up about renaming it is moot; the Out of scope entry says so.

### C2: The bar becomes a full-width glass button (operator, after the second hands-on check)

Operator feedback, verbatim: "That button is not glass. It should not have a divider on top. It
should be full width."

Root cause of the first symptom: `.buttonStyle(.glass)` needs content behind it, and C1's
`.background(.bar)` was opaque, so the glass had nothing to sample and rendered like `.bordered`.
Removing the bar is therefore the fix for all three complaints at once.

`AsideBottomBar` is renamed `AsideAddButton` (`Sources/App/AsideAddButton.swift`) — it is a button
now, not a bar. The `Divider`, the `.bar` background and the `HStack`/`Spacer` are gone; what
remains is one `Button` whose `Label(title, systemImage: "plus")` is `.frame(maxWidth: .infinity)`,
inset 12 horizontal, 12 bottom and 8 top so the aside's bottom mirrors the tab strip's top.

The glass is built the way the app's working precedents build theirs — `ContentView.sidePanelTabStrip`
and `MainTerminalTabStrip.tabsCapsule` — rather than by a button style: on macOS 26 and later,
`.buttonStyle(.plain)` with the label padded 6 vertical, `.glassEffect(.regular.interactive(), in: Capsule())`
and a `Capsule().strokeBorder(Color(nsColor: .separatorColor), lineWidth: 0.5)` overlay. `.interactive()`
is the one addition over those two, so hover and press give feedback on a control that is a button
rather than a container. Below macOS 26 it is `.buttonStyle(.bordered)` at `.controlSize(.large)`
with the same full-width frame.

`applyGlassButtonStyle()` had exactly one caller and goes with it; `applyPrimaryActionStyle(tint:)`
stays where C1 put it, in `GlassButtonStyles.swift`.

This supersedes spec decision 1's bar chrome, decision 14 entirely and decision 19's divider, `.bar`
background and leading alignment, and is recorded as spec decision 21. Decision 19's titled label,
absent tooltip and absent `.accessibilityLabel` are unchanged.

### C3: The button uses the system glass button style (operator, after the third hands-on check)

Operator feedback, verbatim: "We should NEVER do a hand-built glass. That is a big smell."

`AsideAddButton` drops C2's hand-built glass entirely. What remains is one `Button` whose
`Label(title, systemImage: "plus")` is `.frame(maxWidth: .infinity)`, styled by
`applyGlassButtonStyle()` at `.controlSize(.large)`. Gone: `.buttonStyle(.plain)`, the
`.glassEffect(.regular.interactive(), in: Capsule())`, the separator-colour capsule stroke and the
label's 6-point vertical padding. The 12 horizontal / 8 top / 12 bottom insets and the
`.labelStyle(.titleAndIcon)` stay.

`applyGlassButtonStyle()` returns to `Sources/App/GlassButtonStyles.swift` beside
`applyPrimaryActionStyle(tint:)` — `.glass` on macOS 26 and later, `.bordered` below — so that file
is again the one place the app splits button styling between Liquid Glass and its fallback. The
`.controlSize(.large)` belongs at the call site, not in the helper: it is sizing, not the
availability split.

`CLAUDE.md` gains a bullet in the `Sources/App/` list recording the convention, so the next button
does not reach for `.glassEffect` again. The rule is also spec decision 22.

This supersedes C2's glass construction and restores C1's decision 20.

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

### T3: Update the toolbar merge-order paragraph in CLAUDE.md

**What landed**

| File | State |
| --- | --- |
| `CLAUDE.md` | The two sentences at 161-163 rewritten. They no longer name `PromptsView` / `TodosPanelView`, which declare no toolbar content after T1 and T2, and state the merge-order rule on its own: a nested view's toolbar content merges after the enclosing view's, so a nested view puts the break that separates the two groups before its own items where a top-level view puts it after. Same length, three lines. The `ToolbarGroupBreak` sentence that follows is byte-identical, and no other paragraph changed. |

**Evidence**

No regression test was written: spec decision 18 and plan decision 12 settle that this task adds
none, and this task edits no code at all. There is therefore no watched failure to quote. The pin is
the existing suite staying green unchanged — 535 tests, 0 failures, no file under `Tests/` edited.

Acceptance criteria checked directly:

- `grep -n "PromptsView\|TodosPanelView" CLAUDE.md` → no output, exit 1.
- `git diff CLAUDE.md` → one hunk, 3 lines replaced by 3, inside the `.toolbar` paragraph only.
- `git diff --name-only` → `CLAUDE.md` and this plan document; no Swift source changed.

**Deviations from the plan**

None.

**Gate**

`./scripts/ci.sh` — exit 0. `xcodegen generate`, SwiftLint, build, and 535 tests with 0 failures.

### C1: The bar's control becomes a titled push button

**What landed**

| File | State |
| --- | --- |
| `Sources/App/GlassButtonStyles.swift` | New, 24 lines. Holds `applyPrimaryActionStyle(tint:)` moved verbatim out of `WorkTaskWindow.swift` and a new sibling `applyGlassButtonStyle()` — `.glass` on macOS 26 and later, `.bordered` below. One file owns the `#available(macOS 26.0, *)` split. |
| `Sources/App/WorkTaskWindow.swift` | The `// MARK: - Glass Styling` extension and its 13 lines deleted; the file now ends at the `TaskEditor` type. No other change, and its two callers (`WorkTaskWindow.swift:284`, `WorkTaskListView.swift:65`) are untouched — the helper is internal and all sources are one module. |
| `Sources/App/AsideBottomBar.swift` | `help` renamed `title`. The `SidebarHeaderButton` glyph, its `.help` and its `.accessibilityLabel` replaced by `Button(action:)` wrapping `Label(title, systemImage: "plus").labelStyle(.titleAndIcon)`, styled `.applyGlassButtonStyle()`. Padding `.leading 8` / `.vertical 4` becomes `.horizontal 8` / `.vertical 6`. The `HStack` + trailing `Spacer()`, the `.frame(maxWidth: .infinity)`, the `.background(.bar)` and the top `Divider()` overlay are unchanged. |
| `Sources/App/TodosPanelView.swift` | Call site becomes `AsideBottomBar(title: "Add Todo", action: startCreating)`. |
| `Sources/App/PromptsView.swift` | Call site becomes `AsideBottomBar(title: "Add Prompt") { … }`; the closure body is unchanged. |
| `docs/superpowers/specs/2026-09-19-aside-bottom-bar-plus.md` | Decisions 19 and 20 added; success criteria 1, 2 and 6 restated for the button; the `Files touched` table gains the two new rows; the `SidebarHeaderButton` rename bullet under Out of scope marked moot. |
| `docs/superpowers/plans/2026-09-19-aside-bottom-bar-plus.md` | `## Changelog` section added with C1, plus this entry. |

**Evidence**

No regression test was written. Spec decision 18 still holds — this is view chrome with no decision
rule to lift into a pure helper, and the change is a style and a label, not a behaviour. There is
therefore no watched failure to quote. The pin on "nothing else moved" is the existing suite staying
green unchanged: 535 tests, 0 failures, no file under `Tests/` edited.

Checked directly:

- `grep -rn "SidebarHeaderButton" Sources/` → only `SidebarHeaderControls.swift:17` and the three
  sidebar call sites (`SidebarView.swift:307, 315, 589`). The aside no longer uses it, so the spec's
  rename follow-up is moot.
- `grep -rn "#available(macOS 26" Sources/App/` → `GlassButtonStyles.swift` only for button styling;
  no second copy in `AsideBottomBar.swift`.
- `grep -n "help" Sources/App/AsideBottomBar.swift Sources/App/TodosPanelView.swift` → no `.help()`
  on the bar or its callers; `TodosPanelView`'s remaining `help` is `SendToTerminalButton`'s, which
  this change does not touch.
- `swiftlint lint --quiet` → exit 0, the same three pre-existing warnings
  (`WorktreeDraft.swift:17`, `WorktreeConfigStore.swift:99, :266`); none in any file this task
  touched.
- `git status --porcelain` → the seven files above plus `Clearway.xcodeproj/project.pbxproj`, which
  `xcodegen generate` rewrote for the new source file. No `default.profraw`: the app was not
  launched.

**Deviations from the plan**

This is not a plan task. It is operator feedback after the hands-on check, recorded as C1 in
`## Changelog` above and as spec decisions 19 and 20 so no later step reverts it.

One judgement call the feedback left open: it said to reuse `WorkTaskWindow.swift`'s helper "if it
is shaped to take a style, otherwise mirror its pattern". It is not — `applyPrimaryActionStyle`
hard-codes the prominent styles and a tint. Rather than mirror the `#available` check into
`AsideBottomBar`, the extension moved into `GlassButtonStyles.swift` and gained a sibling, which
keeps the check in one place and stops a shared button-style helper living in a file named for one
window.

**Gate**

`./scripts/ci.sh` — exit 0. `xcodegen generate`, SwiftLint, build, and 535 tests with 0 failures.

### C2: The bar becomes a full-width glass button

**What landed**

| File | State |
| --- | --- |
| `Sources/App/AsideAddButton.swift` | Renamed from `AsideBottomBar.swift` (`git mv`, so the history follows). 42 lines. `struct AsideAddButton` taking `title` and `action`; one `Button` whose `Label(title, systemImage: "plus").labelStyle(.titleAndIcon)` is `.frame(maxWidth: .infinity)`, inset 12 horizontal / 8 top / 12 bottom. macOS 26 and later: `.buttonStyle(.plain)`, label padded 6 vertical, `.glassEffect(.regular.interactive(), in: Capsule())` and a `Capsule().strokeBorder(Color(nsColor: .separatorColor), lineWidth: 0.5)` overlay. Below: `.buttonStyle(.bordered)` at `.controlSize(.large)`. The `Divider`, the `.bar` background, the `HStack` and the `Spacer` are gone. |
| `Sources/App/GlassButtonStyles.swift` | `applyGlassButtonStyle()` deleted — `AsideBottomBar` was its only caller. `applyPrimaryActionStyle(tint:)` stays, with its two callers (`WorkTaskWindow.swift:284`, `WorkTaskListView.swift:65`) untouched. |
| `Sources/App/TodosPanelView.swift` | Call site becomes `AsideAddButton(title: "Add Todo", action: startCreating)`; still the last child of the root `VStack`. |
| `Sources/App/PromptsView.swift` | Call site becomes `AsideAddButton(title: "Add Prompt") { … }`; closure body unchanged, still the last child of the root `VStack`. |
| `docs/superpowers/specs/2026-09-19-aside-bottom-bar-plus.md` | Decision 21 added; the summary paragraph and success criteria 1, 2, 3, 5, 6 and 7 restated for a button with no bar; the two `Files touched` rows updated. |
| `docs/superpowers/plans/2026-09-19-aside-bottom-bar-plus.md` | C2 added to `## Changelog`, plus this entry. |

**Evidence**

No regression test. Spec decision 18 still holds: this is view chrome, and the two facts that could
regress — the button staying pinned at the bottom and surviving the empty list — are SwiftUI layout,
not a rule that can be lifted into a pure helper. Both were confirmed by reading: in each view the
call is the last child of the root `VStack(spacing: 0)` after the `if isEmpty / else`, and both
empty-state branches carry `.frame(maxWidth: .infinity, maxHeight: .infinity)`
(`PromptsView.swift:24`, `TodosPanelView.swift:54`), so the list's branch takes the slack either way.

The root cause of "that button is not glass" was confirmed against the SDK rather than guessed:
`SwiftUICore.Glass` declares `public func interactive(_ isEnabled: Bool = true) -> Glass` and
`glassEffect(_ glass: Glass = .regular, in shape: some Shape = DefaultGlassEffectShape())`
(`MacOSX27.0.sdk/.../SwiftUICore.swiftinterface:7245, :3064`), which is the shape the two working
precedents already use. An opaque `.background(.bar)` behind `.buttonStyle(.glass)` leaves the
material nothing to sample, which is why C1's button read as `.bordered`.

Checked directly:

- `grep -rn "AsideBottomBar\|applyGlassButtonStyle" Sources Tests CLAUDE.md` → nothing.
- `swiftlint lint --quiet` → exit 0, the same three pre-existing warnings (`WorktreeDraft.swift:17`,
  `WorktreeConfigStore.swift:99, :266`); none in a file this task touched.
- `git status --porcelain` → the six files above plus `Clearway.xcodeproj/project.pbxproj`, which
  `xcodegen generate` rewrote for the renamed source file. No `default.profraw`: the app was not
  launched.

**Deviations from the plan**

None from C2's brief. The brief left one choice open — `.buttonStyle(.glass)` full-width once the
bar background was gone, or the label-plus-`glassEffect` shape the app already proves — and the
proven shape was taken, with `.interactive()` added so a control, unlike the tab strip container it
copies, answers hover and press.

**Gate**

`./scripts/ci.sh` → `==> CI passed.`, exit 0. 535 tests, 0 failures.

### C3: The button uses the system glass button style

**What landed**

| File | State |
| --- | --- |
| `Sources/App/AsideAddButton.swift` | 20 lines, down from 42. One `Button` whose `Label(title, systemImage: "plus").labelStyle(.titleAndIcon)` is `.frame(maxWidth: .infinity)`, then `.applyGlassButtonStyle()`, `.controlSize(.large)` and the unchanged 12 horizontal / 8 top / 12 bottom insets. The `@ViewBuilder` availability split, `.buttonStyle(.plain)`, `.glassEffect(.regular.interactive(), in: Capsule())`, the `Capsule().strokeBorder(Color(nsColor: .separatorColor), lineWidth: 0.5)` overlay and the label's 6-point vertical padding are gone. |
| `Sources/App/GlassButtonStyles.swift` | `applyGlassButtonStyle()` restored beside `applyPrimaryActionStyle(tint:)` — `.buttonStyle(.glass)` on macOS 26 and later, `.buttonStyle(.bordered)` below. No `.controlSize` in the helper: sizing is the call site's. |
| `CLAUDE.md` | A bullet added to the `Sources/App/` list, after the `.navigationTitle` bullet: buttons never hand-build glass with `.glassEffect` plus a stroke, they take the system `.glass` / `.glassProminent` styles through `GlassButtonStyles.swift` with `.bordered` / `.borderedProminent` below macOS 26; `.glassEffect` is for non-button containers such as the two tab strips. |
| `docs/superpowers/specs/2026-09-19-aside-bottom-bar-plus.md` | Decision 22 added; success criterion 6 restated for the system style; the `AsideAddButton`, `GlassButtonStyles` and `CLAUDE.md` rows in `Files touched` updated. |
| `docs/superpowers/plans/2026-09-19-aside-bottom-bar-plus.md` | C3 added to `## Changelog`, plus this entry. |

**Evidence**

No regression test. Spec decision 18 still holds: this swaps one button style for another and
deletes decoration, with no decision rule to lift into a pure helper and no reachable API to assert
on. There is therefore no watched failure to quote. The pin on "nothing else moved" is the existing
suite staying green unchanged — 535 tests, 0 failures, no file under `Tests/` edited.

Checked directly:

- `grep -rn "glassEffect" Sources/` → `ContentView.swift:977` and `MainTerminalTabStrip.swift:114`
  only, both container capsules. No button hand-builds glass any more.
- `grep -rn "#available(macOS 26" Sources/App/` for button styling → `GlassButtonStyles.swift` only.
- `swiftlint lint --quiet` → exit 0, the same three pre-existing warnings (`WorktreeConfigStore.swift:99, :266`,
  `WorktreeDraft.swift:17`); none in a file this task touched.
- `git status --porcelain` → the five files above and nothing else.
  `Clearway.xcodeproj/project.pbxproj` is byte-identical after `xcodegen generate`: no source file
  was added or renamed. No `default.profraw`: the app was not launched.

**Deviations from the plan**

None. `.controlSize(.large)` was kept at the call site rather than folded into
`applyGlassButtonStyle()`, as the brief directs, so the helper stays purely the availability split
and `applyPrimaryActionStyle(tint:)`'s two callers keep their own sizing.

**Gate**

`./scripts/ci.sh` → `==> CI passed.` 535 tests, 0 failures.

### Simplify

Nothing simplified: `/simplify`'s four passes (reuse, simplification, efficiency, altitude) returned
no change worth making. `AsideAddButton` has no pre-existing twin, `applyGlassButtonStyle` mirrors
`applyPrimaryActionStyle`'s availability split, `ToolbarGroupBreak` kept five other call sites, and
the `PromptsView` doc comment is now accurate at its one remaining call site (`ContentView.swift`).

The one finding — that CLAUDE.md's toolbar merge-order paragraph now describes a nested-view break
placement no `Sources/` file exercises — was skipped. C2 (`c4dea2d`) already made that call: the
sentence is the rule for a nested view's toolbar, not a claim that one exists, and deleting it would
throw away the merge-order fact rather than simplify it.

**Gate**

`./scripts/ci.sh` → `==> CI passed.` 535 tests, 0 failures.
