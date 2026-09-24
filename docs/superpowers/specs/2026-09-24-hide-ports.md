# Hide ports

**Date:** 2026-09-24
**Base:** d8e191f (Give each destination its own window title (#262))

The status bar lists every listening TCP port a worktree owns (#224), including ports no browser
can load, such as the four a Caddy reverse proxy holds in the operator's `icc_app` checkout. This
change adds a right-click menu to each port in `WorktreeStatusBar` with **Hide Port** and
**Copy URL**. A hidden port is identified by its number alone, app-wide, and persists across
launches in `UserDefaults` through `SettingsManager`. A new **Hidden Ports** section in Settings
lists the hidden numbers in ascending order, each with a button to unhide it, and shows a single
"None" row when the list is empty. Automatic detection of browsable ports was considered and
rejected in the task brief; this manual list replaces it.

## Decisions

| # | Question | Decision | Why |
| --- | --- | --- | --- |
| D1 | What identifies a hidden port? | The port number, app-wide. Hiding 443 hides it in every worktree of every project window, including a different server that later binds 443. | Task brief, in scope and Constraints (the collision risk is accepted by the operator). |
| D2 | Where is the hidden list stored? | `SettingsManager`, under a new `SettingsKey.hiddenPorts = "clearway.hiddenPorts"` in `UserDefaults`. Not git config. | Task brief, Constraints: app preference, not worktree metadata. `SettingsManager` is the app's one preference store (`SettingsManager.swift:38-40`). |
| D3 | Shape of the state on `SettingsManager` | `@Published private(set) var hiddenPorts: Set<UInt16>`, written only by `hidePort(_ port: UInt16)` and `unhidePort(_ port: UInt16)`. Each is a no-op, with no publish and no write, when the set would not change. | Two named writers keep the view from assigning the set directly, the way `recordOpenInUse` is the only writer of `lastUsedOpenInAppId` (`SettingsManager.swift:124-127,152-160`). The no-op guard follows the same reasoning recorded there: `objectWillChange` on an app-wide environment object re-evaluates every view observing settings. A `Set` because membership is the only question the status bar asks. |
| D4 | Persisted format | A sorted `[Int]` written with `defaults.set`. The key is removed when the set becomes empty. On read, `defaults.array(forKey:) as? [Int]`, keeping only values `UInt16(exactly:)` accepts. A missing or unreadable value reads as empty. | `[Int]` is a native property-list type, so no JSON encoder is needed. Removing the key when the set is empty follows `mainTerminalCommand` and `promptsDirectory` (`SettingsManager.swift:57-61,95-101`). Nothing is lost by treating an unreadable value as empty: the worst case is that some ports show up again. |
| D5 | Where the filtering rule lives | A pure `static func visible(_ ports: [UInt16], hiding hidden: Set<UInt16>) -> [UInt16]` on `PortAttribution`, which returns `ports` with the hidden numbers dropped and the order unchanged. `WorktreeStatusBar.livePorts` applies it to the attribution result. `attribute(_:to:)` is unchanged. | `PortAttribution` is the pure, fully tested home of the rules for which ports a worktree shows (#224 decision 22). Filtering after attribution keeps the ascending order `attribute` already produces. Rejected: adding a `hiding:` parameter to `attribute` (every existing call in `PortAttributionTests` would change, and the scan-to-worktree mapping has nothing to do with preferences); filtering inline in the view (it could not be unit-tested, which criterion 9 requires). |
| D6 | How the status bar reads the list | `WorktreeStatusBar` adds `@EnvironmentObject private var settings: SettingsManager`. | Each project window already gets the app's single `SettingsManager` through `.clearwayChrome(settings)` (`ClearwayApp.swift:179,199,290-294`). Because `hiddenPorts` is published, every open status bar redraws as soon as a port is hidden or unhidden (criteria 2 and 6), without waiting for the 2 s scan. |
| D7 | The context menu | `.contextMenu` on each port's `Text` in `livePortsView`, with exactly two `Button`s in this order: "Hide Port" → `settings.hidePort(port)`, "Copy URL" → `PortLink.copyURL(port, to: .general)`. No divider, icons, or confirmation. `.onTapGesture`, `.contentShape`, `.pointerCursorOnHover()` and `.help` stay as they are. | Task brief, in scope, criterion 1, and Constraints (hide immediately, undo in Settings). |
| D8 | How Copy URL writes the pasteboard | New `static func copyURL(_ port: UInt16, to pasteboard: NSPasteboard)` on `PortLink`: `clearContents()` then `setString(urlString(port), forType: .string)`. `PortLink.swift` switches its import from `Foundation` to `AppKit`. The call site passes `.general`. The parameter has no default. | Criterion 9 asks the tests to pin the copied text. Taking the pasteboard as a parameter lets a test pass a uniquely named `NSPasteboard(name:)` and read back exactly what was written, so the test covers the clipboard contents and not only the string helper. The text goes through `urlString`, never string interpolation (#224 decision 25). `clearContents` + `setString` is how the app writes the pasteboard elsewhere (`ContentViewHelpers.swift:102-103`, `SidebarView.swift:486-487`). |
| D9 | Where the Settings section lives | A new file `Sources/App/HiddenPortsSettingsSection.swift` with `struct HiddenPortsSettingsSection: View` that takes `@ObservedObject var settings: SettingsManager`. `SettingsView` places it after `OpenInAppsSettingsSection(settings: settings)`. | Follows the precedent `OpenInAppsSettingsSection.swift:3` records: "Its own file so `SettingsView` stays a plain `Form`." Last position because it is the least-used setting. |
| D10 | Section contents | `Section("Hidden Ports")`. With an empty set it holds one row, `Text("None").foregroundStyle(.secondary)`. Otherwise one row per port from `settings.hiddenPorts.sorted()`: `Text(PortLink.label(port))`, a `Spacer()`, and a borderless `Button` with `Image(systemName: "minus.circle")` that calls `settings.unhidePort(port)`, with `.help("Unhide")` and `.accessibilityLabel("Unhide")`. No header control, footer, or description. | Task brief, in scope and criteria 6 and 7. The row matches the Open In Apps remove button (`OpenInAppsSettingsSection.swift:39-46`). No helper text, per the no-description rule (task Constraints; global CLAUDE.md). The label goes through `PortLink.label` so that 3000 never renders as `3,000` (#224 decision 25). No way to add a port here (task, Out of scope). |
| D11 | Does unhiding need to trigger a rescan? | No. `PortMonitor.listeners` still contains hidden ports, because hiding only filters what is displayed, so an unhidden port that is still listening reappears on the next render. | Criterion 6. `PortMonitor` is untouched (`PortMonitor.swift:3-22`). |
| D12 | Keyboard shortcut for Hide Port or Copy URL | None. | #224 decision 21: only claim what the app handles. The brief asks for neither. |
| D13 | Manual check | The operator checks by hand that right-click shows the menu, that a left click still opens the browser, and that the pointer cursor still appears on hover. Build agents do not launch the app. | Task, Open risks. Memory: build agents never launch the app or take screenshots. |

## Assumptions

Each verified against the tree at `d8e191f`. No probes were needed or written.

| # | Assumption | Evidence |
| --- | --- | --- |
| A1 | The status bar gets its ports from `PortAttribution.attribute(portMonitor.listeners, to: worktreeManager.worktrees)[worktree.id]`, and draws nothing when the result is empty. | `Sources/App/ContentViewHelpers.swift:131-153` (`if !ports.isEmpty`). Filtering before that check is enough for criterion 4. |
| A2 | `attribute` returns each worktree's ports in ascending order, with duplicates removed. | `Sources/App/PortAttribution.swift:27` (`ports.mapValues { $0.sorted() }` over a `Set`). |
| A3 | There is one `SettingsManager` for the whole app, and project windows and the Settings scene share it. | `Sources/App/ClearwayApp.swift:179` (`StateObject(wrappedValue: SettingsManager())`), `:199` (`.clearwayChrome(settings)` on `ProjectWindow`), `:277` (`SettingsView(settings: settings, …)`), `:290-294`. |
| A4 | `WorktreeStatusBar` sits inside a project window, so the `SettingsManager` environment object is available to it. | Built only from `Sources/App/ContentView.swift:973`, and `ContentView` already reads `@EnvironmentObject private var settings: SettingsManager` (`ContentView.swift:77`). |
| A5 | `PortLink` is the only place a port becomes text, and it imports only Foundation today. | `Sources/App/PortLink.swift:1-22`. |
| A6 | `SettingsManager` is tested against a per-test `UserDefaults` suite, which gives a place to test persistence. | `Tests/SettingsManagerTests.swift:9-23`. |
| A7 | Deployment target is macOS 13, where SwiftUI `.contextMenu` on a view is available. | `project.yml:4-5`. `.contextMenu(menuItems:)` is macOS 10.15+. |
| A8 | SwiftLint limits leave room: `ContentViewHelpers.swift` 231 lines, `SettingsManager.swift` 194, `SettingsView.swift` 62, against a 700-line file warning. | `wc -l`; `.swiftlint.yml` (`file_length` warning 700). |

## Objective and success criteria

The user can hide a port that no browser can load, so it no longer shows in the status bar, and
can later bring it back from Settings. The work is done when every acceptance criterion in
`.clearway/TASK.md` holds:

1. Right-clicking a port in the status bar shows exactly **Hide Port** and **Copy URL** (D7).
2. **Hide Port** removes the port at once, and from every window where that port is listening (D1, D6).
3. **Copy URL** on 5174 puts exactly `http://localhost:5174` on the clipboard, never with a locale grouping separator (D8).
4. After every port of a worktree is hidden, the status bar shows no ports section (A1).
5. Hidden ports stay hidden after relaunch (D4).
6. Settings lists the hidden ports in ascending order. Unhiding one removes it from the list, and if it is still listening it reappears in the status bar at once (D10, D11).
7. With nothing hidden, the section is present and shows one "None" row (D10).
8. A left click still opens `http://localhost:<port>` (D7).
9. Unit tests cover the filtering and pin the copied URL text (Testing strategy).
10. `./scripts/ci.sh` is green and `swiftlint lint --quiet` reports zero errors.

## Testing strategy

XCTest, in the existing files under `Tests/`:

- `Tests/PortAttributionTests.swift`: `visible(_:hiding:)` drops the hidden numbers and keeps the
  rest in ascending order; an empty hidden set returns the input unchanged; hiding every port
  returns an empty list; a hidden number that is not in the list changes nothing.
- `Tests/PortLinkTests.swift`: `copyURL(3000, to:)` against a uniquely named `NSPasteboard`,
  released in teardown, leaves exactly `http://localhost:3000` as its `.string` contents, with no
  grouping separator.
- `Tests/SettingsManagerTests.swift`: `hiddenPorts` is empty on a fresh suite; `hidePort` persists
  across instances; `unhidePort` removes a port and the removal persists; unhiding the last port
  removes the key; hiding a port twice keeps one entry.

Behaviour that needs a running app (the context menu, a left click still opening the browser, the
cursor, live redraw across windows, the Settings rows) is checked by the operator by hand (D13).

## Commands

From `CLAUDE.md` `## Pipeline`:

| Step | Command |
| --- | --- |
| Every `build` task, and `simplify` (regression check) | `./scripts/ci.sh` |
| `sign-off`, once (full gate) | `./scripts/ci.sh` |
| Lint | `swiftlint lint --quiet` |

## Files touched

- `Sources/App/SettingsManager.swift`: `SettingsKey.hiddenPorts`, `hiddenPorts`, `hidePort`, `unhidePort`, loading in `init`.
- `Sources/App/PortAttribution.swift`: `visible(_:hiding:)`.
- `Sources/App/PortLink.swift`: `import AppKit`, `copyURL(_:to:)`.
- `Sources/App/ContentViewHelpers.swift`: `WorktreeStatusBar` reads `settings`, filters `livePorts`, and adds `.contextMenu`.
- `Sources/App/HiddenPortsSettingsSection.swift` (new).
- `Sources/App/SettingsView.swift`: adds `HiddenPortsSettingsSection(settings: settings)`.
- `Tests/PortAttributionTests.swift`, `Tests/PortLinkTests.swift`, `Tests/SettingsManagerTests.swift`.

## Boundaries

- Always: build every port string through `PortLink`; run `./scripts/ci.sh` after the last edit.
- Ask first: any change to `PortScanner`, `PortMonitor`, or `attribute(_:to:)`.
- Never: a sidebar or toolbar surface for ports (#224 decisions 14, 17); helper text in Settings; launching the app from a build agent.

## Out of scope

From the task brief: automatic detection of browsable ports (probing, terminal or parent-process
rules); HTTPS URLs; hiding by process, project or worktree; adding a port by typing it in
Settings; showing hidden ports anywhere else, or dimming them in the status bar; any other
context-menu item; changes to the scan, the attribution rules, or the 2 s poll.
