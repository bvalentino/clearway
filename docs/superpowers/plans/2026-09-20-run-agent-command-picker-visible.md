# Run agent command picker visible on the create sheet — implementation plan

**Date:** 2026-09-20
**Base:** b4369a5

Breaks down `docs/superpowers/specs/2026-09-20-run-agent-command-picker-visible.md`. Every design
decision below is carried from that spec; this document only orders the work and says how each
piece is verified.

## Architecture decisions carried from the spec

- The "Run after create" field moves out of the collapsed **Advanced** block into the sheet's main
  body, directly below Status and above the Advanced row, and is relabelled
  **"Run agent command after create"**. That label is the field's only copy — no helper text.
- Advanced keeps Base branch and Fetch before creating, and nothing else.
- Both that field's control and the Status control above it span the sheet's 280pt content column.
  The sheet is `.padding(20)` then `.frame(width: 320)` (`Sources/App/SidebarSheets.swift:169-170`),
  so 280pt is what the `TextField`s above already measure.
- A SwiftUI `Picker` cannot be made to span that column: it clamps down to its AppKit intrinsic
  width (80pt for these lists) and `.frame(maxWidth: .infinity)` leaves it at 80pt while **centering**
  it, which is worse than today. Measured at deployment targets 13.0, 14.0 and 26.0.
- So both pickers become one new `NSViewRepresentable` over `NSPopUpButton`,
  `Sources/App/FullWidthPicker.swift`, generic over a `Hashable` selection, whose
  `sizeThatFits(_:nsView:context:)` returns the proposed width. `ProposedViewSize` and that method
  are macOS 13.0 API, matching `MACOSX_DEPLOYMENT_TARGET` (`project.yml:11`). This is the same
  system control SwiftUI itself instantiates for a `Picker`, not a hand-built one.
- The Status rows keep their tinted SF Symbols, drawn as `NSMenuItem.image` from
  `NSImage(systemSymbolName:)` with `NSImage.SymbolConfiguration(paletteColors:)`. Dropping to
  text-only would be a visible regression against `WorktreeStatusLabel`.
- Nothing about behaviour changes: same `onAppear` seeding from
  `savedCommandManager.afterCreateCommand`, same `CommandDefaults.resolve` on Create, same
  `setAfterCreateDefault` on the `.apply` branch only, same
  `TerminalManager.firstTabSource(afterCreateCommand:mainCommand:)` first-tab rule. No file outside
  the two named below is touched.
- One sheet covers both doors: `CreateWorktreeSheet`'s optional `startPrefill` only retitles the
  sheet, adds the read-only Task row and seeds the draft, so a single edit covers New Worktree and
  Start Task.
- The empty case needs no work: the command list is `Text("None")` plus a `ForEach` over
  `savedCommandManager.agentCommands`, so a project with no agent-kind commands renders the field
  with None alone.
- No new tests. The change adds no decision rule to pin, and nothing asserts on the sheet's layout
  today. `./scripts/ci.sh` is the gate; the operator confirms the layout by hand. Build agents do
  not launch the app.
- No `project.yml` edit for the new file: the target globs `Sources` (`project.yml:25-26`) and
  `scripts/ci.sh` runs `xcodegen generate` before building.
- `WorktreeStatusLabel` stays: `SidebarView.swift:464` still renders it in the sidebar's Status
  submenu, which is out of scope.

## Dependency graph

```
T1 (FullWidthPicker.swift) ──> T2 (SidebarSheets.swift: move, rename, adopt)
```

T2 cannot compile without the type T1 introduces. T1 leaves the app's behaviour unchanged — the new
type has no call site until T2 — and is verified by the build and the linter.

### T1: The full-width popup button wrapper

**Files**

- `Sources/App/FullWidthPicker.swift` (new)

**What it does**

Adds a SwiftUI `NSViewRepresentable` that renders one `NSPopUpButton` filling the width it is
offered. Shape:

```swift
struct FullWidthPicker<Value: Hashable>: NSViewRepresentable {
    struct Row: Equatable {
        let value: Value
        let title: String
        var symbol: String?
        var tint: Color?
    }

    let label: String
    @Binding var selection: Value
    let rows: [Row]
}
```

- `makeNSView` builds an `NSPopUpButton(frame: .zero, pullsDown: false)`, points its `target` and
  `action` at the coordinator, and sets `setAccessibilityLabel(label)` — the SwiftUI `Picker` it
  replaces carried its title for VoiceOver even under `.labelsHidden()`, and `LabeledField` draws
  the visible label.
- `updateNSView` rebuilds the menu **only when `rows` differs from what the coordinator last
  applied**, so a keystroke in the Name field cannot rebuild an open menu. Each `Row` becomes an
  `NSMenuItem` whose `title` is `row.title`; when `symbol` is non-nil the item's `image` is
  `NSImage(systemSymbolName:accessibilityDescription:)` with a symbol configuration built from
  `NSImage.SymbolConfiguration(paletteColors: [NSColor(tint)])` merged (`applying(_:)`) with a
  point size matching the menu font, and `isTemplate = false` so AppKit does not recolor the tint
  away. It then selects the item whose row value equals `selection`, and sets
  `isEnabled` from `@Environment(\.isEnabled)`.
- The coordinator holds the binding and the applied rows; its action reads
  `sender.indexOfSelectedItem` and writes `rows[index].value` back through the binding.
- `sizeThatFits(_ proposal: ProposedViewSize, nsView: NSPopUpButton, context: Context) -> CGSize?`
  returns the proposed width when it is non-nil (falling back to the intrinsic width) and the
  intrinsic height. This is the whole reason the type exists.

The `@Environment(\.isEnabled)` read is load-bearing and is not in the spec's file table: a SwiftUI
`.disabled(_:)` sets that environment value but does **not** reach an AppKit control on its own,
and both call sites carry `.disabled(isCreating)` today. Without it the two controls would stay live
while a create is in flight.

No other file references the type yet.

**Acceptance criteria**

- `FullWidthPicker<Value: Hashable>` exists with the `label` / `selection` / `rows` members above,
  and `Row` carries a title plus an optional symbol and tint.
- `sizeThatFits` returns the proposed width, so the control grows to the column it is given.
- A row with a `symbol` and a `tint` produces an `NSMenuItem` carrying a non-nil, non-template
  `image`; a row without one produces an item with no image.
- `isEnabled` from the environment reaches `NSPopUpButton.isEnabled`.
- The file compiles against the macOS 13.0 deployment target with no availability guard.

**Verification**

- `./scripts/ci.sh` green — it runs `xcodegen generate` first, without which the new file is
  invisible to the build.
- `swiftlint lint --quiet` reports zero errors and introduces no new warning.

### T2: Move, rename and adopt the field in the create sheet

**Files**

- `Sources/App/SidebarSheets.swift`

**What it does**

Three edits inside `CreateWorktreeSheet.body`, all within the existing `VStack`:

1. **Move.** Lift the `LabeledField("Run after create")` block out of the `if showingAdvanced`
   `VStack` (`SidebarSheets.swift:103-112`) and place it directly after the Status field and before
   the hand-built Advanced `Button` row. The advanced block is left holding Base branch and the
   Fetch before creating toggle, keeping its
   `.frame(maxWidth: .infinity, alignment: .leading)`.
2. **Rename.** Its `LabeledField` label becomes `"Run agent command after create"`. No other copy.
3. **Adopt.** Both that field and the Status field above it swap their `Picker` for
   `FullWidthPicker`, keeping `.disabled(isCreating)` on each:
   - Status: `label: "Status"`, `selection: $status`, rows from `WorktreeStatus.allCases` mapping
     `displayName`, `symbol` and `color` onto `Row`. The `WorktreeStatusLabel` /
     `ForEach` / `.labelsHidden()` combination goes away here — and only here.
   - Command: `label: "Run agent command after create"`, `selection: $afterCreateCommandId`
     (`UUID?`, which is `Hashable`), rows = a `Row(value: UUID?.none, title: "None")` followed by
     `savedCommandManager.agentCommands` mapped to `Row(value: UUID?.some(command.id), title:
     command.name)`. Order is preserved: None first, then the list as the manager returns it.

Nothing else in the file changes. The `onAppear` seeding (`SidebarSheets.swift:171-173`), the
`CommandDefaults.resolve` call and `setAfterCreateDefault` on the `.apply` branch
(`SidebarSheets.swift:124-144`) are untouched, as are `Self.outcome`, `Self.prefill` and
`NameEntrySheet`.

**Acceptance criteria**

- The sheet renders, in order: headline, optional Task row, Name, Branch name, Status,
  Run agent command after create, the Advanced row, then the Cancel/Create row.
- `showingAdvanced` reveals Base branch and Fetch before creating, and nothing else — no command
  picker remains inside that block.
- Both the Status and the command control are `FullWidthPicker`s and no `Picker` remains in
  `CreateWorktreeSheet`.
- The command rows are None followed by `savedCommandManager.agentCommands`, and with no agent
  commands saved the field still renders with None alone.
- Both controls are disabled while `isCreating` is true.
- No behavioural code moves: seeding, `CommandDefaults.resolve`, `setAfterCreateDefault` and the
  outcome switch are byte-identical to `b4369a5` apart from indentation.
- `WorktreeStatusLabel` is still defined and still used by `SidebarView.swift:464`.

**Verification**

- `./scripts/ci.sh` green: `xcodegen generate`, `swiftlint lint --quiet`, build, and the
  `ClearwayTests` suite — `CreateWorktreeOutcomeTests`, `SavedCommandManagerTests` and
  `SavedCommandStoreTests` continue to pin the behaviour around the field.
- `git diff --stat` shows exactly the two files from this plan changed.
- The 280pt full-width rendering and the tinted status symbol are confirmed by the operator opening
  both the New Worktree and the Start Task sheets; build agents do not launch the app.

## Build log

### T1: The full-width popup button wrapper

**What landed**

| File | State |
| --- | --- |
| `Sources/App/FullWidthPicker.swift` | New. `NSViewRepresentable` over `NSPopUpButton`, generic over `Value: Hashable`, with `Row(value:title:symbol:tint:)`, `label`, `@Binding selection`, `rows`, an `@Environment(\.isEnabled)` read, a menu rebuilt only when `rows` changes, and `sizeThatFits` returning the proposed width. |
| `Clearway.xcodeproj/project.pbxproj` | Regenerated by `xcodegen generate` inside `scripts/ci.sh`; the only change is the new file's two references. |

No call site yet — T2 adopts it.

**Evidence**

No test was written: plan decision 8 and spec decision 8 settle that this change adds no decision
rule to pin and that nothing on an `NSViewRepresentable` is reachable from XCTest. So there is no
watched failure to quote. The acceptance criteria were instead checked with a headless
`NSHostingView` probe in the session scratchpad (never in the repo), compiled
`-swift-version 6 -target arm64-apple-macosx13.0` from the shipped file verbatim plus a harness that
lays the control out at the sheet's real geometry (`.padding(20)`, `.frame(width: 320)`) beside a
`TextField`, and disables the second picker:

```
textfield frame=(0.0, 0.0, 280.0, 24.0)
popup frame=(0.0, 0.0, 280.0, 24.0) enabled=true a11y=Status items=2 selectedTitle=In progress
   item 'Todo' image=yes template=false enabled=true
   item 'In progress' image=yes template=false enabled=true
popup frame=(0.0, 0.0, 280.0, 24.0) enabled=false a11y=Run agent command after create items=3 selectedTitle=None
   item 'None' image=nil template=- enabled=true
   item 'cmd 6B10' image=nil template=- enabled=true
after action: selectedTitle=Todo boxValue=todo
```

That covers every acceptance criterion: 280pt, matching the `TextField` above it; a symbol row
carries a non-nil non-template image and a row without one carries no image; `.disabled(true)`
reaches `NSPopUpButton.isEnabled`; the accessibility label is the passed `label`; and sending the
control's action writes the row's value back through the binding (`boxValue=todo`) without the
`@objc` thunk on the `@MainActor` coordinator trapping. It compiled clean at the 13.0 deployment
target, so no availability guard is needed.

**Deviations from the plan**

- `NSMenu.autoenablesItems = false` on the built menu. Not in the plan. A hand-built `NSMenu`
  auto-enables, which validates each item against the responder chain; these items carry no action
  of their own, so the whole list would render greyed out.
- `sizeThatFits` falls back to the intrinsic width for a **non-finite** proposed width as well as a
  nil one. SwiftUI probes a view with `ProposedViewSize.infinity`; returning an infinite width from
  there is not a size. The 280pt case in the probe is unaffected.

**Gate**

`./scripts/ci.sh` — passed. `xcodegen generate`, `swiftlint lint --quiet` (0 errors, no finding in
the new file), build, then `Executed 676 tests, with 0 failures (0 unexpected)`, `==> CI passed.`
`git status --porcelain` before committing showed only this task's two files.

### T2: Move, rename and adopt the field in the create sheet

**What landed**

| File | State |
| --- | --- |
| `Sources/App/SidebarSheets.swift` | `CreateWorktreeSheet.body`: the command field moved out of the `showingAdvanced` block to directly below Status; its `LabeledField` label is now "Run agent command after create"; both it and Status are `FullWidthPicker`s, each keeping `.disabled(isCreating)`. Two private computed row properties and one `static let afterCreateLabel` added below `body`. |

Advanced now holds Base branch and Fetch before creating alone. No `Picker` remains in the file.
`WorktreeStatusLabel` is still defined and still rendered at `SidebarView.swift:464`. Nothing else
changed: `git diff` shows the `onAppear` seeding, the `CommandDefaults.resolve` call, the
`setAfterCreateDefault` line on the `.apply` branch, `Self.outcome`, `Self.prefill` and
`NameEntrySheet` outside every hunk, so the behavioural code is byte-identical to `b4369a5` and not
even re-indented.

**Evidence**

No test was written, and there is therefore no watched failure to quote. Plan decision 8 and spec
decision 8 settle it: this task moves and re-skins two controls, adds no decision rule to pin, and
nothing in `CreateWorktreeSheet.body` is reachable from XCTest. The rules the change sits on are
already pinned elsewhere and were re-run green as the regression check —
`CreateWorktreeOutcomeTests` (the outcome switch), `SavedCommandManagerTests` (`agentCommands`,
which feeds the new rows) and `SavedCommandStoreTests` (the `CommandDefaults` round-trip behind
seeding and write-back). The acceptance criteria that are not behavioural were checked by reading
the diff, listed above; the 280pt rendering and the tinted status symbol are the operator's to
confirm, since build agents do not launch the app.

**Deviations from the plan**

- The plan mapped both row arrays inline in `body`. They are two `private var` computed properties
  instead, and the label is a `static let afterCreateLabel`. `FullWidthPicker` takes the label
  twice over — `LabeledField`'s visible text and the control's accessibility label — so an inline
  literal would have been written twice and could drift; and two inline `map`s inside a
  `@ViewBuilder` add type-checking work for no gain. The rows and the label are otherwise exactly
  what the plan specifies: None first, then `savedCommandManager.agentCommands` in order, and
  `WorktreeStatus.allCases` carrying `displayName` / `symbol` / `color`.

**Gate**

`./scripts/ci.sh` — passed. `xcodegen generate`, `swiftlint lint --quiet` (zero output, so zero
errors and no new warning), build, then `Executed 676 tests, with 0 failures (0 unexpected)`,
`==> CI passed.` `git status --porcelain` before committing showed `M Sources/App/SidebarSheets.swift`
and nothing else — no `default.profraw`, since no Debug launch happened.
