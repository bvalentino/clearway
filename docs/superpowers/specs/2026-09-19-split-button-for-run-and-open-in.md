# Split Button for Run and Open In

**Date:** 2026-09-19
**Base:** 484482d3fe5e7e539176c4c1f8ae5720d5414836

The worktree toolbar's Run and Open in buttons are plain dropdowns: every click opens the list and
the user picks an item, almost always the same one as last time. Both become split buttons —
clicking the label performs the last-used item, clicking the chevron opens the full list — by
remembering which item was picked last and passing it to SwiftUI's `Menu(content:label:primaryAction:)`.
Run remembers per project, in that project's `commands.json`; Open in remembers globally, in
`UserDefaults`, because the app list it draws from is a global preference. Both ids are resolved
against the current list on every read, so an item that has since been deleted counts as nothing
remembered and the button falls back to opening the list.

## Decisions

| # | Question | Decision | Source |
| --- | --- | --- | --- |
| 1 | How is a split button built in SwiftUI? | `Menu(content:label:primaryAction:)`, declared unconditionally on both toolbar buttons. Supersedes the original decision to declare the menu twice and switch on whether a last-used item resolved: with a fallback (Decision 2) there is always a primary action, so one declaration suffices. `OpenInMenu` still declares it twice, but on `remembersLastUsed` — the sidebar's context submenu is not a split button. | Operator (2026-09-20, after hands-on check) |
| 2 | What happens before the user has picked anything? | The button is still a split button and its label half performs the **first item in the list** — Run's first saved command in display order, Open in's first app in `openInApps`. Supersedes the original decision to fall back to a plain dropdown, which drew as a plain dropdown in the fresh state. The only non-split case is an empty list: Run stays visible and disabled, Open in stays hidden. | Operator (2026-09-20, after hands-on check) |
| 3 | Where is Run's last-used id stored? | `<projectPath>/.clearway/commands.json`, the same file as the project's saved commands. | Operator (brief) |
| 4 | Where is Open in's last-used id stored? | `UserDefaults`, key `clearway.lastUsedOpenInApp`, beside `clearway.openInApps`. The app list is a global preference, so the memory of it is one too. | Operator (brief) |
| 5 | What happens to a remembered id whose item was deleted? | Nothing on delete. The id is resolved against the live list on every read, and an id that names nothing resolves to nil — which is case 2. One rule, applied in one place, instead of a cleanup pass on every delete path. | Operator (brief, "resolved on read") |
| 6 | `commands.json` is a bare `[SavedCommand]` array today. What does it become? | A `SavedCommandsPayload` object, `{"commands":[…],"lastRunId":"…"}`, with a legacy fallback that decodes a bare array into a payload with a nil `lastRunId`. This is exactly what `groups.json` did when it grew `defaultOrder` (`WorktreeGroupStore.swift:109-116`), so the shape and its reasoning already exist in the project. | Spec |
| 7 | Could the legacy fallback be skipped, since per-project `commands.json` has not shipped in a release? | No. `SavedCommandStore.load()` does not merely reset on an undecodable file, it **moves it aside** to `commands.json.corrupt` (`SavedCommandStore.swift:50,59`), so a clean break would rename every dogfood project's list away and log it as corruption. The precedent that declined a migration (spec `2026-09-18-project-specific-commands.md`, Decision 3) was about an abandoned *path*, left untouched on disk; this is the same file being rewritten. | Spec |
| 8 | Does picking from the sidebar's right-click Open in submenu update the last-used app? | No. The brief says that submenu is unchanged, and the parameter that turns the memory on defaults to off, so `SidebarView` is not touched at all. The memory belongs to the button that consumes it. | Operator (brief) + Spec |
| 9 | Is the resolution rule a shared generic helper? | No. It is `list.first { $0.id == rememberedId }` on each side, exposed as `SavedCommandManager.lastRunCommand` and `SettingsManager.lastUsedOpenInApp`. Both are pure, non-view, already have test files, and are directly testable — a generic helper plus a new file would add indirection to one line of standard library. | Spec |
| 10 | Does the label change to name the primary item? | Yes. Run's label is the primary command's name; Open in's is `"Open in <App name>"` ("Open in Cursor"). Both keep the system chevron and no tooltip. Supersedes the original decision to keep the words "Run" and "Open in": a split button's label half acts on a click, so it has to say what that click does. The generic word survives only where nothing resolves — Run on an empty list, where it is disabled. | Operator (2026-09-20, change C2) |
| 11 | Is the last-used id recorded on pick or only on a successful launch? | On pick. It is the last item *used*, not the last that worked; recording only on success would leave a failing command permanently unable to become the primary action. Both entry points into each view's action funnel through one method, so the record is written once per view. | Spec |
| 12 | Where is Run's record written — the view or `TerminalManager`? | `RunCommandMenu.run(_:)`, which already owns the `SavedCommandManager` and already funnels both the menu item and the new primary action. The CLAUDE.md rule that puts *running* on `TerminalManager` is about resolving a worktree and awaiting a shell prompt; recording an id is neither, and `TerminalManager` does not hold the manager. | Spec |
| 13 | Does a `Menu` with `primaryAction:` need an availability check? | No. The initializer is macOS 12.0+ and the deployment target is macOS 13.0 (`project.yml:4-5`). | Spec (verified, below) |
| 14 | Where does "remembered item, else first item" resolve? | On the non-view owners: `SavedCommandManager.primaryCommand` (`lastRunCommand ?? commands.first`) and `SettingsManager.primaryOpenInApp` (`lastUsedOpenInApp ?? openInApps.first`). Both are unit-tested; the views only unwrap the optional. | Operator (2026-09-20) |
| 15 | Does the sibling worktree's `applyPrimaryActionStyle()` come along? | No. It is `.glassProminent`/`.borderedProminent` with an accent tint — what makes Start Now the *prominent* button on its screen, not what makes it split. `primaryAction:` alone is what draws the capsule with a divider. | Build (2026-09-20) |
| 16 | Does the chevron's list still show the primary item? | No, on both toolbar buttons — the label half already runs it, so listing it again offers the same click twice. `SavedCommandManager.menuCommands` and `SettingsManager.menuOpenInApps` are the lists minus the primary. The sidebar's right-click Open in submenu is unchanged: it has no primary and lists `openInApps` whole. | Operator (2026-09-20, change C2) |
| 17 | What does Run's "Add Command…" item do? | Presents `CommandEditorSheet(command: nil)` — the same sheet the Commands view's `+` toolbar item opens, not a second implementation. The sheet is attached to `RunCommandMenu`'s own body, outside its `.disabled(…)` so the editor's controls do not inherit a disabled environment. `CommandsView`'s `+` is not reachable as a seam: it drives a `@State` on that view and publishes `.focusedSceneValue(\.newCommandAction)`, which is only in scope while the Commands destination is on screen — the Run button lives in the worktree detail toolbar, where it never is. `ContentView` was not given the sheet because its `file_length` budget is already spent. | Operator (brief) + Build (2026-09-20) |
| 18 | Does Open in get an equivalent "Add app" item? | No. The operator asked for Run only, and the sibling's pattern is not trivially the same: its editor door is the app's own `CommandEditorSheet`, where Open in's list is edited in Settings. The consequence is that a one-app list leaves Open in's dropdown empty, which AppKit draws as a click that does nothing — accepted, because the one app there is is one click away on the label. | Operator (brief) |

## Assumptions

Each verified by reading the codebase at base `484482d` or by fetching Apple's documentation on
2026-09-19. No probe scripts or temporary files were written, into the repo or the scratchpad.

1. **`Menu(content:label:primaryAction:)` produces the behaviour the brief describes.** Apple's
   SwiftUI `Menu` documentation, "Primary action" section, fetched 2026-09-19 from
   `developer.apple.com/documentation/swiftui/menu`: "Menus can be created with a custom primary
   action. The primary action will be performed when the user taps or clicks on the body of the
   control, and the menu presentation will happen on a secondary gesture, such as on long press or
   on click of the menu indicator." The initializer's availability, from
   `documentation/swiftui/menu/init(content:label:primaryaction:)` fetched the same day, is
   iOS 15.0 / macOS 12.0 / tvOS 17.0 / visionOS 1.0 — below this app's macOS 13.0 target
   (`project.yml:4-5`).
2. **Both toolbar buttons exist where the brief says, and only the toolbar one is a split button.**
   `ContentView.swift:196-198` renders `RunCommandMenu(worktree:)` and `ContentView.swift:200-205`
   renders `OpenInMenu(path:)` with `Text("Open in")`, each in its own `.primaryAction` group.
   `OpenInMenu` is also rendered by `SidebarView.swift:453-457` from the worktree context menu, which
   Decision 8 leaves alone.
3. **Each menu already funnels every pick through one private method.** `RunCommandMenu.swift:15`
   calls `run(command)` and `OpenInMenu.swift:23` calls `open(app)`, so one added line in each method
   records the id for both the list pick and the new primary action.
4. **`commands.json` is a bare array today and the store owns the whole document.**
   `SavedCommandStore.load()` decodes `[SavedCommand].self` (`SavedCommandStore.swift:54`) and
   `save(_:)` encodes whatever array it is handed (`SavedCommandStore.swift:84`); the manager is the
   only caller (`SavedCommandManager.swift:21,30,72`). Changing both signatures to
   `SavedCommandsPayload` touches no other source file.
5. **The bare-array-to-payload upgrade already has a worked precedent in this repo.**
   `WorktreeGroupsPayload` (`WorktreeGroupStore.swift:8-30`) is a `Codable` struct with a
   `static let empty` and a no-defaults memberwise init, and `WorktreeGroupStore.load()` tries the
   payload first and falls back to `[WorktreeGroup].self` "so existing projects keep their groups
   after upgrade" (`WorktreeGroupStore.swift:109-116`).
6. **A missing `lastRunId` key decodes to nil without custom `CodingKeys`.** Swift's synthesized
   `init(from:)` uses `decodeIfPresent` for an `Optional` property, which is why
   `WorktreeGroupsPayload` needs custom keys only for the field it must *not* encode
   (`WorktreeGroupStore.swift:19-24`) and not for absence. So the legacy fallback is needed for the
   top-level array shape only, not for a payload written by an older build.
7. **Both models are `Identifiable` by `UUID`.** `SavedCommand.id` is a `let id: UUID`
   (`SavedCommand.swift:14`) and `OpenInApp.id` is a `let id: UUID` (`OpenInApp.swift:47`), so a
   remembered id is a `UUID` on both sides and `first(where:)` is the whole resolution rule.
8. **`SettingsManager` has the shape a new preference slots into.** Keys are string constants in
   `SettingsKey` (`SettingsManager.swift:4-12`), each preference is a `@Published` property that
   persists in `didSet` (`SettingsManager.swift:73-120`), and `init` reads every key from the
   injected `defaults` (`SettingsManager.swift:122-144`). `openInApps` is already published there
   (`SettingsManager.swift:109-113`), so the resolved `lastUsedOpenInApp` can be a computed property
   beside it.
9. **The test seams needed already exist.** `SettingsManagerTests` builds each manager over a fresh
   `UserDefaults(suiteName:)` and tears the domain down (`Tests/SettingsManagerTests.swift:9-23`),
   which is how "persists across instances" is already asserted there.
   `SavedCommandStoreTests`/`SavedCommandManagerTests` build over a `TempRootTestCase` project path
   (`Tests/SavedCommandStoreTests.swift:13`, `Tests/SavedCommandManagerTests.swift:14-15`) and
   `SavedCommandStoreTests.writeCommandsFile(_:)` already writes raw bytes into the file
   (`Tests/SavedCommandStoreTests.swift:33-36`), which is what the legacy-format case needs.
10. **Nothing else reads or writes a last-used command.** `grep` for `command-defaults`/
    `commandDefaults` over `Sources/`, `Tests/` and `docs/` returns nothing at base `484482d`. A
    stray `.clearway/command-defaults.json` exists in the operator's main checkout from an earlier
    experiment; no code reads it, `.clearway` is ignored through `~/.gitignore:35`, and this change
    neither reads nor removes it.

## Objective

Make the toolbar's Run and Open in buttons repeat the last pick in one click, without taking the
full list away.

### Success criteria

1. With at least one saved command and nothing yet run in this project, the toolbar's Run button is
   a split button: clicking the `Run` label runs the **first** saved command, clicking the chevron
   opens the list.
2. Picking "Build & Run" from that list runs it. Clicking the `Run` label then runs "Build & Run"
   again without opening anything, and clicking the chevron still opens the full list.
3. Picking a different command from the list runs it and makes it the new primary action.
4. Quitting and relaunching keeps the primary action: it is read back from
   `<projectPath>/.clearway/commands.json`.
5. Deleting the remembered command in the Commands view falls the primary action back to the first
   command in the list (criterion 1) with no further action by the user, and deleting a different
   command leaves the primary action alone.
6. Project A's remembered command does not affect project B's Run button.
7. The same five behaviours hold for the toolbar's Open in button against Settings → Open In's app
   list, remembered in `UserDefaults` and therefore shared by every project window.
8. The sidebar's right-click "Open in" submenu is unchanged: still a plain submenu, still opening
   the right-clicked worktree, and picking an item there does not change the toolbar button's
   primary action.
9. Each button's label names its primary action — the primary command's name on Run, "Open in
   <App name>" on Open in — with the system chevron and no tooltip. Run reads "Run" only on an
   empty list. Each chevron's list omits the primary, and Run's ends with "Add Command…" after a
   separator, opening the same editor sheet the Commands view's `+` opens.
10. An existing `commands.json` holding a bare `[SavedCommand]` array loads with its commands intact
    and nothing remembered, and is rewritten as a payload on the next save. It is not moved aside to
    `commands.json.corrupt`.
11. An empty Open in list still hides the toolbar item, and an empty command list still disables the
    Run button.

### Test coverage this requires

- `SavedCommandStoreTests`: a payload round-trips `lastRunId` through save and load; a file holding a
  legacy bare array loads as commands with a nil `lastRunId` and leaves no `.corrupt` file; a genuinely
  undecodable file still moves aside and loads as `.empty` (the existing cases, retargeted at the
  payload); the stored wire format decodes from its literal bytes
  (`{"commands":[…],"lastRunId":"…"}`) and from the same bytes with the `lastRunId` key absent.
- `SavedCommandManagerTests`: `lastRunCommand` is nil before anything is recorded; it resolves to the
  recorded command; it is nil once that command is deleted while a *different* command stays
  resolvable; `recordLastRun` survives a reload through a second store over the same project path.
- `SettingsManagerTests`: `lastUsedOpenInApp` is nil on a fresh suite; it resolves after the id is
  set; it is nil when the id names an app no longer in `openInApps`; the id persists across two
  `SettingsManager` instances over the same suite.
- No view test. `RunCommandMenu` and `OpenInMenu` gain no decision of their own — they render one of
  two menu declarations from an already-resolved optional — and XCTest cannot reach a SwiftUI body
  here. This is the split the project already makes for `Ghostty.SurfaceView` and for
  `TerminalManager.revealSecondaryForHook`.

## Verification

```bash
./scripts/ci.sh
```

Regenerates the Xcode project, lints, builds and runs the test suite — the same gate
`.github/workflows/ci.yml` applies to a PR. It is the regression check for every build step and the
full gate at sign-off. New Swift files are invisible to the build until `xcodegen generate` runs, so
no hand-written `xcodebuild` line substitutes for it.

```bash
swiftlint lint --quiet
```

Runs as a post-build phase; zero errors required.

```bash
git status --porcelain
```

Before any CI stamp or sign-off. Expect the un-gitignored `default.profraw` after any Debug launch;
untracked files block sign-off.

How the split button actually draws in the macOS 26 toolbar is not something the test suite or a
build agent can answer — the operator checks it by hand in the running app, against criteria 1-3
and 9.

## Files touched

- `Sources/App/SavedCommandStore.swift` — add `SavedCommandsPayload` (`commands: [SavedCommand]`,
  `lastRunId: UUID?`, a `static let empty`, and a memberwise init with no defaults so a field added
  later is a compile error at `save()` rather than a silent erase — the `WorktreeGroupsPayload`
  shape). `load()` returns the payload: payload first, legacy bare array second, move-aside third.
  `save(_:)` takes the payload. Doc comment restated for the document.
- `Sources/App/SavedCommandManager.swift` — `@Published private(set) var lastRunId: UUID?` loaded
  with the commands; `var lastRunCommand: SavedCommand?` resolving it against `commands`;
  `recordLastRun(_:)` setting the id and saving; `save()` writing a `SavedCommandsPayload`.
- `Sources/App/RunCommandMenu.swift` — the two menu declarations, switched on
  `savedCommandManager.lastRunCommand`, with the item list factored into one `@ViewBuilder` property
  so the two branches cannot drift. `run(_:)` records the id.
- `Sources/App/OpenInMenu.swift` — a `remembersLastUsed: Bool = false` init parameter; the two menu
  declarations, switched on `settings.lastUsedOpenInApp` when that flag is on; `open(_:)` records the
  id when it is on. Same `@ViewBuilder` factoring for the item list.
- `Sources/App/SettingsManager.swift` — `SettingsKey.lastUsedOpenInApp`;
  `@Published var lastUsedOpenInAppId: UUID?` persisting its `uuidString` in `didSet` and removing
  the key when nil; `var lastUsedOpenInApp: OpenInApp?` resolving it against `openInApps`; `init`
  reading the key.
- `Sources/App/ContentView.swift` — the toolbar's `OpenInMenu` gains `remembersLastUsed: true`. One
  argument on an existing call; the file's `file_length` disable is not made to carry a new section.
- `Tests/SavedCommandStoreTests.swift`, `Tests/SavedCommandManagerTests.swift`,
  `Tests/SettingsManagerTests.swift` — the cases listed above.
- `CLAUDE.md` — three edits. The `SavedCommandStore` bullet (line 201) gains the payload shape and
  the last-run id. The Open In bullet's label rationale (lines 263-266) is rewritten: both toolbar
  items are now split buttons that *do* act on a click, so the reason for a text label is that the
  primary half needs a name, not that a click only opens a menu. Both bullets record that the
  remembered id is resolved on read and never cleaned up on delete.

## Out of scope

- The sidebar's right-click "Open in" submenu (Decision 8), and `SidebarView.swift` generally.
- Naming the remembered item in the label or in a tooltip (Decision 10).
- A keyboard shortcut for either primary action; `AppKeyboardShortcuts` is untouched, which keeps
  the existing "the menu claims no keyboard shortcut" line in CLAUDE.md true.
- Per-worktree memory. Run remembers per project, Open in globally, as the brief sets out.
- Any change to how a command runs (`TerminalManager+Commands.swift`, `CommandLaunch`, `ShellSend`)
  or to how an app is launched (`OpenInAppLauncher`, `buildOpenInScript`).
- The Commands view, the command editor, and the Open In settings section — none of them show or
  edit the remembered id.
- Watching `commands.json` for outside edits. Still deliberately absent.
- The stray `.clearway/command-defaults.json` on the operator's machine (Assumption 10). Not read,
  not written, not deleted.

## Open risks

- `Menu`'s primary action is documented to present the menu "on a secondary gesture, such as on long
  press or on click of the menu indicator". On macOS that indicator is the chevron the buttons
  already draw, but the exact hit target in a macOS 26 Liquid Glass toolbar is not something a test
  asserts. Operator verification, above.
- Recording the last-run id rewrites the whole `commands.json` on every run. Two windows open on the
  same project would each hold a manager and the later write would win — the same exposure
  `2026-09-18-project-specific-commands.md` accepted for command edits, now also reachable by simply
  running a command. Accepted.
- Switching between the two `Menu` declarations changes the view's type, so SwiftUI rebuilds the
  toolbar item the first time an item is picked. Accepted: it happens once per list per session and
  no state lives in the button.
