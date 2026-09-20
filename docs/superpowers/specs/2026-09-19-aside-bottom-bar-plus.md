# Aside Bottom Bar `+`

**Date:** 2026-09-19
**Base:** 484482d3fe5e7e539176c4c1f8ae5720d5414836

The aside panel's Todos and Prompts tabs each declare a `+` in the **window** toolbar, at the far
side of the window from the list it adds to and in the same row as the four worktree buttons.
Because the declaring view only exists while its tab is showing, that `+` appears and disappears as the aside
tab changes or the aside hides, and the worktree buttons slide sideways each time. This change
moves the `+` to the bottom of the aside column, as a full-width titled button drawn on the panel
itself, so it sits against the list it acts on and the window toolbar stops moving. The
create actions themselves, the File menu's New Prompt item and every keyboard shortcut are
unchanged.

## Decisions

| # | Question | Decision | Source |
| --- | --- | --- | --- |
| 1 | What replaces the toolbar `+`? | A classic AppKit-style bottom bar on the aside: a divider across the top, the `+` on the leading edge. It is drawn for the Todos and Prompts tabs only. | Operator |
| 2 | Does the Task tab get one? | No. `TaskAsideView` keeps its existing Create Task CTA (`TaskAsideView.swift:49-62`, `:66-81`) and gets no bar. | Operator |
| 3 | What happens to the existing toolbar blocks? | Both `.toolbar` blocks and their `ToolbarGroupBreak()`s are removed — `PromptsView.swift:45-61` and `TodosPanelView.swift:84-98`, comment headers included. | Operator |
| 4 | Does the File menu's New Prompt command change? | No. It stays as it is in `ClearwayApp.swift:324-346`, gated on the `newPromptAction` focused value that `PromptListView` publishes. No keyboard shortcut is added, changed or claimed, so `AppKeyboardShortcuts` is untouched. | Operator |
| 5 | Does the floating circular `+` come back? | No. It was retired app-wide in 863b2a4 as a non-macOS pattern and stays retired. A `+` on the aside tab strip row was also considered and rejected in favour of the bottom bar. | Operator |
| 6 | Does CLAUDE.md change? | Yes. The paragraph at CLAUDE.md:161-163 says the aside panels' toolbar items merge after `detailView`'s four worktree buttons, so their spacer precedes their `+`. After this change neither aside panel declares toolbar content, so that sentence names views that no longer apply. It is rewritten to state the merge-order rule without them. The `ToolbarGroupBreak` sentence that follows stays: five other call sites use it (decision 15). | Operator |
| 7 | Does the bar belong to the two views or to the aside host in `ContentView`? | To the two views. Each `+` drives state the view owns privately and nothing else can reach: `TodosPanelView.startCreating()` mutates `@State isCreatingNew` / `newTodoGeneration` (`TodosPanelView.swift:32-34`, `:140-144`), and `PromptsView.openPrompt` needs the view's `@Environment(\.openWindow)` and `promptManager.directory` (`PromptsView.swift:63-66`). Hosting the bar in `ContentView` would mean lifting that state or threading a callback back out, for no gain — the bar is per-tab chrome, not a property of the aside. This is the same placement the toolbar block already had, just drawn in the panel instead of the window. | Spec author |
| 8 | Is `PromptsView` rendered anywhere but the aside? | No. It has exactly one call site, `ContentView.swift:915`. Its doc comment claims "Used in both the sidebar detail and worktree aside panel" (`PromptsView.swift:4`) — the sidebar's Prompts destination is `PromptListView` plus `PromptDetailView` (`ContentView.swift:934-939`), a different view. The comment is stale and is corrected in the same change, since it is the sentence that would otherwise make this decision look unsafe. | Spec author |
| 9 | One bar type shared, or one written per view? | One shared `AsideBottomBar` in a new file `Sources/App/AsideBottomBar.swift`, taking the tooltip text and the action. The chrome — divider, `.bar` background, padding, leading alignment — is identical for both tabs, and writing it twice is exactly the drift the two identical toolbar blocks already show. It is not a generic container: its one control is the `+`, so it takes `help` and `action` rather than a `@ViewBuilder`. A second control, if one is ever wanted, is that change's problem. | Spec author |
| 10 | Why a new file rather than an existing one? | `ContentView.swift` is 1022 lines against SwiftLint's 1000-line `file_length` **error** and only builds via the file-wide `swiftlint:disable` on its first line; CLAUDE.md says the next addition there needs a split first. `ContentViewHelpers.swift` is where `WorktreeStatusBar` lives, but the bar is aside chrome, not a `ContentView` helper. A file named for the type is the convention `ToolbarGroupBreak.swift` and `SidebarHeaderControls.swift` already set. | Spec author |
| 11 | What does the `+` itself look like? | `SidebarHeaderButton(systemImage: "plus")` (`SidebarHeaderControls.swift:17-28`) — the app's existing small plain `+`: a 24×24 body-size glyph, secondary until the pointer is over it, `.buttonStyle(.plain)`. Reused rather than re-drawn, even though the type is named for the sidebar header, because duplicating its twelve lines to avoid the name is the worse trade. Renaming it is a follow-up, not this change. | Spec author |
| 12 | Where does the tooltip go? | `.help(help)` is applied to the `SidebarHeaderButton` from inside `AsideBottomBar`. `.help` is an ordinary view modifier, so this needs no change to `SidebarHeaderControls.swift`. The two strings are carried over unchanged: "New todo" and "New prompt". | Spec author |
| 13 | Does the bar carry an accessibility label? | Yes, `.accessibilityLabel(help)` beside the `.help`. The button's label is a bare `Image(systemName:)`, which VoiceOver reads as "plus". `WorktreeStatusBar`'s secondary-terminal toggle (`ContentViewHelpers.swift:121`) sets both for the same reason. | Spec author |
| 14 | What chrome exactly? | `.background(.bar)` with `.overlay(alignment: .top) { Divider() }` — the shape `WorktreeStatusBar` already uses (`ContentViewHelpers.swift:128-129`), so the aside's bottom edge and the window's status bar below it read as one family. Padding is the bar's own; the `SidebarHeaderButton` glyph already carries a 24×24 frame, so the bar adds 8 leading and 4 vertical and lets the button's frame set the rest. Final numbers are confirmed by hand in the running app. | Spec author |
| 15 | Is `ToolbarGroupBreak` now dead? | No. Five call sites remain: `PromptListView.swift:39`, `CommandsView.swift:37`, `WorkTaskListView.swift:59` and `ContentView.swift:199, 206, 217`. The type stays. | Spec author |
| 16 | Where does the bar sit relative to the window status bar? | Above it and inset to the aside's width. The aside is a 380-wide column inside the terminal/aside `HStack` (`ContentView.swift:899-920`); `WorktreeStatusBar` is a sibling of that `HStack` in the enclosing `VStack` (`ContentView.swift:924-932`) and spans the full window width. So the two bars stack, the aside's stopping at the aside's leading divider. | Spec author |
| 17 | Does the bar show when the list is empty? | Yes, both tabs, pinned to the bottom. Each view's empty state already carries `.frame(maxWidth: .infinity, maxHeight: .infinity)` (`PromptsView.swift:24`, `TodosPanelView.swift:54`) inside a `VStack(spacing: 0)`, so appending the bar to that stack puts it at the bottom in the empty case exactly as in the populated one. Creating the first todo or prompt is precisely when the `+` is most needed. | Spec author |
| 18 | Any new tests? | No. The change is view chrome with no decision rule to lift out: which tab renders is settled by the existing `switch effectiveSidePanelTab` (`ContentView.swift:904-918`), which `SidePanelTabTests` already covers, and the bar is unconditional within its two branches. There is nothing here of the shape CLAUDE.md asks to be lifted into a pure helper. The criteria are confirmed by hand in the running app, with `./scripts/ci.sh` as the regression check. | Spec author |
| 19 | What does the bar's control look like after the hands-on check? | A real push button, not the borderless glyph decision 11 chose: `Label("Add Todo", systemImage: "plus")` / `Label("Add Prompt", systemImage: "plus")` with `.labelStyle(.titleAndIcon)`, leading-aligned, styled `.glass` on macOS 26 and later and `.bordered` below. The glyph read as unfinished chrome rather than an action. This supersedes decisions 11, 12 and 13: no `.help` tooltip (a text-labelled button needs none) and no `.accessibilityLabel` (the `Label`'s title is one). The divider, the `.bar` background and the leading alignment stay; the bar's padding becomes 8 horizontal / 6 vertical, since 8 leading / 4 vertical was sized for a 24-pt borderless glyph. `SidebarHeaderButton` therefore has only sidebar callers again, so the follow-up about renaming it is moot. | Operator |
| 21 | What does the control look like after the second hands-on check? | A single full-width glass button on the panel itself, no bar: no `Divider`, no `.bar` background, no `HStack`/`Spacer`. The glass is built the way the aside tab strip builds its capsule (`ContentView.sidePanelTabStrip`, `MainTerminalTabStrip.tabsCapsule`) — on macOS 26 and later a `.buttonStyle(.plain)` `Button` whose label is padded 6 vertical and `.frame(maxWidth: .infinity)`, with `.glassEffect(.regular.interactive(), in: Capsule())` and a `Capsule().strokeBorder(Color(nsColor: .separatorColor), lineWidth: 0.5)` overlay; below macOS 26, `.buttonStyle(.bordered)` at `.controlSize(.large)` with the same full-width frame. Insets are 12 horizontal, 12 bottom and 8 top, mirroring the tab strip's 12 so the aside's top and bottom match. `.buttonStyle(.glass)` on an opaque bar rendered like `.bordered`: Liquid Glass needs content behind it, and the `.bar` background was that content. The type is renamed `AsideAddButton` (`Sources/App/AsideAddButton.swift`) because it is no longer a bar, and `applyGlassButtonStyle()` is deleted with its only caller, leaving `applyPrimaryActionStyle(tint:)` alone in `GlassButtonStyles.swift`. This supersedes decision 1's bar chrome, decision 14 entirely and decision 19's divider, `.bar` background and leading alignment; decision 19's titled `Label` with `.labelStyle(.titleAndIcon)`, no tooltip and no `.accessibilityLabel` all stand. | Operator |
| 20 | Where does the macOS 26 style split live? | `Sources/App/GlassButtonStyles.swift`, a new file holding `applyGlassButtonStyle()` beside the existing `applyPrimaryActionStyle(tint:)`, which moves there out of `WorkTaskWindow.swift`'s `// MARK: - Glass Styling` extension unchanged. One file owns the `#available(macOS 26.0, *)` check rather than a second copy appearing in `AsideBottomBar`, and a shared button-style helper does not belong in a file named for one window. | Spec author |
| 22 | May a button hand-build its glass? | No, never. Operator, verbatim: "We should NEVER do a hand-built glass. That is a big smell." Buttons take the system styles — `.glass` / `.glassProminent` on macOS 26 and later, `.bordered` / `.borderedProminent` below — through `GlassButtonStyles.swift`, which owns that availability split; `.glassEffect` plus a stroke is for non-button containers such as the aside tab strip and the main terminal tab strip. A hand-built glass button drops the system font, padding, shape and hover/press treatment and reads as foreign beside stock buttons like Create Task. So `AsideAddButton` is one `Button` styled by `applyGlassButtonStyle()` at `.controlSize(.large)` with its label `.frame(maxWidth: .infinity)`; `.buttonStyle(.plain)`, the `.glassEffect(.regular.interactive(), in: Capsule())`, the separator-colour capsule stroke and the label's 6-point vertical padding are all gone. `applyGlassButtonStyle()` returns to `GlassButtonStyles.swift`; the `.controlSize` stays at the call site. The 12 horizontal / 8 top / 12 bottom insets and the `Label(title, systemImage: "plus")` with `.titleAndIcon` are unchanged. This supersedes decision 21's glass construction and restores decision 20; the rule is recorded in `CLAUDE.md`. | Operator |

## Assumptions

Each verified at base `484482d`. No probe script or temporary file was written into the repo; all
inspection was reading the tree.

1. **Both aside panels' roots are already `VStack(spacing: 0)`, so the bar appends without
   restructuring.** `PromptsView.swift:14` and `TodosPanelView.swift:44`. In both, the content is
   the stack's only child today.
2. **The toolbar `+` really does come and go with the aside tab.** `TodosPanelView()` and
   `PromptsView(...)` are constructed inside `ContentView`'s `switch effectiveSidePanelTab` under
   `if asideVisible` (`ContentView.swift:899-918`). A view that is not in the hierarchy declares no
   toolbar content, so hiding the aside or switching to the Task tab removes the `+` from the
   window toolbar and the remaining items reflow.
3. **`PromptsView` has one call site.** `ContentView.swift:915`, confirmed by grep across `Sources/`
   and `Tests/`. `TodosPanelView` likewise has one, `ContentView.swift:913`.
4. **`SidebarHeaderButton` is internal and reachable from the new file.** `SidebarHeaderControls.swift:17`
   declares it with no access modifier; only the shared `SidebarHeaderIcon` it draws is `private`.
   All Swift sources are one module (`project.yml` globs `Sources`).
5. **`ToolbarGroupBreak` survives the removal.** Five other call sites, listed in decision 15.
6. **`.bar` + top `Divider()` is an established in-app bar.** `ContentViewHelpers.swift:128-129`.
7. **No test references either view or their toolbar items.** Neither `PromptsView`,
   `TodosPanelView` nor `TaskAsideView` appears anywhere under `Tests/`; nothing in `Sources/Ghostty`
   references them either.
8. **No keyboard shortcut is in play.** Neither toolbar `+` declared a `.keyboardShortcut`, and
   `AppKeyboardShortcuts` has no entry for either action, so removing them claims and releases
   nothing.
9. **`ContentView.swift` is past SwiftLint's `file_length` error.** 1022 lines against
   `error: 1000` (`.swiftlint.yml`), carried by `// swiftlint:disable file_length` at
   `ContentView.swift:1`. This change removes lines from `PromptsView.swift` (171) and
   `TodosPanelView.swift` (172) and adds a new ~25-line file; no file crosses the 700-line warning.

## Objective

The `+` that creates a todo or a prompt sits at the bottom of the panel it fills, and the window
toolbar's worktree buttons hold still whichever aside tab is showing.

### Success criteria

1. With the aside open on **Todos**, a full-width **Add Todo** button, plus glyph and title both
   showing, sits below the list inside the 380-wide aside column, with no divider and no bar behind
   it. Clicking it starts a new todo row, exactly as the toolbar `+` did.
2. With the aside open on **Prompts**, the same button appears, titled **Add Prompt**, creating a
   prompt and opening its window, exactly as the toolbar `+` did.
3. On the **Task** tab the aside shows no add button, and the Create Task CTA is unchanged.
4. The window toolbar shows only the worktree items — Run, Open in, Remove worktree, Show/Hide
   aside. Switching between Task, Todos and Prompts, and hiding and showing the aside, does not move
   or change them.
5. Both buttons show when their list is empty, pinned to the bottom of the panel.
6. The button wears the system `.glass` button style on macOS 26 and later, at `.controlSize(.large)`,
   and `.bordered` below — the stock treatment, not a hand-built capsule. It shows no tooltip, and
   VoiceOver reads "Add Todo" / "Add Prompt" rather than "plus" (decisions 19, 21, 22).
7. The button is inset to the aside column and sits above the full-width worktree status bar; it is
   not drawn over the terminal.
8. The File menu's New Prompt item behaves exactly as before: enabled on the sidebar's Prompts
   destination, greyed out elsewhere, no key equivalent. No shortcut anywhere in the app changes.
9. `./scripts/ci.sh` is green and `swiftlint lint --quiet` reports no new warnings or errors.

### Test coverage this requires

None new (decision 18). Criteria 1–7 are SwiftUI view state confirmed by hand in the running app;
criterion 8 is a menu-enablement check made the same way. The existing suite, `SidePanelTabTests`
and `AppKeyboardShortcutsTests` included, must stay green unchanged — that is the pin on "nothing
else moved".

## Verification

```bash
./scripts/ci.sh
```

Regenerates the Xcode project, lints, builds and runs the test suite — the regression check for
every build task and the full gate at sign-off, per CLAUDE.md's `## Pipeline` section. It is the
only runner of the test suite; the new file is invisible to the build until its `xcodegen generate`
runs, so do not substitute a hand-written `xcodebuild` line.

The view criteria are confirmed against the running app (`./scripts/run.sh`) on a non-main worktree
(all three tabs) and on main (Todos and Prompts only), with each list both empty and populated.
Expect the un-gitignored `default.profraw` in the repo root after any Debug launch; report it before
sign-off and never `git add -A`.

## Files touched

| File | Change |
| --- | --- |
| `Sources/App/AsideAddButton.swift` | New. The shared full-width add button: a `Label(title, systemImage: "plus")` on a system-styled button — `.glass` on macOS 26 and later, `.bordered` below — at `.controlSize(.large)`, drawn on the panel with no bar behind it (decisions 9, 19, 21, 22). |
| `Sources/App/GlassButtonStyles.swift` | New. `applyPrimaryActionStyle(tint:)`, moved unchanged out of `WorkTaskWindow.swift`, and `applyGlassButtonStyle()` beside it. The one place the app splits button styling between Liquid Glass and its fallback (decisions 20, 22). |
| `Sources/App/WorkTaskWindow.swift` | The `// MARK: - Glass Styling` extension moves out to `GlassButtonStyles.swift`; nothing else changes (decision 20). |
| `Sources/App/TodosPanelView.swift` | The `.toolbar` block and its `ToolbarGroupBreak` and comment header are removed; an `AsideAddButton` calling `startCreating()` is appended to the root `VStack` (decisions 3, 7). |
| `Sources/App/PromptsView.swift` | Same removal; an `AsideAddButton` calling the existing create-and-open action is appended to the root `VStack`. The stale doc comment on line 4 is corrected (decisions 3, 7, 8). |
| `CLAUDE.md` | The merge-order paragraph at 161-163 is rewritten to drop `PromptsView` / `TodosPanelView`, which no longer declare toolbar content (decision 6). A bullet records the no-hand-built-glass-buttons rule (decision 22). |
| `docs/superpowers/specs/2026-09-19-aside-bottom-bar-plus.md` | This document. |
| `docs/superpowers/plans/2026-09-19-aside-bottom-bar-plus.md` | The plan, written by the next stage. |

## Out of scope

- The Task tab: no bar, and `TaskAsideView`'s Create Task CTA is untouched (decision 2).
- The window toolbar's four worktree items, `RunCommandMenu`, `OpenInMenu` and `ToolbarGroupBreak`
  itself, all unchanged (decision 15).
- The `+` in `PromptListView`, `WorkTaskListView`, `CommandsView` and the sidebar headers. They are
  toolbar or header buttons in their own right and this change does not generalise the bar to them.
- Any keyboard shortcut: none added, changed, claimed or released, and `AppKeyboardShortcuts` is not
  edited (decision 4).
- The create actions themselves — what a new todo or prompt is, where it is stored, how it is
  opened.
- The aside tab strip, its glass capsule, the 380-point width, tab persistence and
  `resolveSidePanelTab`.
- Renaming `SidebarHeaderButton`. Decision 19 drops the aside's use of it, so its only callers are
  sidebar ones again and the rename is moot.
- Splitting `ContentView.swift` below SwiftLint's `file_length` error. This change adds nothing to
  it (decision 10); the split remains owed.
