# Plan: Improve worktree creation

**Date:** 2026-09-18
**Base:** 7ae81c1e (`Add worktree statuses and three sidebar view modes (#220)`)

Breaks down `docs/superpowers/specs/2026-09-18-improve-worktree-creation.md`. Every design
decision below is carried from that spec; this document only orders the work and says how each
piece is verified.

## Architecture decisions carried from the spec

1. A worktree's **name** and **status** live in that worktree's own git config —
   `clearway.name` and `clearway.status` in `$GIT_DIR/config.worktree`, written with
   `git config --worktree`. They are deleted with the worktree, readable by any tool, and need no
   reconcile, no pruning and no watcher. (Spec decisions 1, 2, 16.)
2. `extensions.worktreeConfig` must be enabled on the repository **before the first write**.
   With it off, `git config --worktree` is documented as "the same as `--local`" and silently
   writes to the shared `.git/config`, where every worktree would then read one name. Enabling it
   also requires moving `core.bare` / `core.worktree` out of `$GIT_DIR/config` into the main
   worktree's `config.worktree`, per git-worktree(1). (Spec decisions 1, 10.)
3. Reads use one process per worktree, `git config --worktree --list --null`, whose output is
   NUL-separated `key\nvalue` records. The parser keeps only keys with the `clearway.` prefix:
   `git worktree add` seeds `core.bare = false` into a new worktree's `config.worktree` once the
   extension is on, and the prefix filter is what stops that reaching the app. When the extension
   is off, reads return empty rather than falling back to `--local`, so a project that never used
   the feature costs zero `git config` processes per refresh. (Spec decisions 10, 11.)
4. The git plumbing lives in a new `WorktreeConfigStore`, `nonisolated` and `Sendable`, owning the
   extension bootstrap, the read, the write and the unset. Its argument building and output
   parsing are pure `static` functions so XCTest can pin them without a repository. (Decision 9.)
5. `WorktreeGroupManager` keeps publishing `statuses` and gains `names` beside it — only the
   backing store changes. The sidebar rows, the search predicate, the status badge, the ⌘N badge
   and `ContentView`'s ⌘1…9 list must all read one object. The manager is not renamed. (Decision 8.)
6. `WorktreeManager.runCommand` becomes `nonisolated`. It is `static` on a `@MainActor` class, so
   under `SWIFT_VERSION: "6.0"` every `git` subprocess — `run()`, two blocking
   `readDataToEndOfFile()` calls and `waitUntilExit()` — runs on the main actor. The keyword is
   the whole change: the body touches only locals, `GitResolver`'s statics and
   `ShellEnvironment.processEnvironment` (a plain `enum`). (Decision 13, operator-confirmed.)
7. The re-read trigger is `ContentView`'s existing `.onChange(of: worktreeManager.worktrees)`,
   inside the guard that already skips a failed or empty refresh.
   `reconcile(knownWorktreeIds:)` widens to `reconcile(_ worktrees: [Worktree])` and both prunes
   group membership and reloads the config, so the call site changes rather than grows —
   `ContentView.swift` is past SwiftLint's 1000-line `file_length` error and lives on a file-wide
   disable. (Decision 12.)
8. `statuses` leaves `WorktreeGroupsPayload`'s `CodingKeys`, so `save()` can no longer write it;
   `init(from:)` decodes the old key into a separate `legacyStatuses` property through its own key
   type. On load, a non-empty `legacyStatuses` is written to each recorded path's worktree config
   and `save()` is called at once, rewriting the file without the key. A path that no longer
   exists fails and is skipped. The migration never needs to know which worktree is main: a status
   key is already the worktree's path, and `status(for:)` already refuses to report a status for
   main. (Decisions 14, 15.)
9. Nothing prunes a vanished worktree's name or status. `git worktree remove` deletes
   `$GIT_COMMON_DIR/worktrees/<id>/` and its `config.worktree` with it, so `reconcile` loses its
   status-pruning branch and gains no name-pruning branch. (Decision 16.)
10. The branch-field ownership rule is a pure `WorktreeDraft` value type holding `name`, `branch`
    and whether the branch has been hand-edited, with `setName` and `setBranch` as the only
    mutators. A SwiftUI `.onChange(of:)` cannot tell a user keystroke from the name-driven write
    it would itself trigger, so the branch `TextField` binds to a `Binding` whose setter is
    `setBranch` — the user-edit path — while `setName` writes the state directly. (Decisions 17, 4.)
11. The slug rule: lowercase; ASCII letters and digits kept; every other run of characters becomes
    one hyphen; leading and trailing hyphens trimmed; no prefix. `"Fix login Bug!"` →
    `fix-login-bug`. A name regenerates the branch only while the branch field has never been
    hand-edited; a hand edit stops it, and clearing the branch back to empty resumes it.
    (Decision 4.)
12. The hand-edit path keeps today's space→hyphen sanitising only — a branch may legitimately
    contain `/`, `_` and `.`, so `setBranch` sanitises exactly what `SidebarSheets.swift:23-26`
    sanitises today and does not run the slug rule over the user's typing. (Decision 18.)
13. A sidebar row's primary text is the stored name when there is one; the TASK.md title fills the
    slot only when no name is stored; the branch is the subtitle in both cases, and the row falls
    back to the branch alone when neither exists. The precedence is lifted out of `SidebarView`'s
    private `rowTexts` into a pure `static` so it is testable. (Decisions 3, 19.)
14. The sidebar filter matches the stored name. `matches(_:query:taskTitle:)` gains it beside the
    branch, task title, group name and status name; its signature does not change, because the
    name comes from the manager's own map. (Decision 20.)
15. The name is optional — Branch name stays the only required field. A "Rename…" item in the
    non-main worktree row's context menu edits it later. The main worktree gets no name, no
    status and no Rename item. (Decision 5.)
16. Advanced holds Base branch and "Fetch before creating", collapsed by default; the sheet keeps
    its fixed 320pt width and grows in height when expanded. (Decision 7.)
17. The Status picker defaults to In progress and uses the SF Symbols and colours already on
    `WorktreeStatus` (`circle`, `circle.lefthalf.filled`, `circle.inset.filled`,
    `checkmark.circle.fill`, `pause.circle`). This change invents no symbol and touches no colour.
    (Decision 6.)
18. No menu command and no keyboard shortcut. `AppKeyboardShortcuts` is untouched. (Decision 22.)

## Decisions this plan makes that the spec left open

These are implementation shapes the spec did not fix. They are recorded here so eight independent
build agents produce one design.

- **The bootstrap order is copy → enable → unset.** `WorktreeConfigStore` copies `core.bare` and
  `core.worktree` (whichever `git config --local --get` reports) into
  `$(git rev-parse --path-format=absolute --git-common-dir)/config.worktree` with
  `git config --file`, *then* sets `extensions.worktreeConfig true`, *then* unsets them from the
  local config. No window exists in which a value is neither live in `.git/config` nor live in
  `config.worktree`. Verified by scratchpad probe on git 2.54 (Apple Git-157): both the main and
  the linked worktree keep a working `git status` afterwards.
- **The extension state is cached as a plain `Bool?` under the store's lock**, not as a memoised
  `Task`. A read probes once and caches; a write that finds the cache `false`/`nil` runs the whole
  idempotent bootstrap and then caches `true`. Two concurrent writers can both run the bootstrap;
  every step of it is idempotent, so that race is benign and is cheaper than serialising it.
- **The manager serialises its config writes on one task chain, and every config read awaits that
  chain first.** Creating a worktree writes a name and a status and *also* changes
  `worktreeManager.worktrees`, which fires the reload in the same turn; without the chain the
  reload can read the worktree's config before the writes land and publish an empty name over the
  one just typed. The legacy-status migration is simply the first item enqueued on that chain, so
  there is one mechanism rather than two.
- **`setName` and `setStatus` publish optimistically**, updating `names` / `statuses` in memory
  before the subprocess runs, so the sidebar never waits on `git`. A failed write is logged, the
  way `WorktreeGroupManager.save()` already logs one; the next reload corrects the map.
- **The create sheet's Status picker offers the five statuses and no "None".** Success criterion 3
  has creation always writing a status, and the row's context menu is where a status is cleared.
- **Tests that need a repository share one fixture in `Tests/TestHelpers.swift`**, not one per
  suite. It shells out to `/usr/bin/git` directly with `GIT_CONFIG_GLOBAL=/dev/null` and
  `GIT_CONFIG_SYSTEM=/dev/null` so the developer's own git config cannot change a result, and it
  resolves symlinks in every path it hands back (a temp root under `/var/folders` is a symlink to
  `/private/var/...`, and `git worktree list` reports the resolved form).

## Preconditions

- **The build phase starts only after `status-with-icons` has merged to `main` and this branch has
  been rebased onto it.** `WorktreeStatus.symbol` and the repainted `color` come from there; this
  change reads them and redefines nothing. Confirm `Sources/App/WorktreeStatus.swift` has a
  `symbol` property before starting T7.
- The spec and this plan are untracked at the time of writing. They belong in the first build
  task's commit.
- A Debug launch drops an un-gitignored `default.profraw` in the repo root. Never `git add -A`.

## Regression command

```bash
./scripts/ci.sh
```

The only runner of the test suite, and the only one that runs `xcodegen generate` — four new
Swift files in this plan are invisible to the build until it does. Do not hand-write an
`xcodebuild` line. It is the regression check for every build task below.

## Dependency graph

```
T1 (WorktreeConfigStore + nonisolated runCommand + git fixture)
 │
 ├─────────────► T4 (manager publishes names from config)
 │                │
T3 (reconcile widened to [Worktree]) ────────┘
                  │
                  ├──► T5 (statuses move to config; groups.json migration)
                  │      │
                  ├──► T6 (row-text precedence + sidebar wiring)
                  │      │
                  └──────┴──► T7 (New Worktree sheet) ──► T8 (Rename… item + sheet)
                                   ▲
T2 (WorktreeDraft) ────────────────┘
```

T1, T2 and T3 are independent of each other and can run in parallel. T4 needs T1 and T3. T5, T6
and T7 each need T4; T5 and T6 are independent of each other. T7 needs T2, T4 and T5. T8 needs T7
(both edit `SidebarSheets.swift` and `SidebarView.swift`).

## Task list

### T1: `WorktreeConfigStore` — the git-config seam

**Files touched**

- `Sources/App/WorktreeConfigStore.swift` (new)
- `Sources/App/Worktree.swift`
- `Tests/WorktreeConfigStoreTests.swift` (new)
- `Tests/TestHelpers.swift`

**What it does**

Adds `WorktreeConfigStore`, a `final class … : Sendable` constructed with the project path — the
same shape `WorktreeGroupStore` has, and for the same reason: its methods are already nonisolated,
so no `@convention(block)` literal can be formed in an isolated context (see CLAUDE.md's
Concurrency section).

Pure, `static`, tested without a repository:

```swift
static let nameKey = "clearway.name"
static let statusKey = "clearway.status"
static let keyPrefix = "clearway."

static func listArgs(worktreePath: String) -> [String]
static func setArgs(worktreePath: String, key: String, value: String) -> [String]
static func unsetArgs(worktreePath: String, key: String) -> [String]
static func parseList(_ output: String) -> [String: String]
```

`listArgs` produces `["git", "-C", path, "config", "--worktree", "--list", "--null"]`, `setArgs`
`["git", "-C", path, "config", "--worktree", key, value]`, `unsetArgs`
`["git", "-C", path, "config", "--worktree", "--unset", key]`. `-C` rather than running with the
worktree as the process's working directory: every command runs `in: projectPath`, a directory
that exists, so a vanished worktree path is a git error (exit 128, caught as
`WorktreeError.commandFailed`) instead of a `Process.run()` throw about the current directory.

`parseList` splits on `\0`, drops the trailing empty record, splits each record at its **first**
`\n` only — a value may contain newlines — and keeps only keys with the `clearway.` prefix. It
returns the full dotted keys, so callers subscript with `nameKey` / `statusKey`. The prefix filter
is load-bearing: `git worktree add` seeds `core.bare\nfalse` into a new worktree's
`config.worktree` once the extension is on (confirmed by probe), and without the filter that
reaches the app.

Async surface:

```swift
func values(forWorktreeAt path: String) async -> [String: String]
func set(_ value: String?, forKey key: String, worktreeAt path: String) async
```

`values` returns `[:]` without spawning anything when the extension is off. `set` with a `nil` or
empty value unsets the key (exit 5 on a key that is not there is success, not a failure); a
non-empty value writes it. Both log failures through `Ghostty.logger` and throw nothing — a config
write is not worth failing a worktree creation over.

The extension bootstrap, run before any write and never on a read:

1. `git config --local --get extensions.worktreeConfig` — a truthy value caches `true` and stops.
2. `git rev-parse --path-format=absolute --git-common-dir` for the main worktree's config
   directory. It returns the same absolute path from a linked worktree as from the main one
   (probe-confirmed), so the bootstrap never needs main's worktree path — which matters, because
   `projectPath` is routinely a linked worktree.
3. For each of `core.bare` and `core.worktree` present in `--local`, write the value into
   `<common>/config.worktree` with `git config --file`.
4. `git config --local extensions.worktreeConfig true`.
5. Unset each key moved in step 3 from `--local`.
6. Cache `true`.

The cached state is a `Bool?` behind `OSAllocatedUnfairLock`, matching `WorktreeGroupStore`'s use
of the same lock.

The one change in `Sources/App/Worktree.swift` is the keyword on `runCommand`:

```swift
@discardableResult
nonisolated static func runCommand(_ args: [String], in directory: String) async throws -> Data
```

Nothing else in that file changes — `fetchWorktrees` stays as it is (explicitly out of scope).

`Tests/TestHelpers.swift` gains the repository fixture the integration tests and T5 share:

```swift
struct GitRepoFixture {
    let root: String
    static func make(at root: String) throws -> GitRepoFixture
    @discardableResult func addWorktree(branch: String) throws -> String
    func value(ofKey key: String, atWorktree path: String) throws -> String?
    func localConfigContents() throws -> String
}
```

It runs `/usr/bin/git` synchronously with `GIT_CONFIG_GLOBAL` and `GIT_CONFIG_SYSTEM` set to
`/dev/null` and a fixed `user.name` / `user.email`, makes one `--allow-empty` commit, and returns
symlink-resolved paths.

**Acceptance criteria**

1. `listArgs`, `setArgs` and `unsetArgs` return exactly the arrays above for a given path and key.
2. `parseList` handles: one record; two records; a record whose value contains a newline (the
   whole remainder after the first `\n` is the value); a `core.bare` record, which is dropped; and
   empty input, which yields `[:]`.
3. Against a real temp repository: enabling the extension moves `core.bare` out of `.git/config`
   into the main worktree's `config.worktree`, sets `extensions.worktreeConfig true`, and leaves
   `git status` working in both the main and a linked worktree.
4. A name and a status written to a linked worktree read back from it, are **not** visible from a
   sibling worktree, and `values` never reports `core.bare`.
5. `set(nil, …)` clears one key and leaves the other intact; `set(nil, …)` on a key that was never
   written is not an error.
6. After `git worktree remove --force`, the removed worktree's config is gone with it.
7. `values` on a repository whose `extensions.worktreeConfig` is unset returns `[:]`.
8. `runCommand` carries `nonisolated` and the project still builds.

**How the criteria are verified**

`./scripts/ci.sh`. Criteria 1, 2 and 7's off-path are pure unit tests in
`WorktreeConfigStoreTests`. Criteria 3–6 are the integration suite in the same file, each test
building its own `GitRepoFixture` under the existing `TempRootTestCase` temp root. Criterion 8 is
read off the diff and proved by the build.

**Notes for the build agent**

- `git config --worktree --unset` exits 5 for a missing key and `git config --get` exits 1;
  neither is a failure worth logging as one.
- git lowercases config key names on read, which is why the two keys are all-lowercase. Values
  keep their case, so the `inProgress` status slug round-trips — probe-confirmed.
- Do not add a watcher for `config.worktree`. Spec decision 2 rules one out.

### T2: `WorktreeDraft` — the slug rule and branch-field ownership

**Files touched**

- `Sources/App/WorktreeDraft.swift` (new)
- `Tests/WorktreeDraftTests.swift` (new)

**What it does**

Adds a pure value type:

```swift
struct WorktreeDraft: Equatable {
    private(set) var name: String = ""
    private(set) var branch: String = ""
    private(set) var branchIsHandEdited: Bool = false

    static func slug(_ name: String) -> String

    mutating func setName(_ newValue: String)
    mutating func setBranch(_ newValue: String)
}
```

`slug` lowercases, keeps ASCII letters and digits, turns every other run of characters into one
hyphen, and trims leading and trailing hyphens. It adds no prefix. `"Fix login Bug!"` →
`fix-login-bug`; `"Café Ausflug"` → `caf-ausflug`, because the rule keeps ASCII alphanumerics and
does not transliterate.

`setName` stores the name and, while `branchIsHandEdited` is false, writes `slug(newValue)` into
`branch`.

`setBranch` is the user-edit path. It sanitises spaces to hyphens exactly as
`SidebarSheets.swift:23-26` does today and leaves `/`, `_` and `.` alone, stores the result, and
sets `branchIsHandEdited` to true — except when the sanitised value is empty, which clears the
flag so name-driven generation resumes.

**Acceptance criteria**

1. The slug rule: the worked example; an all-punctuation input (`"!!!"` → `""`); a
   leading/trailing-punctuation input (`" -Fix- "` → `fix`); a non-ASCII input
   (`"Café Ausflug"` → `caf-ausflug`); an empty input (`""`).
2. Typing a name fills the branch before any hand edit.
3. A hand edit stops it: a later `setName` leaves `branch` alone while still updating `name`.
4. Clearing the branch to empty resumes generation — the next `setName` fills it again.
5. The hand-edit path turns spaces into hyphens and leaves `feature/a_b.c` untouched.

**How the criteria are verified**

`Tests/WorktreeDraftTests.swift`, run by `./scripts/ci.sh`. Every criterion is a direct assertion
on the value type; nothing in this task touches a view.

**Notes for the build agent**

- Keep the mutators the only way to change state. `private(set)` on all three properties is what
  makes the truth table the type's, not the sheet's.
- Do not add a `reset()`, a prefix option or a validity flag. The sheet's Create button gates on
  `branch.isEmpty` and `WorktreeManager.createWorktree` already rejects a malformed branch.

### T3: Widen `reconcile` to take the live worktrees

**Files touched**

- `Sources/App/WorktreeGroupManager.swift`
- `Sources/App/ContentView.swift`
- `Tests/WorktreeGroupManagerTests.swift`
- `Tests/WorktreeGroupManagerStatusTests.swift`

**What it does**

Changes `reconcile(knownWorktreeIds: Set<String>)` to `reconcile(_ worktrees: [Worktree])`, which
derives the ID set itself and otherwise behaves exactly as it does today — it still prunes group
membership, `defaultOrder` and `statuses`, and still saves only when something changed. This task
is a signature change and nothing else; T4 and T5 fill the widened parameter with work.

In `ContentView.swift` the single call inside the existing guard becomes
`groupManager.reconcile(newWorktrees)`. `currentIds` stays — `terminalManager.pruneStale` and
`worktreeManager.prunePRStatuses` still take it. No line is added to that file.

`Tests/WorktreeGroupManagerTests.swift` and `Tests/WorktreeGroupManagerStatusTests.swift` update
their three `reconcile(knownWorktreeIds:)` call sites
(`WorktreeGroupManagerTests.swift:179,202`, `WorktreeGroupManagerStatusTests.swift:145`) to pass
worktrees. The existing assertions do not change.

**Acceptance criteria**

1. `reconcile(_:)` prunes a group's membership and `defaultOrder` of IDs absent from the passed
   worktrees, exactly as the ID-set version did.
2. A reconcile that changes nothing still writes nothing.
3. `ContentView.swift`'s line count does not grow.
4. No call site of the old signature remains.

**How the criteria are verified**

`./scripts/ci.sh` — criteria 1 and 2 are the existing tests carried over to the new signature, and
criterion 4 is the build. Criterion 3 is `git diff --stat`: `ContentView.swift` shows one changed
line and no net addition.

**Notes for the build agent**

- `Tests/WorktreeGroupManagerStatusTests.swift:134-153` still asserts that reconcile prunes a
  status. Leave that test passing here; T5 is where it is re-pointed.

### T4: The manager publishes `names`, backed by worktree config

**Files touched**

- `Sources/App/WorktreeGroupManager.swift`
- `Tests/WorktreeGroupManagerNameTests.swift` (new)
- `Tests/TestHelpers.swift`

**What it does**

Gives `WorktreeGroupManager` a `WorktreeConfigStore` beside its `WorktreeGroupStore`, and adds:

```swift
@Published private(set) var names: [String: String] = [:]

func name(for wt: Worktree) -> String?
func setName(_ name: String?, for wt: Worktree)
func reloadConfig(for worktrees: [Worktree]) async   // private
```

`name(for:)` returns `nil` for main, on the same terms and for the same reason `status(for:)`
already does, and `nil` for a stored value that is empty after trimming.

`setName` guards on `!wt.isMain` and a non-nil `wt.path`, publishes optimistically into `names`
(a `nil`, empty or whitespace-only name removes the key), and enqueues the
`WorktreeConfigStore.set` on the manager's write chain.

The write chain and the read that awaits it:

```swift
private var writeChain: Task<Void, Never>?

private func enqueueWrite(_ work: @escaping @Sendable () async -> Void) {
    let previous = writeChain
    writeChain = Task { await previous?.value; await work() }
}
```

`reloadConfig(for:)` first does `await writeChain?.value`, then reads every non-main worktree's
config concurrently in a `withTaskGroup`, builds the `names` map from
`WorktreeConfigStore.nameKey`, and assigns it only when it differs. Awaiting the chain is what
stops the reload that a freshly created worktree triggers from publishing an empty name over the
one just written.

`reconcile(_:)` calls it: after the existing prune it fires
`Task { await self.reloadConfig(for: worktrees) }`.

`matches(_:query:taskTitle:)` tries `name(for: wt)` beside the four things it already tries. Its
signature does not change.

`Tests/TestHelpers.swift` gains a `WorktreeGroupManagerTestCase` subclass or helper that builds a
`GitRepoFixture` in `tempRoot` and constructs the manager against it, so name and status tests can
write real config. The existing `WorktreeGroupManagerTestCase` keeps working unchanged for the
group/order tests, which need no repository.

**Acceptance criteria**

1. `setName` on a linked worktree publishes the name immediately and lands
   `clearway.name` in that worktree's `config.worktree`.
2. `setName(nil, …)` and `setName("  ", …)` clear both the published entry and the stored key.
3. `setName` on the main worktree writes nothing and publishes nothing.
4. `reconcile(_:)` populates `names` from the worktrees' config, and drops an entry whose config
   no longer carries the key.
5. A `setName` immediately followed by a `reconcile(_:)` still ends with the new name published —
   the reload does not race the write.
6. `matches` returns true for a query matching a stored name, and still returns true for a branch,
   task-title, group-name and status-name query.

**How the criteria are verified**

`./scripts/ci.sh`. Criteria 1–5 are integration tests in
`Tests/WorktreeGroupManagerNameTests.swift` over a `GitRepoFixture`, reading the stored value back
with `git config --worktree --get`. Criterion 6 extends the existing `matches` tests in
`Tests/WorktreeGroupManagerTests.swift`.

**Notes for the build agent**

- Do not add `name` to `Worktree`. `Worktree` is the `List` selection tag and is `Hashable`; a
  mutable name on it would drop the sidebar selection on every rename
  (`ContentView.swift:346-348` already re-seeds the selection when a refreshed instance differs).
- The manager stays `@MainActor`; only the store is nonisolated. Do not mark any manager method
  `nonisolated`.
- Nothing prunes names. The worktree's config dies with the worktree.

### T5: Statuses move to worktree config, and `groups.json` stops carrying them

**Files touched**

- `Sources/App/WorktreeGroupManager.swift`
- `Sources/App/WorktreeGroupStore.swift`
- `Tests/WorktreeGroupStoreTests.swift`
- `Tests/WorktreeGroupManagerStatusTests.swift`

**What it does**

In `WorktreeGroupStore.swift`, `WorktreeGroupsPayload` drops `statuses` from its `CodingKeys` and
from its memberwise initialiser, and gains

```swift
var legacyStatuses: [String: WorktreeStatus]
```

populated only by `init(from:)`, through its own key type, from the old `statuses` key. Encoding a
payload therefore cannot write the key. The existing lenient-decoding contract is unchanged:
`groups` and `defaultOrder` stay required, `grouping` stays `try?`, and the legacy key decodes
through `[String: String]` and `WorktreeStatus(rawValue:)` so an unrecognised slug is dropped
rather than throwing the file away. The legacy bare-array fallback in `load()` and
`WorktreeGroupsPayload.empty` update to the new initialiser.

In `WorktreeGroupManager.swift`:

- `setStatus` keeps its main guard and its no-op guard, publishes optimistically, and enqueues
  `WorktreeConfigStore.set(status?.rawValue, forKey: .statusKey, …)` on the write chain instead of
  calling `save()`.
- `reloadConfig(for:)` builds `statuses` from `WorktreeConfigStore.statusKey` through
  `WorktreeStatus(rawValue:)` in the same pass that builds `names`, dropping an unrecognised slug.
- `reconcile(_:)` loses its status-pruning branch entirely.
- `save()` stops passing statuses to the payload.
- The `init` load path: after assigning groups, `defaultOrder` and `grouping`, a non-empty
  `loaded.legacyStatuses` is published straight into `statuses` (so the sidebar is correct before
  any subprocess runs), enqueued on the write chain as one `set` per recorded path, and `save()`
  is called at once so the file is rewritten without the key. A path that no longer exists fails
  inside `git` and is skipped.
- The `store.startWatching` reload closure stops comparing and assigning `statuses` — the file no
  longer carries them.

**Acceptance criteria**

1. `setStatus` on a linked worktree lands `clearway.status` in that worktree's `config.worktree`
   and writes no status into `groups.json`.
2. `setStatus(nil, …)` clears both the published entry and the stored key.
3. `setStatus` on main still writes nothing and publishes nothing, and a status stored against
   main is still ignored on the read path.
4. `reconcile(_:)` populates `statuses` from config and no longer prunes them.
5. A `groups.json` carrying the pre-change `statuses` key decodes it into `legacyStatuses`, the
   manager writes each one into the matching worktree's config, the file is rewritten without the
   key, and the sidebar shows the same statuses it showed before.
6. A `groups.json` with no `statuses` key still loads its groups, `defaultOrder` and `grouping`.
7. Encoding a payload produces bytes that contain no `statuses` key.

**How the criteria are verified**

`./scripts/ci.sh`. Criteria 1–5 are `Tests/WorktreeGroupManagerStatusTests.swift`, re-pointed at a
`GitRepoFixture`: the existing "persists" assertions read `git config --worktree --get
clearway.status` instead of reloading `groups.json`, and the `groupsFileExists` probes become
"writes no status into the file". Criteria 6 and 7 are
`Tests/WorktreeGroupStoreTests.swift`, asserted over **literal bytes** in both directions — the
pre-change wire format decoded, and an encode inspected for the absent key — for the reason
CLAUDE.md records for `OpenInAppTests`: a round-trip test cannot catch a renamed key.

**Notes for the build agent**

- The migration must publish into `statuses` *before* it awaits any subprocess. If it does not, a
  launch shows an unstatused sidebar until the first reload lands.
- `status(for:)`'s main guard and its comment stay exactly as they are
  (`WorktreeGroupManager.swift:163-170`); a hand-edited file can still carry main's path, and the
  migration deliberately does not filter it out.
- Do not rename `groups.json`, `WorktreeGroupStore` or `WorktreeGroupManager`. The follow-up task
  that deletes the file owns that.

### T6: Row-text precedence and the sidebar row

**Files touched**

- `Sources/App/WorktreeRow.swift`
- `Sources/App/SidebarView.swift`
- `Tests/WorktreeRowTests.swift` (new)

**What it does**

Moves the precedence out of `SidebarView`'s private `rowTexts(for:titles:)`
(`SidebarView.swift:473-480`) into a pure `static` on `WorktreeRow`:

```swift
static func rowTexts(
    for wt: Worktree,
    name: String?,
    taskTitle: String?
) -> (primaryText: String?, subtitle: String?)
```

The rule: a name that is non-empty after trimming wins; otherwise the task title; otherwise
neither. When either wins it is the primary text and `wt.displayName` is the subtitle. When
neither exists both are `nil`, which is what makes `WorktreeRow` render `worktree.displayName`
alone — the existing `else` branch of its `VStack`.

`SidebarView.worktreeRowView` calls it with `groupManager.name(for: wt)` and
`wt.branch.flatMap { titles[$0] }`, and the private method is deleted. Nothing else in
`SidebarView.swift` changes; `WorktreeRow`'s view body and its badges are untouched.

**Acceptance criteria**

1. A worktree with a stored name and a task title shows the name over the branch.
2. A worktree with no name and a task title shows the task title over the branch.
3. A worktree with a name and no task title shows the name over the branch.
4. A worktree with neither returns `(nil, nil)`.
5. An empty or whitespace-only name is treated as absent.
6. The sidebar row for a named worktree renders the name over the branch in the running app.

**How the criteria are verified**

Criteria 1–5 are `Tests/WorktreeRowTests.swift`, run by `./scripts/ci.sh`. Criterion 6 is a
hands-on check in `./scripts/run.sh` against a project with one named worktree, one unnamed
worktree with a TASK.md, and the main worktree — nothing in a SwiftUI body is reachable from
XCTest, which is why the rule was lifted out in the first place.

**Notes for the build agent**

- `SidebarView.swift` is 653 lines against a `file_length` warning of 700. This task removes a
  method and adds no lines, so it stays well under.
- Main is handled by `name(for:)` returning `nil`, not by an `isMain` branch in the helper.

### T7: The New Worktree sheet

**Files touched**

- `Sources/App/SidebarSheets.swift`

**What it does**

Rebuilds `CreateWorktreeSheet`'s body as Name, Branch name, Status, then a collapsed **Advanced**
disclosure holding Base branch and "Fetch before creating". The sheet keeps `.frame(width: 320)`
and its 20pt padding and grows in height when Advanced expands.

State becomes `@State private var draft = WorktreeDraft()`,
`@State private var status: WorktreeStatus = .inProgress`,
`@State private var showingAdvanced = false`, plus the existing `baseBranch`, `fetchBeforeCreate`
and `isCreating`.

The two text fields:

- Name binds to `Binding(get: { draft.name }, set: { draft.setName($0) })`.
- Branch name binds to `Binding(get: { draft.branch }, set: { draft.setBranch($0) })`, and the
  `.onChange(of: branchName)` sanitiser at `SidebarSheets.swift:23-26` is deleted — `setBranch`
  now does that work. This is the whole point of decision 17: an `.onChange` cannot tell a user
  keystroke from the name-driven write it would itself trigger.

The Status picker renders `Label(status.displayName, systemImage: status.symbol)` for each of
`WorktreeStatus.allCases`, with no "None" row. It reads `symbol` and `color` from
`WorktreeStatus`; it defines neither.

Create stays gated on `draft.branch.isEmpty || isCreating`. Its action passes `draft.branch` to
`worktreeManager.createWorktree`, and on success, before dismissing, calls
`groupManager.setName(draft.name, for: created)` and `groupManager.setStatus(status, for: created)`
alongside the existing `addWorktree(_:toGroup:)`. The existing "return lookup failed" warning
branch stays; a creation whose lookup failed writes no name and no status.

**Acceptance criteria**

1. The sheet shows Name, Branch name, Status, then a collapsed Advanced disclosure holding Base
   branch and Fetch before creating. Create is disabled while Branch name is empty.
2. Typing `Fix login Bug!` into Name fills Branch name with `fix-login-bug`. Editing Branch name
   by hand stops further name-driven changes; clearing it to empty resumes them.
3. Creating with a name and a status writes both: from the new worktree,
   `git config --worktree --get clearway.status` prints the slug and `--get clearway.name` prints
   the name.
4. Leaving Name empty writes no `clearway.name`.
5. Expanding Advanced grows the sheet's height and leaves its width at 320pt.

**How the criteria are verified**

Criteria 1, 2 and 5 are hands-on in `./scripts/run.sh` — the sheet is SwiftUI view state with no
XCTest surface, which is why the rule it drives lives in `WorktreeDraft` (T2, already pinned) and
the writes live on the manager (T4 and T5, already pinned). Criteria 3 and 4 are checked in the
running app by creating a worktree and running the two `git config` commands in it.
`./scripts/ci.sh` is the regression check.

**Notes for the build agent**

- Confirm `WorktreeStatus.symbol` exists before starting. It arrives from `status-with-icons`; see
  Preconditions.
- Do not add a keyboard shortcut or a menu command for any of this (decision 22).
- `SidebarSheets.swift` is 152 lines; this task and T8 together leave it far under the 700-line
  warning, so no split is needed.

### T8: "Rename…" in the worktree context menu

**Files touched**

- `Sources/App/SidebarView.swift`
- `Sources/App/SidebarSheets.swift`

**What it does**

Adds `RenameWorktreeSheet` to `SidebarSheets.swift`, shaped exactly like the neighbouring
`RenameGroupSheet`: `init(currentName: String, onSave: @escaping (String) -> Void)`, a
`TextField("Name", …)` seeded with the current name, Cancel on `.cancelAction` and Save on
`.defaultAction`. Unlike `RenameGroupSheet`, **Save is not disabled on an empty field** — saving
an empty name is how a name is cleared.

In `SidebarView.swift`, a `@State private var worktreeToRename: Worktree?` and a
`.sheet(item: $worktreeToRename)` presenting it with
`groupManager.name(for: wt) ?? ""`, whose `onSave` calls `groupManager.setName(newName, for: wt)`.
A `Button("Rename…") { worktreeToRename = wt }` joins the existing `if !wt.isMain` block in
`worktreeContextMenu`, above the Status menu, so main never offers it.

**Acceptance criteria**

1. A non-main worktree's context menu has a "Rename…" item; the main worktree's does not.
2. The sheet opens pre-filled with the current name, and is empty for a worktree that has none.
3. Saving changes the sidebar row and lands the new value in that worktree's `config.worktree`.
4. Saving an empty field clears both the row's name and the stored key, and the row falls back to
   the task title or the branch.
5. The main worktree's `config.worktree` is not written by any gesture in this change.

**How the criteria are verified**

Hands-on in `./scripts/run.sh`, with `git config --worktree --list --null` run in the renamed
worktree and in the main worktree to confirm criteria 3, 4 and 5. The underlying behaviour —
`setName` with an empty string clearing the key, and `setName` refusing main — is already pinned
by T4's tests; this task adds the two view surfaces that call it. `./scripts/ci.sh` is the
regression check.

**Notes for the build agent**

- The ellipsis is the real character `…`, matching "Creating…" elsewhere in this file.
- `SidebarView.swift` grows by roughly a dozen lines here, which keeps it under the 700-line
  warning after T6 removed a method.

## Checkpoints

- **After T1–T3.** `./scripts/ci.sh` green. The store round-trips against a real repository, the
  draft's truth table holds, and the app behaves exactly as it did before — nothing user-visible
  has moved yet.
- **After T5.** `./scripts/ci.sh` green, and a hands-on launch on a project whose `groups.json`
  carries statuses: the sidebar shows the same statuses it showed before, the file comes back
  without the key, and each status is readable with `git config --worktree --get clearway.status`
  in its worktree. This is the riskiest point in the plan — verify it before building any view.
- **After T8.** Every success criterion in the spec, including the hands-on ones, against a
  project with a named worktree, an unnamed worktree with a TASK.md, and the main worktree.

## Risks

| Risk | Impact | Mitigation |
| --- | --- | --- |
| The bootstrap writes to the user's `.git/config` and moves `core.bare` | High if wrong | T1 criterion 3 pins the end state against a real repository, including `git status` in both the main and a linked worktree. The copy → enable → unset order leaves no window in which the value is live in neither file. Probe-confirmed on git 2.54. |
| The migration runs once and the old key is gone; a bug loses every stored status | High | The migration publishes into memory before writing, `save()` rewrites the file only after, and T5 criterion 5 pins the whole path end to end. Statuses are two weeks old at most (#220) and are re-settable from the context menu. |
| A reload racing a write publishes an empty name over a just-typed one | Medium | The manager's single write chain, awaited by every read (T4). Pinned by T4 criterion 5. |
| One `git config` process per worktree on every refresh | Medium | `runCommand` becomes `nonisolated` (T1), the reads run concurrently in a task group, and a project without `extensions.worktreeConfig` spawns nothing at all. |
| The status symbols are not on `main` yet when T7 starts | Low | Preconditions; T7's first note. `WorktreeStatus.symbol` is the single thing to confirm. |

## Out of scope

Everything the spec's "Out of scope" section lists: moving groups, `defaultOrder` and the grouping
mode out of `groups.json`; any watcher for worktree config; TASK.md, `WorkTaskCoordinator` and the
`status` frontmatter; a configurable branch prefix; menu commands and keyboard shortcuts; showing
the name anywhere but the sidebar row and filter; new or renamed statuses and the symbols
themselves; name uniqueness validation; making `fetchWorktrees` `nonisolated` or any wider
main-actor audit; and the known `WorktreeGroupStore.openFileWatcher` fd leak.

## Build log

### T1: `WorktreeConfigStore` — the git-config seam

**What landed**

| File | State |
| --- | --- |
| `Sources/App/WorktreeConfigStore.swift` | New. `final class … : Sendable`. Pure statics `nameKey`, `statusKey`, `keyPrefix`, `listArgs`, `setArgs`, `unsetArgs`, `parseList`. Async `values(forWorktreeAt:)` and `set(_:forKey:worktreeAt:)`. Extension state cached as `Bool?` behind `OSAllocatedUnfairLock`; bootstrap is copy → enable → unset. |
| `Sources/App/Worktree.swift` | `runCommand` gains `nonisolated`. One line; nothing else in the file changed. |
| `Tests/WorktreeConfigStoreTests.swift` | New. `WorktreeConfigArgumentTests` (8 pure cases) and `WorktreeConfigStoreTests` (6 integration cases over a real repository under `TempRootTestCase`'s temp root). |
| `Tests/TestHelpers.swift` | Gains `GitRepoFixture`. Additive; the existing helpers are untouched. |
| `Clearway.xcodeproj/project.pbxproj` | Regenerated by `xcodegen` for the two new files. |

**Evidence**

- *The `nonisolated` keyword cannot be pinned by a test.* The first draft carried
  `testRunCommandIsNonisolated`, converting `WorktreeManager.runCommand` to a
  `@Sendable ([String], String) async throws -> Data` on the theory that a `@MainActor` static
  would lose its global actor and Swift 6 would reject it. The keyword was removed from
  `Worktree.swift` and `./scripts/ci.sh` was run: the project **built and the test passed**
  (`Executed 472 tests, with 3 failures` — all three in `ShellPathResolverTests`, none in the new
  suite). Swift permits dropping global-actor isolation on an `async` function conversion, because
  the caller must `await` regardless. A test that passes with and without the fix pins nothing, so
  it was deleted. Criterion 8 stands on the diff and the build, exactly as the plan wrote it.
- *No watched red for the store itself.* `WorktreeConfigStore` is new code; there is no unfixed
  version to revert to. The behaviour the plan calls riskiest — the extension bootstrap — was
  proved before it was written, by a scratchpad probe on git 2.54.0 (Apple Git-157) that confirmed
  the end state of criterion 3, and is now asserted by
  `testFirstWriteEnablesTheExtensionAndMovesCoreBare`.
- *`ShellPathResolverTests` flakes, and it is not this task's doing.* The full gate failed three
  times here, each with a `degraded(…)` where `full(…)` was expected. Baseline run with the two new
  files moved out of the tree and `Worktree.swift` / `TestHelpers.swift` restored to `7ae81c1`:

  ```
  ✖ testAProfileThatFloodsStderrStillResolves, XCTAssertEqual failed:
    ("degraded("/opt/homebrew/bin:/usr/bin:/bin")") is not equal to
    ("full("/opt/homebrew/bin:/usr/bin:/bin")")
  Executed 457 tests, with 1 failure (0 unexpected) in 59.822 seconds
  ```

  The suite's interactive attempt runs on a 0.5s timeout (`ShellPathResolverTests.swift:10`) and a
  timed-out interactive attempt is exactly what produces `degraded`; it passes on its own
  (`Executed 15 tests, with 0 failures`) and fails only under a loaded full run. It is also
  alphabetically ahead of the new `Worktree*` suites, so they cannot be loading the machine while
  it runs. Pre-existing; recorded as a follow-up, not fixed here.

**Deviations from the plan**

- *Read and clear failures are not logged.* The plan said both async methods "log failures through
  `Ghostty.logger`". Only the state-changing calls do. Probed on git 2.54: `--get` on a missing key
  exits 1, `--unset` on a missing key exits 5 with zero bytes on stderr, and — the case the plan
  did not record — `git config --worktree --list --null` exits **128** with
  `fatal: unable to read config file '.git/config.worktree'` on a worktree created before the
  extension was enabled. All three are ordinary answers, so logging them would make an empty name
  a warning on every refresh. `run(_:reportingFailure:)` carries the distinction and documents it.
- *`GitRepoFixture` gained three members beyond the plan's four*: `removeWorktree(at:)` and
  `statusSucceeds(in:)` for criteria 6 and 3, and `mainWorktreeConfigContents()` so criterion 3 can
  assert where `core.bare` landed rather than only that it left `.git/config`.
- *The extension probe uses `--type=bool`*, so a repository configured with `1`, `yes` or `on`
  reads as enabled rather than triggering a redundant bootstrap.

**Gate**

`./scripts/ci.sh` — `Executed 471 tests, with 0 failures (0 unexpected) in 63.983 seconds`,
`==> CI passed.` Run after the last edit. No new SwiftLint warnings.

### T2: `WorktreeDraft` — the slug rule and branch-field ownership

**What landed**

| File | State |
| --- | --- |
| `Sources/App/WorktreeDraft.swift` | New. `struct WorktreeDraft: Equatable` with `private(set)` `name`, `branch`, `branchIsHandEdited`; `static func slug(_:)`; `setName`, `setBranch`. No `reset()`, no prefix option, no validity flag. |
| `Tests/WorktreeDraftTests.swift` | New. `WorktreeDraftSlugTests` (7 cases) and `WorktreeDraftTests` (7 cases), covering all five acceptance criteria. |
| `Clearway.xcodeproj/project.pbxproj` | Regenerated by `xcodegen` for the two new files. |

**Evidence**

The tests were written and run before the type existed. `./scripts/ci.sh` on that tree:

```
❌ Tests/WorktreeDraftTests.swift:11:24: cannot find 'WorktreeDraft' in scope
… (13 more, one per test method)
```

There is no unfixed version of this type to revert to, so a compile failure is the only red
available; every criterion is a direct assertion on a value type that did not exist. The
implementation then turned all 14 green.

**Deviations from the plan**

- *Two slug cases beyond the plan's five*: `"a  ///  b"` → `a-b` pins that a run of several
  separator characters collapses to one hyphen rather than one per character, and
  `"Issue 42: Retry"` → `issue-42-retry` pins that digits survive. The rule as written is easy to
  implement one-hyphen-per-character; neither of the plan's five inputs would catch that.
- *One hand-edit case beyond the plan's*: `setBranch("Fix/Login!")` → `Fix/Login!` pins decision 18
  directly — the hand-edit path does not lowercase and does not hyphenate punctuation. The plan's
  `feature/a_b.c` case is all-lowercase, so it passes under the slug rule too and cannot tell the
  two paths apart.
- *`slug` trims by construction rather than by a trailing `trimmingCharacters` call*: a pending
  separator is only emitted when a kept character follows it and the result is non-empty, so
  leading and trailing runs never reach the string. Same output, one pass.

**Gate**

`./scripts/ci.sh` — `Executed 485 tests, with 0 failures (0 unexpected) in 65.028 seconds`,
`==> CI passed.` Run after the last edit. No SwiftLint output for either new file.
`ShellPathResolverTests` did not flake on this run.

### T3: Widen `reconcile` to take the live worktrees

**What landed**

| File | State |
| --- | --- |
| `Sources/App/WorktreeGroupManager.swift` | `reconcile(knownWorktreeIds: Set<String>)` → `reconcile(_ worktrees: [Worktree])`, deriving the ID set on its first line. The pruning body, the `changed`/`defaultChanged`/`statusesChanged` guard and the `save()` are byte-identical. |
| `Sources/App/ContentView.swift` | One line: `groupManager.reconcile(currentIds)` → `groupManager.reconcile(newWorktrees)`. `currentIds` stays — `terminalManager.pruneStale` and `worktreeManager.prunePRStatuses` still take it. |
| `Tests/WorktreeGroupManagerTests.swift` | Two call sites (`:179`, `:202`) pass `[alive]` / `[wt]`; the `MARK` heading renamed. No assertion changed. |
| `Tests/WorktreeGroupManagerStatusTests.swift` | One call site (`:145`) passes `[alive]`. The status-pruning test is left passing, as the plan's note requires; T5 re-points it. |

**Evidence**

The three call sites were converted to the new signature first and `./scripts/ci.sh` was run
against the unchanged manager:

```
❌ Tests/WorktreeGroupManagerTests.swift:179:27: missing argument label 'knownWorktreeIds:' in call
❌ Tests/WorktreeGroupManagerTests.swift:179:27: cannot convert value of type 'Set<Worktree>' to expected argument type 'Set<String>'
❌ Tests/WorktreeGroupManagerTests.swift:202:27: missing argument label 'knownWorktreeIds:' in call
❌ Tests/WorktreeGroupManagerStatusTests.swift:145:27: missing argument label 'knownWorktreeIds:' in call
❌ Tests/WorktreeGroupManagerStatusTests.swift:145:27: cannot convert value of type 'Set<Worktree>' to expected argument type 'Set<String>'
** TEST FAILED **
```

A signature change has no behavioural red available: the pruning rules are unchanged, so the two
carried-over tests assert exactly what they asserted before and would pass under either signature.
The compile failure is the only watched red, and criterion 4 — no call site of the old signature
remains — is what it proves.

Criterion 3 is `git diff --stat`: `Sources/App/ContentView.swift | 2 +-`, one changed line and no
net addition. A `grep -rn knownWorktreeIds Sources Tests` afterwards returns only the four uses of
the local constant inside `reconcile` itself.

**Deviations from the plan**

None.

**Gate**

`./scripts/ci.sh` — `Executed 485 tests, with 0 failures (0 unexpected) in 64.954 seconds`,
`==> CI passed.` Run after the last edit. No SwiftLint output for any touched file.
`ShellPathResolverTests` did not flake on this run. `git status --porcelain` before the commit
showed the four modified files and nothing untracked.

### T4: The manager publishes `names`, backed by worktree config

**What landed**

| File | State |
| --- | --- |
| `Sources/App/WorktreeGroupManager.swift` | Holds a `WorktreeConfigStore` beside its `WorktreeGroupStore`. New `@Published private(set) var names`, `name(for:)`, `setName(_:for:)`, private `reloadConfig(for:)` and `enqueueWrite(_:)` over a `writeChain: Task<Void, Never>?`. `reconcile(_:)` fires the reload on its first line; `matches` tries the stored name. `setStatus` and `save()` are untouched — statuses are T5. |
| `Tests/WorktreeGroupManagerNameTests.swift` | New. Seven cases over a real repository: publish-then-write, two clearing paths, main ignored, reconcile populating and dropping, the write/reload race, and a name query through `matches`. |
| `Tests/TestHelpers.swift` | `WorktreeGroupManagerTestCase` gains an overridable `prepareProjectRoot()`, called between the scratch root and the manager; `WorktreeGroupManagerGitTestCase` overrides it with a `GitRepoFixture`. `GitRepoFixture` gains `enableWorktreeConfig()`, `setValue(_:ofKey:atWorktree:)` and `unsetValue(ofKey:atWorktree:)`. |
| `Clearway.xcodeproj/project.pbxproj` | Regenerated by `xcodegen` for the new test file. |

**Evidence**

- *The write chain is the one behavioural rule here, and it was watched red.* With
  `await writeChain?.value` removed from the first line of `reloadConfig(for:)`, `./scripts/ci.sh`:

  ```
  ✖ testReconcileRightAfterSetNameDoesNotRaceTheWrite, XCTAssertEqual failed:
    ("nil") is not equal to ("Optional("Fresh name")")
  Executed 7 tests, with 1 failure (0 unexpected) in 7.997 seconds
  ```

  The reload's `git config --list` reaches the worktree before `setName`'s write has cleared the
  extension bootstrap, reads nothing, and publishes `[:]` over the just-typed name. The keyword
  restored, the same suite is green.
- *The rest of the API is new code with no unfixed version to revert to*, so the compile failure
  was the available red. The tests were written first; `./scripts/ci.sh` on that tree:

  ```
  ❌ Tests/WorktreeGroupManagerNameTests.swift:26:17: value of type 'WorktreeGroupManager' has no member 'setName'
  ❌ Tests/WorktreeGroupManagerNameTests.swift:50:31: value of type 'WorktreeGroupManager' has no member 'names'
  … (11 more, over `setName`, `names` and `name`)
  ```

- *`ShellPathResolverTests` flaked once, as T1 recorded.* The first green-path run reported
  `Executed 492 tests, with 3 failures` — all three inside
  `testAHealthyShellGivesFullFromOneInteractiveAttempt` and `testAProfileThatFloodsStderrStillResolves`,
  each a `degraded(…)` where `full(…)` was expected, none in a `Worktree*` suite. Re-run unchanged:
  0 failures. Pre-existing; not touched here.

**Deviations from the plan**

- *The name-query case lives in the new suite, not in `WorktreeGroupManagerTests.swift`.* The plan
  pointed criterion 6 at that file, but every `matches` case is in
  `WorktreeGroupManagerStatusTests.swift`, and a name query needs a worktree whose config can be
  written — which is the new suite's fixture. The four existing `matches` cases (branch, task
  title, group name, status name) are unchanged and still green.
- *`GitRepoFixture` gained three seeding helpers beyond T1's set.* `reconcile` must be proved to
  publish a name this manager never wrote, so the test seeds `config.worktree` directly, which
  needs the extension enabled by something other than the store.
- *`WorktreeGroupManagerTestCase` gained a `prepareProjectRoot()` hook* rather than a parallel base
  class: the repository has to exist before the manager is constructed over it, and the hook is
  three lines against a duplicated `setUp`/`tearDown` pair.
- *Tests poll rather than sleep.* The suite's existing convention is a fixed `Task.sleep`, but a
  name write is a git subprocess behind a first-call bootstrap, so the assertions poll to a 5s
  deadline and fail with the last value read. The two cases that must prove a *later* write does
  not land — main ignored, and the race — keep a fixed sleep, because there is nothing to poll for.

**Gate**

`./scripts/ci.sh` — `Executed 492 tests, with 0 failures (0 unexpected) in 71.705 seconds`,
`==> CI passed.` Re-run after the chain-await was restored. No SwiftLint output for any touched
file; `WorktreeGroupManager.swift` is 420 lines, under the 700-line warning.

### T5: Statuses move to worktree config, and `groups.json` stops carrying them

**What landed**

| File | State |
| --- | --- |
| `Sources/App/WorktreeGroupStore.swift` | `WorktreeGroupsPayload` drops `statuses` from its properties, its `CodingKeys` and its memberwise initialiser, and gains `legacyStatuses`, populated only by `init(from:)` through a private `LegacyCodingKeys`. The lenient contract is unchanged. The bare-array fallback in `load()` and `.empty` use the three-argument initialiser. |
| `Sources/App/WorktreeGroupManager.swift` | `setStatus` requires a path, publishes optimistically and enqueues a `WorktreeConfigStore.set` on the write chain instead of calling `save()`. `reloadConfig(for:)` builds `statuses` in the same pass as `names`, dropping an unrecognised slug. `reconcile(_:)` loses its status-pruning branch. `save()` stops passing statuses. `init` calls the new `migrateLegacyStatuses(_:)`. The watcher's reload closure no longer compares or assigns `statuses`. |
| `Sources/App/WorktreeStatus.swift` | Two doc comments only: the slugs are `clearway.status` in worktree config, not `groups.json`. |
| `Tests/WorktreeGroupManagerStatusTests.swift` | Re-pointed at `WorktreeGroupManagerGitTestCase`. Persistence cases read `git config --worktree --get clearway.status`; `groupsFileExists` probes became "writes no status into the file". Three new cases: the migration, the migration skipping a vanished path, and a file that never carried the key. |
| `Tests/WorktreeGroupStoreTests.swift` | `legacyStatuses` replaces `statuses` in the decode cases; `testPayloadRoundTripsStatusesAndGrouping` became `testPayloadRoundTripsGrouping`; new `testEncodeOmitsTheStatusesKey` asserts over encoded bytes. |
| `Tests/TestHelpers.swift` | `WorktreeGroupManagerTestCase` gains `groupsFilePath`, which `groupsFileExists` now uses. |

**Evidence**

The suite was rewritten first and `./scripts/ci.sh` run against the unchanged manager and store.
Twelve failures in `WorktreeGroupManagerStatusTests`, eleven of them the intended reds:

```
✖ testSetStatusPublishesAndPersistsToWorktreeConfig, XCTAssertEqual failed:
  ("nil") is not equal to ("Optional("inReview")") - stored status at …/.worktrees/feature
✖ testSetStatusPublishesAndPersistsToWorktreeConfig, XCTAssertFalse failed
  - a status must write nothing into groups.json
✖ testSetStatusNilClearsThePublishedEntryAndTheStoredKey, XCTAssertEqual failed:
  ("nil") is not equal to ("Optional("done")")
✖ testLegacyStatusesMigrateIntoWorktreeConfigAndLeaveTheFile, XCTAssertEqual failed:
  ("nil") is not equal to ("Optional("onHold")")
✖ testLegacyStatusesMigrateIntoWorktreeConfigAndLeaveTheFile, XCTAssertEqual failed:
  ("true") is not equal to ("false") - groups.json still carries statuses
✖ testLegacyMigrationSkipsAPathThatNoLongerExists, XCTAssertEqual failed:
  ("nil") is not equal to ("Optional("inReview")")
✖ testLegacyMigrationSkipsAPathThatNoLongerExists, XCTAssertEqual failed:
  ("true") is not equal to ("false") - groups.json still carries statuses
✖ testReconcilePopulatesStatusesFromWorktreeConfig, XCTAssertEqual failed:
  ("[:]") is not equal to ("[".../.worktrees/alive": Clearway.WorktreeStatus.inReview]")
✖ testReconcileDropsAnAbsentWorktreeWithoutSaving, XCTAssertEqual failed:
  ("nil") is not equal to ("Optional("onHold")")
✖ testReconcileDropsAnAbsentWorktreeWithoutSaving, XCTAssertFalse failed
  - reconcile no longer saves a status prune
✖ testExternalWriteRepublishesGroupingAndIgnoresAStatusesKey, XCTAssertTrue failed
  - the watcher no longer republishes statuses from the file
Executed 19 tests, with 12 failures (0 unexpected) in 56.811 seconds
```

The twelfth was not planned for and is a finding of its own:

```
✖ testStatusGroupingStablyPartitionsTheBaseOrder, XCTAssertEqual failed:
  ("["/tmp/main", "/tmp/alpha", "/tmp/bravo", "/tmp/charlie", "/tmp/delta"]") is not equal to
  ("["/tmp/main", "/tmp/delta", "/tmp/bravo", "/tmp/alpha", "/tmp/charlie"]")
```

Rewriting the case dropped the fixed `Task.sleep` the old code needed between consecutive
`setStatus` calls, because the new `setStatus` publishes synchronously. Under the *old* code three
saves in one turn raced the store's own watcher, whose reload closure then republished a stale
`statuses` map over the in-memory one and the partition came back unpartitioned. That is the
behaviour this task removes — the watcher no longer touches `statuses` — so the case passes on the
implemented tree with no sleep at all.

**Deviations from the plan**

- *`setStatus` requires `wt.path`, not just `!wt.isMain`.* The plan said it "keeps its main guard";
  a config write needs a directory, so the guard is `guard !wt.isMain, let path = wt.path`, the
  shape `setName` already has. A worktree with no path has `id == branch ?? ""`, which was never a
  writable target.
- *`WorktreeGroupManagerStatusTests` keeps synthetic paths for the ordering and `matches` cases.*
  Only the cases that assert on stored state build a real worktree. A status set against
  `/tmp/alpha` still publishes; its write fails inside `git` and is logged, which is exactly the
  optimistic-publish contract, and adding four `git worktree add` calls per ordering case would buy
  nothing.
- *Criterion 6 is pinned twice.* `testInitLoadsAFileThatNeverCarriedStatuses` at the manager
  joins the store's decode case, because the old `testInitLoadsStatusesAndGrouping` was the only
  thing standing between a relaunch and a `grouping` reset and its replacement had to keep that job.
- *`testEncodeOmitsTheStatusesKey` encodes a payload decoded from legacy bytes*, so the assertion
  covers both halves of decision 14 at once: a non-empty `legacyStatuses` is what would leak if the
  key were still in `CodingKeys`.

**Gate**

`./scripts/ci.sh` — `Executed 498 tests, with 0 failures (0 unexpected) in 84.706 seconds`,
`==> CI passed.` Run after the last edit. `swiftlint lint --quiet` prints nothing for any touched
file; `WorktreeGroupManager.swift` is 455 lines, under the 700-line warning.
`ShellPathResolverTests` did not flake on this run. `git status --porcelain` before the commit
showed the six modified files and nothing untracked.

### T6: Row-text precedence and the sidebar row

**What landed**

| File | State |
| --- | --- |
| `Sources/App/WorktreeRow.swift` | Gains `static func rowTexts(for:name:taskTitle:)`, the pure precedence: a name non-empty after trimming wins, else the task title, else `(nil, nil)`; the winner's subtitle is `wt.displayName`. The view body and both badges are untouched. |
| `Sources/App/SidebarView.swift` | The private `rowTexts(for:titles:)` is deleted; `worktreeRowView` calls the static with `groupManager.name(for: wt)` and `wt.branch.flatMap { titles[$0] }`. Nothing else changed. 668 → 658 lines. |
| `Tests/WorktreeRowTests.swift` | New. `WorktreeRowTextTests`, seven cases covering criteria 1–5 plus an empty-name-and-no-title case and a detached worktree. |
| `Clearway.xcodeproj/project.pbxproj` | Regenerated by `xcodegen` for the new test file. |

**Evidence**

The suite was written before the static existed. `./scripts/ci.sh` on that tree:

```
❌ Tests/WorktreeRowTests.swift:9:33: type 'WorktreeRow' has no member 'rowTexts'
❌ Tests/WorktreeRowTests.swift:19:33: type 'WorktreeRow' has no member 'rowTexts'
… (5 more, one per test method)
** TEST FAILED **
```

A compile failure is the only red available: the old private `rowTexts` had no name parameter, so
no call of the new shape could reach it, and the precedence it implemented (task title or nothing)
is exactly what this task replaces. Criteria 1, 3 and 5 are the behaviour the old method did not
have; criteria 2 and 4 are the behaviour it did, carried over and now pinned.

**Deviations from the plan**

- *Two cases beyond the plan's five.* `testAnEmptyNameAndNoTaskTitleLeavesBothNil` pins that an
  empty name does not become an empty-string primary text with a subtitle behind it, which the
  plan's whitespace case cannot catch because it has a task title to fall through to.
  `testADetachedWorktreeSubtitlesWithItsDisplayName` pins that the subtitle is `displayName`, not
  `branch`: a named detached worktree would otherwise subtitle with the empty string, and
  `WorktreeRow`'s body collapses to one line when the subtitle is empty, silently dropping the
  branch line for exactly the rows CLAUDE.md says stay visible.
- *The helper takes `name: String?` and does its own trimming* rather than trusting
  `WorktreeGroupManager.name(for:)`, which already refuses an empty stored value. The manager is
  one of two callers — the tests are the other — and a pure rule that depends on its caller having
  filtered first is not testable on its own terms.

**Gate**

`./scripts/ci.sh` — `Executed 505 tests, with 0 failures (0 unexpected) in 85.285 seconds`,
`==> CI passed.` Run after the last edit. `swiftlint lint --quiet` prints nothing for either
touched file. `ShellPathResolverTests` did not flake on this run. `git status --porcelain` before
the commit showed three modified files and the one new test file, nothing else untracked.
