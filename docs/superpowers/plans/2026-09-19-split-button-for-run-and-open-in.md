# Split button for Run and Open in — implementation plan

**Date:** 2026-09-19
**Base:** 484482d3fe5e7e539176c4c1f8ae5720d5414836

Breaks down `docs/superpowers/specs/2026-09-19-split-button-for-run-and-open-in.md`. Every design
decision below is carried from that spec; this document only orders the work and says how each
piece is verified.

## Architecture decisions carried from the spec

- A split button is `Menu(content:label:primaryAction:)`. `primaryAction:` cannot be attached
  conditionally, so each view declares the menu **twice** — once with it, once without — and
  switches on whether a last-used item resolved. No availability check: the initializer is
  macOS 12.0+ and the deployment target is macOS 13.0 (`project.yml:4-5`).
- Before anything has been picked, the no-`primaryAction` declaration is used, so clicking the label
  opens the list. The button never silently does nothing.
- Run's memory lives in `<projectPath>/.clearway/commands.json`. Open in's lives in `UserDefaults`
  under `clearway.lastUsedOpenInApp`, beside `clearway.openInApps`, because the app list it draws
  from is a global preference.
- A remembered id is resolved against the **live list on every read**: `list.first { $0.id == id }`.
  An id naming nothing resolves to nil, which is the no-`primaryAction` case. Nothing is cleaned up
  on delete, and no delete path is touched.
- The resolution rule is **not** a shared generic helper. It is one line of standard library exposed
  as `SavedCommandManager.lastRunCommand` and `SettingsManager.lastUsedOpenInApp`.
- `commands.json` becomes `SavedCommandsPayload` — `{"commands":[…],"lastRunId":"…"}` — with a
  legacy fallback that decodes a bare `[SavedCommand]` array into a payload with a nil `lastRunId`.
  This is the `WorktreeGroupsPayload` shape (`WorktreeGroupStore.swift:8-30,109-116`): a `Codable`
  struct with a `static let empty` and a memberwise init carrying **no defaults**, so a field added
  later is a compile error at `save()` rather than a silent erase.
- The legacy fallback is required, not optional. `SavedCommandStore.load()` does not merely reset on
  an undecodable file, it **moves it aside** to `commands.json.corrupt`
  (`SavedCommandStore.swift:50,59`), so a clean break would rename every dogfood project's list away
  and log it as corruption.
- A missing `lastRunId` key decodes to nil through the synthesized `init(from:)`, which uses
  `decodeIfPresent` for an `Optional` property. No custom `CodingKeys` are needed.
- The id is recorded **on pick**, not on successful launch: it is the last item *used*. Recording
  only on success would leave a failing command permanently unable to become the primary action.
- Run's record is written in `RunCommandMenu.run(_:)`, which already owns the `SavedCommandManager`
  and already funnels both the menu item and the new primary action. The CLAUDE.md rule that puts
  *running* on `TerminalManager` is about resolving a worktree and awaiting a shell prompt;
  recording an id is neither, and `TerminalManager` does not hold the manager.
- `OpenInMenu` gains a `remembersLastUsed: Bool = false` init parameter. The sidebar's worktree
  context submenu is **not touched at all** — the default is off, so picking there changes nothing.
- Neither label changes. `Text("Run")` and `Text("Open in")`, system chevron, no `.help()` tooltip.
- Neither button claims a keyboard shortcut, so `AppKeyboardShortcuts` is untouched.
- No view test. Both menus gain no decision of their own — they render one of two declarations from
  an already-resolved optional — and XCTest cannot reach a SwiftUI body here. This is the split the
  project already makes for `Ghostty.SurfaceView` and `TerminalManager.revealSecondaryForHook`.

## Dependency graph

```
T1 (Run memory: store + manager)          T2 (Open in memory: SettingsManager)
        │                                          │
        ▼                                          ▼
T3 (RunCommandMenu split button)          T4 (OpenInMenu split button + ContentView)
        │                                          │
        └──────────────────┬───────────────────────┘
                           ▼
                    T5 (CLAUDE.md)
```

T1 and T2 are independent and may run in parallel. T3 depends on T1 only; T4 on T2 only. T5 depends
on all four.

## Regression check

Every task's verification is `./scripts/ci.sh` from the worktree root — it regenerates the Xcode
project, lints, builds and runs the test suite. New Swift files are invisible to the build until
`xcodegen generate` runs, so no hand-written `xcodebuild` line substitutes for it. No new Swift
files are expected in this plan, but the tasks still run it.

### T1: Store and remember Run's last-used command

**Files:** `Sources/App/SavedCommandStore.swift`, `Sources/App/SavedCommandManager.swift`,
`Tests/SavedCommandStoreTests.swift`, `Tests/SavedCommandManagerTests.swift`

**What it does**

Add `SavedCommandsPayload` to `SavedCommandStore.swift`: `var commands: [SavedCommand]`,
`var lastRunId: UUID?`, `Codable`, `Equatable`, a `static let empty`, and a memberwise init with no
default arguments. Change `load()` to return `SavedCommandsPayload` and `save(_:)` to take one,
keeping the existing temp-file/permissions/move-aside write path byte for byte.

`load()` decodes in three steps, in this order:

1. `SavedCommandsPayload.self` — the current format.
2. `[SavedCommand].self` — the legacy bare array, returned as a payload with a nil `lastRunId` and
   **no move-aside**. A legacy file is not corrupt.
3. Otherwise, the existing move-aside to `commands.json.corrupt` and `.empty`.

The unreadable-file branch (`fm.contents` returning nil) keeps its current behaviour: log, move
aside, return `.empty`. Update the type's doc comment so it describes the document rather than an
array.

In `SavedCommandManager`, add `@Published private(set) var lastRunId: UUID?` populated by `load()`
alongside `commands`, `var lastRunCommand: SavedCommand? { commands.first { $0.id == lastRunId } }`,
and `func recordLastRun(_ command: SavedCommand)` which sets `lastRunId` and calls the private
`save()`. `save()` snapshots both fields and writes a `SavedCommandsPayload`; its existing
`pendingSave` chaining is unchanged.

**Acceptance criteria**

- An existing `commands.json` holding a bare `[SavedCommand]` array loads with its commands intact,
  a nil `lastRunId`, and leaves no `commands.json.corrupt` behind.
- A payload round-trips `lastRunId` through `save()` then `load()`.
- A genuinely undecodable file still moves aside and loads as `.empty` — the existing corruption
  cases, retargeted at the payload.
- `lastRunCommand` is nil before anything is recorded, resolves to the recorded command after
  `recordLastRun`, and is nil once that command is deleted while a *different* command stays
  resolvable.
- `recordLastRun` survives a reload through a second store over the same project path.

**How they are verified**

`Tests/SavedCommandStoreTests.swift` gains: a payload save/load round-trip carrying `lastRunId`; a
legacy-bare-array case written through the existing `writeCommandsFile(_:)` helper asserting the
commands load and `FileManager.default.fileExists(atPath: corruptFile)` is false; and two wire-format
cases decoding `SavedCommandsPayload` from literal bytes — `{"commands":[…],"lastRunId":"…"}` and the
same bytes with the `lastRunId` key absent. Existing cases
(`testLoadCorruptFileReturnsEmpty`, `testLoadFileWithMissingFieldReturnsEmpty`,
`testLoadUnknownKindIsTreatedAsCorrupt`, `testLoadMovesACorruptFileAsideWithItsOriginalBytes`,
`testLoadOverwritesAnOlderCorruptFile`, `testSaveThenLoadPreservesArrayOrder`, and the rest) are
retargeted at the payload. Note that `testLoadFileWithMissingFieldReturnsEmpty` and
`testLoadUnknownKindIsTreatedAsCorrupt` must still be corrupt under **both** decode attempts — a
`[SavedCommand]` array whose element is malformed fails the legacy path too, so they keep asserting
move-aside.

`Tests/SavedCommandManagerTests.swift` gains the four `lastRunCommand` cases above, using its
existing `persistedCommands(matching:)` settling helper's pattern for the reload case.

`./scripts/ci.sh` passes.

### T2: Remember Open in's last-used app in UserDefaults

**Files:** `Sources/App/SettingsManager.swift`, `Tests/SettingsManagerTests.swift`

**What it does**

Add `static let lastUsedOpenInApp = "clearway.lastUsedOpenInApp"` to `SettingsKey`, beside
`openInApps`. Add `@Published var lastUsedOpenInAppId: UUID?` whose `didSet` writes
`uuidString` to that key and calls `defaults.removeObject(forKey:)` when nil — the shape
`promptsDirectory` already uses for its remove-on-default branch. Add
`var lastUsedOpenInApp: OpenInApp? { openInApps.first { $0.id == lastUsedOpenInAppId } }` beside
`openInApps`. Read the key in `init` (`defaults.string(forKey:).flatMap(UUID.init(uuidString:))`),
with the rest of the stored values.

No cleanup anywhere: nothing in the Open In settings section is touched, and an id naming an app the
user deleted resolves to nil by the rule above.

**Acceptance criteria**

- `lastUsedOpenInApp` is nil on a fresh `UserDefaults` suite.
- It resolves to the matching app after `lastUsedOpenInAppId` is set.
- It is nil when the id names an app no longer in `openInApps`, without any delete-path change.
- The id persists across two `SettingsManager` instances over the same suite, and setting it back to
  nil removes the key.

**How they are verified**

Four cases in `Tests/SettingsManagerTests.swift`, built over the per-test
`UserDefaults(suiteName:)` the file's `setUp`/`tearDown` already provide. `./scripts/ci.sh` passes.

### T3: Make the toolbar's Run button a split button

**Files:** `Sources/App/RunCommandMenu.swift`

**Depends on:** T1

**What it does**

Factor the existing item list into one `@ViewBuilder private var items: some View` holding the
`ForEach(savedCommandManager.commands)` block, so the two menu declarations cannot drift. `body`
becomes a switch on `savedCommandManager.lastRunCommand`:

- non-nil → `Menu { items } label: { Text("Run") } primaryAction: { run(lastCommand) }`
- nil → `Menu { items } label: { Text("Run") }`

Both keep the existing
`.disabled(savedCommandManager.commands.isEmpty || ghosttyApp.app == nil)`, applied once around the
switch rather than duplicated. Add one line to `run(_:)`:
`savedCommandManager.recordLastRun(command)`, placed so it records on pick regardless of whether
`ghosttyApp.app` resolves — the id is the last item *used*, and the existing
`guard let app = ghosttyApp.app else { return }` stays for the launch itself.

The label and the absence of a `.help()` tooltip are unchanged.

**Acceptance criteria**

- With nothing recorded, the view renders the no-`primaryAction` declaration.
- With a recorded command still in the list, it renders the `primaryAction:` declaration whose
  action runs that command.
- Deleting the recorded command returns it to the first case with no other change, because
  `lastRunCommand` re-resolves against `commands` on every body evaluation.
- The item list exists in exactly one place in the file.
- An empty command list still disables the button.

**How they are verified**

`./scripts/ci.sh` passes, including `swiftlint lint` with zero errors. There is no view test
(carried from the spec): the decision is `lastRunCommand`, which T1 already pins. Reviewer check:
`grep -c "ForEach(savedCommandManager.commands)" Sources/App/RunCommandMenu.swift` returns 1 and
the file contains exactly one `Text("Run")` source expression. Criteria 1-3 as the user sees them
are on the operator's hand-check list below, not a build agent's.

### T4: Make the toolbar's Open in button a split button

**Files:** `Sources/App/OpenInMenu.swift`, `Sources/App/ContentView.swift`

**Depends on:** T2

**What it does**

Add `remembersLastUsed: Bool = false` to `OpenInMenu`'s init, stored as a `private let`. Factor the
`ForEach(settings.openInApps)` block into one `@ViewBuilder private var items: some View`. `body`
switches on `remembersLastUsed ? settings.lastUsedOpenInApp : nil`:

- non-nil → `Menu { items } label: { label } primaryAction: { open(lastApp) }`
- nil → `Menu { items } label: { label }`

In `open(_:)`, record the id when the flag is on: `if remembersLastUsed { settings.lastUsedOpenInAppId = app.id }`,
before the launch `Task`, so it records on pick rather than on success. `presentFailure` is
unchanged.

In `ContentView.swift`, the toolbar's call site (around line 200-205) gains
`remembersLastUsed: true`. That is the only edit to that file — one argument on an existing call.
Do not add a new section there; the file is past SwiftLint's 1000-line `file_length` error and only
carries on via its file-wide disable.

`SidebarView.swift` is **not** touched: its call omits the parameter and therefore gets the default
`false`.

**Acceptance criteria**

- The toolbar's Open in button renders the `primaryAction:` declaration once an app has been picked
  from it, and the plain declaration before that or when the remembered id names no current app.
- Picking from the sidebar's right-click submenu changes nothing: `git diff --stat` shows no change
  to `Sources/App/SidebarView.swift`, and that call site passes no `remembersLastUsed`.
- The item list exists in exactly one place in the file.
- An empty Open In list still hides the toolbar item — the `!settings.openInApps.isEmpty` gate in
  `ContentView` is unchanged.
- The label stays `Text("Open in")` with no tooltip.

**How they are verified**

`./scripts/ci.sh` passes, including `swiftlint lint` with zero errors. Reviewer check:
`git diff --stat` lists only `OpenInMenu.swift` and `ContentView.swift` for this task, and
`git diff Sources/App/ContentView.swift` is a one-argument change. As in T3, there is no view test.

### T5: Record the new shapes in CLAUDE.md

**Files:** `CLAUDE.md`

**Depends on:** T1, T2, T3, T4

**What it does**

Three edits, each describing behaviour the previous tasks shipped:

1. The `SavedCommandStore.swift` bullet (around line 201) gains the payload shape
   (`{"commands":[…],"lastRunId":"…"}`), its legacy bare-array fallback and why the fallback is
   required — `load()` moves an undecodable file aside, so a clean break would rename dogfood lists
   to `.corrupt` — plus the rule that the remembered id is resolved against the live list on every
   read and never cleaned up on delete.
2. The Open In bullet's label rationale (around lines 263-266) is rewritten. Today it says both
   toolbar items carry a text label *because* they only open a menu rather than acting on a click.
   Both are now split buttons that do act on a click, so the reason for a text label is that the
   primary half needs a name. The surrounding claims — the lowercase preposition, no `.help()`,
   the remaining items staying icon-only — stay true and stay.
3. The same Open In bullet records that the last-used app is a global `UserDefaults` preference
   (`clearway.lastUsedOpenInApp`), that only the toolbar entry point remembers
   (`remembersLastUsed`), and that the sidebar submenu is unaffected.

The existing "The menu claims **no** keyboard shortcut" line stays: neither primary action claims
one, so it remains accurate.

**Acceptance criteria**

- All three edits are present and no other CLAUDE.md section is rewritten.
- No statement in the edited bullets contradicts the shipped code — each claim is checkable against
  `SavedCommandStore.swift`, `SettingsManager.swift`, `OpenInMenu.swift` and `ContentView.swift`.
- No sentence added restates a heading or adds descriptive copy for its own sake.

**How they are verified**

`git diff CLAUDE.md` shows edits confined to the two bullets. `./scripts/ci.sh` passes (no code
changed, so this is a no-regression confirmation).

## Operator hand-check

How the split button actually draws in the macOS 26 Liquid Glass toolbar is not something the test
suite or a build agent can answer. After T4, the operator checks by hand, against spec success
criteria 1-3 and 9:

1. With saved commands and nothing yet run in the project, clicking anywhere on Run opens the list.
2. After picking "Build & Run", clicking the `Run` label runs it without opening anything, and
   clicking the chevron opens the full list.
3. Picking a different command makes it the new primary action.
4. Both buttons still read `Run` and `Open in` with the system chevron and no tooltip.

## Risks

| Risk | Impact | Mitigation |
| --- | --- | --- |
| The chevron's hit target in a macOS 26 toolbar is not what the docs describe | Med | Operator hand-check above; carried from the spec's Open risks |
| Recording an id rewrites the whole `commands.json` on every run, so two windows on one project race | Low | Accepted in the spec — the same exposure `2026-09-18-project-specific-commands.md` accepted for command edits |
| Switching between the two `Menu` declarations changes the view's type, so SwiftUI rebuilds the toolbar item on the first pick | Low | Accepted in the spec: once per list per session, and no state lives in the button |
| A legacy `commands.json` whose *elements* are malformed still moves aside | Low | Intended — it fails both decode attempts and is genuinely corrupt. Pinned by the retargeted existing cases in T1 |

## Build log

### T1: Store and remember Run's last-used command

| File | State |
| --- | --- |
| `Sources/App/SavedCommandStore.swift` | `SavedCommandsPayload` added (`commands`, `lastRunId`, `static let empty`, no-defaults memberwise init). `load()` returns the payload — payload first, legacy bare array second (no move-aside), move-aside third. `save(_:)` takes the payload; its temp-file/permissions/replace path is unchanged. Type doc comment restated for the document. |
| `Sources/App/SavedCommandManager.swift` | `@Published private(set) var lastRunId: UUID?` populated by `load()`; `lastRunCommand` resolving it against `commands`; `recordLastRun(_:)`; `save()` snapshots both fields into a `SavedCommandsPayload`. `pendingSave` chaining unchanged. |
| `Tests/SavedCommandStoreTests.swift` | Existing cases retargeted at the payload. Added: `testSaveThenLoadPreservesTheLastRunId`, `testLegacyBareArrayLoadsWithNothingRemembered`, `testPayloadDecodesFromItsStoredBytes`, `testPayloadWithoutTheLastRunIdKeyDecodesAsNothingRemembered`. `testLoadFileWithMissingFieldReturnsEmpty` now also asserts the move-aside, since a malformed element fails both decode attempts. |
| `Tests/SavedCommandManagerTests.swift` | `persistedCommands(matching:)` reads `.commands`; added `persistedLastRunId(matching:)`. Added the four `lastRunCommand` cases. |

**Watched failure.** The legacy fallback was left out of the first implementation and
`./scripts/ci.sh` run against it, with every other retargeted case already passing:

```
Test Suite 'SavedCommandStoreTests' started at 2026-09-19 23:34:11.934.
    ✖ testLegacyBareArrayLoadsWithNothingRemembered, XCTAssertEqual failed: ("[]") is not equal to ("[Clearway.SavedCommand(id: 11111111-1111-1111-1111-111111111111, name: "Dev server", kind: Clearway.SavedCommand.Kind.terminal, text: "bin/dev", agent: "claude", autoRun: true)]")
    ✖ testLegacyBareArrayLoadsWithNothingRemembered, XCTAssertFalse failed - A legacy file is not corrupt and must not be moved aside
    ✖ testLegacyBareArrayLoadsWithNothingRemembered, XCTAssertTrue failed
Executed 543 tests, with 3 failures (0 unexpected) in 86.149 (86.347) seconds
```

Adding the `[SavedCommand].self` branch to `load()`'s `catch` turned it green.

**Deviations.** The two wire-format cases decode `SavedCommandsPayload` from literal bytes with
`JSONDecoder` directly rather than through `store.load()`, matching the file's existing
`testEncodedShapeIsAFlatObjectPerCommand`; the legacy case goes through `writeCommandsFile(_:)` and
`store.load()` as planned, because the move-aside is what it has to pin. No other deviation.

**Gate.** `./scripts/ci.sh` — 543 tests, 0 failures, `swiftlint` clean, `==> CI passed.`

### T2: Remember Open in's last-used app in UserDefaults

| File | State |
| --- | --- |
| `Sources/App/SettingsManager.swift` | `SettingsKey.lastUsedOpenInApp` added beside `openInApps`. `@Published var lastUsedOpenInAppId: UUID?` writes its `uuidString` in `didSet` and calls `removeObject(forKey:)` when nil. `var lastUsedOpenInApp: OpenInApp?` resolves it against `openInApps` on every read. `init` reads the key with `string(forKey:).flatMap(UUID.init(uuidString:))`. No delete path touched. |
| `Tests/SettingsManagerTests.swift` | Added `test_lastUsedOpenInApp_isNilOnAFreshSuite`, `test_lastUsedOpenInApp_resolvesTheRememberedId`, `test_lastUsedOpenInApp_isNilWhenTheIdNamesNoCurrentApp`, `test_lastUsedOpenInAppId_persistsAcrossInstances`, `test_lastUsedOpenInAppId_setBackToNilRemovesTheKey`, over the per-test `UserDefaults(suiteName:)` the file already provides. |

**Watched failure.** The `init` read was left out of the first implementation — `lastUsedOpenInAppId`
initialised to nil — and `./scripts/ci.sh` run against it, with the other three cases already
passing:

```
Test Suite 'SettingsManagerTests' started at 2026-09-19 23:41:06.831.
    ✖ test_lastUsedOpenInAppId_persistsAcrossInstances, XCTAssertEqual failed: ("nil") is not equal to ("Optional(9E9093A5-CBC3-483E-8437-5FE990803A08)")
    ✖ test_lastUsedOpenInAppId_persistsAcrossInstances, XCTAssertEqual failed: ("nil") is not equal to ("Optional(Clearway.OpenInApp(id: 9E9093A5-CBC3-483E-8437-5FE990803A08, kind: Clearway.OpenInApp.Kind.builtIn(Clearway.OpenInBuiltIn.zed), command: "zed"))")
Executed 548 tests, with 2 failures (0 unexpected) in 84.776 (84.979) seconds
```

Reading the key in `init` turned it green.

**Deviations.** The plan lists four cases; a fifth,
`test_lastUsedOpenInAppId_setBackToNilRemovesTheKey`, splits the fourth acceptance criterion's two
claims — persistence across instances and the remove-on-nil branch — into their own cases rather
than asserting both in one. The delete case also asserts `lastUsedOpenInAppId` still holds the
removed app's id, pinning the spec's "nothing is cleaned up on delete". No other deviation.

**Gate.** `./scripts/ci.sh` — 548 tests, 0 failures, `swiftlint` clean, `==> CI passed.`

### T3: Make the toolbar's Run button a split button

| File | State |
| --- | --- |
| `Sources/App/RunCommandMenu.swift` | `body` applies the `.disabled(...)` gate once around a `menu` property that declares the `Menu` twice, switched on `savedCommandManager.lastRunCommand` — with `primaryAction: { run(lastCommand) }` when one resolves, without it when none does. The item list is one `@ViewBuilder private var items`, the label one `private var label`, so the two declarations cannot drift. `run(_:)` records the pick with `savedCommandManager.recordLastRun(command)` before the `guard let app = ghosttyApp.app`. Struct doc comment restated for the split button. |

**Watched failure.** None, by design. The plan and the spec both rule out a view test here: the
only decision is `lastRunCommand`, which T1 already pins in `SavedCommandManagerTests`, and XCTest
cannot reach a SwiftUI body. Acceptance criteria 1-3 are on the operator's hand-check list.

Reviewer checks, run against the file as committed:

```
$ grep -c 'ForEach(savedCommandManager.commands)' Sources/App/RunCommandMenu.swift
1
$ grep -c 'Text("Run")' Sources/App/RunCommandMenu.swift
1
```

**Deviations.** The plan's two declarations each spell `label: { Text("Run") }`, which would put two
`Text("Run")` expressions in the file against its own reviewer check; the label is factored into one
`private var label` alongside `items` instead. No other deviation.

**Gate.** `./scripts/ci.sh` — 548 tests, 0 failures, `swiftlint` clean, `==> CI passed.`
