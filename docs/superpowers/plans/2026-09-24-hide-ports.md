# Plan: Hide ports

Breaks down `docs/superpowers/specs/2026-09-24-hide-ports.md`.

**Date:** 2026-09-24
**Base:** d8e191f (Give each destination its own window title (#262))

## Architecture decisions carried from the spec

- A hidden port is identified by its number alone, app-wide, across every worktree and project
  window (D1).
- The list lives in `SettingsManager` under `SettingsKey.hiddenPorts = "clearway.hiddenPorts"` in
  `UserDefaults`, never in git config (D2).
- State is `@Published private(set) var hiddenPorts: Set<UInt16>`. Its only writers are
  `hidePort(_ port: UInt16)` and `unhidePort(_ port: UInt16)`, and each one returns without
  publishing or writing when the set would not change (D3).
- Persisted as a sorted `[Int]` via `defaults.set`. The key is removed when the set becomes empty.
  It is read with `defaults.array(forKey:) as? [Int]`, keeping only values `UInt16(exactly:)`
  accepts. A missing or unreadable value reads as empty (D4).
- Filtering is `static func visible(_ ports: [UInt16], hiding hidden: Set<UInt16>) -> [UInt16]` on
  `PortAttribution`, applied after `attribute(_:to:)` in `WorktreeStatusBar.livePorts`. It keeps the
  input order. `attribute(_:to:)` is not changed (D5).
- `WorktreeStatusBar` reads `@EnvironmentObject private var settings: SettingsManager` (D6).
- Each port `Text` gets a `.contextMenu` with exactly two `Button`s in this order: "Hide Port" →
  `settings.hidePort(port)`, "Copy URL" → `PortLink.copyURL(port, to: .general)`. No divider, icons,
  or confirmation. The existing `.contentShape`, `.pointerCursorOnHover()`, `.onTapGesture` and
  `.help` stay as they are (D7).
- `PortLink.copyURL(_ port: UInt16, to pasteboard: NSPasteboard)` calls `clearContents()` and then
  `setString(urlString(port), forType: .string)`. The pasteboard parameter has no default.
  `PortLink.swift` imports `AppKit` in place of `Foundation` (D8).
- `Sources/App/HiddenPortsSettingsSection.swift` holds `struct HiddenPortsSettingsSection: View`
  with `@ObservedObject var settings: SettingsManager`. It is placed in `SettingsView` after
  `OpenInAppsSettingsSection(settings: settings)` (D9).
- The section is `Section("Hidden Ports")`. When the set is empty it shows one row,
  `Text("None").foregroundStyle(.secondary)`. Otherwise it shows one row per port from
  `settings.hiddenPorts.sorted()`: `Text(PortLink.label(port))`, a `Spacer()`, and a borderless
  `Button` with `Image(systemName: "minus.circle")` that calls `settings.unhidePort(port)`, with
  `.help("Unhide")` and `.accessibilityLabel("Unhide")`. No header control, footer, or helper text
  (D10).
- Unhiding does not trigger a rescan. `PortMonitor` is not changed (D11). No keyboard shortcuts (D12).
- Every port string goes through `PortLink`. No `"\(port)"` interpolation into a string literal.
- Never: changes to `PortScanner`, `PortMonitor`, or `attribute(_:to:)`; a sidebar or toolbar
  surface for ports; helper text in Settings; launching the app from a build agent (D13).

## Dependency graph

```
T1: hidden-ports state and filter  ──┬──> T3: status bar filters and context menu
T2: PortLink.copyURL               ──┘
T1 ─────────────────────────────────────> T4: Hidden Ports settings section
```

T1 and T2 are independent. T3 needs `SettingsManager.hidePort`, `hiddenPorts`,
`PortAttribution.visible` (T1) and `PortLink.copyURL` (T2). T4 needs `hiddenPorts` and
`unhidePort` (T1). T3 and T4 do not depend on each other.

## Tasks

### T1: Hidden-ports state and filter

**Files:**
- `Sources/App/SettingsManager.swift`
- `Sources/App/PortAttribution.swift`
- `Tests/SettingsManagerTests.swift`
- `Tests/PortAttributionTests.swift`

**What:**
- `SettingsKey`: add `static let hiddenPorts = "clearway.hiddenPorts"`.
- `SettingsManager`: add `@Published private(set) var hiddenPorts: Set<UInt16>` with a `didSet`
  that writes `hiddenPorts.sorted().map(Int.init)` via `defaults.set`, or calls
  `defaults.removeObject(forKey: SettingsKey.hiddenPorts)` when the set is empty.
- Add `func hidePort(_ port: UInt16)` (`guard !hiddenPorts.contains(port) else { return }`, then insert)
  and `func unhidePort(_ port: UInt16)` (`guard hiddenPorts.contains(port) else { return }`, then remove).
  Keep the doc comment short: why these are the only writers and why they return early (see
  `recordOpenInUse`).
- `init`: `self.hiddenPorts = Set((defaults.array(forKey: SettingsKey.hiddenPorts) as? [Int] ?? []).compactMap(UInt16.init(exactly:)))`.
- `PortAttribution`: add
  `static func visible(_ ports: [UInt16], hiding hidden: Set<UInt16>) -> [UInt16]` returning
  `ports.filter { !hidden.contains($0) }`.
- Tests in `SettingsManagerTests` (use the existing per-test suite `defaults`): `hiddenPorts` is
  empty on a fresh suite; `hidePort(5174)` is read back by a second `SettingsManager` on the same
  suite; `unhidePort` removes a port and a second instance sees it removed; unhiding the last port
  leaves `defaults.object(forKey: SettingsKey.hiddenPorts)` nil; `hidePort` twice leaves
  `hiddenPorts == [port]`; a stored array holding an out-of-range value (such as `[80, 70000, -1]`)
  reads back as `[80]`.
- Tests in `PortAttributionTests`: `visible([3000, 5174, 8080], hiding: [5174])` is `[3000, 8080]`;
  an empty hidden set returns the input unchanged; hiding every port returns `[]`; a hidden number
  not in the input changes nothing.

**Acceptance criteria:**
- `hiddenPorts` can only be changed through `hidePort` and `unhidePort`, and it survives a new
  `SettingsManager` on the same `UserDefaults`.
- The key is absent when nothing is hidden.
- `visible(_:hiding:)` drops exactly the hidden numbers and keeps the input order.
- `./scripts/ci.sh` exits 0.

**Verification:**
- `./scripts/ci.sh` exits 0 with the new `SettingsManagerTests` and `PortAttributionTests` cases
  passing.
- `git diff Sources/App/PortAttribution.swift` shows `attribute(_:to:)` unchanged.

### T2: PortLink.copyURL

**Files:**
- `Sources/App/PortLink.swift`
- `Tests/PortLinkTests.swift`

**What:**
- Replace `import Foundation` with `import AppKit`.
- Add `static func copyURL(_ port: UInt16, to pasteboard: NSPasteboard)` that calls
  `pasteboard.clearContents()` and then `pasteboard.setString(urlString(port), forType: .string)`.
  No default for `pasteboard`.
- `PortLinkTests`: add `import AppKit`. Add a test that creates
  `NSPasteboard(name: NSPasteboard.Name("PortLinkTests." + UUID().uuidString))`, calls
  `PortLink.copyURL(3000, to:)`, asserts `pasteboard.string(forType: .string) == "http://localhost:3000"`,
  and calls `releaseGlobally()` on the pasteboard afterwards (via `defer` or `addTeardownBlock`). Add a
  second case showing a previous string on the same pasteboard is replaced (write `"stale"` first,
  then copy 5174, and expect exactly `http://localhost:5174`).

**Acceptance criteria:**
- `copyURL` writes exactly `PortLink.urlString(port)` to the given pasteboard, with no grouping
  separator, and replaces what was there before.
- The tests never touch `NSPasteboard.general`.
- `./scripts/ci.sh` exits 0.

**Verification:**
- `./scripts/ci.sh` exits 0 with the new `PortLinkTests` cases passing.
- `grep -n "general" Tests/PortLinkTests.swift` prints nothing.

### T3: Status bar filters hidden ports and gains the context menu

**Files:**
- `Sources/App/ContentViewHelpers.swift`

**What:**
- `WorktreeStatusBar`: add `@EnvironmentObject private var settings: SettingsManager` beside the
  existing `worktreeManager` and `portMonitor` environment objects.
- `livePorts`: wrap the existing attribution result in
  `PortAttribution.visible(..., hiding: settings.hiddenPorts)`. The `if !ports.isEmpty` check in
  `livePortsView` then hides the whole ports section once every port is hidden.
- In `livePortsView`, after the existing modifiers on each port's `Text`, add
  `.contextMenu { Button("Hide Port") { settings.hidePort(port) }; Button("Copy URL") { PortLink.copyURL(port, to: .general) } }`,
  written as two separate lines inside the builder, in that order. Do not change or reorder
  `.contentShape`, `.pointerCursorOnHover()`, `.onTapGesture` or `.help`.

**Acceptance criteria:**
- The menu has exactly two items, "Hide Port" then "Copy URL", with no divider or icons.
- Hidden ports do not render, and a worktree whose ports are all hidden renders no ports section.
- The left-click, cursor and tooltip modifiers are unchanged.
- `./scripts/ci.sh` exits 0 and `swiftlint lint --quiet` reports no errors.

**Verification:**
- `./scripts/ci.sh` exits 0.
- `git diff Sources/App/ContentViewHelpers.swift` shows only the environment object, the
  `livePorts` wrap, and the `.contextMenu` block. None of the existing modifier lines are changed.
- The operator checks by hand that right-click shows the two items, Hide Port removes the port from
  every open window at once, Copy URL puts `http://localhost:<port>` on the clipboard, a left click
  still opens the browser, and the pointer cursor still shows on hover. Build agents do not launch
  the app.

### T4: Hidden Ports settings section

**Files:**
- `Sources/App/HiddenPortsSettingsSection.swift` (new)
- `Sources/App/SettingsView.swift`

**What:**
- New `struct HiddenPortsSettingsSection: View` with `@ObservedObject var settings: SettingsManager`.
  Give it a one-line doc comment matching `OpenInAppsSettingsSection`'s ("Settings → Hidden Ports.
  Its own file so `SettingsView` stays a plain `Form`.").
- Body: `Section("Hidden Ports")`. If `settings.hiddenPorts.isEmpty`, show
  `Text("None").foregroundStyle(.secondary)`. Otherwise, show
  `ForEach(settings.hiddenPorts.sorted(), id: \.self)` with rows of
  `HStack { Text(PortLink.label(port)); Spacer(); Button { settings.unhidePort(port) } label: { Image(systemName: "minus.circle") }.buttonStyle(.borderless).help("Unhide").accessibilityLabel("Unhide") }`.
- `SettingsView`: add `HiddenPortsSettingsSection(settings: settings)` directly after
  `OpenInAppsSettingsSection(settings: settings)`.
- `xcodegen generate` picks up the new file. `./scripts/ci.sh` runs it.

**Acceptance criteria:**
- The section is always present, lists hidden ports in ascending order, and shows one "None" row
  when nothing is hidden.
- Each row's button calls `unhidePort` for that row's port. The port label goes through
  `PortLink.label`.
- No header control, footer, or descriptive text.
- `./scripts/ci.sh` exits 0 and `swiftlint lint --quiet` reports no errors.

**Verification:**
- `./scripts/ci.sh` exits 0.
- `grep -nF '\(port' Sources/App/HiddenPortsSettingsSection.swift` prints nothing, so no port is
  interpolated into a string.
- The operator checks by hand that the section shows "None" when nothing is hidden, lists hidden
  ports in ascending order, and that Unhide brings a port that is still listening back to the status
  bar at once.

## Build log

### T1: Hidden-ports state and filter

| File | State |
| --- | --- |
| `Sources/App/SettingsManager.swift` | `SettingsKey.hiddenPorts`; `@Published private(set) var hiddenPorts: Set<UInt16>` persisted as a sorted `[Int]`, key removed when empty; `hidePort` / `unhidePort` with no-op guards; loaded in `init` through `UInt16(exactly:)`. |
| `Sources/App/PortAttribution.swift` | `visible(_:hiding:)` added. `attribute(_:to:)` unchanged. |
| `Tests/SettingsManagerTests.swift` | 6 cases: fresh suite empty, hide persists, unhide persists, last unhide removes the key, double hide keeps one entry, `[80, 70000, -1]` reads as `[80]`. |
| `Tests/PortAttributionTests.swift` | 4 `visible` cases: drops hidden and keeps order, empty hidden set, all hidden, unlisted hidden number. |

**Evidence.** Tests were written first and run against no-op stubs (`visible` returned its input,
`hidePort`/`unhidePort` did nothing, `hiddenPorts` was a constant `[]`). `./scripts/ci.sh` exited 65:

```
✖ testVisibleDropsHiddenPortsAndKeepsOrder, XCTAssertEqual failed: ("[3000, 5174, 8080]") is not equal to ("[3000, 8080]")
✖ testVisibleWithEveryPortHiddenReturnsNothing, XCTAssertEqual failed: ("[3000, 5174]") is not equal to ("[]")
✖ test_hidePort_persistsAcrossInstances, XCTAssertEqual failed: ("[]") is not equal to ("[5174]")
✖ test_hidePortTwice_keepsOneEntry, XCTAssertEqual failed: ("[]") is not equal to ("[443]")
✖ test_hidePortTwice_keepsOneEntry, XCTAssertEqual failed: ("nil") is not equal to ("Optional([443])")
✖ test_storedOutOfRangeValues_areDropped, XCTAssertEqual failed: ("[]") is not equal to ("[80]")
✖ test_unhidePort_removesThePortAndTheRemovalPersists, XCTAssertEqual failed: ("[]") is not equal to ("[5174]")
```

The remaining new cases (fresh suite empty, empty hidden set, unlisted hidden number, last unhide
removes the key) passed against the stubs, as expected: they pin behaviour a no-op already has.

**Deviations.** None.

**Gate.** `./scripts/ci.sh` after the last source edit: exit 0, 880 tests, 0 failures, lint clean.

### T2: PortLink.copyURL

| File | State |
| --- | --- |
| `Sources/App/PortLink.swift` | Imports `AppKit` in place of `Foundation`. `copyURL(_:to:)` calls `clearContents()` then `setString(urlString(port), forType: .string)`. No default pasteboard. |
| `Tests/PortLinkTests.swift` | Imports `AppKit`. 2 cases against a uniquely named `NSPasteboard`, released with `defer`: 3000 copies as `http://localhost:3000`; a `"stale"` string is replaced by exactly `http://localhost:5174`. |

**Evidence.** Tests were written first and run against an empty `copyURL` body. `./scripts/ci.sh`
exited 65:

```
✖ testCopyURLReplacesThePreviousContents, XCTAssertEqual failed: ("Optional("stale")") is not equal to ("Optional("http://localhost:5174")")
✖ testCopyURLWritesTheURLString, XCTAssertEqual failed: ("nil") is not equal to ("Optional("http://localhost:3000")")
```

**Deviations.** The plan allowed `defer` or `addTeardownBlock` for the release. `addTeardownBlock`
does not compile: its closure is `sending`, and capturing the non-`Sendable` `NSPasteboard` fails
with `Sending 'pasteboard' risks causing data races`. Each test uses `defer` instead.

**Gate.** `./scripts/ci.sh` after the last source edit: exit 0, 882 tests, 0 failures.
`grep -n "general" Tests/PortLinkTests.swift` prints nothing.

### T3: Status bar filters hidden ports and gains the context menu

| File | State |
| --- | --- |
| `Sources/App/ContentViewHelpers.swift` | `WorktreeStatusBar` reads `@EnvironmentObject private var settings: SettingsManager`. `livePorts` passes the attribution result through `PortAttribution.visible(_:hiding: settings.hiddenPorts)`. Each port `Text` gains `.contextMenu` with "Hide Port" → `settings.hidePort(port)` then "Copy URL" → `PortLink.copyURL(port, to: .general)`, after the unchanged `.contentShape`, `.pointerCursorOnHover()`, `.onTapGesture` and `.help`. |

**Evidence.** No new test. Both rules this task applies are already pinned by tests that were
watched failing in T1 (`visible(_:hiding:)`, `hidePort`) and T2 (`copyURL`). What remains is SwiftUI
wiring, the context menu, and live redraw, which the spec assigns to the operator's manual check
(D13). `SettingsManager` reaches the status bar through `.clearwayChrome(settings)`; its only call
site is `ContentView.swift:973`, inside a project window.

**Deviations.** None.

**Gate.** `./scripts/ci.sh` after the last source edit: exit 0, 882 tests, 0 failures, CI passed.
`swiftlint lint --quiet Sources/App/ContentViewHelpers.swift` reports nothing.

### T4: Hidden Ports settings section

| File | State |
| --- | --- |
| `Sources/App/HiddenPortsSettingsSection.swift` (new) | `Section("Hidden Ports")`: one secondary "None" row when `hiddenPorts` is empty, otherwise one row per `hiddenPorts.sorted()` port with `Text(PortLink.label(port))`, a `Spacer()`, and a borderless `minus.circle` button calling `unhidePort(port)`, with `.help("Unhide")` and `.accessibilityLabel("Unhide")`. No header control, footer, or helper text. |
| `Sources/App/SettingsView.swift` | `HiddenPortsSettingsSection(settings: settings)` directly after `OpenInAppsSettingsSection(settings: settings)`. |

**Evidence.** No new test. The section is SwiftUI layout only; the rules it relies on
(`hiddenPorts`, `unhidePort`, persistence) are pinned by the T1 tests watched failing above, and
`PortLink.label` by the existing `PortLinkTests`. The rendered rows are the operator's manual check
(D13). `grep -nF '\(port' Sources/App/HiddenPortsSettingsSection.swift` prints nothing.

**Deviations.** None.

**Gate.** `./scripts/ci.sh` after the last source edit: exit 0, 882 tests, 0 failures, CI passed.
`swiftlint lint --quiet` on both files reports nothing.

### Simplify

Four review agents (reuse, simplification, efficiency, altitude) found the diff clean — no code
changes applied. Four raised findings were skipped as contradicting decisions already settled and
approved in the spec: two "redundant" test cases in `PortAttributionTests`/`PortLinkTests` each
pin a distinct case the Testing strategy section requires; keying `hiddenPorts` per-worktree and
moving `visible(_:hiding:)` off `PortAttribution` were both explicitly considered and rejected as
D1 and D5.
