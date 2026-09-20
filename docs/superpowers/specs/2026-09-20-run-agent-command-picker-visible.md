# Run agent command picker visible on the create sheet

**Date:** 2026-09-20
**Base:** b4369a5

The "Run after create" picker that PR #234 added to the worktree create sheet sits inside the
collapsed **Advanced** disclosure, so operators never saw it and read the feature as missing. This
moves the field into the sheet's main body below Status, renames it to "Run agent command after
create", and makes it — and the Status picker above it — span the sheet's content column the way
the Name and Branch name fields already do. Nothing about what the picker lists, how the pick is
stored, or how it becomes the new worktree's first tab changes.

## Decisions

| # | Question | Decision | Why the alternatives lose |
| --- | --- | --- | --- |
| 1 | Where does the field go? | Main body, directly below Status and above the Advanced row. | Settled by the operator in the task brief. Advanced is for base-branch and fetch settings; this field is the reason most people open the sheet. |
| 2 | What does the label read? | "Run agent command after create", and it is the field's only copy. | Settled in the task brief. "Run after create" did not say an agent command was what it ran. No helper text — project rule against descriptive copy under labels. |
| 3 | Which pickers go full width? | The new one and the Status picker directly above it. | Settled in the task brief: the two must read as one convention, and the text fields above them already fill the column. |
| 4 | How is full width achieved? | An `NSViewRepresentable` over `NSPopUpButton` whose `sizeThatFits` returns the proposed width; both pickers use it. | Measured, not assumed — see Assumptions 3–5. `.frame(maxWidth: .infinity)` leaves the control at its 80pt content width and **centers** it, which is worse than today's left-aligned control. `Form`/`.formStyle`, an exact `.frame(width: 280)`, `.frame(maxWidth:, alignment: .leading)`, and frames on the option rows all measured 80pt too, because SwiftUI flattens a `Picker`'s rows into `NSMenuItem` titles and the popup button takes its AppKit intrinsic width. `.pickerStyle(.segmented)` does fill, but cannot carry a variable-length command list. A hand-built `Menu` plus a styled label is the "not a hand-built control" the task forbids; an `NSPopUpButton` is the same system control SwiftUI itself instantiates. |
| 5 | Where does that wrapper live? | One new file, `Sources/App/FullWidthPicker.swift`, generic over a `Hashable` selection with rows carrying a title and an optional SF Symbol + tint. | Two call sites in one sheet need it; a second copy inside `SidebarSheets.swift` would let the two pickers drift. Keeping it generic avoids a status-specific and a command-specific variant. |
| 6 | Do the Status rows keep their tinted symbols? | Yes — `NSMenuItem.image` from `NSImage(systemSymbolName:)` tinted with `NSImage.SymbolConfiguration(paletteColors:)`. | Dropping to text-only would be a visible regression against `WorktreeStatusLabel`. Verified rendering in the probe (Assumption 5). |
| 7 | Does the sidebar's Status picker change? | No. | `SidebarView`'s Status picker is `.pickerStyle(.inline)` inside an `NSMenu`, where rows already span the menu. Out of scope per the task brief. |
| 8 | Any new tests? | No. | The change adds no decision rule to pin; nothing in `Ghostty.SurfaceView`-style view code is reachable from XCTest. `CreateWorktreeOutcomeTests`, `SavedCommandManagerTests` and `SavedCommandStoreTests` continue to pin the behaviour around the field. `./scripts/ci.sh` is the gate; the operator confirms the layout by hand. |
| 9 | What stays in Advanced? | Base branch and Fetch before creating, nothing else. | Task brief. |
| 10 | Does anything about the pick's behaviour change? | No: same `onAppear` seeding from `afterCreateCommand`, same `CommandDefaults.resolve` on Create, same `setAfterCreateDefault` on the `.apply` branch only, same first-tab rule. | Task brief marks all of it out of scope. |

## Assumptions

Each was checked against the tree at b4369a5. The measurements come from headless
`NSHostingView` probes written to the session scratchpad (`pickerprobe.swift`, `probe2`–`probe5`),
never into the repo; each was compiled with `-target arm64-apple-macosx13.0` to match
`MACOSX_DEPLOYMENT_TARGET` (`project.yml:11`) and laid out at the sheet's real geometry.

1. **Both sheet variants are one view.** `CreateWorktreeSheet` takes an optional
   `startPrefill` that only retitles the sheet, adds a read-only Task row and seeds the draft
   (`Sources/App/SidebarSheets.swift:5-44`). So a single edit covers New Worktree and Start Task.
2. **The content column is 280pt.** The sheet is `.padding(20)` then `.frame(width: 320)`
   (`Sources/App/SidebarSheets.swift:169-170`). The probe measured the `TextField`s at exactly
   280pt, confirming "full width" means 280pt here.
3. **The SwiftUI `Picker` never grows past its content.** Measured at 80pt for a `None`/`plan`
   list in the real sheet geometry. It reached 280pt only when an option's *title string* was
   itself wider than the column — it clamps down, never up.
4. **`.frame(maxWidth: .infinity)` makes it worse.** The control stayed 80pt and its origin moved
   from x=60 to x=160: the frame centers a control that refuses to grow. Identical at
   deployment targets 13.0, 14.0 and 26.0, so this is not a linked-on-or-after behaviour.
5. **The `NSPopUpButton` wrapper works.** With `sizeThatFits` returning the proposed width, both
   a status list (tinted symbols) and a command list measured 280pt at x=60, height 24pt, with
   `selectedItem.image` non-nil for the status rows. `ProposedViewSize` and
   `NSViewRepresentable.sizeThatFits(_:nsView:context:)` are macOS 13.0 API — the probe compiled
   clean at that target.
6. **The empty case already works.** The picker renders `Text("None")` before a `ForEach` over
   `savedCommandManager.agentCommands` (`Sources/App/SidebarSheets.swift:104-108`), and
   `agentCommands` is just `SavedCommand.filter(commands, by: .agent)`
   (`Sources/App/SavedCommandManager.swift:72-74`), so a project with none saved renders the field
   with None alone.
7. **Seeding and write-back are untouched by a move.** Seeding is `onAppear`
   (`Sources/App/SidebarSheets.swift:171-173`) reading `afterCreateCommand`
   (`Sources/App/SavedCommandManager.swift:66-68`); the write-back is `setAfterCreateDefault` on the
   `.apply` branch only (`Sources/App/SidebarSheets.swift:136-144`). Neither depends on where the
   control is drawn.
8. **First-tab behaviour lives elsewhere.** `TerminalManager.firstTabSource(afterCreateCommand:mainCommand:)`
   (`Sources/App/TerminalManager.swift:211`) and `takeFirstTabSource`
   (`Sources/App/TerminalManager.swift:202`) decide that, reached through the creation mark. No view
   change touches it.
9. **A new file needs no `project.yml` edit.** The target globs the directory —
   `sources: - path: Sources` (`project.yml:25-26`) — and `scripts/ci.sh` runs `xcodegen generate`
   before building.
10. **No test reads the picker.** Grepping `Tests/` for `afterCreate` finds only
    `WorktreeHooksTests` (a different `afterCreate`, the shell hook) and `SavedCommandStoreTests`'
    `CommandDefaults` round-trips. Nothing asserts on the sheet's layout.

## Objective

Make the agent command a first-class field of the create sheet: visible without a disclosure,
named for what it does, and sized like the fields around it.

### Success criteria

- Opening either the New Worktree or the Start Task sheet shows a field labelled
  "Run agent command after create" with no click on Advanced.
- That field sits below Status and above the Advanced row.
- Its control spans the sheet's 280pt content column, left edge flush with the text fields above;
  so does the Status control, with its tinted status symbol still drawn.
- Advanced expands to Base branch and Fetch before creating, and nothing else.
- With no agent-kind saved commands the field still renders, offering only None.
- Behaviour is unchanged: the picker is seeded from the remembered default, the pick is written
  back only on a successful create, and the picked command opens as the new worktree's first tab in
  place of the Main Terminal tab.
- `./scripts/ci.sh` passes with a clean `git status --porcelain` (allowing for the un-gitignored
  `default.profraw` a Debug launch drops).

## Verification

```bash
./scripts/ci.sh
```

That is both the regression check and the full gate for this repo: it runs `xcodegen generate`
(without which the new Swift file is invisible to the build), `swiftlint lint --quiet`, then builds
and runs the `ClearwayTests` scheme. The layout itself is confirmed by the operator opening both
sheets; build agents do not launch the app.

## Files

| File | Change |
| --- | --- |
| `Sources/App/FullWidthPicker.swift` | New. `NSViewRepresentable` over `NSPopUpButton`, generic over a `Hashable` selection, rows carrying a title and an optional symbol + tint; `sizeThatFits` returns the proposed width. |
| `Sources/App/SidebarSheets.swift` | Move the command field out of the `showingAdvanced` block to just below Status; rename its label; switch both it and the Status field to `FullWidthPicker`. |

## Out of scope

- What the picker lists (agent-kind saved commands only), how the pick persists
  (`command-defaults.json`), and how it becomes the worktree's first tab.
- The rest of Advanced: Base branch and Fetch before creating stay where they are.
- Hiding the field when the project has no agent commands.
- `SidebarView`'s Status submenu picker, `SettingsView`'s pickers, and every other `Picker` in the
  app: none of them is in a fixed-width sheet column and none is mentioned by the task.
- Raising the macOS deployment target. The measurement in Assumption 4 holds at 26.0 too, so
  nothing would be gained.
