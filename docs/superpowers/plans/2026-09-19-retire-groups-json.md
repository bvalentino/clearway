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
