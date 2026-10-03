# Plan: Clearway CLI: create, list and show tasks

Breaks down `docs/superpowers/specs/2026-10-03-clearway-cli-create-list-and-show-tasks.md`.

**Date:** 2026-10-03
**Base:** 32bfb80 (Remove all use of the task status, #264)

## Architecture decisions carried from the spec

- The executable is `Clearway.app/Contents/Helpers/clearway`, never `Contents/MacOS/` (D1).
- New xcodegen target `ClearwayCLI`: `type: tool`, `PRODUCT_NAME: clearway`,
  `PRODUCT_MODULE_NAME: ClearwayCLI`, `PRODUCT_BUNDLE_IDENTIFIER: app.getclearway.mac.cli`. The
  `Clearway` target depends on it with `embed: true`, `codeSign: true`,
  `copy: {destination: wrapper, subpath: Contents/Helpers}` (D2).
- `Sources/Shared/` is compiled into both targets. `WorkTask.swift` and `YAMLHelpers.swift` move
  there unchanged. A new `TaskFiles` (Foundation only, no actor isolation) owns the tasks-directory
  path, the central `<UUID>.md` path, `taskMarkdownPath(inWorktree:)`, the write (directory `0700`,
  file `0600`, `throws`), the single-file load (with the `requireFrontmatterID` rule) and the
  merge-load (central by filename UUID, then each worktree `TASK.md`, worktree copy wins, newest
  first, each task returned with the path it was read from). `WorkTaskManager` keeps watchers,
  pool and routing and calls `TaskFiles` for all of the above (D3).
- The CLI runs `git worktree list --porcelain` in its working directory. First entry is the main
  worktree; the backlog is `<main>/.clearway/tasks`; every listed worktree path is a `TASK.md`
  candidate (D4).
- `HeadStatus`, the `Worktree` struct and the porcelain parser move to `Sources/Shared/`; the
  parser becomes `Worktree.parseList(_:)`. `WorktreeManager` keeps `applyHeadResolution`, `gitdir`
  and process plumbing (D5).
- The CLI runs git as `/usr/bin/env git`. Launch failure or non-zero exit is a runtime error (D6).
- Commands: `clearway task create --title <title> [--body <text>]` (`--body -` reads stdin, and
  stdin is read only then), `clearway task list`, `clearway task show <id>`, `clearway help` /
  `--help` (usage on stdout, exit 0). Hand-written argument parsing, no new package (D7).
- `create` writes `WorkTask(title: trimmed, body: body).serialized()` to
  `<main>/.clearway/tasks/<UUID>.md` through `TaskFiles`, creating missing directories. Title is
  trimmed of whitespace and newlines. No `worktree`, `hidden` or `status` line (D8).
- Output is always JSON on stdout via `JSONEncoder` with `.prettyPrinted`, `.sortedKeys`,
  `.withoutEscapingSlashes`. `create` → `{"id","path"}`; `list` → array of
  `{"id","title","location","worktree","path"}`; `show` → that object plus `"body"`. `location` is
  `"backlog"` or `"worktree"` by which file the task was read from. `worktree` is always present,
  JSON `null` when unset. `id` is the uppercase `uuidString` (D9).
- Errors: `clearway: <message>` on stderr, empty stdout, nothing written. Exit 2 for usage errors
  (unknown command or flag, missing title, empty title after trimming, missing `show` id). Exit 1
  for runtime failures (not a git repo, git missing, bare main worktree, unknown or malformed id,
  write failure) (D10).
- `list` returns every non-hidden task in the merge-loaded pool, newest first (D11). `show` looks
  the id up in the whole pool, hidden included, case-insensitively (D12).
- `WorkTaskManager.init` creates `tasksDirectory` (intermediate directories, `0700`) before
  `watchDirectory()` (D13).
- The `Clearway` target sets `APP_PRODUCT_NAME: Clearway`, `PRODUCT_NAME: $(APP_PRODUCT_NAME)`,
  `PRODUCT_MODULE_NAME: Clearway`. `build.sh`, `install.sh`, `release.sh` pass
  `APP_PRODUCT_NAME="…"` instead of `PRODUCT_NAME` and `PRODUCT_MODULE_NAME`. `run.sh` unchanged
  (D14).
- `ClearwayCLI` signing mirrors the app: Debug `CODE_SIGN_IDENTITY: "-"`; Release
  `CODE_SIGN_STYLE: Manual`, `CODE_SIGN_IDENTITY: "Developer ID Application: Bruno Valentino
  (76AEQBHY3K)"`, `DEVELOPMENT_TEAM: 76AEQBHY3K`, `ENABLE_HARDENED_RUNTIME: YES`,
  `OTHER_CODE_SIGN_FLAGS: "--timestamp"`. No entitlements. `release.sh`/`notarize.sh` otherwise
  untouched (D15).
- Command logic lives in `Sources/Shared/TaskCommand.swift` as a pure function from arguments,
  working directory and stdin to stdout, stderr and exit code. `Sources/CLI/main.swift` only wires
  process I/O and calls `exit`. The `Clearway` target excludes `CLI/**`. Tests reach
  `TaskCommand` through `@testable import Clearway` (D16).
- No status is written or read (D17). One task per `create` (D18).

## Choices made in this plan

These fill in names and signatures the spec leaves open. None changes behavior.

- The moved worktree model goes to `Sources/Shared/WorktreeModel.swift`, not
  `Sources/Shared/Worktree.swift`: Xcode refuses two files with the same basename in one target,
  and `Sources/App/Worktree.swift` stays.
- `TaskFiles` is a caseless `enum` with static members:
  - `tasksDirectory(inProject projectPath: String) -> String` (`<project>/.clearway/tasks`)
  - `centralPath(for id: UUID, tasksDirectory: String) -> String`
  - `taskMarkdownPath(inWorktree worktreePath: String) -> String`
  - `write(_ task: WorkTask, toPath path: String) throws` — creates the parent directory with
    `0700`, then `FileManager.createFile(atPath:contents:attributes: [.posixPermissions: 0o600])`,
    throwing when serialization to UTF-8 or `createFile` fails. Same on-disk effect as today's
    `WorkTaskManager.write`.
  - `load(atPath:fallbackId:requireFrontmatterID: Bool = false) -> WorkTask?` — today's
    `WorkTaskManager.loadTask`, body unchanged.
  - `struct LoadedTask: Equatable { let task: WorkTask; let path: String }`
  - `loadPool(tasksDirectory: String, worktreePaths: [String]) -> [LoadedTask]` — today's
    `reload()` merge, sorted by `createdAt` descending.
- `TaskCommand` is a caseless `enum` with
  `static func run(arguments: [String], workingDirectory: String, readStdin: () -> Data) -> Result`
  and `struct Result: Equatable { let stdout: String; let stderr: String; let exitCode: Int32 }`.
  `arguments` excludes `argv[0]`. `readStdin` is a closure so it is only called for `--body -`.
- `location` is `"backlog"` when the loaded path's parent directory is the tasks directory, else
  `"worktree"`.
- A bare main worktree (D10) is detected by a line equal to `bare` in the first porcelain block,
  checked in `TaskCommand` before parsing. The shared `Worktree` struct is not widened for it.
- Malformed `show` id (not a UUID) and unknown id are both exit 1 with distinct messages.

## Sequencing

Two risks come first because everything else sits on them: the shared-source split (T1, T2) and
the build-system changes (T4, T5). T4 lands before T5 because adding a second target while
`build.sh` still overrides `PRODUCT_NAME` breaks `build.sh` (spec, D14 probe). The CLI then grows
command by command (T6, T7) on a binary that already builds, embeds and runs. Every task leaves
`./scripts/ci.sh` passing.

## Dependency graph

```
T1 (shared model move) ── T2 (TaskFiles) ──┬── T3 (D13 watcher)
                                           │
T4 (APP_PRODUCT_NAME) ── T5 (CLI target) ──┴── T6 (create) ── T7 (list, show, e2e) ── T8 (docs)
```

T1 and T4 have no prerequisites. T2 needs T1. T3 needs T2. T5 needs T1 and T4 (the CLI target
compiles `Sources/Shared`). T6 needs T2 and T5. T7 needs T6. T8 needs T3 and T7. Run in numeric
order unless parallelizing; T4 may run alongside T1–T3, but T2/T3 and T6/T7 all touch shared files
and must stay sequential.

## Tasks

Every task's last acceptance criterion is that `./scripts/ci.sh` exits 0 after the task's final
edit, with `swiftlint lint` at zero new warnings. Use `git mv` for moves so history follows. Build
agents never launch the app, never take screenshots, and never run `release.sh`. Resolve
`BUILT_PRODUCTS_DIR` the way `run.sh` does (`xcodebuild … -showBuildSettings`), never a hardcoded
DerivedData path. Do not add comments beyond what the moved code already carries.

### T1: Move the task format and worktree parser into Sources/Shared

**Files:** `Sources/App/WorkTask.swift` → `Sources/Shared/WorkTask.swift`,
`Sources/App/YAMLHelpers.swift` → `Sources/Shared/YAMLHelpers.swift`,
`Sources/App/Worktree.swift`, new `Sources/Shared/WorktreeModel.swift`, `Tests/WorktreeTests.swift`

**What:** `git mv` the two files unchanged. Cut `HeadStatus` and `struct Worktree`
(`Worktree.swift:6-56`) into `Sources/Shared/WorktreeModel.swift`, with `import Foundation` only.
Move `WorktreeManager.parseWorktreeListOutput` (`Worktree.swift:248-280`) into that file as
`extension Worktree { static func parseList(_ output: String) -> [Worktree] }`, body unchanged.
Update the call in `fetchWorktrees` (`Worktree.swift:358`) and the eight test call sites in
`WorktreeTests.swift` to `Worktree.parseList(_:)`. No `project.yml` change: the `Clearway` target
already globs `Sources` (A7). `Sources/App/Worktree.swift` keeps `import GhosttyKit` only if it
still needs it.

**Acceptance criteria:**
- No file under `Sources/Shared` imports anything but Foundation or has actor isolation.
- `grep -rn parseWorktreeListOutput Sources Tests` returns nothing.
- Existing `WorktreeTests` pass unchanged apart from the call-site rename.
- `./scripts/ci.sh` exits 0.

**Verify:** the two greps (`grep -rn "^import" Sources/Shared`; the one above);
`./scripts/ci.sh`.

### T2: Extract TaskFiles and route WorkTaskManager through it

**Files:** new `Sources/Shared/TaskFiles.swift`, `Sources/App/WorkTaskManager.swift`,
`Sources/App/WorkTaskCoordinator.swift`, new `Tests/TaskFilesTests.swift`

**What:** Create `TaskFiles` with the members listed under "Choices made in this plan". Move the
bodies from `WorkTaskManager`: `taskMarkdownPath(inWorktree:)` (`:295-298`), the write
(`:301-308`, minus the watcher re-arm), `loadTask` (`:418-425`) and the merge in `reload()`
(`:315-337`). In `WorkTaskManager`:
- `init` sets `tasksDirectory = TaskFiles.tasksDirectory(inProject: projectPath)`.
- `filePath(for:)` and every `"\(id.uuidString).md"` join (`:69`, `:183`, `:292`) use
  `TaskFiles.centralPath(for:tasksDirectory:)`.
- `write(_:)` becomes `try? TaskFiles.write(task, toPath: filePath(for: task))` followed by the
  existing `if watcherSource == nil { watchDirectory() }`.
- `reload()` sets the pool from
  `TaskFiles.loadPool(tasksDirectory:worktreePaths: worktreeResolver().map(\.path)).map(\.task)`
  and keeps its change check and `syncTaskFileWatchers()`.
- `freshTask` and `desiredTaskFileWatcherPaths` call `TaskFiles.load` / `TaskFiles.taskMarkdownPath`.
- Delete `WorkTaskManager.taskMarkdownPath` and `loadTask`; point
  `WorkTaskCoordinator.swift:144` at `TaskFiles.taskMarkdownPath(inWorktree:)`.

Add `TaskFilesTests` (spec T10), using `TempRootTestCase` and plain directories, no git:
worktree copy wins over a central file with the same id and its `path` is the `TASK.md`; a
`TASK.md` without a frontmatter `id` is skipped; results are newest first (set creation dates with
`FileManager.setAttributes([.creationDate: …])`); a legacy central file without `id` loads under
its filename UUID; `write` creates the directory `0700` and the file `0600`.

**Acceptance criteria:**
- `WorkTaskManager` contains no path join for `.clearway`, `TASK.md` or `<UUID>.md`, and no
  frontmatter parsing call; `grep -n "TASK.md\|\.clearway/tasks\|uuidString).md" Sources/App/WorkTaskManager.swift`
  returns nothing.
- Every pre-existing `WorkTaskManager*`, `WorkTaskCoordinator*` and `WorkTaskRelocationSafety*`
  test passes without edits (pins unchanged behavior).
- The new `TaskFilesTests` pass.
- `./scripts/ci.sh` exits 0.

**Verify:** the grep above; `./scripts/ci.sh`; `git diff --stat Tests/` shows only the new file.

### T3: Arm the backlog watcher when .clearway/tasks is missing at launch

**Files:** `Sources/App/WorkTaskManager.swift`, `Tests/WorkTaskManagerWatcherTests.swift`

**What:** In `WorkTaskManager.init`, before `watchDirectory()`, create `tasksDirectory` with
`withIntermediateDirectories: true` and `[.posixPermissions: 0o700]` (`try?`; failure leaves
today's behavior). Update the `makeWatcher` doc comment that says the watcher is nil until `write`
re-arms it, since that is no longer the normal case. Add the spec T11 test: a manager initialized
on an empty temp project (no `.clearway`), then a task written with
`TaskFiles.write(_:toPath: TaskFiles.centralPath(...))` and no manager call, appears in
`manager.tasks` within the existing `waitUntil` timeout. Assert also that `.clearway/tasks`
exists with mode `0700` right after `init`.

**Acceptance criteria:**
- The new test fails on the T2 tree (watch it fail before the `init` edit) and passes after.
- Existing watcher tests pass.
- `./scripts/ci.sh` exits 0.

**Verify:** run `./scripts/ci.sh` once with only the test added (expect the new test to fail),
then after the `init` change (expect exit 0). Record the failing output in the build log.

### T4: Stop overriding PRODUCT_NAME for every target

**Files:** `project.yml`, `scripts/build.sh`, `scripts/install.sh`, `scripts/release.sh`

**What:** In the `Clearway` target's `settings.base`, add `APP_PRODUCT_NAME: Clearway`, change
`PRODUCT_NAME: Clearway` to `PRODUCT_NAME: $(APP_PRODUCT_NAME)`, add
`PRODUCT_MODULE_NAME: Clearway`. In the three scripts, replace every
`PRODUCT_NAME="…" PRODUCT_MODULE_NAME=Clearway` pair on an `xcodebuild` line (`build.sh:23,26`,
`install.sh:14,19`, `release.sh:27,33`) with `APP_PRODUCT_NAME="…"`. The shell variable named
`PRODUCT_NAME` inside each script may stay; only the arguments passed to `xcodebuild` change.
Touch nothing else in `release.sh` (operator approved only this). Do not run `release.sh` or
`install.sh`.

**Acceptance criteria:**
- `./scripts/ci.sh` exits 0 (tests still find `Clearway.app` as `TEST_HOST`).
- `./scripts/build.sh` from this worktree produces
  `<BUILT_PRODUCTS_DIR>/Clearway (clearway-cli-create-list-and-show-tasks).app` whose
  `Contents/MacOS/` executable matches `CFBundleExecutable`.
- `grep -n "PRODUCT_MODULE_NAME\|PRODUCT_NAME=" scripts/*.sh` shows no `xcodebuild` argument
  other than `APP_PRODUCT_NAME=`.

**Verify:** `./scripts/ci.sh`, then `./scripts/build.sh`, then `ls` the bundle and
`/usr/libexec/PlistBuddy -c "Print CFBundleExecutable"` on its `Info.plist`; the grep.

### T5: Add the ClearwayCLI target and embed it in Contents/Helpers

**Files:** `project.yml`, new `Sources/CLI/main.swift`, new `Sources/Shared/TaskCommand.swift`,
new `Tests/TaskCommandTests.swift`, `Clearway.xcodeproj/project.pbxproj` (regenerated)

**What:**
- `project.yml`: add `"CLI/**"` to the `Clearway` target's `Sources` excludes. Add target
  `ClearwayCLI` per D2: `type: tool`, `platform: macOS`, sources `Sources/Shared` and
  `Sources/CLI` (exclude `**/*.md`), settings `PRODUCT_NAME: clearway`,
  `PRODUCT_MODULE_NAME: ClearwayCLI`, `PRODUCT_BUNDLE_IDENTIFIER: app.getclearway.mac.cli`, and
  the D15 Debug/Release signing configs. Add to the `Clearway` target's `dependencies`:
  `- target: ClearwayCLI` with `embed: true`, `codeSign: true`,
  `copy: {destination: wrapper, subpath: Contents/Helpers}`.
- `TaskCommand.swift`: the `TaskCommand` enum and `Result` from "Choices made in this plan", with
  only `help` / `--help` / no arguments → usage on stdout, exit 0 (usage lists all three task
  subcommands as specified in D7), and any other first argument → `clearway: unknown command
  '<arg>'` on stderr, exit 2. `task create|list|show` arrive in T6 and T7; until then `task`
  with any subcommand is the unknown-command error.
- `main.swift`: call `TaskCommand.run(arguments: Array(CommandLine.arguments.dropFirst()),
  workingDirectory: FileManager.default.currentDirectoryPath,
  readStdin: { FileHandle.standardInput.readDataToEndOfFile() })`, write `stdout`/`stderr` to the
  matching handles, `exit(result.exitCode)`.
- `TaskCommandTests`: (a) `help`, `--help` and no arguments exit 0 with non-empty stdout and empty
  stderr; (b) an unknown command exits 2 with empty stdout; (c) the first half of spec T12:
  `Bundle.main.bundleURL/Contents/Helpers/clearway` exists and `isExecutableFile`, and running it
  with `help` via `Process` exits 0.

**Acceptance criteria:**
- `./scripts/ci.sh` exits 0 and the built `Clearway.app/Contents/Helpers/clearway` exists and runs
  (crit. 10).
- `./scripts/build.sh` still produces `Clearway (<worktree>).app` with
  `Contents/Helpers/clearway` inside and no duplicate-output error (crit. 11).
- `codesign --verify --deep --strict` passes on the Debug app.
- `git status --porcelain` shows no `Clearway.swiftmodule`/`clearway` collision artifacts in the
  repo.

**Verify:** `./scripts/ci.sh`; `./scripts/build.sh`; `ls -l` the helper in both bundles;
`codesign --verify --deep --strict <app>`. For crit. 12, attempt one Release build of the app
with `xcodebuild -project Clearway.xcodeproj -scheme Clearway -configuration Release
-destination 'platform=macOS' -derivedDataPath <scratchpad>/release-dd build` and run
`codesign -dvvv <app>/Contents/Helpers/clearway` (expect `Authority=Developer ID Application`,
`Timestamp=`, `flags=0x10000(runtime)`) plus `codesign --verify --deep --strict <app>`. That build
rebuilds the gitignored `Resources/git-dist`; if it cannot finish for a reason unrelated to the CLI
target, record the reason in the build log and leave crit. 12 to the operator. Never `release.sh`.

### T6: clearway task create

**Files:** `Sources/Shared/TaskCommand.swift`, `Tests/TaskCommandTests.swift`

**What:** Implement project resolution and `task create` (D4, D6–D10):
- Run `/usr/bin/env git worktree list --porcelain` with `currentDirectoryURL` set to
  `workingDirectory`, capturing stdout and stderr. Launch failure → exit 1 "git not found";
  non-zero exit → exit 1 "not a git repository" (include git's first stderr line); first block
  with a `bare` line → exit 1; otherwise main = `Worktree.parseList(output).first?.path`, all
  paths = every parsed `path`.
- Parse `task create` flags: `--title <v>` (required), `--body <v>` (optional, `-` means
  `readStdin()` decoded as UTF-8). Unknown flag, a flag without its value, a repeated flag, or a
  stray positional → exit 2. Validate the title (trim `.whitespacesAndNewlines`, empty → exit 2)
  **before** running git, so a usage error never touches the filesystem.
- Write `WorkTask(title: trimmed, body: body)` with
  `TaskFiles.write(_:toPath: TaskFiles.centralPath(for:tasksDirectory: TaskFiles.tasksDirectory(inProject: main)))`.
  Failure → exit 1.
- Encode `{"id": uuidString, "path": <absolute path>}` with the D9 encoder options; append a
  trailing newline to stdout. All errors use the `clearway: <message>` stderr shape with empty
  stdout.

Tests, each with a `GitRepoFixture` under `tempRoot` (spec T1–T4, T7 for create, T8, T9):
- From the main root and from a linked worktree (`addWorktree`), the file lands in
  `<main>/.clearway/tasks/<id>.md`, JSON `path` equals it, and its bytes equal
  `WorkTask(id: id, title:, body:).serialized()` (compare against the serialization of the
  re-parsed task's id).
- No `.clearway` beforehand: created; file mode `0600`.
- Titles `a "quoted" title`, `key: value`, `back\slash`, `# hash`, `-leading dash`,
  `it's` round-trip through `WorkTask.parse` and through a fresh
  `WorkTaskManager(projectPath: fixture.root).tasks`.
- Missing `--title`, `--title ""`, `--title "   "`: exit 2, empty stdout, no `.clearway`.
- `--body text` and `--body -` (with `readStdin` returning bytes) land as the body; a
  `readStdin` that fails the test when called proves it is not read without `--body -`.
- Non-repo `tempRoot` subdirectory as cwd: exit 1, empty stdout, nothing created.
- Every success stdout parses with `JSONSerialization`.

**Acceptance criteria:**
- Criteria 1–5, 8 and 9 of the spec hold for `create`, each proven by a test above.
- `./scripts/ci.sh` exits 0.

**Verify:** `./scripts/ci.sh`; then by hand, from this worktree,
`"<BUILT_PRODUCTS_DIR>/Clearway.app/Contents/Helpers/clearway" task create --title probe` in a
scratchpad `git init` repo prints JSON and writes the file. Delete that scratchpad repo after.

### T7: clearway task list and task show, end to end through the bundle

**Files:** `Sources/Shared/TaskCommand.swift`, `Tests/TaskCommandTests.swift`

**What:** Using T6's project resolution:
- `task list` (no further arguments, else exit 2): `TaskFiles.loadPool(tasksDirectory:
  worktreePaths: <all paths>)`, drop `hidden`, encode an array of
  `{"id","title","location","worktree","path"}` in pool order. `worktree` encodes as `null` when
  unset (use an `Encodable` struct with a custom `encode(to:)` or `encodeNil`, since synthesized
  conformance omits nil optionals).
- `task show <id>` (exactly one argument, else exit 2): `UUID(uuidString:)` fails → exit 1
  "malformed task id"; look up in the full pool including hidden; not found → exit 1 "no task
  <id>"; else the list object plus `"body"`.
- Extend the usage text only if T5's text needs it.

Tests (spec T5, T6, T7 for list/show, T8, T12):
- Backlog task + linked worktree `TASK.md` task (frontmatter `worktree: <branch>`) + a second
  worktree with `hidden: true` `TASK.md`: `list` returns exactly two entries, `location`
  `"backlog"`/`"worktree"`, `worktree` `null`/the branch, correct `path`s, newest first.
- `show` finds the backlog id, the worktree id, the hidden id, and a lowercased id; unknown and
  malformed ids exit 1 with empty stdout; missing id exits 2.
- `list` and `show` with a non-repo cwd exit 1.
- All success stdouts parse with `JSONSerialization`; `list` with no tasks prints `[]`.
- End to end: run `Bundle.main.bundleURL/Contents/Helpers/clearway` via `Process` with a fixture
  repo as `currentDirectoryURL`: `task create --title e2e`, parse the id, then `task show <id>`
  returns the same id and title (crit. 10).

**Acceptance criteria:**
- Criteria 6, 7, 8 and 9 of the spec hold for `list` and `show`, each proven by a test above.
- The end-to-end test passes against the embedded binary.
- `./scripts/ci.sh` exits 0.

**Verify:** `./scripts/ci.sh`.

### T8: Document Sources/Shared, Sources/CLI and the build-name change

**Files:** `CLAUDE.md`, `Sources/App/CLAUDE.md`

**What:** Root `CLAUDE.md`: in "Build & Run", say `build.sh` names the app per worktree through
`APP_PRODUCT_NAME`; in "Verifying a change", replace "`build.sh`'s `PRODUCT_NAME` override breaks
`TEST_HOST`" with the `APP_PRODUCT_NAME` wording (it still renames the app, so it still breaks
`TEST_HOST`), and add that passing `PRODUCT_NAME` to `xcodebuild` now fails with a duplicate
`.swiftmodule` because it reaches the `ClearwayCLI` target. Under Architecture add one line each
for `Sources/Shared/` (format, layout and porcelain parser, compiled into both targets, Foundation
only, no actor isolation) and `Sources/CLI/` (the `clearway` helper's `main.swift`; logic in
`TaskCommand`; embedded at `Contents/Helpers/clearway`). In `Sources/App/CLAUDE.md`, update any
note that names `WorkTask.swift`, `YAMLHelpers.swift`, `WorkTaskManager.taskMarkdownPath`,
`loadTask` or `parseWorktreeListOutput` to the new location or name, and note in the
`WorkTaskManager` notes (if any) that `init` creates `.clearway/tasks` so the backlog watcher is
always armed. Add no new section where none exists.

**Acceptance criteria:**
- `grep -rn "parseWorktreeListOutput\|Sources/App/WorkTask.swift\|Sources/App/YAMLHelpers.swift\|PRODUCT_NAME override" CLAUDE.md Sources/App/CLAUDE.md`
  returns nothing.
- `./scripts/ci.sh` exits 0.

**Verify:** the grep; `./scripts/ci.sh`.

## Checkpoints

- After T3: the app builds and behaves as before, plus D13; all existing task tests unchanged.
- After T5: `Clearway.app/Contents/Helpers/clearway` exists in Debug, `build.sh` works in a
  worktree, signature verifies.
- After T7: spec criteria 1–11 are covered by tests; criterion 12 is the operator's if T5 could
  not complete the Release build. Criterion 2's live "appears without relaunch" is the operator's
  by hand.

## Risks

| Risk | Impact | Mitigation |
| --- | --- | --- |
| Refactor in T2 changes pool behavior subtly (ordering, legacy ids). | High | Existing manager/coordinator tests must pass with no edits; T2 adds direct `TaskFiles` tests. |
| Embed phase does not re-sign with hardened runtime in Release. | Medium | T5 Release `codesign -dvvv` check; operator verifies at next notarization. |
| Test host's `PATH` lacks `git` for the CLI's `/usr/bin/env git`. | Low | `/usr/bin` is always on the default `PATH`; if a test fails on launch, report it rather than changing D6. |
| `xcodegen` `copy.subpath` semantics differ from the spec probe. | Low | T5 verifies the helper path in both Debug bundles. |

## Build log

### T1: Move the task format and worktree parser into Sources/Shared

| File | State |
| --- | --- |
| `Sources/Shared/WorkTask.swift` | `git mv` from `Sources/App/`, unchanged |
| `Sources/Shared/YAMLHelpers.swift` | `git mv` from `Sources/App/`, unchanged |
| `Sources/Shared/WorktreeModel.swift` | new: `HeadStatus`, `struct Worktree` (verbatim), and `extension Worktree { static func parseList(_:) }` holding the old `parseWorktreeListOutput` body verbatim; `import Foundation` only |
| `Sources/App/Worktree.swift` | model and parser removed; `fetchWorktrees` calls `Worktree.parseList`; `import GhosttyKit` dropped (only use was `Ghostty.logger`, a Swift type in the same module) |
| `Tests/WorktreeTests.swift` | eight call sites renamed to `Worktree.parseList(_:)`, nothing else |

Evidence: a pure move, so no new test and no watched failure; the existing `WorktreeTests`
parser cases pin the behavior. `grep -rn parseWorktreeListOutput Sources Tests` returns nothing.
`grep -rn "^import" Sources/Shared` lists only `import Foundation` (three files);
`grep -rn "MainActor\|actor " Sources/Shared` returns nothing.

Deviations: none. `parseList` drops the `nonisolated` modifier, which only meant something on the
`@MainActor` `WorktreeManager`; the struct extension is not isolated.

Gate: `./scripts/ci.sh` exit 0, 885 tests, 0 failures, run after the final edit.

### T2: Extract TaskFiles and route WorkTaskManager through it

| File | State |
| --- | --- |
| `Sources/Shared/TaskFiles.swift` | new caseless `enum`: `LoadedTask`, `tasksDirectory(inProject:)`, `centralPath(for:tasksDirectory:)`, `taskMarkdownPath(inWorktree:)`, `write(_:toPath:) throws`, `load(atPath:fallbackId:requireFrontmatterID:)`, `loadPool(tasksDirectory:worktreePaths:)`; `import Foundation` only, no isolation |
| `Sources/App/WorkTaskManager.swift` | `init`, `moveCentralFileIntoWorktree`, `freshTask`, `filePath(for:)`, `write`, `reload`, `desiredTaskFileWatcherPaths` and `setWatchedWorktrees` call `TaskFiles`; `taskMarkdownPath` and `loadTask` deleted |
| `Sources/App/WorkTaskCoordinator.swift` | `completePendingCreate` calls `TaskFiles.taskMarkdownPath(inWorktree:)` |
| `Tests/TaskFilesTests.swift` | new, five cases: worktree copy wins (and its `path` is the `TASK.md`), `TASK.md` without `id` skipped, newest first across central and worktree files, legacy central file loads under its filename UUID, `write` gives directory `0700` / file `0600` |
| `Clearway.xcodeproj/project.pbxproj` | regenerated by `ci.sh` for the two new files |

Evidence: an extraction, not a bug fix, so there is no unfixed code to watch a test fail against.
Unchanged behavior is pinned by the pre-existing `WorkTaskManager*`, `WorkTaskCoordinator*` and
`WorkTaskRelocationSafety*` suites, which pass unedited (`git diff --stat Tests/` is empty; the
only test change is the new untracked file). The suite grew from 885 to 890 tests, the five new
`TaskFilesTests`.

Deviations:
- `write` no longer has a UTF-8 failure branch: it encodes with `Data(String.utf8)`, which cannot
  fail. It throws the `createDirectory` error, or `CocoaError(.fileWriteUnknown)` naming the path
  when `createFile` returns false.
- `setWatchedWorktrees` joined `.clearway` onto each worktree path by hand; it now derives the
  directory from `TaskFiles.taskMarkdownPath(inWorktree:)` so the manager holds no `.clearway`
  join, per the first acceptance criterion. No new `TaskFiles` member.
- The criterion's grep (`TASK.md\|\.clearway/tasks\|uuidString).md`) still matches doc comments
  that describe the layout (lines 4–5, 24, 30, 46–54, 73, 83, 283, 299, 380). No code line
  matches. The comments were left as they were, since they describe behavior that is unchanged.

Gate: `./scripts/ci.sh` exit 0, 890 tests, 0 failures, run after the final source edit.
`swiftlint lint --quiet` on the four touched Swift files printed nothing.

### T3: Arm the backlog watcher when .clearway/tasks is missing at launch

| File | State |
| --- | --- |
| `Sources/App/WorkTaskManager.swift` | `init` creates `tasksDirectory` (`withIntermediateDirectories: true`, `0700`, `try?`) between `reload()` and `watchDirectory()`; `makeWatcher` doc comment now says `init` creates the tasks directory, so a nil watcher there means the create failed and `write` re-arms it |
| `Tests/WorkTaskManagerWatcherTests.swift` | new `testWatcherSeesBacklogTaskWrittenWhenTasksDirectoryWasMissingAtLaunch`: manager on an empty temp project; asserts `.clearway/tasks` is a directory with mode `0700` right after `init`; writes a task with `TaskFiles.write(_:toPath: TaskFiles.centralPath(...))` and no manager call; asserts it appears in `manager.tasks` within `waitUntil(timeout: 3)` |

Evidence: the test was added first and run against the T2 tree. The first `./scripts/ci.sh` run
(exit 65, 891 tests, 3 failures) stopped the test at a throwing `attributesOfItem` before it
reached the watcher assertion, so the mode read was made non-throwing and the test re-run with
`xcodebuild … test -only-testing:ClearwayTests/WorkTaskManagerWatcherTests` on the unfixed code:

```
WorkTaskManagerWatcherTests.swift:118: error: … XCTAssertTrue failed
WorkTaskManagerWatcherTests.swift:119: error: … XCTAssertTrue failed
WorkTaskManagerWatcherTests.swift:122: error: … XCTAssertEqual failed: ("nil") is not equal to ("Optional(448)")
WorkTaskManagerWatcherTests.swift:130: error: … XCTAssertTrue failed - backlog watcher must be armed even when .clearway/tasks was missing at init
Executed 4 tests, with 4 failures (0 unexpected)
```

All four assertions fail, the watcher one included: `TaskFiles.write` creates the directory but
the manager's watcher was nil and nothing re-armed it. After the `init` edit all four watcher tests
pass.

Deviations: none. The directory is created after `reload()` rather than before it; `reload` reads
nothing from an empty directory, so the order does not matter, and the plan only requires it
before `watchDirectory()`.

Gate: `./scripts/ci.sh` exit 0, 891 tests, 0 failures, run after the final source edit.
`swiftlint lint --quiet` on the two touched Swift files printed nothing.

### T4: Stop overriding PRODUCT_NAME for every target

| File | State |
| --- | --- |
| `project.yml` | `Clearway` target `settings.base`: `APP_PRODUCT_NAME: Clearway`, `PRODUCT_NAME: $(APP_PRODUCT_NAME)`, `PRODUCT_MODULE_NAME: Clearway` |
| `scripts/build.sh`, `scripts/install.sh`, `scripts/release.sh` | each of the two `xcodebuild` lines passes `APP_PRODUCT_NAME="$PRODUCT_NAME"` in place of `PRODUCT_NAME="$PRODUCT_NAME" PRODUCT_MODULE_NAME=Clearway`; nothing else in `release.sh` changed |
| `Clearway.xcodeproj/project.pbxproj` | regenerated: the same three settings in the `Clearway` target's Debug and Release configurations |

Evidence: no regression test applies; this is a build-setting indirection with one target today.
`./scripts/build.sh` from this worktree built
`<BUILT_PRODUCTS_DIR>/Clearway (clearway-cli-create-list-and-show-tasks).app`; its
`Contents/MacOS/` holds `Clearway (clearway-cli-create-list-and-show-tasks)` and `CFBundleExecutable`
prints the same name. `BUILT_PRODUCTS_DIR` still holds `Clearway.swiftmodule`, so the module name
did not follow the bundle name. `grep -n "PRODUCT_MODULE_NAME\|PRODUCT_NAME=" scripts/*.sh` matches
only the shell-variable assignments in `build.sh`, `install.sh`, `release.sh` and `run.sh`; no
`xcodebuild` argument other than `APP_PRODUCT_NAME=`.

Deviations: none. The stale comments in `ci.sh:17` and `run.sh:26` that mention the `PRODUCT_NAME`
override were left alone; T8 owns the documentation of this change.

Gate: `./scripts/ci.sh` exit 0, 891 tests, 0 failures, 0 warnings in the log, run after the final
edit. `install.sh` and `release.sh` were not run.

### T5: Add the ClearwayCLI target and embed it in Contents/Helpers

| File | State |
| --- | --- |
| `project.yml` | `Clearway` target excludes `CLI/**` and depends on `ClearwayCLI` with `embed: true`, `codeSign: true`, `copy: {destination: wrapper, subpath: Contents/Helpers}`; new `ClearwayCLI` target (`type: tool`, sources `Sources/Shared` + `Sources/CLI`, `PRODUCT_NAME: clearway`, `PRODUCT_MODULE_NAME: ClearwayCLI`, `PRODUCT_BUNDLE_IDENTIFIER: app.getclearway.mac.cli`, D15 Debug/Release signing) |
| `Sources/Shared/TaskCommand.swift` | new: `TaskCommand.Result`, `TaskCommand.usage` (lists `task create`, `task list`, `task show`, `help`), `run(arguments:workingDirectory:readStdin:)` handling only no arguments / `help` / `--help` (usage, exit 0); anything else is `clearway: unknown command '<arg>'`, exit 2 |
| `Sources/CLI/main.swift` | new: calls `TaskCommand.run` with the process arguments, cwd and a stdin reader, writes stdout/stderr, `exit(result.exitCode)` |
| `Tests/TaskCommandTests.swift` | new, four cases: help/`--help`/no args, usage names every subcommand, unknown command, embedded helper exists, is executable and prints the usage with exit 0 |
| `Clearway.xcodeproj/project.pbxproj` | regenerated |

Evidence: `TaskCommand`, `main.swift` and the `CLI/**` exclude were added first, without the
`ClearwayCLI` target, and `TaskCommandTests` run alone:

```
TaskCommandTests.swift:38: error: … testEmbeddedHelperExistsAndRunsHelp : XCTAssertTrue failed - …/Debug/Clearway.app/Contents/Helpers/clearway
TaskCommandTests.swift:0: error: … failed: caught error: "… The file “clearway” doesn’t exist."
Executed 4 tests, with 2 failures (1 unexpected)
```

After adding the target all four pass. `./scripts/build.sh` built
`Clearway (clearway-cli-create-list-and-show-tasks).app` with `Contents/Helpers/clearway`
(executable, `help` exits 0), no duplicate-output error; `BUILT_PRODUCTS_DIR` holds separate
`Clearway.swiftmodule` and `ClearwayCLI.swiftmodule`. `codesign --verify --deep --strict` passed
on that bundle and on the `ci.sh`-built `Clearway.app`, which also carries the helper.

Release (crit. 12, first half): `xcodebuild … -configuration Release -derivedDataPath
<scratchpad>/release-dd build` exit 0. `codesign -dvvv Contents/Helpers/clearway` shows
`flags=0x10000(runtime)`, `Authority=Developer ID Application: Bruno Valentino (76AEQBHY3K)`,
`Timestamp=Oct 3, 2026 at 3:45:17 PM`; `codesign --verify --deep --strict` on the app passed. The
signature's `Identifier=clearway`, not `app.getclearway.mac.cli`: a tool with no Info.plist is
signed under its product name. Notarization is the operator's.

Deviations: the end-to-end test asserts the helper's stdout equals `TaskCommand.usage` rather than
only the exit code, which proves the embedded binary runs the shared code. `readStdin` is unused
until T6.

Gate: `./scripts/ci.sh` exit 0, 895 tests, 0 failures, 0 warnings in the log, run after the final
code edit. `git status --porcelain` shows only this task's files.

### T6: clearway task create

| File | State |
| --- | --- |
| `Sources/Shared/TaskCommand.swift` | `run` dispatches `task create`; any other command (including `task list`/`task show` until T7) stays `unknown command '<first two args>'`, exit 2. Private `Failure` (message + exit code, `usage` → 2, `runtime` → 1) thrown with typed throws and turned into the `clearway: <message>` stderr result in one place. `create` parses `--title`/`--body` via `parseOptions` (every flag takes the next argument as its value, so `-leading dash` and `--body -` work; unknown option, stray positional, missing value or repeated flag → exit 2), trims and validates the title, reads stdin only for `--body -`, then resolves the project, writes through `TaskFiles.write` and prints `{"id","path"}` with the D9 encoder options and a trailing newline. `resolveProject` runs `/usr/bin/env git worktree list --porcelain` in the working directory: launch failure or env exit 127 → "git not found", other non-zero → `not a git repository: <git's first stderr line>`, a `bare` line in the first block → exit 1, otherwise main = first parsed path |
| `Tests/TaskCommandTests.swift` | now a `TempRootTestCase`; ten new create cases: main worktree, linked worktree (file lands in main backlog, nothing in the linked worktree), missing `.clearway` (dir `0700`, file `0600`), the six-title round trip through `WorkTask.parse` and a fresh `WorkTaskManager`, title trimming, missing/empty/blank title, malformed flags, `--body text`, `--body -`, non-repo cwd. Every success goes through `created(_:)`, which parses stdout with `JSONSerialization` and checks the id is an uppercase `uuidString`; every failure through `assertFailed`, which checks empty stdout and the `clearway: ` stderr shape |

Evidence: the tests were written first and run against the T5 tree
(`xcodebuild … test -only-testing:ClearwayTests/TaskCommandTests`):

```
Executed 14 tests, with 36 failures (14 unexpected)
TaskCommandTests.swift:191: error: … testBodyDashReadsStdin : XCTAssertEqual failed: ("2") is not equal to ("0") - clearway: unknown command 'task'
… failed: testBodyFlagTextLandsAsBody, testCreateFromLinkedWorktreeWritesIntoMainBacklog,
testCreateFromMainWorktreeWritesSharedSerializationIntoBacklog, testCreateMakesMissingDirectoriesAndAnOwnerOnlyFile,
testCreateOutsideGitRepositoryExitsOneAndWritesNothing (exit 2, not 1), testTitleIsTrimmedOfWhitespaceAndNewlines,
testTitlesRoundTripThroughParserAndManager
```

The two usage-error cases passed vacuously on the T5 tree, since `task` was itself an unknown
command with exit 2; they only exercise flag parsing now. After the implementation all 14 pass.

By hand, with the `ci.sh`-built `<BUILT_PRODUCTS_DIR>/Clearway.app/Contents/Helpers/clearway` in a
scratchpad `git init` repo: `task create --title probe` printed `{"id","path"}`, exit 0, and wrote
`.clearway/tasks/<id>.md` (`-rw-------`, `id:` + `title: "probe"`); `--title " "` printed
`clearway: --title is empty`, exit 2; run from `/` it printed
`clearway: not a git repository: fatal: not a git repository (or any of the parent directories): .git`,
exit 1. The scratchpad repo was deleted afterwards.

Deviations:
- The JSON `path` is git's real path, so under `/var/folders` it is `/private/var/…`. The fixture
  root comes from `resolvingSymlinksInPath`, which strips `/private`, so the two path assertions
  compare through the same resolution (`canonical(_:)`). The CLI is not changed to match the
  fixture: git's path is the honest absolute path.
- Invalid UTF-8 on stdin for `--body -` is a runtime error (exit 1); the plan does not name it.
- The Debug helper is coverage-instrumented, so running it from a read-only cwd also prints
  `LLVM Profile Error: Failed to write file "default.profraw"` on stderr. Release builds carry no
  profiling; nothing to change in the CLI.

Gate: `./scripts/ci.sh` exit 0, 905 tests, 0 failures, run after the final code edit.
`swiftlint lint --quiet` on both touched Swift files printed nothing.
