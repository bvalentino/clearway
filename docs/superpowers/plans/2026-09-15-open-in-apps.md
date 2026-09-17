# Open in apps — implementation plan

**Date:** 2026-09-15
**Base:** d94b0b0f879606872a8b1a92e2f38ac144914339
**PR:** #219

Breaks down `docs/superpowers/specs/2026-09-15-open-in-apps.md`. Every design decision below is
carried from that spec; this document only orders the work and says how each piece is verified.

## Architecture decisions carried from the spec

- The app list is `[OpenInApp]`, JSON-encoded into one `UserDefaults` `Data` value under
  `clearway.openInApps`, held by `SettingsManager` as a `@Published` array with a persisting `didSet`.
- Absent key → seed `[Finder]`. Present key holding `[]` → genuinely empty list. A decode failure is
  treated as absent and re-seeds Finder.
- `OpenInApp.kind` is `.builtIn(OpenInBuiltIn)` or `.custom(label:)`; `label` is computed, never
  stored for a built-in, so a built-in's label has no editable field at all.
- Built-ins are Finder / VS Code / Cursor / Zed with default commands `open` / `code` / `cursor` /
  `zed`. Each may be added at most once; one already in the list is absent from the add menu.
- The path is appended as the last argument, shell-escaped with `shellEscape`
  (`Sources/App/TerminalTab.swift:3-7`). No placeholder syntax.
- The command text is interpolated **raw** — it is the user's and is read by the shell as typed, the
  same contract as `WorktreeHooks.interpolated`. Only the path is escaped.
- Execution is `/bin/sh -c "export PATH=<escaped resolved PATH>; <command text> <escaped path>"` via
  `Process`, cwd set to the worktree path, environment `ShellEnvironment.processEnvironment`. No
  `exec` prefix — `exec` binds to the first simple command only and would mis-parse a user command
  containing shell operators.
- Failure window is 2 seconds. A detached task drains stderr to EOF and waits for exit; the caller
  races that against a 2-second deadline. Non-zero exit inside the window → alert. Still running at
  the deadline → treated as launched.
- No `Process.terminationHandler`: it is a bridged ObjC block property, and a `@convention(block)`
  literal written inside a `@MainActor` member traps when invoked off-main (CLAUDE.md). The spawn,
  drain and wait all live on a `nonisolated` detached task.
- Failure is reported with `NSAlert().runModal()` from the menu view, the pattern already used at
  `ClearwayApp.swift:68, 90`. Success is silent.
- One `OpenInMenu` view, generic over its label, serves both entry points, so the items, the launch
  call and the alert are written once.
- Both views reach the list through `@EnvironmentObject var settings: SettingsManager` directly.
  `clearwayChrome` already injects it into the whole `ProjectWindow` hierarchy. No provider closure.
- Settings editing is a **sheet**, not inline commit-on-blur, because a blank label or command must
  be *refused* — expressed as a disabled Save button. The same sheet serves "add custom" and "edit
  any entry". Adding a built-in takes its default command and opens no sheet.
- Menu order is list order, which is insertion order. No drag-to-reorder.
- Empty list hides the toolbar item and the sidebar submenu entirely.
- No keyboard shortcut, and therefore **no `AppKeyboardShortcuts` change**. The claim table must stay
  exactly what the app handles.
- Deployment target is macOS 13, so use the two-parameter `onChange(of:perform:)` form.
- `project.yml` collects sources by directory, so new files need no `project.yml` edit — but they are
  invisible to the build until `xcodegen generate` runs, which `./scripts/ci.sh` does.

## Regression command

Every task's verification is `./scripts/ci.sh` — the project's only runner of the test suite, and the
only thing that regenerates the Xcode project so new Swift files compile.

## Dependency graph

```
T1 model + validation
 ├──> T2 launcher            (shares Tests/OpenInAppTests.swift with T1)
 ├──> T3 persistence ──┬──> T5 settings section
 │                     └──> T6 toolbar + sidebar wiring
 └──> T4 menu view ─────────> T6
T2 ──────────────────> T4
T5, T6 ──────────────> T7 docs note
```

Order: T1 → T2 → (T3 and T4 in parallel) → (T5 and T6 in parallel) → T7.

---

### T1: Open-in app model and draft validation

**Files**

- `Sources/App/OpenInApp.swift` (new)
- `Tests/OpenInAppTests.swift` (new)

**What it does**

Adds the pure model layer, no views and no I/O.

- `OpenInBuiltIn`: a `String`-raw-value `Codable`, `CaseIterable`, `Identifiable` enum with cases for
  Finder, VS Code, Cursor and Zed, each exposing `label` (`"Finder"`, `"VS Code"`, `"Cursor"`,
  `"Zed"`) and `defaultCommand` (`"open"`, `"code"`, `"cursor"`, `"zed"`). Raw values are the
  persisted form, so they must not change after this task.
- `OpenInApp`: `Identifiable`, `Codable`, `Equatable`, with `let id: UUID`, `var kind: Kind`,
  `var command: String`, and a computed `var label: String` that reads the built-in's label or the
  custom case's stored label.
- `OpenInApp.Kind`: `case builtIn(OpenInBuiltIn)` / `case custom(label: String)`, `Codable` and
  `Equatable` (synthesized `Codable` is fine).
- `OpenInApp.availableBuiltIns(excluding: [OpenInApp]) -> [OpenInBuiltIn]`: the built-ins not already
  present in the list, in `allCases` order.
- A draft type carrying the sheet's two fields plus the kind being edited, with a validity rule:
  a custom draft is valid only when both label and command are non-blank after trimming whitespace;
  a built-in draft has no label field and is valid only when the command is non-blank after trimming.

**Acceptance criteria**

- Each built-in reports the label and default command listed above.
- `availableBuiltIns(excluding:)` omits every built-in already in the list and preserves `allCases`
  order for the rest; excluding an empty list returns all four; custom entries never exclude anything.
- A draft with a whitespace-only label, a whitespace-only command, or both is invalid; a draft with
  both non-blank is valid. A built-in draft with a non-blank command is valid regardless of label.
- `OpenInApp` round-trips through `JSONEncoder`/`JSONDecoder` for both kinds with `id`, `kind` and
  `command` unchanged.

**Verification**

`./scripts/ci.sh` is green, with new `Tests/OpenInAppTests.swift` cases covering each criterion above.
The test file constructs no views.

---

### T2: Open-in launcher

**Files**

- `Sources/App/OpenInAppLauncher.swift` (new)
- `Tests/OpenInAppTests.swift` (extend)

**What it does**

Adds the script builder and the spawn.

- `buildOpenInScript(command:path:resolvedPath:) -> String`, pure and `nonisolated`, returning
  `export PATH=<shellEscape(resolvedPath)>; <command> <shellEscape(path)>`. The command text is
  interpolated raw; only `resolvedPath` and `path` are escaped.
- A `nonisolated` async `launch` that runs that script with `Process`: `executableURL`
  `/bin/sh`, arguments `["-c", script]`, `currentDirectoryURL` the worktree path, `environment`
  `ShellEnvironment.processEnvironment`, stderr on a `Pipe`. A detached task drains stderr to EOF and
  then calls `waitUntilExit()`; the caller races that task against a 2-second deadline. Non-zero exit
  inside the window returns a failure carrying the trimmed stderr text; a still-running child at the
  deadline returns no failure and the drain task ends on its own when the child does. A `Process.run()`
  throw is also a failure, carrying the error's description.
- No `Process.terminationHandler`, and no `@convention(block)` or `@convention(c)` closure literal
  anywhere in the file. Nothing in this file is `@MainActor`.

**Acceptance criteria**

- `buildOpenInScript` with command `cursor` and path `/tmp/wt` yields
  `export PATH='<resolved>'; cursor '/tmp/wt'`.
- A path containing a single quote or a space is escaped so the shell receives it as one argument;
  a command containing shell operators (`myeditor --new-window`, `a && b`) appears verbatim in the
  script.
- Launching `false` (or a command that exits non-zero immediately) returns a failure whose message
  contains the shell's stderr text; launching a command that is not on PATH returns a failure
  containing `command not found`.
- Launching a command that stays running past the deadline (`sleep 5`) returns no failure and does
  not block the caller beyond the 2-second window.
- Launching `true` returns no failure.

**Verification**

`./scripts/ci.sh` is green, with `Tests/OpenInAppTests.swift` covering the script-building criteria
and the launch outcomes. The launch tests call `launch` directly with real commands (`true`, `false`,
a nonexistent binary, `sleep 5`); they construct no views.

---

### T3: Persist the list on SettingsManager

**Files**

- `Sources/App/SettingsManager.swift`
- `Tests/OpenInAppsSettingsTests.swift` (new)

**What it does**

- Adds `SettingsKey.openInApps = "clearway.openInApps"`.
- Adds `@Published var openInApps: [OpenInApp]` with a `didSet` that JSON-encodes the array and
  writes it to `defaults` under that key — including when the array is empty, so an empty list
  persists as `[]` rather than reverting to the seed.
- Seeds in `init`: if the key is absent, or its value fails to decode, the list starts as a single
  Finder entry (`.builtIn(.finder)` with command `open`) and that seed is written to defaults; a
  present, decodable value is used as stored, empty included. `didSet` does not fire during `init`,
  so the seed write is explicit.

**Acceptance criteria**

- A fresh `SettingsManager` over an empty suite reports exactly one entry, labelled "Finder", command
  `open`.
- Setting the list to `[]` and constructing a second `SettingsManager` over the same suite yields an
  empty list, not the seed.
- Corrupt data under the key (e.g. arbitrary bytes) yields the Finder seed.
- Add, remove and edit of a command all survive a second `SettingsManager` over the same suite, and
  list order is preserved exactly.

**Verification**

`./scripts/ci.sh` is green, with `Tests/OpenInAppsSettingsTests.swift` following the per-test
`UserDefaults(suiteName:)` pattern of `Tests/SettingsManagerTests.swift:12-23` and constructing no
views.

---

### T4: OpenInMenu view

**Files**

- `Sources/App/OpenInMenu.swift` (new)

**What it does**

Adds the one `Menu` view both entry points use.

- Generic over its label (`Label: View`) so the toolbar can pass an icon and the sidebar a title.
- Takes the worktree path to open, and reads `@EnvironmentObject var settings: SettingsManager` for
  the list.
- Renders one button per entry, in list order, titled by `label`.
- Choosing an entry calls the T2 launcher with that entry's command, the passed path and
  `ShellEnvironment.path`, and on a returned failure presents `NSAlert().runModal()` whose message
  names the entry's label and quotes the stderr text. Success shows nothing.
- No `@convention(block)` or `@convention(c)` closure literal; the launcher call is a plain `Task`
  awaiting the `nonisolated` async function.

**Acceptance criteria**

- The file compiles and lints clean, is used by nothing yet, and adds no `AppKeyboardShortcuts` entry.
- The view takes the path as a parameter rather than resolving a selection itself, so a caller can
  pass a worktree other than the current selection.
- Menu item order matches `settings.openInApps` order.

**Verification**

`./scripts/ci.sh` is green (compile + `swiftlint lint` with zero errors). Behaviour is verified at
T6, where the view is first reachable; nothing here is unit-testable without constructing a view,
and the decision logic it would test already lives in T1 and T2.

---

### T5: Open In Apps settings section

**Files**

- `Sources/App/OpenInAppsSettingsSection.swift` (new)
- `Sources/App/SettingsView.swift`

**What it does**

- A new `Section("Open In Apps")` view over `@ObservedObject settings`, added to `SettingsView`'s
  `Form` and holding:
  - one row per entry showing its label and command, with an edit affordance and a remove control;
  - an add menu offering "Custom…" plus each result of `availableBuiltIns(excluding:)` — adding a
    built-in appends it with its `defaultCommand` and opens no sheet; "Custom…" opens the sheet empty;
  - an editor sheet used by both add-custom and edit, with a command field always, a label field only
    for custom entries, and a Save button disabled while the T1 draft rule reports the draft invalid.
- `SettingsView`'s frame height changes from `420` to `560`.

**Acceptance criteria**

- Settings → Open In Apps lists the current entries in list order; a fresh install shows Finder alone.
- The add menu does not offer a built-in already in the list; after adding Cursor it offers only
  VS Code, Zed and Custom.
- Adding Cursor appends an entry labelled "Cursor" with command `cursor` and opens no sheet.
- Editing a built-in offers a command field and no label field; editing a custom entry offers both.
- Save is disabled while either required field is blank, in both add-custom and edit.
- Removing an entry removes it from the list, Finder included.
- `SettingsView`'s frame is `width: 450, height: 560`.

**Verification**

`./scripts/ci.sh` is green. Manual check with `./scripts/run.sh`: open Settings, confirm the fresh
list, add Cursor, confirm it drops out of the add menu, edit its command, add a custom "Xcode"/`xed`
entry, confirm Save refuses a blank field in both sheets, remove an entry, relaunch and confirm the
list survived — including after removing everything.

---

### T6: Toolbar item and sidebar submenu

**Files**

- `Sources/App/ContentView.swift`
- `Sources/App/SidebarView.swift`

**What it does**

- `ContentView`: one `ToolbarItem(placement: .primaryAction)` inside the existing
  `if selectedWorktree != nil` block (`ContentView.swift:198`), gated additionally on
  `!settings.openInApps.isEmpty` and a non-nil `currentWorktree?.path`, rendering `OpenInMenu` with an
  icon label and that path. `currentWorktree` (`:456-459`) is the freshest `Worktree` for the
  selection. Keep the addition to a few lines — the file is already at 987 lines against a
  SwiftLint error threshold of 1000, with `file_length` and `type_body_length` suppressed.
- `SidebarView`: adds `@EnvironmentObject private var settings: SettingsManager`, and in
  `worktreeContextMenu(_:)` an `OpenInMenu` submenu titled "Open In" placed **above** Reveal in Finder
  (`SidebarView.swift:340-355`), gated on `!settings.openInApps.isEmpty` and a non-nil `wt.path`, and
  passing `wt.path` — the right-clicked worktree, not the selection.
- The existing Reveal in Finder and Copy Path items are untouched.

**Acceptance criteria**

- With a worktree selected and a non-empty list, the toolbar shows the Open In menu; choosing Finder
  opens that worktree's folder.
- Choosing Cursor runs `cursor '<worktree path>'` and the worktree opens in Cursor.
- Right-clicking main in the sidebar while a different worktree is selected → Open In → Zed opens
  **main's** path.
- Removing every entry in Settings hides both the toolbar item and the sidebar submenu with no
  relaunch; adding one back shows them again.
- A command that is not on PATH produces an alert containing the entry's label and the shell's error
  text.
- `ContentView.swift` stays under 1000 lines.

**Verification**

`./scripts/ci.sh` is green. Manual check with `./scripts/run.sh` covering each criterion above,
including the empty-list hide/show without relaunch and the not-on-PATH alert (set a custom entry's
command to a name that does not exist).

---

### T7: Document the new files in CLAUDE.md

**Files**

- `CLAUDE.md`

**What it does**

Adds a short entry under `## Architecture` → `Sources/App/` describing the four new files and the two
contracts a future reader would otherwise have to rediscover: the command text is interpolated raw
while only the appended path is escaped (same contract as `WorktreeHooks.interpolated`), and the
launcher is `nonisolated` with no `terminationHandler` because a `@convention(block)` literal in a
`@MainActor` member traps off-main. Also notes that the menu deliberately claims no keyboard shortcut,
so `AppKeyboardShortcuts` has no entry for it.

**Acceptance criteria**

- The entry names `OpenInApp.swift`, `OpenInAppLauncher.swift`, `OpenInMenu.swift` and
  `OpenInAppsSettingsSection.swift`, states the raw-command / escaped-path contract, and states why
  the launcher is nonisolated.
- It matches the surrounding bullet style and adds no section heading.

**Verification**

`./scripts/ci.sh` is green (unchanged by a docs edit; run to confirm the tree is still clean).

---

## Risks

| Risk | Impact | Mitigation |
| --- | --- | --- |
| PATH never exports `code`/`cursor`/`zed` | Med | By design: the T2 failure alert is the only feedback. Clearway detects nothing. |
| User writes shell operators into a command | Low | By design: the shell reads the command as typed, same as worktree hooks. Only the path is escaped. |
| `ContentView.swift` crosses the 1000-line SwiftLint error threshold | Med | T6 adds only the `ToolbarItem`; the menu and the settings section are separate files for this reason. |
| The 2-second failure window misses a slow failure | Low | `sh` reports `command not found` and exits 127 in well under 100 ms. A later failure is treated as launched, which is the spec's choice. |

---

## Build log

### T1: Open-in app model and draft validation

**What landed**

| File | State |
| --- | --- |
| `Sources/App/OpenInApp.swift` | New. `OpenInBuiltIn` (raw-value `Codable`/`CaseIterable`/`Identifiable`, `label`, `defaultCommand`), `OpenInApp` (`id`/`kind`/`command`, computed `label` and `builtIn`), `OpenInApp.Kind`, `OpenInApp.availableBuiltIns(excluding:)`, `OpenInApp.Draft` with `isValid`. No views, no I/O. |
| `Tests/OpenInAppTests.swift` | New. 10 cases: built-in labels and default commands, raw-value ordering, computed `label` for both kinds, `availableBuiltIns` for empty/partial/custom-only lists, custom and built-in draft validity, JSON round-trip for both kinds. |
| `Clearway.xcodeproj/project.pbxproj` | Regenerated by `xcodegen generate` inside `./scripts/ci.sh` to pick up the two new files. |

**Evidence**

Test file written first and run against the absent model. `./scripts/ci.sh` failed to compile:

```
❌ Tests/OpenInAppTests.swift:65:48: cannot find 'OpenInApp' in scope
        let decoded = try JSONDecoder().decode(OpenInApp.self, from: JSONEncoder().encode(app))
❌ Tests/OpenInAppTests.swift:68:39: type 'Equatable' has no member 'builtIn'
        XCTAssertEqual(decoded.kind, .builtIn(.zed))
** TEST FAILED **
```

After adding `Sources/App/OpenInApp.swift` the same command passed.

**Deviations from the plan**

- `OpenInApp.Draft` carries `builtIn: OpenInBuiltIn?` rather than an `OpenInApp.Kind`. The plan says
  "the kind being edited"; a full `Kind` would store the custom label twice — once in the case's
  associated value and once in the draft's editable `label` field — with no rule saying which wins.
  `nil` means custom, which is exactly the distinction the validity rule and the sheet's label field
  need.
- `OpenInApp.builtIn` (computed, optional) was added beyond the listed members. It is what
  `availableBuiltIns(excluding:)` filters on, and T5 needs the same question answered to decide
  whether to show a label field.

**Environment note**

The worktree had never been set up: `ghostty/` was an uninitialised submodule, so the first
`./scripts/ci.sh` failed with `Unable to resolve module dependency: 'GhosttyKit'`. Fixed by running
the project's own `./scripts/worktree-post-create.sh`, which copies the primary worktree's built
`ghostty/` in and seeds `BuildInfo.generated.swift`. No source change.

**Gate**

`./scripts/ci.sh` — `Executed 317 tests, with 0 failures (0 unexpected)`, `==> CI passed.`
`git status --porcelain` clean apart from this task's own files before committing.

### T2: Open-in launcher

**What landed**

| File | State |
| --- | --- |
| `Sources/App/OpenInAppLauncher.swift` | New. `OpenInLaunchOutcome` (`.launched` / `.failed(message:)`), `OpenInAppLauncher.buildOpenInScript(command:path:resolvedPath:)`, `nonisolated static func launch(command:path:resolvedPath:) async`, private `runToCompletion`, and a fileprivate `LaunchOutcomeBox` that races the child against the 2-second window. Nothing `@MainActor`; no `terminationHandler` and no `@convention(block)`/`@convention(c)` literal. |
| `Tests/OpenInAppTests.swift` | Extended with a `// MARK: - Launcher` extension: 7 cases covering script shape, path escaping (space + single quote), verbatim command interpolation (`myeditor --new-window`, `a && b`), and the four launch outcomes (`true`, `false`, a command not on PATH, `sleep 5 #` past the deadline, and a `Process.run()` throw from a missing cwd). |

**Evidence**

Tests written first and run against the absent launcher. `./scripts/ci.sh` failed to compile:

```
❌ Tests/OpenInAppTests.swift:89:22: cannot find 'OpenInAppLauncher' in scope
❌ Tests/OpenInAppTests.swift:128:34: type 'Equatable' has no member 'launched'
** TEST FAILED **
```

The deadline itself was then proved by deleting the `outcome.settle(.launched)` line from the
deadline task and re-running the gate — the long-running case blocked on the child instead of
returning at the window:

```
✖ test_launch_commandThatKeepsRunning_reportsLaunchedAtTheDeadline,
  XCTAssertLessThan failed: ("5.011722922325134") is not less than ("3.5")
Executed 325 tests, with 1 failure (0 unexpected)
```

Restoring the line turned it green.

**Deviations from the plan**

- `launch` returns `OpenInLaunchOutcome` (`.launched` / `.failed(message:)`) rather than an optional
  failure. "No failure" and "succeeded" are not the same thing here — a child still running at the
  deadline is neither — and the optional shape forced a double optional (`Failure??`) through the
  race box, which needs to distinguish "nothing has arrived yet" from "arrived carrying no failure".
- The race is an `NSLock`-guarded `LaunchOutcomeBox` bridging one `withCheckedContinuation`, the
  shape `ShellPathStore` already uses (`ShellPathStore.swift:79-90`), rather than a task group. A
  group cannot express this: `await task.value` on a `Task<_, Never>` ignores cancellation, so the
  group's implicit await of its losing child would block until the editor exits, defeating the
  window. The blocking work runs on `DispatchQueue.global(qos: .userInitiated)` for the same reason
  it does there — `readDataToEndOfFile()` and `waitUntilExit()` must not sit on the cooperative pool.
- A failure carries only the trimmed stderr, per the plan, so `false` (which prints nothing) yields
  `.failed(message: "")`. Composing an alert body when stderr is empty is T4's call.

**Gate**

`./scripts/ci.sh` — `Executed 325 tests, with 0 failures (0 unexpected)`, `==> CI passed.`

### T3: Persist the list on SettingsManager

**What landed**

| File | State |
| --- | --- |
| `Sources/App/SettingsManager.swift` | `SettingsKey.openInApps = "clearway.openInApps"`; `nonisolated static var seedOpenInApps` (one `.builtIn(.finder)` entry with `OpenInBuiltIn.finder.defaultCommand`); `@Published var openInApps: [OpenInApp]` whose `didSet` calls the new private `persistOpenInApps()`; `init` decodes the stored `Data` and falls back to the seed, writing it explicitly because `didSet` does not fire during `init`. |
| `Tests/OpenInAppsSettingsTests.swift` | New. 8 cases: fresh-suite seed, seed written to defaults, empty list persisting as empty, corrupt bytes and a wrong-typed value both reseeding Finder, and add / remove / command-edit surviving a second manager with order and `id` preserved. Per-test `UserDefaults(suiteName:)` following `Tests/SettingsManagerTests.swift:12-23`. No views. |

**Evidence**

Test file written first and run against the unchanged `SettingsManager`. `./scripts/ci.sh` failed to compile:

```
❌ Tests/OpenInAppsSettingsTests.swift:71:31: value of type 'SettingsManager' has no member 'openInApps'
❌ Tests/OpenInAppsSettingsTests.swift:83:57: type 'Equatable' has no member 'builtIn'
** TEST FAILED **
```

The empty-list rule was then proved separately, since a compile failure only shows the member is
absent. Adding `guard !openInApps.isEmpty else { return }` to `persistOpenInApps()` — the natural
wrong implementation — turned exactly one case red:

```
✖ test_emptyList_persistsAsEmptyRatherThanReseeding,
  XCTAssertEqual failed: ("[Clearway.OpenInApp(id: E7910677-…, kind: …builtIn(…finder), command: "open")]")
  is not equal to ("[]")
Executed 333 tests, with 1 failure (0 unexpected)
```

Removing the guard turned it green again.

**Deviations from the plan**

- The seed is `nonisolated static var seedOpenInApps` (computed) rather than a stored constant, so
  each seeded install gets a fresh `UUID` instead of one shared for the process lifetime.
- A decode failure and an absent key are one branch (`data(forKey:).flatMap { try? decode }` → `nil`),
  which also covers a stored value of the wrong type — `data(forKey:)` returns `nil` for the string
  the test writes. Both reseed, as the plan requires.
- `persistOpenInApps()` swallows an encode failure with `try?`, matching `TodoManager.swift:88`.
  `[OpenInApp]` is `UUID`/`String`/enum only, so `JSONEncoder` has nothing to throw on.

**Gate**

`./scripts/ci.sh` — `Executed 333 tests, with 0 failures (0 unexpected)`, `==> CI passed.`

### T4: OpenInMenu view

**What landed**

| File | State |
| --- | --- |
| `Sources/App/OpenInMenu.swift` | New. `OpenInMenu<Label: View>`: `path` parameter plus a `@ViewBuilder` label, `@EnvironmentObject settings`, one `Button` per `settings.openInApps` entry in list order, a `Task` awaiting the T2 `nonisolated` launcher, and `NSAlert().runModal()` on `.failed`. Nothing `@MainActor`-bound forms a callback; no `@convention(block)`/`@convention(c)` literal. Used by nothing yet — T6 wires both entry points. |
| `Clearway.xcodeproj/project.pbxproj` | Regenerated by `xcodegen generate` inside `./scripts/ci.sh` to pick up the new file. |

**Evidence**

No RED test. The plan records that nothing in this task is unit-testable without constructing a
view, and the decision logic a test would cover already lives in T1 (`availableBuiltIns`, draft
validity) and T2 (script building, launch outcomes). The gate here is compile + lint, per the task's
own Verification section. Behaviour is verified at T6, where the view first becomes reachable.

**Deviations from the plan**

- The label is stored as a built `Label` value (`init(path:@ViewBuilder label:)` calls the builder
  once) rather than held as an escaping `() -> Label` closure. Both call sites pass a static icon or
  title, so there is nothing to re-evaluate, and the value form keeps the view free of an escaping
  closure.
- The alert composes a body when stderr was blank, which T2's build log left to this task:
  `.failed(message: "")` — the outcome `false` produces — would otherwise show an empty alert. The
  informative text falls back to `"<command>" failed without reporting an error.`; a non-empty
  message is quoted as-is.

**Gate**

`./scripts/ci.sh` — `Executed 333 tests, with 0 failures (0 unexpected)`, `==> CI passed.`
`swiftlint lint --quiet Sources/App/OpenInMenu.swift` — no output, zero errors.
`git status --porcelain` showed only this task's own file plus the regenerated `project.pbxproj`
before committing.

### T5: Open In Apps settings section

**What landed**

| File | State |
| --- | --- |
| `Sources/App/OpenInAppsSettingsSection.swift` | New. `OpenInAppsSettingsSection` over `@ObservedObject settings`: `Section("Open In Apps")` with one row per entry (label, monospaced command, pencil edit, destructive remove), an Add menu offering `availableBuiltIns(excluding:)` then a divider then "Custom…", and a private `EditorTarget` driving `.sheet(item:)`. Plus the private `OpenInAppEditorSheet`: a Name field only when `draft.builtIn == nil`, a Command field always, Save disabled on `!draft.isValid`. No footer or helper copy. |
| `Sources/App/OpenInApp.swift` | `OpenInApp.Draft` gains `init(app:)` (seeds the sheet from an existing entry) and `app(id:)` (builds the entry the draft describes, trimming the fields `isValid` trims, and keeping a built-in's kind so only its command is editable). The explicit memberwise `init(builtIn:label:command:)` is restored because declaring `init(app:)` in the body suppresses the synthesized one. |
| `Sources/App/SettingsView.swift` | `OpenInAppsSettingsSection(settings: settings)` appended to the `Form`; `.frame(width: 450, height: 420)` → `height: 560`. |
| `Tests/OpenInAppTests.swift` | Extended with 5 cases for the two new `Draft` members: draft-from-built-in and draft-from-custom, `app(id:)` keeping the built-in kind while ignoring the label field, `app(id:)` building a custom entry, and field trimming. |
| `Clearway.xcodeproj/project.pbxproj` | Regenerated by `xcodegen generate` inside `./scripts/ci.sh` to pick up the new file. |

**Evidence**

The five new tests were run against the unchanged `OpenInApp.Draft` (`git show HEAD:Sources/App/OpenInApp.swift` restored over the working copy). `./scripts/ci.sh` failed to compile:

```
❌ Sources/App/OpenInAppsSettingsSection.swift:65:28: value of type 'OpenInApp.Draft' has no member 'app'
                save(draft.app(id: target.id))
❌ Sources/App/OpenInAppsSettingsSection.swift:92:42: extra argument 'app' in call
            draft = OpenInApp.Draft(app: app)
❌ Sources/App/OpenInAppsSettingsSection.swift:92:36: missing arguments for parameters 'label', 'command' in call
Testing cancelled because the build failed.
** TEST FAILED **
```

Restoring the two members turned the same command green.

**Deviations from the plan**

- The plan lists the section as the only new file; `OpenInApp.Draft.app(id:)` and `Draft(app:)` were added to the T1 model instead of being written inside the view. Building the entry from the draft is the sheet's one decision rule, and `Sources/App/OpenInApp.swift` is where the rest of that rule (`isValid`) already lives and is testable — a view is not.
- The `.sheet(item:)` hangs off the Add-menu row, not the `Section`. A modifier applied to a `Section` inside a `Form` is applied to its content, so the presentation needs a concrete row to attach to; the Add row is present in every state, including an empty list.
- Add and edit share one save path (`save(_:)`, append-or-replace by `id`) because `EditorTarget` mints a fresh `UUID` for a new custom entry. No separate add branch.
- No footer or helper text under the section, per the project's UI-copy rule — unlike the Main Terminal and Prompts sections above it.

**Gate**

`./scripts/ci.sh` — `Executed 338 tests, with 0 failures (0 unexpected)`, `==> CI passed.`
`swiftlint lint --quiet` — no output, zero errors.
`git status --porcelain` showed only this task's own files before committing.

**Not verified here**

The manual pass in the task's Verification section (add Cursor, confirm it leaves the add menu, edit,
add a custom entry, refuse a blank field, remove, relaunch) needs a running app and is the operator's.

### T6: Toolbar item and sidebar submenu

**What landed**

| File | State |
| --- | --- |
| `Sources/App/ContentView.swift` | One `ToolbarItem(placement: .primaryAction)` added inside the existing `if selectedWorktree != nil` toolbar block, gated on `!settings.openInApps.isEmpty` and a non-nil `currentWorktree?.path`, rendering `OpenInMenu` with an `arrow.up.forward.app` icon and `.help("Open in app")`. 8 lines; file goes 987 → 995, under the 1000-line SwiftLint error threshold. `settings` was already an `@EnvironmentObject` on the view (`:60`). |
| `Sources/App/SidebarView.swift` | `@EnvironmentObject private var settings: SettingsManager` added; `worktreeContextMenu(_:)` gains an `OpenInMenu` submenu titled "Open In", gated on `!settings.openInApps.isEmpty` and a non-nil `wt.path` and passing `wt.path` — the right-clicked worktree, not the selection. Placed directly above Reveal in Finder, below the existing `Divider`, so the three path actions group together. Reveal in Finder and Copy Path untouched. |

**Evidence**

No RED test, for the reason the task's own Verification section records: both additions are view
wiring with no decision rule a test could reach without constructing a view, and the logic behind
them is already covered — `settings.openInApps` by `Tests/OpenInAppsSettingsTests.swift` (T3), the
launch by `Tests/OpenInAppTests.swift` (T2). Same position as T4. The gate here is compile + lint
plus the operator's manual pass.

The one compile-level unknown was whether `ToolbarContentBuilder` accepts an `if let` binding, since
the existing block only uses a plain `if`. It does; the build is green with `let path =
currentWorktree?.path` driving the item's presence.

**Deviations from the plan**

- The toolbar item is the **first** primary action rather than appended last. Open In is a worktree
  action like Remove Worktree; appending it would have put it after the two panel toggles and split
  the worktree actions across them. No existing item moved relative to another.
- The sidebar submenu sits below the existing `Divider` rather than above it, which is still directly
  above Reveal in Finder as the plan requires. Above the divider would have grouped it with Close /
  Remove Worktree instead of with the two path actions it belongs with.

**Gate**

`./scripts/ci.sh` — `Executed 338 tests, with 0 failures (0 unexpected)`, `==> CI passed.`
`swiftlint lint --quiet` — no output, zero errors.
`wc -l Sources/App/ContentView.swift` — 995.
`git status --porcelain` showed only this task's two files before committing.

**Not verified here**

Everything in the task's Verification section that needs a running app is the operator's: the toolbar
menu opening a worktree in Finder and in Cursor, right-clicking main while another worktree is
selected and confirming Open In uses **main's** path, emptying the list in Settings and watching both
entry points disappear without a relaunch, and the not-on-PATH alert naming the entry's label.

### T7: Document the new files in CLAUDE.md

**What landed**

| File | State |
| --- | --- |
| `CLAUDE.md` | One bullet added under `## Architecture` → `Sources/App/`, between the `TerminalManager.appendLauncherTab` and `WorktreeGroupStore.openFileWatcher` entries. Names all four new files, states where the list is persisted and the reseed/empty rule, the raw-command / escaped-path contract and its `WorktreeHooks.interpolated` precedent, why the launcher is `nonisolated` with no `terminationHandler` and what the `LaunchOutcomeBox` replaces it with, the gating of both entry points, the `ContentView.swift` 995/1000 headroom, and that no keyboard shortcut is claimed. No new section heading; matches the surrounding bullet style and wrap width. |

**Evidence**

A docs-only edit; no RED test. The note was written from the T1–T6 build log entries rather than the
task descriptions, so it records what shipped: the lock-and-continuation race box (T2 deviation), the
sidebar passing the right-clicked worktree's path and the toolbar item's double gate (T6), and the
995-line `ContentView.swift` count (`wc -l`, T6).

**Deviations from the plan**

- The bullet goes beyond the four items the acceptance criteria name, picking up three things the
  build log recorded as deviations from the plan: the `LaunchOutcomeBox` race (and why a task group
  cannot do it), the non-empty-list + non-nil-path gate on both entry points, and the
  `ContentView.swift` line budget. Each is something a future reader would otherwise rediscover.

**Gate**

`./scripts/ci.sh` — `Executed 338 tests, with 0 failures (0 unexpected)`, `==> CI passed.`
`git status --porcelain` showed only `CLAUDE.md` and this plan before committing; no
`default.profraw`, no untracked files.

### Simplify pass (after the Changelog entries below)

`OpenInApp.Draft` lost its hand-written memberwise init (`init(app:)` moved to an extension, so the
synthesized one comes back) and now trims each field once behind two private computed properties,
collapsing `isValid` and `app(id:)` to one expression each. `OpenInAppsSettingsSection.EditorTarget`
dropped to `let app: OpenInApp?` + computed `id` — the `CommandEditorTarget` shape
(`CommandsView.swift:97`) — and `OpenInAppEditorSheet` derives its title and draft from that app the
way `CommandEditorSheet.init` does, so three pass-through members and one init are gone. The blank-
stderr alert wording moved out of the view into a pure `OpenInAppLauncher.failureMessage(command:
stderr:)` with two new tests, and `launch` now defaults `resolvedPath` to `ShellEnvironment.path` so
`OpenInMenu` no longer knows about PATH resolution. `SettingsManager.seedOpenInApps` is private,
four doc comments that restated their own code are gone, two CLAUDE.md sentences restating the model
are gone, and the two JSON round-trip tests dropped the per-field assertions their
`XCTAssertEqual(decoded, app)` already covers.

`./scripts/ci.sh` — `Executed 386 tests, with 0 failures (0 unexpected)`, `==> CI passed.`
`swiftlint lint --quiet` — no output, exit 0.

Declined, with reasons: lifting the two entry points' `!openInApps.isEmpty && path != nil` gate into
a helper (indirection for a two-term boolean, and each site's path source differs); moving add /
remove / upsert onto `SettingsManager` (it is a preference bag — every other Settings section mutates
its `@Published` property directly); passing `openInApps` into `OpenInMenu` instead of reading the
environment (spec decision 11); dropping `export PATH=` from the script as redundant with
`processEnvironment` (spec decision 13 fixes the script shape, so this is the operator's call, not a
cleanup); sharing the
Cancel/Save sheet footer with `CommandEditorSheet` and hoisting the `UserDefaults`-suite test
scaffolding out of `SettingsManagerTests`, both of which reach well outside this branch's diff.

## Changelog

Operator-requested changes made after the seven plan tasks landed. These are deliberate; do not
revert them as unintentional drift.

### Add menu moved into the section header (after T7, `a2213d5`)

From the hands-on check: in Settings → Open In Apps the `+ Add` menu sat on its own row below the
entries. It now sits on the section title's row, right-aligned, so the header reads
`Open In Apps            [ + Add ]`.

`Sources/App/OpenInAppsSettingsSection.swift` — `body` switched from `Section("Open In Apps") { … }`
to the `Section { … } header: { HStack { Text; Spacer; addMenu } }` form, and `addMenu` lost the
`HStack`/`Spacer` it used to right-pad itself with. The `.sheet(item:)` moved onto the `Menu` itself.
It still cannot hang off the `Section`: a modifier on a `Section` inside a `Form` applies to the
section's content, which is empty until the first app is added.

`./scripts/ci.sh` — `Executed 338 tests, with 0 failures (0 unexpected)`, `==> CI passed.`
`git status --porcelain` showed only the two files below before committing.

### Toolbar label and Add menu shape (after `a4f8daa`)

Two operator-requested changes from the hands-on check, not plan tasks.

**Toolbar "Open in" reads as text.** `Sources/App/ContentView.swift` — the `.primaryAction`
`OpenInMenu` label was `Image(systemName: "arrow.up.forward.app")`; it is now `Text("Open in")`.
`arrow.up.forward.app` is not a familiar icon for this action the way `square.and.arrow.up` is for
Share, and the HIG's button content rule is "Use short text labels when words communicate more
clearly than an icon" (`buttons.md`, Content). The `.help("Open in app")` tooltip went with it: the
HIG grants hover tooltips to *icon-only* buttons on macOS, and a tooltip restating a visible text
label is the kind of redundant copy CLAUDE.md rules out.

**Settings Add menu is a plain text pull-down.** `Sources/App/OpenInAppsSettingsSection.swift` —
`addMenu` rendered `Label("Add", systemImage: "plus")`, which SwiftUI drew as a plus glyph, the word
Add, and a separate round chevron segment. The operator's suspicion checks out against the HIG:
macOS documents *two* add shapes, and neither is the hybrid. A **square (gradient) button** is the
view-level add/remove-rows control and "Contain symbols only, not text. […] Prefer SF Symbols.
Avoid labels" (`buttons.md`, Platform Considerations → macOS); a **pull-down button** carries the
text and the system chevron, and its canonical example is literally "Add button → specify what to
add" (`pull-down-buttons.md`, Best Practices). This menu has to open (built-ins plus Custom…), so
it is a pull-down: the label is now `Menu("Add")` with no image, and `.menuStyle(.borderlessButton)`
renders label and chevron as one borderless control instead of a split label + indicator — the same
style `SidebarView`'s group menu already uses.

`Sources/App/OpenInMenu.swift`'s doc comment no longer says the toolbar passes an icon; both entry
points pass text now.

**Evidence**

No RED test. Both are rendering-shape changes to SwiftUI view bodies, with no decision rule to lift
into a helper — `OpenInMenu` is generic over its label precisely so each call site picks one, and
nothing in the test suite observes a `Menu`'s label.

**Gate**

`./scripts/ci.sh` — `Executed 338 tests, with 0 failures (0 unexpected)`, `==> CI passed.`
A first run failed both assertions of one `ShellPathResolverTests` case
(`testAHealthyShellGivesFullFromOneInteractiveAttempt`, expecting `.full` and one `-lic`
invocation, got `.degraded` and `-lc`). That is the suite's 0.5-second fake-shell timeout losing to process spawn on a loaded machine, not a regression:
neither changed file is reachable from `ShellPathResolver`, and the immediate re-run above was green.
`git status --porcelain` showed only the three files above and this plan before committing.

### Rebased onto #216 and aligned with it (after `189c50b`)

Operator-requested: `main` had moved and PR #216 ("Add saved commands and a worktree Run dropdown",
merged `ce39685`) overlapped this branch. The nine feature commits were rebased onto `origin/main`
and then aligned with #216's conventions. No #216 work was redone or reverted.

**Conflicts resolved during the rebase**

| File | Conflict | Resolution |
| --- | --- | --- |
| `Clearway.xcodeproj/project.pbxproj` | Five times: both sides insert `PBXBuildFile` / `PBXFileReference` lines into the same sorted regions. | Union of both sides. The file is generated; `./scripts/ci.sh` runs `xcodegen generate`, which rewrote it deterministically at the end. |
| `Sources/App/ContentView.swift` (T6) | This branch added an `OpenInMenu` `ToolbarItem` to the `.toolbar` on the `NavigationSplitView`; #216 deleted that block and re-declared it on `detailView`. | Took #216's block and moved the Open In item into it. See the alignment table below. |
| `Sources/App/ContentView.swift` (`189c50b`) | Same block again, for the text-label change. | Same resolution; the label question is settled in the alignment table. |
| `CLAUDE.md` (T7) | #216 rewrote the `TerminalManager.appendLauncherTab` bullet this branch's new bullet was inserted after, and added three bullets there. | Kept #216's rewritten and new bullets, then appended the Open In bullet after them. |

`Sources/App/SidebarView.swift` merged clean: #216 added a `commandsRow` to the destination list,
this branch adds a submenu to the worktree context menu.

**Alignments made**

| What | #216's convention | Change |
| --- | --- | --- |
| Toolbar attachment point | A `.toolbar` for the detail column goes on the detail column's content, because SwiftUI hoists a `ToolbarSpacer` into the sidebar section otherwise. | The Open In `ToolbarItem` now sits in `detailView`'s `.toolbar` inside the existing `if let runWorktree = selectedWorktree` block. `ContentView` declares no second `.toolbar`. |
| Toolbar grouping | Each worktree toolbar button gets its own Liquid Glass capsule, separated by `ToolbarGroupBreak` (`Sources/App/ToolbarGroupBreak.swift`). | A `ToolbarGroupBreak()` follows the Open In item, inside the same `if !settings.openInApps.isEmpty` gate so no stray break is left behind when the list is empty. Order in the row is Run, Open In, Archive, secondary terminal, aside. |
| Dropdown shape | `RunCommandMenu` is an icon-only `Menu` with `.menuIndicator(.hidden)` and a `.help()` tooltip standing in for its name (#216 changelog C4, an operator request). | The label is `Image(systemName: "arrow.up.forward.app")` again, with `.menuIndicator(.hidden)` and `.help("Open in app")`. **This reverses `189c50b`'s `Text("Open in")`.** Spec decision 23 carries the reasoning; it is flagged back to the operator because both shapes were operator requests, on different branches. `OpenInMenu`'s doc comment says "the toolbar can pass an icon" again. |
| Editor sheet shape | `CommandEditorSheet` is a `VStack(spacing: 0)` of padded content, a `Divider()`, then a footer whose actions are grouped at the trailing edge after a `Spacer()`, padded 16 against the content's 20, under an explicit `.frame(width:)`. | `OpenInAppEditorSheet` adopts that shape: its footer moves below a `Divider()` into its own `footer` property, and Cancel now sits beside Save at the trailing edge instead of at the leading edge. Width stays 320 — two fields do not need #216's 460. |
| CLAUDE.md | #216's three new bullets describe the detail-column toolbar rule, `TerminalManager.run`, and `SavedCommandStore`. | The Open In bullet now points at `detailView`'s toolbar and its `ToolbarGroupBreak` capsule, says why the item hides where `RunCommandMenu` disables, says why the list stays a `SettingsManager` preference rather than a `~/.clearway` file, and drops the stale "995 lines" count for the fact that `ContentView.swift` is past the `file_length` error and living on its file-wide `swiftlint:disable`. |

**Deliberately not aligned**

- **Persistence.** The list stays a `UserDefaults` JSON blob on `SettingsManager` rather than moving
  to a `~/.clearway` file like `SavedCommandStore`. Spec decision 24.
- **Settings row controls.** #216 retired the floating circular `+` for a toolbar `+` with a
  `.help()` tooltip, and `CommandsView` rows are click-to-edit with a context-menu delete. Neither
  reaches a `Form` `Section`: there is no toolbar in the Settings window and no selection or context
  menu in a grouped form. The `Add` pull-down in the section header and the per-row pencil / minus
  buttons stay as `a4f8daa` and `189c50b` left them.
- **Menu commands and shortcuts.** #216 added New Prompt / New Command to
  `CommandGroup(replacing: .newItem)` on focused scene values, and claimed `⌃3` for its destination.
  Open In declares no command and no shortcut, so `AppKeyboardShortcuts` is untouched. Spec
  decision 21.

**Evidence**

No RED test. Every change is a rebase conflict resolution, a SwiftUI view-body shape, or prose; no
decision rule moved, and nothing in `Tests/` observes a toolbar label, a menu indicator or a sheet
footer. The suite gates this as a regression check over #216's code, which is the point.

**Gate**

`./scripts/ci.sh` — `Executed 384 tests, with 0 failures (0 unexpected)`, `==> CI passed.` The count
rose from 338 to 384 because #216's own suites are now in the tree. `xcodegen generate` resorted the
five union-resolved `project.pbxproj` regions; that regenerated file is part of this commit.
`git status --porcelain` listed only the five files above; `--ignored` adds `.clearway/`, `.work/`
and `Sources/App/BuildInfo.generated.swift`, all gitignored, and no `default.profraw` because the
app was not launched.

**Decision needed from the operator**

The toolbar dropdown's label. `189c50b` made it `Text("Open in")` on this branch; #216's changelog C4
made the neighbouring Run dropdown an icon-only button with the chevron hidden. Both were hands-on
operator requests, and they are now two controls side by side in one capsule row. This rebase took
#216's shape for both. If the text label is what you want, the change is to revert decision 23 and
apply the same shape to `RunCommandMenu` so the row stays consistent.

### Toolbar Open In is a text label; Run is left alone (after `15bda5f`)

The operator's answer to the decision the rebase left open, above: the Open In toolbar item is the
text label "Open in", and Run stays exactly as #216 shipped it. `RunCommandMenu` is not touched.

| File | State |
| --- | --- |
| `Sources/App/ContentView.swift` | The `.primaryAction` `OpenInMenu` label is `Text("Open in")`. `Image(systemName: "arrow.up.forward.app")`, `.menuIndicator(.hidden)` and `.help("Open in app")` are gone. |
| `Sources/App/OpenInMenu.swift` | Doc comment back to "Generic over its label so each entry point can title it for its own surface" — neither entry point passes an icon now. |
| `Sources/App/RunCommandMenu.swift` | Unchanged. |
| `docs/superpowers/specs/2026-09-15-open-in-apps.md` | Decision 23 rewritten: Text, source Operator. |
| `CLAUDE.md` | The Open In bullet now states the label shape and why Run's differs, so the next agent reading the row does not align it back. |

The row therefore mixes one text item with four icon items, accepted knowingly by the operator.
`play` carries Run's meaning on its own; `arrow.up.forward.app` does not carry this one — it is the
glyph `189c50b` rejected for exactly that reason. Consistency inside the row loses to the label
being readable at all.

`.menuIndicator(.hidden)` went with the icon rather than being kept. It was not load-bearing for the
capsule grouping the rebase set up: `ToolbarGroupBreak` (a `ToolbarSpacer(.fixed, …)` on macOS 26)
is what draws the capsule boundaries, and `RunCommandMenu` declares its own hidden indicator inside
its own body, so nothing at the `ContentView` call site depends on it. A text pull-down drawing no
chevron reads as a plain button that unexpectedly opens a menu, which is the affordance
`OpenInAppsSettingsSection`'s `Add` pull-down already keeps.

**Evidence**

No RED test. This is a SwiftUI view-body label change with no decision rule to lift into a helper —
`OpenInMenu` is generic over its label precisely so each call site picks one, and nothing in
`Tests/` observes a `Menu`'s label or its indicator.

**Gate**

`./scripts/ci.sh` — `Executed 384 tests, with 0 failures (0 unexpected)`, `==> CI passed.`
`git status --porcelain` listed only the four changed files above plus this plan before committing;
`--ignored` adds
`.clearway/`, `.work/` and `Sources/App/BuildInfo.generated.swift`, all gitignored, and no
`default.profraw` because the app was not launched.

### PATH injected once, through the child's environment (after `66b1a25`)

Operator decision on the item the simplify pass had declined as "the operator's call": the script
built by `OpenInAppLauncher.buildOpenInScript` prepended `export PATH=<escaped resolved PATH>;`
while `runToCompletion` also set `process.environment = ShellEnvironment.processEnvironment`, whose
`PATH` is the same `ShellEnvironment.path`. `processEnvironment` is now the single source, matching
`WorktreeManager.runCommand` (`Worktree.swift:324-343`).

| File | State |
| --- | --- |
| `Sources/App/OpenInAppLauncher.swift` | `buildOpenInScript(command:path:)` — the `resolvedPath` parameter and the `export PATH=` prefix are gone, leaving `"<command> <escaped path>"`. `launch(command:path:)` lost its `resolvedPath: String = ShellEnvironment.path` parameter with it: it existed only to feed the script. |
| `Tests/OpenInAppTests.swift` | The three `buildOpenInScript` cases assert the new script text and drop `resolvedPath`; the five `launch` cases drop it too, along with the `testPath` constant. No case was deleted. |
| `docs/superpowers/specs/2026-09-15-open-in-apps.md` | Decision 13 rewritten to the new script shape. |
| `CLAUDE.md` | The Open In bullet now records that the script escapes only the folder and that the PATH arrives through `processEnvironment`. |

**Evidence**

No RED test: this removes a redundant assignment, and the behaviour is unchanged by construction.
Verified by reading rather than by a failing test — `Process.environment`, set to a non-`nil`
dictionary, *is* the child's environment, so `/bin/sh -c` starts with
`PATH = ShellEnvironment.path`, the identical value the export wrote. The only production caller,
`OpenInMenu.swift:32`, never passed a `resolvedPath`, so no call site saw a different PATH. The
launch tests still exercise the inherited PATH end to end: `true`, `false` and `sleep` resolve only
because the child's environment carries a usable PATH, and `ShellPathValidation.unionWithBaseline`
guarantees `/usr/bin:/bin:/usr/sbin:/sbin` is in it whether or not a resolution has run — which is
why dropping the tests' `testPath` (`"/usr/bin:/bin"`, a subset of that baseline) changes nothing.

**Gate**

`./scripts/ci.sh` — `Executed 386 tests, with 0 failures (0 unexpected)`, `==> CI passed.`
`git status --porcelain` listed only the four files above plus this plan; `--ignored` adds
`.clearway/`, `.work/` and `Sources/App/BuildInfo.generated.swift`, all gitignored, and no
`default.profraw` because the app was not launched.

### Sidebar submenu label lowercased to "Open in" (after `c445747`)

Review fix. `Sources/App/SidebarView.swift:352` read `Text("Open In")` while the toolbar item, the
spec and CLAUDE.md all say "Open in", and the adjacent Reveal in Finder keeps its preposition
lowercase.

| File | State |
| --- | --- |
| `Sources/App/SidebarView.swift` | The `OpenInMenu` label in `worktreeContextMenu(_:)` is `Text("Open in")`. |
| `CLAUDE.md` | The Open In bullet now states that the sidebar submenu carries the toolbar's label, lowercase preposition included, so the two do not drift apart again. |

The remaining "Open In" spellings are the Settings section title `Open In Apps`
(`OpenInAppsSettingsSection.swift:17`, CLAUDE.md:206, spec decisions 2 and 24, its file table and
its step 1) — a
heading, left as is. The spec already spelled the menu "Open in" everywhere it named the label.

**Evidence**

No RED test: the label is a `Text` inside a SwiftUI `Menu` builder, which no test reaches.

**Gate**

`./scripts/ci.sh` — `Executed 386 tests, with 0 failures (0 unexpected)`, `==> CI passed.`

### PR review fixes (review-pr stage, after `cdde062`)

`/pr-review-toolkit:review-pr code tests errors types`. Four agents; the important findings and what
was done with each.

**The launcher decided on pipe EOF, not on the child's exit.** Two agents proved it independently,
and it is a deviation from decision 15 rather than a disagreement with it: `readDataToEndOfFile()`
returns when the *last* holder of the write end closes it, so any grandchild inheriting stderr — the
editor a command backgrounds — hid the shell's exit status behind its whole lifetime. RED on
`cdde062`: `test_launch_nonZeroExitWithADescendantHoldingTheOutput_stillReportsFailure`
(`sleep 30 & echo boom 1>&2; exit 1 #`) failed with `expected a failure, got launched`. The same
mechanism parked a `DispatchQueue.global(qos: .userInitiated)` worker per launch for the editor's
session, and `ShellPathStore` resolves PATH on that same queue and QoS, so enough parked launches
would hang `awaitPath()` and with it every new launcher tab — silently.

`Sources/App/OpenInAppLauncher.swift` was rewritten: stdout **and** stderr go to one unlinked temp
file, the watch window is a `Task.sleep` poll of `process.isRunning` on the cooperative pool, and
`LaunchOutcomeBox`, the `DispatchQueue` hop and `runToCompletion` are gone — a net simplification of
the racing apparatus, with no block or C callback formed anywhere (decision 16 holds). A regular
file has no 64KB buffer, so the read-before-wait rule the pipe needed no longer applies; unlinking
at once reclaims the space when the last descriptor closes, including for a child abandoned at the
deadline. `standardInput` is `nullDevice`. Decision 15 is unchanged and now pinned by
`test_launch_failureAfterTheDeadline_staysLaunched`.

**Reseeding overwrote an undecodable stored list.** Decision 9 asks for the reseed, not the write.
`Kind`'s synthesized JSON carries its case names and `_0` as persisted form, so a rename or a
version rollback makes the whole array throw; writing `[Finder]` over it destroyed the user's list
with no recovery. `SettingsManager.init` now persists only for a genuinely absent key and logs the
decode failure. Pinned by `test_undecodableStoredValue_isLeftOnDiskRatherThanOverwritten`, and the
wire format itself by `test_storedWireFormat_decodesFromItsPersistedBytes`, which decodes literal
bytes — a round-trip test passes under any rename.

**Other fixes.** A failing command's stdout is captured too, so a wrapper that prints its complaint
there no longer reaches the user as "failed without reporting an error"; the spec excludes surfacing
output *on success*, not on failure. A `run()` throw now goes through `spawnFailureMessage`, which
names the working directory — a removed worktree folder previously read as if the editor were
missing. The settings section's index-or-append upsert moved to a pure `OpenInApp.upsert(_:into:)`
with both branches tested: it was the one decision rule in the diff still private to a view, and
criterion 10 asks for those to be view-free. `Draft` trims `.whitespacesAndNewlines`, matching the
launcher. Failure paths log through `Ghostty.logger`, as `SavedCommandManager.save` does. The
`failureMessage(command:stderr:)` label became `detail:`, since a spawn throw is not stderr. New
tests pin the child's PATH and cwd, `availableBuiltIns` with every built-in present, and
`.failed(message: "")` for a silent non-zero exit. `EditorTarget`'s doc comment, copied verbatim
from `CommandEditorTarget`, is gone.

**Declined, with reasons.** Moving `openInApps` to `private(set)` with add/update/delete methods on
`SettingsManager` (the `SavedCommandManager` shape) — the upsert lift takes the testability win
without inventing a test-only mutation door, and the simplify pass already declined the move on
consistency grounds; recorded as a follow-up. Making `Draft.app(id:)` failable — the door it closes
(Save with a blank field) is already unreachable behind `.disabled(!draft.isValid)`, and it does not
close the door that is reachable (a hand-edited blob), so it would add an unreachable branch at the
call site. Per-element decoding of the stored array — leaving the bytes intact already makes a
rollback recoverable. Serializing `NSAlert.runModal()` against a nested modal — a `command not
found` alerts in under 100 ms and is modal once up, so two overlapping failures are not reachable
through the menu. Lenient non-UTF-8 decoding of the child's output — `String(decoding:as:)` trips
SwiftLint's `optional_data_string_conversion` and CLAUDE.md forbids new warnings. The "Open in" vs
"Open In" capitalisation disagreement — an operator decision recorded in this changelog.

**Gate**

`./scripts/ci.sh` — `Executed 420 tests, with 0 failures (0 unexpected)`, `==> CI passed.`, exit 0,
run after the last edit, with no SwiftLint warnings (the first run after the rewrite reported
`optional_data_string_conversion`, which the final `String(data:encoding:)` form removes).
`git status --porcelain` listed only the eight files above plus this plan; `--ignored` adds
`.clearway/`, `.work/` and `Sources/App/BuildInfo.generated.swift`, all gitignored, and no
`default.profraw` because the app was not launched.
