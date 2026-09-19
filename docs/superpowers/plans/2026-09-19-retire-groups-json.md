# Plan: Retire groups.json

**Date:** 2026-09-19
**Base:** ec12656 (`Name a worktree when you create it, and store it in git config (#226)`)

Breaks down `docs/superpowers/specs/2026-09-19-retire-groups-json.md`. Every design decision below
is carried from that spec; this document only orders the work and says how each piece is verified.

## Architecture decisions carried from the spec

1. A group is identified by its **name**: unique per repo, non-empty, compared exactly
   (case-sensitive). `UUID` and `createdAt` go away; display order is creation order with new
   groups appended. (Decision 1.)
2. The **group registry** is a repo-level multivar, `clearway.groupOrder`, one value per group name
   in creation order, written with `git config --local`. The **grouping mode** is the repo-level
   `clearway.grouping` (`group` / `status` / `none`). (Decisions 3, 6.)
3. A worktree's **group membership** and **sidebar position** live in its own `config.worktree`:
   `clearway.group` (absent means ungrouped) and `clearway.position` (a decimal integer, absent
   means not yet ordered). Main is never grouped and never carries a position. (Decisions 2, 6.)
4. The two worktree-scope keys are **single lowercase words** because `git config --list`
   lowercases key names and `WorktreeConfigStore.parseList` keys its dictionary on what git
   printed. The repo-level keys are read with `--get`/`--get-all`, which return values only, so
   `clearway.groupOrder` may keep its camel case. (Decision 7.)
5. `git config --local` reaches the **same shared `.git/config` from every worktree**, so one
   process reads the registry for the whole project wherever `projectPath` points. (Decision 8.)
6. The registry is rewritten **whole** on every create, rename and delete: `--unset-all`, then one
   `--add` per name in order. Never `--replace-all` or a value-regex — a group name is arbitrary
   user text. (Decision 9.)
7. **The registry is written last.** A rename publishes at once, then one write-chain job rewrites
   every member's `clearway.group` and only then the registry; a delete unsets every member first,
   then rewrites the registry. A wholly failed rename or delete changes nothing on disk.
   (Decisions 10, 12.)
8. A worktree naming a group the registry does not list **renders ungrouped**. The registry is the
   only source of which groups exist. Nothing prunes a stale `clearway.group` or
   `clearway.position`. (Decisions 11, 18.)
9. A section's order is its worktrees by `clearway.position` ascending, then `Worktree.sorted`
   order for those without one and as the tie-break. A drag **reassigns exactly the position
   values the rendered rows already occupied**, so a row hidden by the detached filter or the
   search field keeps its slot; only rows whose value changed are written. (Decision 13.)
10. New worktrees get a position from the successor to `seedDefaultOrder`, at the same
    `ContentView` call site: every non-main worktree without one is assigned in `Worktree.sorted`
    order. A row that reaches a drag still without one takes the section's maximum plus one.
    (Decision 14.)
11. A drop into a group sets `clearway.group` and `clearway.position` = that group's maximum plus
    one. A drop onto the Worktrees header unsets `clearway.group` and appends to the ungrouped
    section the same way. Two keys, one write-chain job. (Decision 15.)
12. **The repo-level writes go through the same `enableExtension()` gate** as the per-worktree
    ones, and reads answer empty while the extension is off. Operator-confirmed since the spec.
    (Decision 16.)
13. A load costs **two extra processes**: `--local --get clearway.grouping` and
    `--local --get-all clearway.groupOrder`. Membership and position arrive in the
    `--worktree --list` read `reloadConfig` already performs per worktree. (Decision 17.)
14. The duplicate-name rule is a pure `static` on `WorktreeGroup`: trim, reject empty, reject a
    name the registry already holds unless it is the group being renamed. `NameEntrySheet`'s
    `allowsEmptyName` becomes an `isValid: (String) -> Bool` its confirm button reads.
    (Decision 19.)
15. `WorktreeGroup` keeps **only its name**, derives `id` from it, and drops `Codable`, `UUID`,
    `createdAt`, `sortedByCreation` and `worktreeIds`. Membership becomes a published
    `[worktreeId: String]` map on the manager, the shape `names` and `statuses` already have.
    (Decision 20.)
16. The `deduplicated` guard goes with its two tests: `clearway.group` is a single value per
    worktree, so the sections are disjoint by construction. (Decision 21.)
17. `WorktreeStatus` and `WorktreeGrouping` drop `Encodable` and the comments explaining it.
    (Decision 22.)
18. **Nothing is migrated.** An existing `groups.json` is neither read nor deleted, the
    `legacyStatuses` migration goes with the store, and groups, order and grouping start empty.
    (Decision 4.)
19. **Nothing watches git config.** Values are re-read when the worktree list changes.
    (Decision 5.)
20. The non-git manager test base does not survive: `WorktreeGroupManagerTestCase` merges into
    `WorktreeGroupManagerGitTestCase`, and its fixed 100 ms `setUp` sleep is replaced by the
    `waitFor` polling the git suites already use. (Decision 23.)

## Decisions this plan makes that the spec left open

These are implementation shapes the spec did not fix. They are recorded here so seven independent
build agents produce one design.

- **The repo-level reads pass `--null`.** git-config(1) documents `--null` for "all options that
  output values", so `--get` and `--get-all` terminate each value with NUL instead of a newline.
  Spec assumption 4 requires a group name containing a newline to round-trip, and line-splitting
  `--get-all` output would break exactly that name. The per-worktree read already uses `--null`.
- **`WorktreeConfigStore` gains a repo-level pair beside the per-worktree pair**, not a second
  type: `localValues(forKey:)` / `setLocal(_:forKey:)` / `replaceLocalValues(_:forKey:)`, with the
  same `ExtensionState` gate, the same `GitOutcome` handling and the same "a refusal is an answer"
  rule. Argument building and parsing stay pure `static`s.
- **The position permutation reuses `repositioned`.** `WorktreeGroupManager.repositioned` already
  implements decision 13 over an id array; the new code keeps it, applies it to the section's
  stored id order, and then zips the section's existing position values back onto the permuted
  order. That is one new pure `static` — `reassignedPositions` — and the existing `repositioned`
  tests carry over unchanged.
- **Group identity flips to the name one task before the storage moves.** The manager's public API
  (`renameGroup(named:to:)`, `deleteGroup(named:)`, `addWorktree(_:toGroupNamed:)`,
  `groupName(for:)`, `setGroupOrder(named:ids:)`) and the sidebar's `@State` become name-keyed
  while `groups.json` is still the store. This is what keeps the storage cutover inside five
  files. It is safe only because the uniqueness rule (T2) lands first.
- **Manager tests assert through the public API, never through the storage array.** T4 rewrites
  the ordering assertions to read `sidebarOrderedWorktrees` and `groupName(for:)` instead of
  `manager.defaultOrder` and `groups[i].worktreeIds`, so T5 can replace the storage without
  touching them.
- **Tests for behaviour this change deletes are removed in T3**, before the behaviour goes: the
  `groups.json` round-trip, the legacy-status migration block, the two duplicate-row cases and the
  membership half of `reconcile`. The net they provide is worthless two tasks later and keeping
  them would push T4 and T5 past five files each.

## Preconditions

- The spec and this plan are untracked at the time of writing. They belong in the first build
  task's commit.
- A Debug launch drops an un-gitignored `default.profraw` in the repo root. Never `git add -A`.

## Regression command

```bash
./scripts/ci.sh
```

The only runner of the test suite and the only command that runs `xcodegen generate`, without
which a deleted or added Swift file is invisible to the build. It is the regression check for
every task below. Lint alone is `swiftlint lint --quiet`.

## Dependency graph

```
T1 (config store: repo scope) ──────────────┐
                                            │
T2 (name rule + NameEntrySheet.isValid) ─┐  │
                                         ├──┤
T3 (test bases merge; retired cases go) ─┘  │
                                         │  │
                                         ▼  ▼
                              T4 (identity becomes the name)
                                         │
                                         ▼
                              T5 (storage cutover; store deleted)
                                         │
                            ┌────────────┴────────────┐
                            ▼                         ▼
                 T6 (persistence tests)        T7 (docs and strays)
```

T1, T2 and T3 are independent and can run in parallel. T4 needs T2 and T3. T5 needs T1 and T4.
T6 and T7 are independent of each other and both need T5.

## Task list

### T1: Repo-scope git config in `WorktreeConfigStore`

**Files touched**

- `Sources/App/WorktreeConfigStore.swift`
- `Tests/WorktreeConfigStoreTests.swift`

**What it does**

Adds the repo-level half of the store beside the per-worktree half. Nothing else in the file
changes: the `ExtensionState` cache, `GitOutcome`, `run` and `log` are reused as they are.

Key constants:

```swift
static let groupKey = "clearway.group"
static let positionKey = "clearway.position"
static let groupingKey = "clearway.grouping"
static let groupOrderKey = "clearway.groupOrder"
```

`groupKey` and `positionKey` are single lowercase words on purpose (carried decision 4) — a
comment says so, because a later camel-case rename would silently stop `parseList` finding them.

Pure `static`s, tested without a repository:

```swift
static func localGetArgs(key: String) -> [String]
static func localGetAllArgs(key: String) -> [String]
static func localSetArgs(key: String, value: String) -> [String]
static func localAddArgs(key: String, value: String) -> [String]
static func localUnsetAllArgs(key: String) -> [String]
static func parseNullSeparated(_ output: String) -> [String]
```

They produce, respectively, `["git", "config", "--local", "--get", "--null", key]`,
`["git", "config", "--local", "--get-all", "--null", key]`,
`["git", "config", "--local", key, value]`,
`["git", "config", "--local", "--add", key, value]` and
`["git", "config", "--local", "--unset-all", key]`. No `-C`: these commands run in `projectPath`,
which is where `run` already puts them. `parseNullSeparated` splits on `\0` and drops the trailing
empty record, so a value containing newlines survives whole.

Async surface:

```swift
func localValues(forKey key: String) async -> [String]?
func localValue(forKey key: String) async -> String?
@discardableResult func setLocal(_ value: String?, forKey key: String) async -> Bool
@discardableResult func replaceLocalValues(_ values: [String], forKey key: String) async -> Bool
```

- `localValues` answers `[]` when the extension is off (carried decision 12), `nil` when git could
  not answer, `[]` on a refusal (`--get-all` exits 1 for an absent key), and the parsed values
  otherwise. `localValue` is `localValues(...)?.first` over `--get`.
- `setLocal` with a `nil` or empty value runs `--unset-all` and treats exit 5 as success, exactly
  as `set` does; with a value it runs `enableExtension()` first and then the plain set. It is for
  single-valued keys only — a comment says so.
- `replaceLocalValues` runs `enableExtension()`, then `--unset-all`, then one `--add` per value in
  order, and returns false at the first failure. An empty array leaves the key unset.

**Acceptance criteria**

1. The five arg builders return exactly the arrays above, and `parseNullSeparated` returns
   `["a\nb", "c"]` for `"a\nb\0c\0"`.
2. Against a `GitRepoFixture`: `replaceLocalValues(["one", "two"], forKey: groupOrderKey)` then
   `localValues(forKey: groupOrderKey)` returns `["one", "two"]` in that order; a second call with
   `["two"]` leaves exactly one value; a name containing regex metacharacters (`a.*b[0]` and a
   name containing a space) round-trips unharmed.
3. `setLocal("status", forKey: groupingKey)` then `localValue(forKey: groupingKey)` returns
   `"status"`; `setLocal(nil, forKey: groupingKey)` clears it and returns true, and a second clear
   of the now-absent key also returns true.
4. With `extensions.worktreeConfig` off, `localValues` and `localValue` answer empty **without**
   the values being read, and the first `replaceLocalValues` enables the extension (the
   `core.bare` bootstrap runs) and then writes.
5. The values land in the main repository's `.git/config` and are readable from a linked worktree
   created by the fixture.

**Verification**

`./scripts/ci.sh` green, with the new cases in `Tests/WorktreeConfigStoreTests.swift` present in
the run.

**Estimated scope:** Medium (2 files).

---

### T2: The group-name rule and `NameEntrySheet.isValid`

**Files touched**

- `Sources/App/WorktreeGroup.swift`
- `Sources/App/SidebarSheets.swift`
- `Sources/App/SidebarView.swift`
- `Tests/WorktreeGroupTests.swift` (new)

**What it does**

Adds the pure availability rule and makes the sheet enforce it. The model is otherwise untouched
in this task — `WorktreeGroup` keeps its `UUID`, `worktreeIds` and `createdAt` until T5.

```swift
extension WorktreeGroup {
    /// Whether `name` may be created, or renamed to. `renaming` is the current name of the group
    /// being renamed, which is allowed to keep its own name.
    static func isNameAvailable(_ name: String, in existing: [String], renaming: String? = nil) -> Bool
}
```

It trims whitespace and newlines, rejects an empty result, and rejects an exact
(case-**sensitive**) match in `existing` unless that match is `renaming`. A name differing only in
case is available.

`NameEntrySheet` swaps `allowsEmptyName: Bool` for `isValid: (String) -> Bool`, defaulting to a
non-empty-after-trim rule so the Rename Worktree call site keeps today's behaviour without passing
anything. The confirm button's `.disabled` reads `!isValid(name)`.

The two group call sites in `SidebarView` pass the rule:

- New Group: `isValid: { WorktreeGroup.isNameAvailable($0, in: groupManager.groups.map(\.name)) }`
- Rename Group: the same with `renaming: group.name`.

Rename Worktree (`SidebarView.swift:145`) passes an `isValid` that accepts everything, since
clearing a worktree's name is how it is removed — today's `allowsEmptyName: true` call.

**Acceptance criteria**

1. `isNameAvailable` accepts `"Backlog"` against `[]`, rejects `""` and `"   "`, rejects
   `"Backlog"` against `["Backlog"]`, accepts `"backlog"` against `["Backlog"]`, accepts
   `"Backlog"` against `["Backlog"]` when `renaming: "Backlog"`, and rejects `" Backlog "`
   against `["Backlog"]` (it trims first).
2. `NameEntrySheet` has no `allowsEmptyName` parameter left, and every call site compiles.
3. `swiftlint lint --quiet` reports no new error.

**Verification**

`./scripts/ci.sh` green with `Tests/WorktreeGroupTests.swift` in the run. The sheet behaviour
itself is not reachable from XCTest — that is why the rule is a `static` — so the criterion for it
is the compile plus the operator's own check.

**Estimated scope:** Medium (4 files).

---

### T3: One git-backed manager test base; retired cases deleted

**Files touched**

- `Tests/TestHelpers.swift`
- `Tests/WorktreeGroupManagerTests.swift`
- `Tests/WorktreeGroupManagerStatusTests.swift`
- `Tests/WorktreeGroupStoreTests.swift` (deleted)

**What it does**

Clears the test ground before the source changes, so T4 and T5 each stay inside five files.

1. Deletes `Tests/WorktreeGroupStoreTests.swift` whole. The store it covers is deleted in T5 and
   nothing in this change preserves its behaviour.
2. Deletes `GroupsFile` (`TestHelpers.swift:174-189`) and the `groupsFilePath` / `groupsFileExists`
   properties.
3. Merges `WorktreeGroupManagerTestCase` into `WorktreeGroupManagerGitTestCase`: one base, which
   builds the `GitRepoFixture` over the scratch root and then the manager. `WorktreeGroupManagerTests`
   changes its superclass to it. The fixed `try await Task.sleep(nanoseconds: 100_000_000)` in
   `setUp` goes; a test that needs the initial load to have happened uses `waitFor`, which already
   lives on the surviving base. `prepareProjectRoot()` collapses into `setUp` since there is now
   one subclass shape.
4. Deletes the cases whose behaviour this change removes:
   - `WorktreeGroupManagerTests.testRoundTripPersistsToDisk` (`:46`) — asserts the `groups.json`
     round trip.
   - `testReconcileDropsPhantomIds` (`:156`) and `testReconcileNoOpWhenNoPruningNeeded` (`:186`) —
     `reconcile` stops pruning membership (carried decision 8).
   - `testDuplicateStoredDefaultOrderDoesNotDuplicateRows` (`:508`) and
     `testIdStoredInTwoGroupsDoesNotDuplicateRows` (`:527`) — the `deduplicated` guard goes
     (carried decision 16).
   - `WorktreeGroupManagerStatusTests`' whole "The one-shot groups.json migration" block
     (`:75-177`) and its `groupsFileExists` assertion at `:20`.
   The `reconcile` cases in `WorktreeGroupManagerStatusTests` (`:178-229`) and
   `WorktreeGroupManagerNameTests` stay: they assert the config **reload**, which survives.

Nothing in `Sources/` changes. `WorktreeGroupStore` is briefly untested; it is deleted in T5.

**Acceptance criteria**

1. `Tests/WorktreeGroupStoreTests.swift` no longer exists and
   `grep -rn "WorktreeGroupStoreTests\|GroupsFile\|groupsFileExists" Tests` returns nothing except
   the comment in `WorkTaskManagerWatcherTests.swift:7` (T7 removes that one).
2. Exactly one manager base class remains, it is git-backed, and it contains no
   `Task.sleep`-based `setUp`.
3. The three manager suites compile against it and pass.

**Verification**

`./scripts/ci.sh` green. Confirm in its output that the three manager suites still run (the merge
must not silently drop a suite).

**Estimated scope:** Medium (4 files).

---

### T4: Group identity becomes the name

**Files touched**

- `Sources/App/WorktreeGroupManager.swift`
- `Sources/App/SidebarView.swift`
- `Sources/App/SidebarSheets.swift`
- `Tests/WorktreeGroupManagerTests.swift`
- `Tests/WorktreeGroupManagerStatusTests.swift`

**Depends on:** T2 (the uniqueness rule must exist before a name is used as a key), T3.

**What it does**

Flips every group-identity parameter from `UUID` to the group's name. `groups.json` is still the
store and `WorktreeGroup` still carries its `UUID`, `worktreeIds` and `createdAt` — only the
public API and the view state change.

Manager:

- `renameGroup(named:to:)`, `deleteGroup(named:)`, `addWorktree(_:toGroupNamed:)`,
  `setGroupOrder(named:ids:)`, `groupName(for worktreeId: String) -> String?`.
- `createGroup(named:)` trims and refuses a name `WorktreeGroup.isNameAvailable` rejects, so the
  name-keyed lookups cannot be ambiguous even if a call site forgets to check.
- `removeWorktreeFromAllGroups(_ worktreeId:)` becomes `removeWorktreeFromGroup(_ wt: Worktree)`.
  It takes a `Worktree` because T5 writes two config keys for it and needs `wt.path`; making the
  shape change here keeps `SidebarView` out of T5's file list.
- `setDefaultOrder(_:)` becomes `setUngroupedOrder(_:)`. `seedDefaultOrder` keeps its name until
  T5, so `ContentView` is untouched here.
- The no-op guard in `addWorktree` — "already in the target group" — is preserved verbatim with
  its comment. Dropping it crashes the backing `NSTableView` mid-drag.

`SidebarView`: `createWorktreeTargetGroupId`, `groupToRename`, `groupToDelete` and
`targetedGroupId` become name-based (`targetedGroupName: String?`; the two sheet-item states stay
`WorktreeGroup?`), `Dictionary(grouping: ordered) { groupManager.groupName(for: $0.id) }`,
`byGroup[group.name]`, `dropIntoGroup(_:groupNamed:)`. The `.group` branch of
`dropIntoWorktreesHeader` routes through `withDroppedWorktrees` so it hands
`removeWorktreeFromGroup` a `Worktree`; that helper already defers to the next main-queue turn, so
the mid-drag deferral the current `DispatchQueue.main.async` provides is preserved.

`SidebarSheets`: `CreateWorktreeSheet.targetGroupId: UUID?` becomes `targetGroupName: String?`.

Tests: the two manager suites are rewritten to call the new API **and** to assert through
`sidebarOrderedWorktrees` and `groupName(for:)` rather than through `manager.defaultOrder` or
`groups[i].worktreeIds`, so T5 can change the storage without touching them. The `repositioned`
cases (`:435-507`) keep their assertions, expressed as the order `sidebarOrderedWorktrees` returns.

**Acceptance criteria**

1. `grep -rn "UUID" Sources/App/SidebarView.swift Sources/App/SidebarSheets.swift` returns nothing
   group-related.
2. `createGroup(named: "Backlog")` twice leaves one group; `createGroup(named: "  ")` creates none.
3. No manager test reads `manager.defaultOrder` or a group's `worktreeIds`.
4. Sidebar behaviour is unchanged: the existing ordering, search-filter, section and detached-filter
   cases pass as they did.

**Verification**

`./scripts/ci.sh` green.

**Estimated scope:** Large (5 files) — the single widest task; its safety comes from T3 having
already removed the cases that would otherwise be rewritten twice.

---

### T5: Storage moves to git config; `WorktreeGroupStore` is deleted

**Files touched**

- `Sources/App/WorktreeGroup.swift`
- `Sources/App/WorktreeGroupManager.swift`
- `Sources/App/WorktreeGroupStore.swift` (deleted)
- `Sources/App/WorktreeStatus.swift`
- `Sources/App/ContentView.swift`

**Depends on:** T1, T4.

**What it does**

`WorktreeGroup` becomes `struct WorktreeGroup: Identifiable, Hashable { var name: String }` with
`var id: String { name }`. `Codable`, `UUID`, `createdAt`, `worktreeIds` and `sortedByCreation` go.
`isNameAvailable` from T2 stays.

`WorktreeStatus` and `WorktreeGrouping` drop `Encodable` and the two comments explaining why they
had it.

`Sources/App/WorktreeGroupStore.swift` is deleted, taking `WorktreeGroupsPayload`, both
`DispatchSource` watchers and the file-descriptor leak with it.

`WorktreeGroupManager` published state:

```swift
@Published private(set) var groups: [WorktreeGroup] = []          // registry order
@Published private(set) var groupNames: [String: String] = [:]    // worktreeId -> group name
@Published private(set) var positions: [String: Int] = [:]        // worktreeId -> position
@Published private(set) var statuses: [String: WorktreeStatus] = [:]
@Published private(set) var names: [String: String] = [:]
@Published private(set) var grouping: WorktreeGrouping = .group
```

`defaultOrder` and `save()` go. So do `store`, `deinit`, `migrateLegacyStatuses` and
`deduplicated`. `loadTask` stays and now reads `clearway.grouping` and `clearway.groupOrder`
through the config store. `enqueueWrite` and `writeChain` stay exactly as they are and carry every
new write.

Reads:

- `reloadConfig(for:)` keeps its bracketing of the write chain and gains the two repo-level reads
  beside the per-worktree ones.
- `readConfig` also pulls `clearway.group` and `clearway.position` out of the same
  `--worktree --list` output it already reads (no new process per worktree). A membership naming a
  group the registry does not list is dropped when publishing (carried decision 8). A
  `clearway.position` that is not a decimal integer is dropped. A worktree whose read answered
  `nil` keeps its published membership and position, the rule already applied to name and status.

Writes — each publishes optimistically, then enqueues one job on `writeChain`:

| Gesture | Published | Written |
| --- | --- | --- |
| `createGroup(named:)` | append to `groups` | registry rewrite |
| `renameGroup(named:to:)` | rename in `groups`, rewrite `groupNames` | every member's `clearway.group`, **then** the registry, and only if every member write returned true |
| `deleteGroup(named:)` | drop from `groups`, drop its memberships | unset every member's `clearway.group`, **then** the registry |
| `addWorktree(_:toGroupNamed:)` | membership + position = target section max + 1 | `clearway.group` and `clearway.position` on that worktree |
| `removeWorktreeFromGroup(_:)` | drop membership + position = ungrouped max + 1 | unset `clearway.group`, set `clearway.position` |
| `setUngroupedOrder(_:)` / `setGroupOrder(named:ids:)` | the changed positions | one `clearway.position` per changed worktree |
| `seedPositions(for:openIds:)` | positions for non-main worktrees without one | one `clearway.position` each |
| `setGrouping(_:)` | `grouping` | `clearway.grouping` |

Ordering, as one new pure `static` beside the retained `repositioned`:

```swift
static func reassignedPositions(
    section: [(id: String, position: Int?)],   // the section in current display order
    newOrder: [String]                          // the rendered rows in their new order
) -> [String: Int]
```

It applies `repositioned` to `section.map(\.id)`, then zips the section's occupied position values
— ascending, with each `nil` filled by the next integer above the section's maximum, in display
order — back onto the permuted ids, and returns only the entries whose value changed.

`sidebarOrderedWorktrees` sections by `groupNames` and orders each section by `positions` ascending
with `Worktree.sorted` as the fallback and tie-break. `groups` is already in registry order, so
nothing sorts it. The `deduplicated` call goes.

`seedDefaultOrder(with:openIds:)` becomes `seedPositions(for:openIds:)`; `ContentView.swift:331`
follows the rename and adds no line — the file is past SwiftLint's `file_length` error and lives
on a file-wide disable.

`reconcile(_:)` becomes the config reload alone.

**Acceptance criteria**

1. `Sources/App/WorktreeGroupStore.swift` no longer exists, and
   `grep -rn "WorktreeGroupsPayload\|startWatching" Sources` returns nothing.
2. `WorktreeGroup` has one stored property. `WorktreeStatus` and `WorktreeGrouping` declare no
   `Encodable`.
3. No `.clearway/` path is constructed anywhere in `WorktreeGroupManager`.
4. `reassignedPositions` returns only changed entries, and a row the caller omitted keeps the
   position it had. (Pinned by the reorder cases T4 rewrote, plus a direct case on the `static`.)
5. The whole existing suite passes, including the reorder, sectioning, search and detached-filter
   cases.

**Verification**

`./scripts/ci.sh` green. `ci.sh` is mandatory here rather than a hand-written `xcodebuild` line:
a deleted Swift file is invisible to the build until `xcodegen generate` runs.

**Estimated scope:** Large (5 files).

---

### T6: Persistence tests

**Files touched**

- `Tests/WorktreeGroupPersistenceTests.swift` (new)
- `Tests/TestHelpers.swift`

**Depends on:** T5.

**What it does**

Proves the spec's success criteria against real git. `GitRepoFixture` gains one reader,
`localValues(ofKey:) throws -> [String]`, running `config --local --get-all --null`, and the new
suite sits on the merged manager base from T3.

Cases:

1. **Registry survives a relaunch.** Create two groups, wait for the writes, build a second
   manager over the same root, and assert `groups` comes back in creation order.
2. **Membership and position survive a relaunch.** Add a worktree to a group and reorder within
   it; a second manager renders the same order.
3. **Rename rewrites members and the registry.** After a rename, every member's `clearway.group`
   names the new group and `localValues(ofKey: "clearway.groupOrder")` holds the new name in the
   old slot.
4. **Delete unsets members first.** After a delete, no worktree holds a `clearway.group` and the
   registry no longer lists the name.
5. **A membership naming an unlisted group renders ungrouped.** Write `clearway.group = "Ghost"`
   into a worktree directly through the fixture, reload, and assert the row appears in the
   ungrouped section and no phantom section exists.
6. **`git worktree remove` leaves nothing.** Remove a grouped, positioned worktree through the
   fixture, reload, and assert it is gone from the sidebar order and that no remaining worktree
   carries its keys.
7. **Grouping mode round-trips**, including `.none`.
8. **No `.clearway/` directory is created** by any of the above.
9. **A project where the extension cannot be enabled shows no groups.** Build a manager over a
   plain (non-repository) temp directory, create a group, and assert nothing crashes and a second
   manager over the same directory shows no groups. This is the one case the deleted non-git base
   used to cover.

**Acceptance criteria**

Every case above present and passing, each reading git through `GitRepoFixture` rather than
through the manager it is testing.

**Verification**

`./scripts/ci.sh` green with `WorktreeGroupPersistenceTests` in the run.

**Estimated scope:** Medium (2 files).

---

### T7: Documentation and the last `groups.json` references

**Files touched**

- `CLAUDE.md`
- `Sources/App/SavedCommandStore.swift`
- `Sources/App/WorktreeConfigStore.swift`
- `Tests/WorkTaskManagerWatcherTests.swift`

**Depends on:** T5.

**What it does**

- `CLAUDE.md:272-275` — the `WorktreeGroupStore.openFileWatcher` leak note goes; the leak is gone
  with the file.
- `CLAUDE.md:97` — the safe-`DispatchSource` precedent cites `WorktreeGroupStore`. Replace the
  subject with `ClaudeSessionFiles.makeWatcher`, which the same paragraph already names as the one
  route every `DispatchSource` goes through; the sentence about a `Sendable` type building its own
  sources goes, since no such type is left.
- `CLAUDE.md:203` — `SavedCommandStore` "owns the `.clearway` component itself, the way
  `WorktreeGroupStore` does". Rewrite so it stands alone: `SavedCommandStore` takes the project
  path and owns the `.clearway` component, and `commands.json` is now the only file under it.
- The `Sources/App/` architecture entry gains a `WorktreeGroupManager` paragraph: the four keys
  (`clearway.grouping` and `clearway.groupOrder` repo-level, `clearway.group` and
  `clearway.position` per worktree), the registry-written-last rule, the "membership naming an
  unlisted group renders ungrouped" rule, that nothing prunes and nothing watches, and that the
  two worktree keys must stay single lowercase words because `git config --list` lowercases them.
- `Sources/App/SavedCommandStore.swift:5` — the doc comment's `groups.json` reference.
- `Sources/App/WorktreeConfigStore.swift:8` and `:117` — `:8` cites `WorktreeGroupStore` as the
  shape it copies; `:117` explains `set`'s return value by the `groups.json` migration. Re-point
  `:117` at the rename ordering (carried decision 7), which is now the caller that cannot be
  corrected by the next reload, and drop the `WorktreeGroupStore` mention at `:8`.
- `Tests/WorkTaskManagerWatcherTests.swift:7` — the comment citing
  `WorktreeGroupStoreTests.testWatcherFiresOnExternalWrite`. Keep the 3s timeout, drop the dead
  citation.

Comments are a smell: each edit above replaces or removes a comment that names something gone. Do
not add new prose beyond the `CLAUDE.md` architecture entry, which is the one place the storage
contract has to be written down.

**Acceptance criteria**

1. `grep -rn "groups.json" Sources Tests CLAUDE.md` returns nothing.
2. `grep -rn "WorktreeGroupStore" Sources Tests CLAUDE.md` returns nothing.
3. `CLAUDE.md` names the four keys and the registry-last rule.

**Verification**

The two greps return nothing, and `./scripts/ci.sh` is green.

**Estimated scope:** Medium (4 files).

## Risks

| Risk | Impact | Mitigation |
| --- | --- | --- |
| T4 and T5 are both five-file tasks on the same two files | Medium | T3 removes the test cases that would otherwise be rewritten in both; T4 is deliberately mechanical (identity only, no storage change) so T5's diff is the storage alone. |
| A partly applied rename leaves a worktree naming an unlisted group | Low | Carried decision 8: it renders ungrouped and one more drag repairs it. T6 case 5 pins the rendering. |
| A group name containing a newline breaks the registry read | Low | `--null` on both repo-level reads (plan decision 1); T1 criterion 1 pins the parser. |
| The drag reassignment loses a hidden row's slot | Medium | `reassignedPositions` is a pure `static` over the section's stored order, and the existing reorder cases — rewritten in T4 to assert through `sidebarOrderedWorktrees` — carry over unchanged into T5. |

## Build log

### T1: Repo-scope git config in `WorktreeConfigStore`

**What landed**

| File | State |
| --- | --- |
| `Sources/App/WorktreeConfigStore.swift` | Four key constants (`groupKey`, `positionKey`, `groupingKey`, `groupOrderKey`), five repo-scope arg builders, `parseNullSeparated`, and the async pair `localValues`/`localValue` + `setLocal`/`replaceLocalValues` over a shared `readLocal` and `unsetAllLocal`. The class doc now names both scopes. |
| `Tests/WorktreeConfigStoreTests.swift` | Nine pure cases in `WorktreeConfigArgumentTests` (the five builders, the parser's terminator, empty input, single empty value) and nine integration cases in `WorktreeConfigStoreTests` (order round trip, whole rewrite, regex/space/newline values, empty rewrite, grouping mode set-and-clear-twice, sharing with a linked worktree, extension-off reads, first-write bootstrap). |

The per-worktree half of the file is untouched: `ExtensionState`, `GitOutcome`, `run` and `log` are
reused as they are.

**Git behaviour verified by probe** (git 2.54.0, scratchpad `probe/`, never inside the repo): `--add`
preserves insertion order and `--get-all --null` returns file order NUL-*terminated*; values carrying
`.`, `*`, `[`, `]`, a space and an embedded newline round-trip unharmed; `--get` on an absent key
exits 1, `--get-all` on one exits 1, `--unset-all` on one exits 5.

**Evidence**

Both new rules were watched failing. The parser was reverted to keep the record after the final NUL,
and the extension gate was removed from `readLocal`; `xcodebuild -only-testing` on the two suites
then reported 10 failures where the restored code reports none:

```
testParseNullSeparatedKeepsNewlinesAndDropsTheTerminator : XCTAssertEqual failed:
  ("["a\nb", "c", ""]") is not equal to ("["a\nb", "c"]")
testTheRegistryRoundTripsInOrder : XCTAssertEqual failed:
  ("Optional(["one", "two", ""])") is not equal to ("Optional(["one", "two"])")
testRepoScopeReadsWithTheExtensionOffReturnNothingWithoutReadingTheValues : XCTAssertEqual failed:
  ("Optional(["Backlog", ""])") is not equal to ("Optional([])")
testRepoScopeReadsWithTheExtensionOffReturnNothingWithoutReadingTheValues : XCTAssertNil failed: "status"
     Executed 33 tests, with 10 failures (0 unexpected)
** TEST FAILED **
```

The store was then restored from a scratchpad copy — no `git checkout` or `git stash`.

**Deviations from the plan**

None. `replaceLocalValues` calls `enableExtension()` unconditionally, including for an empty array,
as the plan specifies; `setLocal(nil, ...)` keeps `set`'s extension-off shortcut. The two differ
because only `setLocal` has a caller that clears on a project that never wrote anything.

**Gate**

`./scripts/ci.sh` — green. `Executed 551 tests, with 0 failures (0 unexpected)`, `==> CI passed.`
Both config suites present in the run (16 and 17 tests).

### T2: The group-name rule and `NameEntrySheet.isValid`

**What landed**

| File | State |
| --- | --- |
| `Sources/App/WorktreeGroup.swift` | `static isNameAvailable(_:in:renaming:)` beside `sortedByCreation`. Trims whitespace and newlines, rejects an empty result, rejects an exact case-sensitive match in `existing` unless that match is `renaming`. The model is otherwise untouched — `UUID`, `worktreeIds` and `createdAt` stay until T5. |
| `Sources/App/SidebarSheets.swift` | `NameEntrySheet.allowsEmptyName: Bool` replaced by `isValid: (String) -> Bool`; the confirm button's `.disabled` reads `!isValid(name)`. The type's doc comment names `isValid` as what separates the three call sites. |
| `Sources/App/SidebarView.swift` | Rename Worktree passes `isValid: { _ in true }` (clearing the field is how a worktree name is removed). New Group and Rename Group pass `WorktreeGroup.isNameAvailable` over `groupManager.groups.map(\.name)`, Rename Group with `renaming: group.name`. |
| `Tests/WorktreeGroupTests.swift` (new) | Eight cases: unused name, empty and whitespace-only, exact duplicate, trim-before-compare, case sensitivity, a group keeping its own name while renaming, a rename onto another group's name, a rename to an empty name. |

**Evidence**

The rule was watched failing. `isNameAvailable` was reverted to the naive `!existing.contains(name)`
— no trim, no empty rejection, no `renaming` exemption — and `xcodebuild -only-testing` on the new
suite reported 6 of 8 failing where the restored code reports none:

```
WorktreeGroupTests.swift:32: testAGroupMayKeepItsOwnNameWhileRenaming : XCTAssertTrue failed
WorktreeGroupTests.swift:14: testAnEmptyOrWhitespaceOnlyNameIsRefused : XCTAssertFalse failed
WorktreeGroupTests.swift:15: testAnEmptyOrWhitespaceOnlyNameIsRefused : XCTAssertFalse failed
WorktreeGroupTests.swift:16: testAnEmptyOrWhitespaceOnlyNameIsRefused : XCTAssertFalse failed
WorktreeGroupTests.swift:41: testARenameToAnEmptyNameIsRefused : XCTAssertFalse failed
WorktreeGroupTests.swift:24: testTheNameIsTrimmedBeforeComparison : XCTAssertFalse failed
     Executed 8 tests, with 6 failures (0 unexpected)
** TEST FAILED **
```

The model was then restored from a scratchpad copy — no `git checkout` or `git stash`.

**Deviations from the plan**

`isValid` has **no default value**; all three call sites pass one explicitly. The plan asked for a
default non-empty-after-trim rule "so the Rename Worktree call site keeps today's behaviour without
passing anything", but Rename Worktree's behaviour today is `allowsEmptyName: true` — the plan says
so itself two paragraphs later, and passes `{ _ in true }` there. With every call site passing a
rule, a default would have had no user. Acceptance criterion 2 (`allowsEmptyName` gone, every call
site compiles) is met either way.

**Gate**

`./scripts/ci.sh` — green. `Executed 559 tests, with 0 failures (0 unexpected)`, `==> CI passed.`
`WorktreeGroupTests`' eight cases confirmed present in the run's `.xcresult`, all passed.

### T3: One git-backed manager test base; retired cases deleted

**What landed**

| File | State |
| --- | --- |
| `Tests/WorktreeGroupStoreTests.swift` | Deleted (17 cases). The store it covers goes in T5. |
| `Tests/TestHelpers.swift` | `GroupsFile`, `groupsFilePath` and `groupsFileExists` gone. `WorktreeGroupManagerTestCase` and `WorktreeGroupManagerGitTestCase` merged into the latter: one base, which builds the `GitRepoFixture` over the scratch root and then the manager, with `prepareProjectRoot()` collapsed into `setUp`. The fixed 100 ms `setUp` sleep is replaced by `waitForInitialLoad()`, a `waitFor` poll. |
| `Tests/WorktreeGroupManagerTests.swift` | Superclass is the merged base. `testRoundTripPersistsToDisk`, `testReconcileDropsPhantomIds`, `testReconcileNoOpWhenNoPruningNeeded`, `testDuplicateStoredDefaultOrderDoesNotDuplicateRows` and `testIdStoredInTwoGroupsDoesNotDuplicateRows` deleted, with the now-empty `reconcile(_:)` MARK. 23 cases remain. |
| `Tests/WorktreeGroupManagerStatusTests.swift` | The migration block and the `setGrouping` pair deleted, along with `writeGroupsFile` (both overloads), `reopenedManager` and `waitForGroupsFileWithoutStatuses`; the three `groupsFileExists` assertions dropped. 13 cases remain. |

Nothing in `Sources/` changed. `Clearway.xcodeproj/project.pbxproj` lost the deleted file's three
entries when `ci.sh` ran `xcodegen generate`.

**Deviations from the plan**

- The plan's `:75-177` range for the migration block also spans `// MARK: - setGrouping`. Both of
  its cases went with it, and they had to: `testSetGroupingPublishesAndPersists` asserts through
  `WorktreeGroupStore(projectPath:)` and `testSetGroupingToTheCurrentValueWritesNothing` through
  `groupsFileExists`, which acceptance criterion 1 forbids. T6 case 7 re-adds the round trip.
- `testStatusStoredAgainstMainIsIgnoredOnTheReadPath` was deleted too, though the plan does not name
  it. It seeds `statuses` by writing a legacy `groups.json` through `GroupsFile`, so it cannot
  survive the helper's removal, and after T5 nothing can put main's id into `statuses` at all —
  `readConfig` skips main. `setStatus`'s own refusal of main stays covered by
  `testSetStatusIgnoresTheMainWorktree`.
- `testReconcileDropsAnAbsentWorktreeWithoutSaving` lost its `groupsFileExists` assertion and is
  renamed `testReconcileDropsAnAbsentWorktree`; the surviving assertion is the published map.
- Two surviving doc comments that named `groups.json` were reworded rather than left for T7, whose
  file list does not include this suite. `Tests/WorktreeConfigStoreTests.swift:226` still names the
  file and is not in T7's list either — see Follow-ups.

**Evidence**

There is no new behaviour here, so there is no regression test to watch fail. The one new mechanism
is `waitForInitialLoad`, and it was probed rather than assumed: `TestHelpers.swift` was copied to
the session scratchpad, the call removed from `setUp`, and the two manager suites run on their own.
They **passed** — `Executed 36 tests, with 0 failures (0 unexpected)`, `** TEST SUCCEEDED **` — so
the clobber the deleted sleep guarded against does not reproduce on this machine. The guard is
therefore carried over, not newly proven: the race it covers is an ordering one (the `init` load
republishing `groups` over a mutation a test body already made), and losing the only protection
against it on one green run would be trading a documented guard for nothing. The file was restored
from the scratchpad copy — no `git checkout`, no `git stash`.

**Gate**

`./scripts/ci.sh` — green. `Executed 529 tests, with 0 failures (0 unexpected)`, `==> CI passed.`
All three manager suites confirmed present in the run's `.xcresult`: `WorktreeGroupManagerTests` 23
passed, `WorktreeGroupManagerStatusTests` 13 passed, `WorktreeGroupManagerNameTests` 11 passed.

### T4: Group identity becomes the name

**What landed**

| File | State |
| --- | --- |
| `Sources/App/WorktreeGroupManager.swift` | Every group-identity parameter is the name: `renameGroup(named:to:)`, `deleteGroup(named:)`, `addWorktree(_:toGroupNamed:)`, `setGroupOrder(named:ids:)`, `groupName(for:)`, `removeWorktreeFromGroup(_ wt: Worktree)`, `setUngroupedOrder(_:)`. `createGroup(named:)` trims and refuses what `WorktreeGroup.isNameAvailable` rejects. `seedDefaultOrder` keeps its name, so `ContentView` is untouched. `matches` now reads `groupName(for:)` instead of scanning `worktreeIds`. `repositioned` lost `private` and moved under a new `// MARK: - Ordering`. `groups.json`, `WorktreeGroup`'s `UUID`/`worktreeIds`/`createdAt` and `defaultOrder` are unchanged — this task is identity only. |
| `Sources/App/SidebarView.swift` | `createWorktreeTargetGroupName: String?`, `targetedGroupName: String?`, `Dictionary(grouping:) { groupManager.groupName(for: $0.id) }`, `byGroup[group.name]`, `dropIntoGroup(_:groupNamed:)`. The `.group` branch of `dropIntoWorktreesHeader` now routes through `withDroppedWorktrees`, which supplies the `Worktree` `removeWorktreeFromGroup` takes and keeps the same next-main-queue-turn deferral the inline `DispatchQueue.main.async` provided. `groupToRename`/`groupToDelete` stay `WorktreeGroup?`. No `UUID` is left in the file. |
| `Sources/App/SidebarSheets.swift` | `CreateWorktreeSheet.targetGroupId: UUID?` → `targetGroupName: String?`. No `UUID` left. |
| `Tests/WorktreeGroupManagerTests.swift` | 24 cases. Every group reference is a name literal, so the `guard let group = manager.groups.first` preambles are gone. The ordering assertions read `sidebarOrderedWorktrees` (via a local `renderedOrder` helper) and `groupName(for:)`; nothing reads `manager.defaultOrder` or `worktreeIds`. New case `testCreateGroupRefusesADuplicateOrEmptyName`. |
| `Tests/WorktreeGroupManagerStatusTests.swift` | 13 cases, moved to `toGroupNamed:` and `setUngroupedOrder`; three `guard let group` preambles dropped. |

**Evidence**

The one new rule is `createGroup`'s refusal, and it was watched failing. The `isNameAvailable` guard
and the trim were removed from `createGroup`; `xcodebuild -only-testing:ClearwayTests/WorktreeGroupManagerTests`
then reported the new case failing where the restored code reports nothing:

```
Tests/WorktreeGroupManagerTests.swift:26: error: -[ClearwayTests.WorktreeGroupManagerTests testCreateGroupRefusesADuplicateOrEmptyName] : XCTAssertEqual failed: ("["Backlog", "Backlog", "  "]") is not equal to ("["Backlog"]")
	 Executed 24 tests, with 1 failure (0 unexpected) in 14.898 (14.914) seconds
** TEST FAILED **
```

The manager was then restored from a scratchpad copy — no `git checkout`, no `git stash`.

**Deviations from the plan**

- **`renameGroup(named:to:)` carries the same `isNameAvailable` guard as `createGroup`.** The plan
  names only `createGroup`, but its reason — a name-keyed lookup must not be ambiguous even if a
  call site forgets to check — applies verbatim to a rename onto another group's name, and the
  guard is one clause.
- **`testSetDefaultOrderCollapsesADuplicateStoredId` became `testRepositionedCollapsesADuplicateStoredId`,
  a direct case on the pure `static`.** The plan asks the four reorder cases to keep their
  assertions expressed as the order `sidebarOrderedWorktrees` returns; for this one that is
  impossible, because `deduplicated` collapses a repeated id before the order is published, so the
  rendered list is identical whether `repositioned` collapsed the duplicate or added a third copy.
  The assertion is preserved exactly against `repositioned` itself, which T5 retains, and
  `repositioned` lost `private` to allow it — the same shape T5's acceptance criterion 4 already
  asks for on `reassignedPositions`.
- **`testSeedDefaultOrderAppendsOnlyMissingIds` lost its "grouped ids are skipped" assertion.** It
  was only observable through `defaultOrder`: `sidebarOrderedWorktrees` puts a grouped worktree in
  its group section whether or not the ungrouped order also names it. The case now renames its
  pre-recorded worktree to `zebra` so the surviving assertion distinguishes "appended" from
  "re-sorted", which the old `already`/`fresh` pair did not. T5 removes the rule anyway —
  `seedPositions` assigns a position to every non-main worktree without one.
- **`testSeedDefaultOrderIsIdempotent` gained a second worktree**, for the same reason: with one
  row there is no order for the rendered list to disagree about.

**Gate**

`./scripts/ci.sh` — green, run after the restore. `Executed 530 tests, with 0 failures (0 unexpected)`,
`==> CI passed.` `WorktreeGroupManagerTests` 24, `WorktreeGroupManagerStatusTests` 13,
`WorktreeGroupManagerNameTests` 11.

### T5: Storage moves to git config; `WorktreeGroupStore` is deleted

**What landed**

| File | State |
| --- | --- |
| `Sources/App/WorktreeGroup.swift` | One stored property, `name`, with `id` derived from it. `Codable`, `UUID`, `createdAt`, `worktreeIds` and `sortedByCreation` gone; `isNameAvailable` unchanged. |
| `Sources/App/WorktreeStatus.swift` | `WorktreeStatus` and `WorktreeGrouping` drop `Encodable` and the two comments explaining it; `WorktreeGrouping`'s doc now names `clearway.grouping`. |
| `Sources/App/WorktreeGroupStore.swift` | Deleted, taking `WorktreeGroupsPayload`, both `DispatchSource` watchers and the file-descriptor leak with it. |
| `Sources/App/WorktreeGroupManager.swift` | `groupNames` and `positions` replace `defaultOrder` and `WorktreeGroup.worktreeIds`. `store`, `deinit`, `save()`, `migrateLegacyStatuses` and `deduplicated` gone. `loadTask` reads `clearway.grouping` and `clearway.groupOrder`; `reloadConfig` re-reads both beside the per-worktree pair and `readConfig` pulls `clearway.group` and `clearway.position` out of the `--worktree --list` output it already had. Every gesture publishes optimistically and enqueues one `writeChain` job; rename and delete write the members first and the registry only if every member write landed. New pure `static reassignedPositions(section:newOrder:)` beside the retained `repositioned`. `seedDefaultOrder(with:openIds:)` → `seedPositions(for:openIds:)`; `reconcile` is the config reload alone. |
| `Sources/App/ContentView.swift` | Follows the `seedPositions` rename; the pruning comment no longer claims group membership and the default order are at stake, since nothing prunes them. |
| `Tests/TestHelpers.swift` | `waitForInitialLoad`'s `.clearway` poll replaced by `await manager.loadTask?.value`. New `restartManager()` — see Deviations. |
| `Tests/WorktreeGroupManagerTests.swift` | 26 cases. The two `seedDefaultOrder` cases follow the rename, `testGroupsAppearInCreatedAtAscendingOrder` → `testGroupsAppearInCreationOrder`, and two new direct cases on `reassignedPositions`. |
| `Tests/WorktreeGroupManagerNameTests.swift`, `Tests/WorktreeGroupManagerStatusTests.swift` | One `await restartManager()` each in the three cases that enable `extensions.worktreeConfig` through the fixture — see Deviations. |

**Ordering rules as implemented**

`sidebarOrderedWorktrees` sections by `groupNames` and orders each section by `positions` ascending;
a worktree without one follows those that have one, in `Worktree.sorted` order, which is also the
tie-break. Main stays pinned to the top of the ungrouped section and never carries a position.
`reassignedPositions` permutes the section's stored ids with `repositioned`, then zips the values the
section already occupied — ascending, padded above the maximum for members and new ids without one —
back onto the permuted order, returning only the entries whose value changed. That is what keeps a
row the caller omitted, hidden by the detached filter or the search field, in the slot it had.

**Evidence**

`reassignedPositions` was watched failing. The value pool and the changed-only filter were replaced
by a bare `enumerated()` over the permuted ids;
`xcodebuild -only-testing:ClearwayTests/WorktreeGroupManagerTests` then reported both new cases
failing where the restored code reports none:

```
Tests/WorktreeGroupManagerTests.swift:408: error: testReassignedPositionsAppendsAboveTheSectionMaximum :
  XCTAssertEqual failed: ("["/tmp/stored": 1, "/tmp/fresh": 0, "/tmp/unpositioned": 2]")
  is not equal to ("["/tmp/stored": 6, "/tmp/unpositioned": 7, "/tmp/fresh": 5]")
Tests/WorktreeGroupManagerTests.swift:396: error: testReassignedPositionsWritesOnlyTheRowsThatMoved :
  XCTAssertEqual failed: ("["/tmp/b": 0, "/tmp/hidden": 1, "/tmp/a": 2]")
  is not equal to ("["/tmp/b": 0, "/tmp/a": 2]")
	 Executed 26 tests, with 2 failures (0 unexpected) in 13.388 (13.400) seconds
** TEST FAILED **
```

The manager was then restored from a scratchpad copy — no `git checkout`, no `git stash`.

**Deviations from the plan**

- **The initial-load signal is `manager.loadTask?.value`, not a poll.** T3's build log flagged that
  deleting the store removes the `.clearway` directory the guard waited on. `loadTask` lost `private`
  (keeping `private(set)`), the same shape T4 gave `repositioned`, and the test base awaits it
  directly. That is exact rather than approximate, and it is what T6 case 8 — no `.clearway/`
  directory is created — requires.
- **Three test files outside the plan's file list changed.** `ContentView` is not the only caller of
  the renamed `seedDefaultOrder`: two manager cases call it too, and a test file that does not
  compile is not a smaller diff. The same three suites needed `await restartManager()` in the three
  cases that enable `extensions.worktreeConfig` through `GitRepoFixture` behind the manager's back:
  `WorktreeConfigStore` memoises a probe that found the extension off, and the load now runs one
  before any test body does. Production is unaffected — the only writer that turns the extension on
  is `enableExtension()`, which updates the cache itself — but a test that enables it externally now
  needs a fresh store. `restartManager()` is also the relaunch helper T6 needs.
- **`seedPositions` assigns within each section, not only the ungrouped one.** The plan says "every
  non-main worktree without one is assigned in `Worktree.sorted` order"; a grouped worktree without a
  position needs one as much as an ungrouped one does, and appending it to the ungrouped section's
  range would collide with that section's values.
- **The registry is de-duplicated on load.** `Self.registered` drops a repeated name. `groups` is
  keyed by name and `SidebarView` renders it through `ForEach`, so two sections with the same `id`
  trap the backing `NSTableView`; a hand-edited `.git/config` can list a name twice. This replaces
  the `deduplicated` guard the plan retires, at the one place a duplicate can now enter.
- **Acceptance criterion 1's `startWatching` grep is not empty**, but no hit is this change's:
  `ClaudeActivityMonitor`, `PromptManager`, `ProjectWindow` and `PromptWindow` each own one and
  always did. `WorktreeGroupsPayload` returns nothing.

**Gate**

`./scripts/ci.sh` — green, run after the restore. `Executed 532 tests, with 0 failures (0 unexpected)`,
`==> CI passed.` Suites confirmed present in the run's `.xcresult`: `WorktreeGroupManagerTests` 26,
`WorktreeGroupManagerStatusTests` 13, `WorktreeGroupManagerNameTests` 11, `WorktreeGroupTests` 8.
`git status --porcelain` shows only this change's files; no `default.profraw`.

### T6: Persistence tests

**What landed**

| File | State |
| --- | --- |
| `Tests/TestHelpers.swift` | `GitRepoFixture.localValues(ofKey:)`, running `config --local --get-all --null` and dropping the record after the final NUL. Exit 1 — the key is absent — answers `[]`. Nothing splits on a newline, so a group name holding one comes back whole. |
| `Tests/WorktreeGroupPersistenceTests.swift` | New, 9 cases on the merged git-backed base: the registry, membership+position and grouping mode across a relaunch; rename rewriting every member and keeping the registry slot; delete unsetting every member and dropping the entry; a membership naming an unlisted group rendering ungrouped; `git worktree remove` leaving nothing on the worktrees that remain; no `.clearway/` directory; and a plain directory git will not let the extension be enabled in. |

Every assertion about stored state reads git through `GitRepoFixture`, never through the manager.
No `Sources/` file changed.

**Deviations from the plan**

- **Case 6 keeps a second worktree alive.** The plan asks only that the removed worktree is gone
  from the sidebar order. Reconciling against a list holding main alone proves nothing — `readConfig`
  skips main, so every map is empty whatever git holds. The case removes one of two grouped,
  positioned worktrees and asserts the survivor keeps its own membership and position while main
  carries neither key.
- **Case 5 does not call `repo.enableWorktreeConfig()` and needs no `restartManager()`.** It creates
  a real group through the manager first, which enables the extension through the manager's own
  store and updates that store's cache, so the fixture can then write `clearway.group = "Ghost"`
  directly and the same manager reads it. A `clearway.name` is written beside it and awaited, which
  is what makes the two absence assertions land after the read rather than before it.
- **Cases 4 and 8 await an intermediate state before the final one.** `waitForRegistry([])` polls
  immediately, and the registry is also `[]` before the first write lands, so on its own it passes
  vacuously. Both cases first await the stored `clearway.group` the creates produce.

**Evidence**

There is no unfixed code here — T5 shipped the behaviour — so each case was watched failing against
a deliberately broken manager instead, in two passes, with the file restored from a scratchpad copy
after each. No `git checkout`, no `git stash`.

Probe A — `readConfig` drops the `clearway.position` parse, `reloadConfig` drops the unlisted-group
filter, `deleteGroup` stops unsetting its members:

```
WorktreeGroupPersistenceTests.swift:105: testAMembershipNamingAnUnlistedGroupRendersUngrouped :
  XCTAssertNil failed: "Ghost" - the membership names no listed group
WorktreeGroupPersistenceTests.swift:84: testDeleteUnsetsEveryMemberAndDropsTheRegistryEntry :
  XCTAssertEqual failed: ("Optional("Doomed")") is not equal to ("nil")
WorktreeGroupPersistenceTests.swift:36: testMembershipAndPositionSurviveARelaunch :
  XCTAssertEqual failed: ("[…/alpha", "…/bravo"]") is not equal to ("[…/bravo", "…/alpha"]")
WorktreeGroupPersistenceTests.swift:130: testRemovingAWorktreeLeavesNothingBehind :
  XCTAssertEqual failed: ("[:]") is not equal to ("["…/staying": 1]")
	 Executed 9 tests, with 5 failures (0 unexpected) in 18.445 seconds
** TEST FAILED **
```

Probe B — `loadTask` stops publishing the grouping mode and the registry, `renameGroup` stops
rewriting its members:

```
WorktreeGroupPersistenceTests.swift:71: testRenameRewritesEveryMemberAndKeepsTheRegistrySlot :
  XCTAssertEqual failed: ("Optional("Old")") is not equal to ("Optional("New")")
WorktreeGroupPersistenceTests.swift:48: testTheGroupingModeRoundTrips :
  XCTAssertEqual failed: ("group") is not equal to ("status")
WorktreeGroupPersistenceTests.swift:54: testTheGroupingModeRoundTrips :
  XCTAssertEqual failed: ("group") is not equal to ("none")
WorktreeGroupPersistenceTests.swift:18: testTheRegistrySurvivesARelaunch :
  XCTAssertEqual failed: ("[]") is not equal to ("["Backlog", "Shipped"]")
** TEST FAILED **
```

Cases 8 and 9 are the two that no mutation probes: nothing in the manager can create a `.clearway/`
directory any more, and case 9 asserts a directory git refuses stays empty of state.

**Gate**

`./scripts/ci.sh` — green, run after the restore. `Executed 541 tests, with 0 failures (0 unexpected)`,
`==> CI passed.` `WorktreeGroupPersistenceTests` 9 passed. `git status --porcelain` shows only this
change's files; no `default.profraw`.

### T7: Documentation and the last `groups.json` references

**What landed**

| File | State |
| --- | --- |
| `CLAUDE.md` | Concurrency: the `WorktreeGroupStore` sentence closing the `DispatchSource` bullet removed — `ClaudeSessionFiles.makeWatcher` is already the subject the paragraph names. Architecture: the `SavedCommandStore` entry no longer compares itself to `WorktreeGroupStore`; the `WorktreeGroupStore.openFileWatcher` leak bullet is replaced by a `WorktreeGroupManager.swift` entry carrying the four keys, the registry-last rule, the unlisted-group rule, that nothing prunes or watches, and the lowercase-key constraint. |
| `Sources/App/SavedCommandStore.swift` | Doc comment no longer says `commands.json` sits "beside that project's `groups.json`". |
| `Sources/App/WorktreeConfigStore.swift` | Type doc drops the `WorktreeGroupStore` shape citation; `set`'s doc re-points its return-value rationale from the `groups.json` migration to the rename/delete chain, which is now the one caller a later reload cannot correct. |
| `Tests/WorkTaskManagerWatcherTests.swift` | The 3s timeout stays; the citation of the deleted `WorktreeGroupStoreTests.testWatcherFiresOnExternalWrite` is gone. |
| `Tests/WorktreeConfigStoreTests.swift` | The exit-5 comment attributes the distinction to a group delete reaching its registry write, not to the migration keeping `groups.json`. |

**Evidence**

No regression test: this task changes comments and documentation only, so there is no behaviour to
watch fail. The acceptance criteria are greps.

```
$ grep -rn "groups.json" Sources Tests CLAUDE.md
$ grep -rn "WorktreeGroupStore" Sources Tests CLAUDE.md
$ echo $?
1
```

Both return nothing. `.work/brief.md` still names both, deliberately — it is the historical task
brief, outside the criteria's scope and not a claim about the current code.

**Deviations from the plan**

One beyond the plan's file list: `Tests/WorktreeConfigStoreTests.swift:226` named `groups.json` and
would have failed acceptance criterion 1. Rewritten in place, same assertion.

**Gate**

`./scripts/ci.sh` — green. `Executed 541 tests, with 0 failures (0 unexpected)`, `==> CI passed.`,
exit status 0 on a re-run after the last edit. `git status --porcelain` shows only this change's
five files; no `default.profraw`.

### Simplify

`WorktreeGroup.isNameAvailable` became `available`, returning the trimmed name instead of a `Bool`,
so `createGroup` and `renameGroup` store what the validator checked rather than re-deriving the trim
at each call site. `renameGroup`, `deleteGroup` and `writeRegistry` collapsed into one
`writeRegistry(settingGroup:on:)` carrying the members-before-registry rule once. `maxPosition` now
reads `section(named:)` instead of re-deriving section membership, and `section`'s comparator moved
to `ordered`'s `?? .max` spelling. The two repo-level reads in `init` and `reloadConfig` became
`async let`, so the three independent reads of a reload overlap instead of costing three serial
`git config` spawns. In the tests, `GitRepoFixture.localValues(ofKey:)` now calls
`WorktreeConfigStore.parseNullSeparated` rather than repeating it, the two `renderedOrder` copies
moved onto `WorktreeGroupManagerGitTestCase`, and four comments plus the three sleeps they justified
— all naming the deleted `groups.json` watcher — are gone.

Skipped: folding `localValue`/`localGetArgs` into `localValues` (T1's specified API, and `--get`
refuses a multivar where `--get-all` would silently take the first value); replacing `createGroup`'s
whole-registry rewrite with one `--add` (carried decision 6); parallelising the per-member and
per-position write loops with `withTaskGroup` (more code for a win on a path nothing renders behind);
and the remaining ~45 fixed `Task.sleep`s in `WorktreeGroupManagerTests` (~6 s per run, pre-existing,
and auditing each site is its own task).

**Gate:** `./scripts/ci.sh` — green. `Executed 542 tests, with 0 failures (0 unexpected)`,
`==> CI passed.` `git status --porcelain` shows only this change's files; no `default.profraw`.

## Changelog

### Review fixes

The review stage's four findings, resolved in one commit with the two proof tests it left in the
tree.

**What landed**

| File | State |
| --- | --- |
| `Sources/App/WorktreeGroupManager.swift` | `reconcile(_:openIds:)` now awaits `reloadConfig` and *then* seeds, so the two are one entry point. `section` takes the live worktrees and orders them with `ordered` — render order, not ID order — and sources the ungrouped section from the worktree list rather than `positions.keys`. `setUngroupedOrder`/`setGroupOrder` gained `in:`/`openIds:`. `maxPosition` reads `positions` directly instead of going through `section`. |
| `Sources/App/ContentView.swift` | The two calls at `:330-331` became one `reconcile(newWorktrees, openIds:)`. One line removed; the file is still on its file-wide `file_length` disable. |
| `Sources/App/SidebarView.swift` | Both `.onMove` handlers collapsed into one `reorder(_:from:to:inGroupNamed:)` that passes `worktreeManager.worktrees` and `terminalManager.openWorktreeIds`. Written as one helper because the inline form pushed the type past SwiftLint's 500-line `type_body_length` warning. |
| `Sources/App/WorktreeConfigStore.swift` | One private `decoded(_:)` now holds the `Data` → `String` conversion for all three call sites. |
| `Tests/WorktreeGroupManagerTests.swift` | Gains `testADragKeepsTheSlotOfAnUnpositionedRowTheFilterHid`, reframed (see below) and moved here from the persistence suite, where it belongs beside the other reorder cases. |
| `Tests/WorktreeGroupPersistenceTests.swift` | Gains `testTheStoredOrderSurvivesContentViewsReloadSequence` and `testARenameWhoseMemberWritesFailLeavesTheRegistryUntouched` — the "New tests" entry the spec named and T6 did not deliver. |
| `Tests/WorktreeGroupManagerStatusTests.swift`, `Tests/WorktreeGroupManagerNameTests.swift` | Call sites follow the two signature changes. |

**Finding 1 (critical) — the seed clobbered the stored order.** Watched failing on `64401de`:

```
testTheStoredOrderSurvivesContentViewsReloadSequence : XCTAssertEqual failed:
  ("[".worktrees/alpha", ".worktrees/bravo"]") is not equal to
  ("[".worktrees/bravo", ".worktrees/alpha"]") - rendered order after a relaunch
testTheStoredOrderSurvivesContentViewsReloadSequence : XCTAssertEqual failed:
  ("Optional("1")") is not equal to ("Optional("0")")
  - the seed must not renumber a worktree git already holds a position for
```

**Finding 2 (important) — a drag numbered the slots in ID order.** The reviewer's proof asserted an
order `Worktree.sorted` cannot produce: `"(detached)"` sorts *before* `"alpha"`, so the hidden row
was second, not last, and the permutation came out identical under both the old and the new rule.
Fixing finding 1 then made the case unreachable through `reconcile` — the seed now numbers every row
before any drag can see it — so the reframed test drops the group and the reload and drives the one
state that still reaches it: the window between the worktree list arriving and `reconcile` publishing
what git holds. Watched failing with only `section` reverted, finding 1 fixed:

```
testADragKeepsTheSlotOfAnUnpositionedRowTheFilterHid : XCTAssertEqual failed:
  ("["/tmp/alpha", "/tmp/zulu", "/tmp/zzz"]") is not equal to
  ("["/tmp/alpha", "/tmp/zzz", "/tmp/zulu"]") - the hidden row keeps the slot it had
```

**Finding 3 (important) — the rename failure branch had no coverage.** The new case removes the
member's worktree directory, so `git -C <path> config --worktree` can only fail, then queues
`setGrouping` behind the rename to know the chain has drained. Watched failing with `writeRegistry`
reverted to write the registry first:

```
testARenameWhoseMemberWritesFailLeavesTheRegistryUntouched : XCTAssertEqual failed:
  ("["New"]") is not equal to ("["Old"]") - a rename no member accepted must not reach the registry
testARenameWhoseMemberWritesFailLeavesTheRegistryUntouched : XCTAssertEqual failed:
  ("["New"]") is not equal to ("["Old"]") - the next launch shows the old name
```

**Finding 4 (nit) — the new `optional_data_string_conversion` warning.** Consolidated rather than
suppressed: `String(decoding:as:)` was already written at two pre-existing sites, so all three now go
through one `decoded(_:)`. Behaviour is unchanged — an invalid sequence is still replaced rather than
failing the read, which `String(bytes:encoding:)` would not preserve. The file carries one such
warning instead of the base's two.

Each regression above was applied to a copy of `WorktreeGroupManager.swift` held in the session
scratchpad and restored from it; nothing was reverted through git.

**Gate:** `./scripts/ci.sh` — green. `Executed 545 tests, with 0 failures (0 unexpected)`,
`==> CI passed.`

### PR review fixes

`/pr-review-toolkit:review-pr code tests errors types` over `git diff ec12656...HEAD`. Four agents;
the `code` and `types` passes independently found the same critical bug. Nothing was built, linted
or tested — `sign-off` owns the single gate run.

**What landed**

| File | State |
| --- | --- |
| `Sources/App/WorktreeGroupManager.swift` | `deleteGroup` appends its members to the ungrouped section at `maxPosition(inSectionNamed: nil) + 1`, in the order the group showed them; `members(ofGroupNamed:)` orders by position rather than by ID to supply that order. `reassignedPositions` takes its pool as a `Set`, so a section holding a duplicate is healed by the first drag. `registered` drops a blank registry value. The `init` load takes `reloadConfig`'s `writeChain` guard before publishing. |
| `Sources/App/WorktreeConfigStore.swift` | `readLocal` matches `.refused(1, _)` for "key absent" and answers `nil` for every other refusal, the discipline `set` and `unsetAllLocal` already apply to exit 5. |
| `Tests/WorktreeGroupManagerTests.swift` | `testDeleteGroupAppendsItsMembersToTheUngroupedSection`, `testReassignedPositionsDoesNotReissueADuplicateSlot`. |
| `Tests/WorktreeGroupPersistenceTests.swift` | `testAHandEditedRegistryDropsBlanksAndRepeats`. |
| `CLAUDE.md` | The per-section position rule added to the `WorktreeGroupManager` entry. |

**Finding 1 (critical) — deleting a group scrambled the ungrouped section.** `deleteGroup` cleared
`groupNames` and never touched `positions`, but every section numbers from zero. With ungrouped
rows at 0, 1 and a group member at 0, the delete left two rows sharing slot 0; `ordered`'s
`Worktree.sorted` tie-break then interleaved the member among rows the user never moved, and
`seedPositions` does not renumber a worktree that already has a position, so it survived every
relaunch. The next drag made it worse: `reassignedPositions` zipped the duplicated pool back on and
the drop rendered in a third order. Behaviour at `ec12656` was defined — a deleted group's members
fell out of `defaultOrder` and `seedDefaultOrder` appended them — so this was a regression, and the
spec's decision 12 is silent on positions rather than sanctioning it.

**Finding 2 (important) — `reassignedPositions` reissued a duplicate slot.** Fixed with finding 1
rather than left to it: the pool is now a set, which makes the static total over any stored state,
including a hand-edited `config.worktree`. It is the same healing rule `repositioned` already
applies to an ID recorded twice.

**Finding 3 (important) — the `init` load could publish over a gesture made during it.**
`reloadConfig` snapshots `writeChain` and re-checks it before publishing; the load did not, so a
group created or a grouping mode chosen while its two subprocesses were in flight was overwritten
by what git held beforehand and stayed lost until the worktree list next changed. The load now
takes the same guard.

**Finding 4 (important) — a repo-level read reported "no groups" from any git failure.** The bare
`case .refused` in `readLocal` collapsed exit 128 (`bad config line`, `not in a git directory`) and
exit 2 (`--get` on a multivar) into "the key is absent". `reloadConfig` then published `groups = []`
and dropped every membership, and the next group the user created rewrote the registry without the
ones git still held. Only exit 1 means absent, and every other refusal now answers `nil`, which
`registry.map(Self.registered) ?? groups` already handles by keeping what is published.

**Finding 5 (nit, fixed) — a blank registry value rendered a nameless section** with a live drop
target whose drop `set` discards as a clear, so the row snapped back on the next reload.
`registered` drops it alongside the repeat it already dropped.
