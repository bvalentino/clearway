# Open in apps

**Date:** 2026-09-15
**Base:** d94b0b0f879606872a8b1a92e2f38ac144914339
**PR:** #219
**Rebased onto:** `ce39685` (#216, saved commands and the worktree Run dropdown). Decisions 22-24
record what that reconciliation changed; the Assumptions below were verified at the original base.
Rebased again onto `d4fd73e` (#217, #218) before the PR opened — both landed additively alongside
this work, so no decision here changed.

Opening the selected worktree in Cursor, Zed or VS Code currently means opening a terminal tab and
typing `cursor .`. This change adds an "Open in" menu — in the window toolbar and in the sidebar's
worktree context menu — that runs a user-configured command with the worktree path appended. The
list of apps lives in a new Settings section: four built-ins (Finder, VS Code, Cursor, Zed) that can
each be added once with an editable command and a fixed label, plus custom entries with both fields
editable. Clearway detects nothing and assumes nothing about what is installed.

## Decisions

| # | Question | Decision | Source |
| --- | --- | --- | --- |
| 1 | Where does the menu appear? | Two places: a toolbar item in `ContentView`, gated the same way the archive/panel items are (`selectedWorktree != nil`, `ContentView.swift:198`), and a submenu in the sidebar worktree context menu next to Reveal in Finder (`SidebarView.swift:325-355`). The sidebar entry is what makes main reachable without selecting it. | Operator |
| 2 | What is configurable, and where? | App-wide Settings → "Open In Apps": add, remove, edit. Built-ins Finder / VS Code / Cursor / Zed, each addable at most once, label fixed, command editable, defaults `open` / `code` / `cursor` / `zed`. Custom entries carry a user label and command, both editable, both required. | Operator |
| 3 | What does a fresh install show? | Finder only, pre-added, removable like any other entry. | Operator |
| 4 | How is the path passed? | Appended as the last argument, shell-escaped. No placeholder syntax. `myeditor --new-window` → `myeditor --new-window '<path>'`. | Operator |
| 5 | What happens on failure? | An alert naming the app and quoting stderr. Success is silent. | Operator |
| 6 | Empty list behaviour | Toolbar item and sidebar submenu are both hidden entirely. | Operator |
| 7 | Menu order | List order in Settings, which is insertion order. No drag-to-reorder. | Operator |
| 8 | How is the list persisted? | `[OpenInApp]` JSON-encoded into one `UserDefaults` `Data` value under `clearway.openInApps`, held by `SettingsManager` as a `@Published` array with a persisting `didSet` — the shape every other preference there already uses (`SettingsManager.swift:57-100`). A per-entry key scheme would need its own index key to preserve order; one blob does not. | Spec author |
| 9 | How is "fresh install" told apart from "user removed everything"? | By key presence. Absent key → seed `[Finder]`. Present key holding `[]` → empty list, and the toolbar item stays hidden. A decode failure is treated as absent and re-seeds Finder. | Spec author |
| 10 | Is the label stored for a built-in? | No. `OpenInApp.kind` is `.builtIn(OpenInBuiltIn)` or `.custom(label:)`, and `label` is computed from it. "Built-in labels are not editable" then has no rule to enforce — there is no field to edit. | Spec author |
| 11 | How do the two views reach the app list? | `@EnvironmentObject var settings: SettingsManager` directly. `ContentView` already declares it (`ContentView.swift:60`); `SidebarView` adds the declaration. No provider closure is needed: `clearwayChrome` injects `SettingsManager` into the whole `ProjectWindow` hierarchy (`ClearwayApp.swift:158-163, 236-243`), and the `mainCommandProvider` seam exists only because `TerminalManager` is a manager outside that hierarchy (`TerminalManager.swift:164`). | Spec author |
| 12 | Where does the menu's code live? | One `OpenInMenu` view (new file), generic over its label so the toolbar can pass an icon and the context menu a title. It owns the items, the launch call and the failure alert, so that logic is written once for both entry points. | Spec author |
| 13 | How is the command run? | `/bin/sh -c "<command text> <escaped path>"` via `Process`, cwd set to the worktree path, environment `ShellEnvironment.processEnvironment` — which is where the resolved PATH comes from, as in `WorktreeManager.runCommand` (`Worktree.swift:324-343`). The script itself carries no `export PATH=`: the child inherits the same value, so exporting it again was one PATH injected twice. The command text is interpolated raw — it is the user's and is meant to be read by the shell as typed (same contract as `WorktreeHooks.interpolated`, `WorktreeHooks.swift:18-26`). Only the path is escaped. | Spec author, revised by the operator after the simplify step |
| 14 | `exec` in front of the command? | No. `exec` binds to the first simple command only, so `exec foo && bar` would mis-parse a user command containing shell operators. Saving one `sh` process does not justify that. | Spec author |
| 15 | How long is a launch watched for failure? | 2 seconds. A detached task drains stderr to EOF and waits for exit; the caller races that against a 2-second deadline. Exit with non-zero status inside the window → alert. Still running at the deadline → treated as launched, and the drain task ends on its own when the child does. `sh` reports `command not found` and exits 127 in well under 100 ms, so the window is never actually felt. | Spec author |
| 16 | Why not `Process.terminationHandler`? | It is a bridged ObjC block property, and the project's CLAUDE.md records that a `@convention(block)` literal written inside a `@MainActor` member traps when invoked off-main. `waitUntilExit()` on a detached, nonisolated task avoids the question entirely. | Spec author |
| 17 | How is the failure alert presented? | `NSAlert().runModal()` from `OpenInMenu`, the pattern already used for app-level alerts (`ClearwayApp.swift:68, 90`). A `@Published` failure plus `.alert` modifiers would have to be wired into two separate view trees for one fire-and-forget message. | Spec author |
| 18 | Does Finder go through `NSWorkspace` instead of the shell? | No. Finder is `open` like any other entry, so there is one execution path and Finder's command stays editable. | Operator |
| 19 | Inline editing or an editor sheet? | A sheet. The acceptance criteria require that saving a blank label or command is *refused*, which a sheet expresses as a disabled Save button. Inline commit-on-blur would need per-field previous-value state to revert to and would show the refusal as nothing at all. The same sheet serves "add custom" and "edit any entry"; adding a built-in takes its default command and opens no sheet. | Spec author |
| 20 | Settings window size | `SettingsView`'s frame grows from `height: 420` to `height: 560` to fit the new section. The grouped `Form` already scrolls, so a longer list clips rather than breaking the window. | Spec author |
| 21 | Does the toolbar item get a keyboard shortcut? | No — out of scope, and therefore no `AppKeyboardShortcuts` entry. The claim table must stay exactly what the app handles (`AppKeyboardShortcuts.swift`). | Operator |
| 22 | Where is the toolbar item declared, now that #216 has moved the worktree toolbar? | On `detailView`'s own `.toolbar`, inside the existing `if let runWorktree = selectedWorktree` block, not on the `NavigationSplitView`. #216 moved the block because SwiftUI hoists every `ToolbarSpacer` into the leading sidebar section when the `.toolbar` hangs off the split view. The item gets its own `ToolbarGroupBreak()` so it takes a Liquid Glass capsule of its own, like the four buttons beside it. | Reconciliation with #216 |
| 23 | Toolbar dropdown shape: text label or icon? | Text. `Text("Open in")`, no icon, no `.help()` tooltip and no `.menuIndicator(.hidden)` — the HIG grants hover tooltips to icon-only buttons, and a text pull-down that draws no chevron reads as a plain button that unexpectedly opens a menu. Run stays exactly as #216 shipped it, icon-only; `RunCommandMenu` is not touched. The reason the two differ: `play` is self-explanatory, `arrow.up.forward.app` is not — it is the glyph the operator rejected in `189c50b` because it does not name this action the way `square.and.arrow.up` names Share. So the row mixes one text item with icon items, which the operator accepts knowingly; consistency inside the row loses to the label being readable at all. This reverses the alignment the rebase agent made toward #216's icon shape. | Operator |
| 24 | Does the list move to a `~/.clearway` JSON file, as #216's saved commands did? | No. `SavedCommandStore` owns a file because saved commands are a first-class, reorderable, process-wide list with its own sidebar destination. The Open In list is a preference edited only in Settings, and `SettingsManager`'s `UserDefaults` JSON blob is the shape `WorktreeGroupStore` and every other preference already use. Decision 8 stands. | Reconciliation with #216 |

## Assumptions

Each verified against the codebase at base `d94b0b0`. Empirical probing was not needed; nothing was
written to the repo outside this spec.

1. **`SettingsManager` is injected into every view that needs it.** `ClearwayApp.clearwayChrome`
   applies `environmentObject(settings)` (`Sources/App/ClearwayApp.swift:236-243`) to the
   `ProjectWindow` scene (`:158-163`), which hosts both `ContentView` and, through it, `SidebarView`
   (`ContentView.swift:182`). `ContentView` already reads it at `:60`.
2. **The toolbar's existing gate is `selectedWorktree != nil`**, and `selectedWorktree` is
   `detailSelection?.worktree` (`ContentView.swift:97, 198`), which includes the main worktree. The
   freshest `Worktree` for that selection is `currentWorktree` (`:456-459`); its `path` is optional.
3. **The sidebar context menu already reads `wt.path` optionally** for Reveal in Finder and Copy
   Path (`SidebarView.swift:343-355`), so gating a new item on a non-nil path matches what is there.
4. **`shellEscape` is single-quote wrapping** and is the project's escape for programmatically built
   shell commands (`Sources/App/TerminalTab.swift:3-7`); `Ghostty.Shell.escape` is for injecting at a
   live terminal's cursor and is not what this needs.
5. **`ShellEnvironment.processEnvironment` returns the login-shell PATH unioned with a baseline of
   `/usr/bin:/bin:/usr/sbin:/sbin`** (`ShellEnvironment.swift:23-27`, `ShellPathValidation.swift:13`),
   and reading it starts no resolution, so a spawn cannot trigger a profile script's approval prompt.
6. **`Process` + pipes is the established subprocess shape**, including the "read the pipes before
   `waitUntilExit`" deadlock note (`Sources/App/Worktree.swift:323-368`). `runCommand` itself is not
   reusable here: it waits unconditionally for exit, which an editor that stays in the foreground
   never does.
7. **UserDefaults JSON blobs are an established persistence shape** — `WorktreeGroupStore` encodes
   `WorktreeGroupsPayload` the same way (`WorktreeGroupStore.swift:64-78`).
8. **`SettingsManagerTests` builds a `SettingsManager` over a per-test `UserDefaults` suite**
   (`Tests/SettingsManagerTests.swift:12-23`), so list-editing and seeding rules are testable without
   touching the real domain.
9. **New Swift files are invisible to the build until `xcodegen generate` runs**; `project.yml`
   collects sources by directory (`project.yml:25-26` for `Sources`, `:303-304` for `Tests`), so no
   `project.yml` edit is needed and `./scripts/ci.sh` covers the regeneration.
10. **`ContentView.swift` is 987 lines with `file_length` and `type_body_length` already suppressed**
    at `:1` and `:54`; the SwiftLint thresholds are warning 700 / error 1000 (`.swiftlint.yml`). The
    toolbar change must stay a few lines, which is why the menu and the settings section are new
    files rather than additions there.
11. **The deployment target is macOS 13** (`project.yml:4-6`), so the two-parameter
    `onChange(of:perform:)` form used throughout (`SidebarSheets.swift:22`) is the one to use.

## Objective

A user configures the editors they actually have once, in Settings, and afterwards opens any
worktree — including main — in any of them from the toolbar or from a right-click in the sidebar,
without a terminal tab.

### Success criteria

1. Fresh install: Settings → Open In Apps lists Finder alone. With a worktree selected the toolbar
   shows the "Open in" menu with one Finder item, and choosing it opens that worktree's folder.
2. Adding Cursor and choosing Open in → Cursor runs `cursor '<worktree path>'` and the worktree opens
   in Cursor.
3. Editing Cursor's command uses the edited command on the next launch; its label stays "Cursor" and
   offers no editable field.
4. A built-in already in the list does not appear among the add choices.
5. A custom entry with label "Xcode" and command `xed` shows "Xcode" in the menu and runs
   `xed '<path>'`; both fields stay editable afterwards, and Save is refused while either is blank.
6. Removing every entry hides both the toolbar item and the sidebar submenu; adding one back shows
   them again with no relaunch.
7. Right-clicking main in the sidebar while a different worktree is selected → Open in → Zed opens
   **main's** path, not the selection's.
8. A command that is not on PATH produces an alert containing the app's label and the shell's error
   text.
9. The list survives an app relaunch, including the empty list.
10. `./scripts/ci.sh` is green, and the command building, the seeding/edit rules and the draft
    validation are covered by unit tests that construct no views.

## Verification

```bash
./scripts/ci.sh
```

The project's only runner of the test suite; it also runs `xcodegen generate`, without which the new
Swift files are invisible to the build. It is both the per-step regression check and the sign-off
gate here.

Manual checks against the running app (`./scripts/run.sh`) cover criteria 1-9, which reach AppKit
menus, a real subprocess and a modal alert.

## Files this change touches

### New

| File | What it holds |
| --- | --- |
| `Sources/App/OpenInApp.swift` | `OpenInBuiltIn` (label + default command per built-in), `OpenInApp` (`id`, `kind`, `command`, computed `label`), `OpenInApp.Kind`, the draft-validation rule shared by add and edit, and `availableBuiltIns(excluding:)`. All pure. |
| `Sources/App/OpenInAppLauncher.swift` | `buildOpenInScript(command:path:resolvedPath:)` (pure, returns the `/bin/sh -c` script) and the `nonisolated` async `launch` that spawns it, drains stderr and reports a failure within the 2-second window. |
| `Sources/App/OpenInMenu.swift` | The shared `Menu` view: the items in list order, the launch call, and the `NSAlert` on failure. Generic over its label. |
| `Sources/App/OpenInAppsSettingsSection.swift` | The Settings section: the rows, the add menu, the remove control, and the editor sheet used for add-custom and edit. |
| `Tests/OpenInAppTests.swift` | Command/script building, built-in defaults, `availableBuiltIns` exclusion, draft validation. |
| `Tests/OpenInAppsSettingsTests.swift` | Seeding on absent key, empty-list round-trip, add/remove/edit persistence across `SettingsManager` instances, order preservation. |

### Changed

| File | Change |
| --- | --- |
| `Sources/App/SettingsManager.swift` | `SettingsKey.openInApps`; `@Published var openInApps: [OpenInApp]` with a persisting `didSet`; seeding in `init`. |
| `Sources/App/SettingsView.swift` | Adds the Open In Apps section; frame height 420 → 560. |
| `Sources/App/ContentView.swift` | One `ToolbarItem` inside the existing `selectedWorktree != nil` block, gated additionally on a non-empty list and a non-nil `currentWorktree?.path`. |
| `Sources/App/SidebarView.swift` | `@EnvironmentObject settings`; an `OpenInMenu` submenu in `worktreeContextMenu` above Reveal in Finder, gated on a non-empty list and a non-nil `wt.path`. |
| `CLAUDE.md` | A short note under Architecture describing the new files and the raw-command / escaped-path contract. |

## Out of scope

- Detecting installed apps, or checking that a CLI exists before offering it.
- Drag-to-reorder in the settings list.
- Per-project app lists, and opening a specific file rather than the worktree root.
- Keyboard shortcuts for the menu items, and therefore any `AppKeyboardShortcuts` change.
- Changing or removing the existing Reveal in Finder / Copy Path context-menu items.
- Surfacing anything the launched command prints on success.

## Known risks

- PATH resolution is what makes `code` / `cursor` / `zed` findable. If a user's shell config never
  exports them, the failure alert is the only feedback — by design, since Clearway detects nothing.
- The command text is interpreted by the shell as typed, so a user who writes shell operators into it
  gets exactly what they wrote. Only the appended path is escaped. This matches the existing worktree
  hooks contract.
