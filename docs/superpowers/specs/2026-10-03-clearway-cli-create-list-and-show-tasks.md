# Clearway CLI: create, list and show tasks

**Date:** 2026-10-03
**Base:** 32bfb80 (Remove all use of the task status, #264)

`Clearway.app` gains a second executable, `Contents/MacOS/cway`, with three commands:
`task create`, `task list` and `task show`. An agent uses it to file a backlog task, or to read
tasks, without knowing that a task is a markdown file with YAML frontmatter under
`.clearway/tasks/<UUID>.md` or a worktree's `.clearway/TASK.md`. The CLI and the app compile the
same Swift files for the task format, the file layout and the `git worktree list` parser, so there
is one definition of each. The CLI works on files only; the running app sees a new task through its
existing directory watcher. Three supporting changes ship with it: the app keeps its backlog
watcher armed even when `.clearway/tasks` did not exist at launch, the build scripts stop
overriding `PRODUCT_NAME` for every target (which breaks the build once a second target exists),
and the release signing settings cover the new executable.

## Decisions

| # | Question | Decision | Why |
| --- | --- | --- | --- |
| D1 | Where does the executable live in the bundle, and what is it called? | `Clearway.app/Contents/MacOS/cway`, beside the app executable, in Debug and Release bundles (D20). | Apple's "Placing content in a bundle" table lists "help app, helper tool" at `Contents/MacOS/` or `Contents/Helpers/` (fetched 2026-10-03, `developer.apple.com/tutorials/data/documentation/bundleresources/placing-content-in-a-bundle.json`). Originally `Contents/Helpers/clearway`, because `clearway` and the app executable `Clearway` are the same path on the default case-insensitive APFS volume; the rename to `cway` (D20) removes that collision, and `Contents/MacOS` is the directory Ghostty's shell integration already puts on `PATH`. |
| D2 | How is it built? | A new xcodegen target `ClearwayCLI`, `type: tool`, `PRODUCT_NAME: cway`, `PRODUCT_MODULE_NAME: ClearwayCLI`, `PRODUCT_BUNDLE_IDENTIFIER: app.getclearway.mac.cli`. The `Clearway` target lists it as a dependency with `embed: true`, `codeSign: true`, `copy: {destination: executables}` (D20). | Scratchpad probe built the original shape (`destination: wrapper, subpath: Contents/Helpers`) with xcodegen 2.45.3 / Xcode 27.0: the tool landed in `Contents/Helpers/`, ran, and `codesign --verify --deep --strict` passed on the app; C2 re-verified the `executables` destination the same way. An explicit module name is required: a tool emits `<module>.swiftmodule` into `BUILT_PRODUCTS_DIR` (seen in the probe), so a module named after the product could collide with `Clearway.swiftmodule`. |
| D3 | How do the app and the CLI share one definition of the format? | A new source directory `Sources/Shared/` compiled into both targets. `Sources/App/WorkTask.swift` and `Sources/App/YAMLHelpers.swift` move there unchanged. A new `TaskFiles` (Foundation only, no actor isolation) holds the layout and I/O now private to `WorkTaskManager`: the tasks directory under a project, the central `<UUID>.md` path, `taskMarkdownPath(inWorktree:)`, the write (directory `0700`, file `0600`, `throws`), the single-file load (`requireFrontmatterID` rule), and the merge-load of the pool (central files by filename UUID, then each worktree `TASK.md`, worktree copy wins, newest first). The merge-load returns each task with the path it was read from. `WorkTaskManager` calls `TaskFiles` for all of these and keeps its watchers, pool and routing. | Brief, Constraints: "no second, hand-maintained writer". Today the layout and merge rule live in `@MainActor WorkTaskManager` (`WorkTaskManager.swift:287-309, 315-348, 418-425`), which the CLI cannot compile (it depends on `FileWatchers`, `ScheduledWork`, `ObservableObject`). Rejected: a framework or static library target, which adds a target, linking and signing for three files. Rejected: listing individual `Sources/App/*.swift` files in the CLI target, which hides the boundary in `project.yml`. |
| D4 | How does the CLI find the main worktree and the other worktrees? | It runs `git worktree list --porcelain` in the current directory. The first entry is the main worktree, as the app already assumes (`Worktree.swift:272`, `isMain = index == 0`). The backlog is `<main>/.clearway/tasks`. The `TASK.md` candidates are every listed worktree path. | Brief, criterion 1: "the same place the pasted prompt resolves with `git worktree list`". |
| D5 | Is the porcelain parser shared or rewritten? | Shared. `HeadStatus`, the `Worktree` struct (`Worktree.swift:6-56`) and `parseWorktreeListOutput` (`:249-280`) move to `Sources/Shared/`, the parser as `Worktree.parseList(_:)`. Its one app call site (`Worktree.swift:358`) and the test call sites in `Tests/WorktreeTests.swift` are updated. | Same "one definition" rule. All three are pure Foundation code. `WorktreeManager` keeps `applyHeadResolution`, `gitdir` and the process plumbing. |
| D6 | Which git does the CLI run? | `/usr/bin/env git`, i.e. `git` from the caller's `PATH`. A launch failure or non-zero exit is an error (D10). | The CLI runs in a shell that already has git; it has no Finder-launched minimal `PATH` problem, which is what `GitResolver` (`GitResolver.swift:19-60`) solves for the app. |
| D7 | What is the command surface? | `cway task create --title <title> [--body <text>]`, where `--body -` reads the body from stdin. `cway task list`. `cway task show <id>`. `cway help` / `--help` prints usage to stdout with exit 0. Arguments are parsed by hand. | Brief, In scope. Reading stdin only on `--body -` keeps a harness that leaves stdin open from hanging. A hand parser for three subcommands beats adding swift-argument-parser, a new dependency. |
| D8 | What does `create` write? | `WorkTask(title: trimmed, body: body)` serialized by the shared `serialized()`, to `<main>/.clearway/tasks/<UUID>.md` via `TaskFiles`. The title is trimmed of whitespace and newlines, like `WorkTaskManager.createTask` (`WorkTaskManager.swift:131`). No `worktree`, `hidden` or `status` line. Missing directories are created. | Criteria 2, 3. `frontmatterLines` writes only `id`, `title`, and `worktree`/`hidden` when set (`WorkTask.swift:28-40`), so a CLI task and an app task are byte-identical in shape. |
| D9 | What is the output format? | JSON on stdout, always, encoded with `JSONEncoder` (`.prettyPrinted`, `.sortedKeys`, `.withoutEscapingSlashes`). `create`: `{"id", "path"}`. `list`: an array of `{"id", "title", "location", "worktree", "path"}`. `show`: the same object plus `"body"`. `location` is `"backlog"` for a central file and `"worktree"` for a `TASK.md`, decided by which file the task was read from. `worktree` is the frontmatter link or JSON `null`, always present. `id` is the uppercase `uuidString`. | Criterion 9: an agent parses it reliably. No `--json` flag: the users are agents, and one format is simpler than two. |
| D10 | Errors and exit codes | Message on stderr as `cway: <message>`, nothing on stdout. Exit 2 for a usage error (unknown command or flag, missing title, empty title after trimming, missing `show` id). Exit 1 for a runtime failure (not in a git repo, git missing, bare main worktree, unknown or malformed id, write failure). Nothing is written on any error. | Criteria 5, 7, 8. |
| D11 | Which tasks does `list` show? | Every task in the merge-loaded pool whose `hidden` is false, newest first. | Criterion 6. |
| D12 | Does `show` find a hidden shadow task? | Yes. `show` looks the id up in the whole pool; hiding is a `list` rule. | Criterion 7 asks for any task "wherever its file lives". An agent holding an id should get it back. |
| D13 | The backlog watcher is never armed when `.clearway/tasks` is missing at app launch. What changes? | `WorkTaskManager.init` creates `tasksDirectory` (intermediate directories, `0700`) before `watchDirectory()`, so the backlog watcher is always armed. | Decided by the operator. Without it, a CLI task created while the app runs in a project with no `.clearway/tasks` does not appear (criterion 2 with criterion 3). `makeWatcher` returns nil when `open(path, O_EVTONLY)` fails (`FileWatchers.swift:25-26`), and only `write` re-arms it (`WorkTaskManager.swift:308`), which the CLI never reaches. The `.clearway` watchers cover only opened worktrees and only when `.clearway` already exists (`WorkTaskManager.swift:433-445`, `ContentView.swift:727-732`). An empty directory is invisible to git, so this adds no `git status` noise. Rejected: watching the project root for `.clearway` to appear, which fires on every root entry change, adds a second watcher and needs a two-level re-arm. Rejected: leaving it as is, which fails criterion 3's "still appears" in a project with no tasks directory. |
| D14 | `build.sh`, `install.sh` and `release.sh` pass `PRODUCT_NAME=… PRODUCT_MODULE_NAME=Clearway` to `xcodebuild`, which applies to every target. What changes? | The `Clearway` target sets `APP_PRODUCT_NAME: Clearway`, `PRODUCT_NAME: $(APP_PRODUCT_NAME)` and `PRODUCT_MODULE_NAME: Clearway`. The three scripts pass `APP_PRODUCT_NAME="…"` instead of `PRODUCT_NAME` and `PRODUCT_MODULE_NAME`. `run.sh` is unchanged (it only computes the name). | Decided by the operator, who explicitly approved changing `release.sh` this way. Scratchpad probe: with a second target, `xcodebuild … PRODUCT_NAME="Probe (wt)" PRODUCT_MODULE_NAME=Probe build` failed with "duplicate output file …/Probe.swiftmodule" because both targets took the module name. With the `APP_PRODUCT_NAME` indirection the same build produced `Probe (wt).app/Contents/Helpers/probe`. Brief, Open risks, second bullet. |
| D15 | How is the executable signed for release? | `ClearwayCLI` mirrors the app's signing settings: Debug `CODE_SIGN_IDENTITY: "-"`; Release `CODE_SIGN_STYLE: Manual`, the same Developer ID identity and `DEVELOPMENT_TEAM`, `ENABLE_HARDENED_RUNTIME: YES`, `OTHER_CODE_SIGN_FLAGS: "--timestamp"` (`project.yml:72-82`). No entitlements file. The embed phase re-signs on copy. `release.sh` and `notarize.sh` need no change: they build, zip and submit the whole `.app`. | Apple, "Resolving common notarization issues" (fetched 2026-10-03): "When code signing items like Mach-O files, disk images, bundles, apps, command line tools, photos, and so on, sign with a Developer ID Application certificate", and "By default, Xcode doesn't include a secure timestamp as part of the app's code signature during the build process". The probe showed the copy re-sign runs `codesign … --preserve-metadata=identifier,entitlements,flags` with the signing flags in effect, so the hardened-runtime flag survives the copy. The tool needs no JIT, so it does not take the app's `allow-unsigned-executable-memory` entitlement. |
| D16 | Where does CLI logic live, and how is it tested? | The command logic (argument parsing, project resolution, running each command, rendering JSON and errors) lives in `Sources/Shared/TaskCommand.swift` as a function from arguments, working directory and stdin to `(stdout, stderr, exitCode)`. `Sources/CLI/main.swift` only wires the real process I/O to it and calls `exit`. The `Clearway` target excludes `CLI/**`. | A tool target cannot be a test host, and `ClearwayTests` already reaches everything in the app module through `@testable import Clearway`. Rejected: a second test bundle compiling the shared files, which duplicates symbols against the host app. The cost is a few kilobytes of unused code in the app binary. |
| D17 | Is a status written or read? | No. | Brief, Constraints; dependency landed in 32bfb80. |
| D18 | One task per `create` call? | Yes. | Brief, Constraints. |
| D19 | Typing `clearway` in one of Clearway's own terminals launched a second app instance. What changes? | **Superseded by D20; implemented in C1 (21c3235) and reverted (94d1d24) by the operator's decision.** Was: put the running bundle's `Contents/Helpers` first on every terminal's `PATH` (`CLIHelperPath`, through the surface environment and `ShellEnvironment.path` / `awaitPath()`), and turn Ghostty's `path` shell-integration feature off with a `shell-integration-features` override loaded after the user's config. | Failed the operator's live check: in a Debug build's terminal `Contents/Helpers` ended up last on `PATH`, after an inherited `/Applications/Clearway.app/Contents/MacOS`, so `clearway` still launched the installed app. The operator chose not to fight `PATH` ordering. |
| D20 | How is the CLI reached from Clearway's own terminals? | Decided by the operator after D19 failed. The CLI is renamed `cway` (`cway task create`, `cway task list`, `cway task show`, `cway help`; errors and usage use the new name) and embedded at `Contents/MacOS/cway`. Ghostty's shell integration appends the bundle's `Contents/MacOS` to `PATH` in every in-app terminal (`GHOSTTY_BIN_DIR`, feature `path`, default on), and that is the only thing that puts `cway` on `PATH`. Clearway has no `PATH` code of its own for it. Accepted limits: bare `clearway` in an in-app terminal still opens the app, as on main; a Debug build launched from an installed Clearway's terminal finds the installed app's `cway` first once a release ships one, because the inherited `PATH` entry precedes the Debug bundle's. | `ghostty/src/termio/Exec.zig:660-698` sets `GHOSTTY_BIN_DIR` to the executable's directory and appends it to `PATH` at spawn unless already present; with the `path` feature on, the shell integration re-appends it after the user's rc files (`ghostty/src/shell-integration/zsh/ghostty-integration:277-279`). With no case collision, `Contents/MacOS` is a supported location (D1). Rejected: D19's `PATH` rewriting, which lost to an inherited entry live. |

## Assumptions

Checked against the tree at `32bfb80`. Two probes were run in the session scratchpad, never in
the repo: a minimal xcodegen project with an app and an embedded `tool` target, built with and
without a global `PRODUCT_NAME` override (D2, D14, D15).

| # | Assumption | Evidence |
| --- | --- | --- |
| A1 | `WorkTask` and `YAML` depend on Foundation only, so they compile in a tool target. | `WorkTask.swift:1` and `YAMLHelpers.swift:1` import only Foundation; neither type is actor-isolated. |
| A2 | The serializer quotes the title, so quotes, colons and backslashes round-trip. | `frontmatterLines` writes `title: \(YAML.quote(title))` (`WorkTask.swift:33`). `YAML.quote` escapes `\`, `"`, newline, CR, tab (`YAMLHelpers.swift:6-14`). `parseFrontmatter` splits on the first colon only (`:96-99`) and unquotes. |
| A3 | The app's backlog is `<projectPath>/.clearway/tasks`, and the merge-load reads every `<UUID>.md` there plus each resolver worktree's `TASK.md` that carries a frontmatter `id`. | `WorkTaskManager.swift:36`, `:315-348`, `:418-425`. |
| A4 | The app detects a new central file through its directory watcher, when armed. | `watchDirectory` (`WorkTaskManager.swift:447-450`) → `makeWatcher` → `scheduleReload` (`:455-470`), default mask includes `.write` (`FileWatchers.swift:9-10`). |
| A5 | That watcher is nil when the directory is missing at init, and only `write` re-arms it. | `FileWatchers.swift:25-26`; `WorkTaskManager.swift:38, 308`. |
| A6 | The main worktree is the first `git worktree list --porcelain` entry. | `Worktree.swift:272`; `build.sh:13` uses the same rule. |
| A7 | The `Clearway` target globs all of `Sources`, so `Sources/Shared` is picked up automatically and `Sources/CLI` must be excluded. | `project.yml:25-30`. |
| A8 | Three scripts override `PRODUCT_NAME` and `PRODUCT_MODULE_NAME`; `ci.sh` does not. | `build.sh:23,26`, `install.sh:14,19`, `release.sh:27,33`; `ci.sh:17-24`. |
| A9 | `release.sh` and `notarize.sh` act on the whole `.app`, not a list of binaries. | `release.sh:31-55` (build, `xattr -cr`, `ditto` the `.app`); `notarize.sh:47-96` (submit the zip, staple and `spctl` the `.app`). |
| A10 | Tests can build real git repos and worktrees with isolated git config. | `GitRepoFixture` (`Tests/TestHelpers.swift:103-141`). |
| A11 | Tests run inside the host app, so `Bundle.main` is the built `Clearway.app`. | `TEST_HOST = $(BUILT_PRODUCTS_DIR)/Clearway.app/Contents/MacOS/Clearway` (`Clearway.xcodeproj/project.pbxproj:1271`). |
| A12 | A developer ID signing identity is present on this machine. | `security find-identity -v -p codesigning` lists one "Developer ID Application" identity. Notarization credentials are not checked here. |
| A13 | The app's project path is the main worktree root. | Not enforced: `ProjectListManager.addProject` stores the picked path as-is (`ProjectListManager.swift:49-77`). The CLI follows the brief (main worktree from git). A project added at a linked worktree or a subdirectory would keep its own backlog that the CLI does not write to. Out of scope. |

## Objective and success criteria

An agent in any worktree of a project runs `cway task create --title "…"` and gets back the
new task's id and path as JSON. The task appears in the app's Tasks list without a relaunch,
shaped exactly like one the app created. `cway task list` and `cway task show <id>` return
the same tasks the app holds.

1. From the main worktree and from a linked worktree, `task create` writes
   `<main>/.clearway/tasks/<UUID>.md`.
2. The written file equals `WorkTask(id:title:body:).serialized()` for the same values, and the
   app's `WorkTaskManager` loads it with that title and body.
3. `task create` works with `.clearway/tasks` (and `.clearway`) absent. With the app running and
   the directory absent at its launch, the new task still appears (D13).
4. A title with `"`, `:`, `\`, `#`, a leading `-` or `'` reads back identical through the app's
   parser.
5. A missing, empty or whitespace-only title writes nothing, prints a message on stderr and
   exits 2.
6. `task list` returns backlog tasks and worktree `TASK.md` tasks with the right `location`, and
   omits `hidden: true` tasks.
7. `task show <id>` returns a backlog task and a worktree task by id (case-insensitive); an
   unknown or malformed id exits 1 with a message.
8. Every command run outside a git repository writes nothing, prints a message on stderr and
   exits 1.
9. stdout is valid JSON for every successful command and empty for every failure.
10. The built `Clearway.app` contains an executable `Contents/MacOS/cway` in Debug, and
    `./scripts/ci.sh` passes.
11. `./scripts/build.sh` in a linked worktree produces `Clearway (<worktree>).app` with the
    helper inside, and the build does not fail on duplicate outputs.
12. A Release build signs `Contents/MacOS/cway` with the Developer ID identity, the
    hardened runtime flag and a secure timestamp, and notarization of the release accepts it.

## Commands

From the project's `## Pipeline` section:

| Step | Command |
| --- | --- |
| Regression check (every build task, simplify) | `./scripts/ci.sh` |
| Full gate (sign-off, once) | `./scripts/ci.sh` |

Criterion 11 is checked once with `./scripts/build.sh` from this worktree, then
`ls "<BUILT_PRODUCTS_DIR>/Clearway (clearway-cli-create-list-and-show-tasks).app/Contents/MacOS/cway"`.
Resolve `BUILT_PRODUCTS_DIR` the way `run.sh` does.

Criterion 12, first half, is checked by the operator or a build agent with a Release build and
`codesign -dvvv <app>/Contents/MacOS/cway` (expect `Authority=Developer ID Application`,
`Timestamp=`, `flags=0x10000(runtime)`) plus `codesign --verify --deep --strict <app>`. The
notarization half needs App Store Connect credentials and is the operator's, at the next
`release.sh` + `notarize.sh`.

## Files touched

Moved, contents unchanged except as noted:
- `Sources/App/WorkTask.swift` → `Sources/Shared/WorkTask.swift`
- `Sources/App/YAMLHelpers.swift` → `Sources/Shared/YAMLHelpers.swift`
- `HeadStatus`, `Worktree` and the porcelain parser out of `Sources/App/Worktree.swift` into
  `Sources/Shared/` (D5).

New:
- `Sources/Shared/TaskFiles.swift` (D3).
- `Sources/Shared/TaskCommand.swift` (D7-D12, D16).
- `Sources/CLI/main.swift` (D16).

Changed:
- `Sources/App/WorkTaskManager.swift`: delegate layout, write, load and merge-load to
  `TaskFiles`; create `tasksDirectory` in `init` (D13).
- `Sources/App/Worktree.swift`: call the shared parser (D5).
- `project.yml`: `ClearwayCLI` target, embed dependency, `CLI/**` exclude, `APP_PRODUCT_NAME`
  indirection (D2, D14, D15).
- `scripts/build.sh`, `scripts/install.sh`, `scripts/release.sh`: `APP_PRODUCT_NAME` (D14).
- `Clearway.xcodeproj/project.pbxproj`: regenerated by `xcodegen generate`.
- `CLAUDE.md` (root): the `build.sh` note and the "Verifying a change" sentence about the
  `PRODUCT_NAME` override; a line under Architecture for `Sources/Shared/` and `Sources/CLI/`.
- `Sources/App/CLAUDE.md`: per-file notes for the moved and new files, where it already has
  notes for them.

Tests:
- `Tests/WorktreeTests.swift`: call sites of the moved parser.
- New `Tests/TaskCommandTests.swift` and `Tests/TaskFilesTests.swift`.
- `Tests/WorkTaskManagerWatcherTests.swift`: the D13 case.

## Testing

XCTest, through `./scripts/ci.sh`. Command tests drive `TaskCommand` with a `GitRepoFixture`
repo as the working directory.

- T1 `create` from the main worktree and from a linked worktree writes into
  `<main>/.clearway/tasks`, the JSON `path` matches, and the file equals the shared
  serialization (crit. 1, 2).
- T2 `create` in a repo with no `.clearway` creates it; the file mode is `0600` (crit. 3).
- T3 Round-trip of the title set in criterion 4 through `create`, then `WorkTask.parse` and a
  `WorkTaskManager` reload (crit. 2, 4).
- T4 Missing `--title`, `--title ""`, `--title "   "`: exit 2, empty stdout, no file
  (crit. 5).
- T5 `list` over a backlog task, a worktree `TASK.md` task and a hidden shadow `TASK.md`:
  two entries with the right `location` and `worktree` (crit. 6).
- T6 `show` of a backlog id, a worktree id, a lowercase id; unknown and malformed ids exit 1
  (crit. 7).
- T7 Each command with a non-repo temp directory as cwd: exit 1, nothing written (crit. 8).
- T8 Every success output decodes with `JSONSerialization` (crit. 9).
- T9 `--body -` reads stdin; `--body` text lands as the body.
- T10 `TaskFiles` merge-load: worktree copy wins over a central file with the same id, a
  `TASK.md` without an `id` is skipped, newest first. Existing `WorkTaskManager` tests keep
  passing unchanged, which pins that the refactor kept behavior.
- T11 `WorkTaskManagerWatcherTests`: a manager initialized on a project with no `.clearway`
  picks up a `<UUID>.md` written afterwards by `TaskFiles` without any app-side write
  (crit. 3, D13).
- T12 End to end: `Bundle.main.bundleURL/Contents/MacOS/cway` exists and is executable;
  running `task create` then `task show` through it in a fixture repo returns the task
  (crit. 10).
- Criterion 2's "appears in the Tasks list without a relaunch" in the live UI is the operator's
  by hand; build agents do not launch the app (memory).

## Boundaries

- Always: run `./scripts/ci.sh` after the last edit; keep `swiftlint lint` at zero new warnings;
  one implementation of the task format, layout and porcelain parse.
- Ask first: adding a package dependency; changing `release.sh` or `notarize.sh` beyond D14;
  any channel from the CLI into the running app.
- Never: launch the app or take screenshots from a build agent; run `release.sh` (it bumps the
  build number); write a `status:` line.

## Out of scope

- The Clearway skill, the Settings install, and any symlink or `PATH` entry outside the bundle
  (next task, `025C4523-53A2-42C2-8A17-1F9679F3B610`).
- Starting or planning a task from the CLI; editing or deleting tasks.
- Any task status or lifecycle.
- Scanning external sources such as Linear.
- Canonicalizing a project path that is not the main worktree root (A13).
- A human-readable output mode.
