# Retire groups.json

**Date:** 2026-09-19
**Base:** ec12656 (`Name a worktree when you create it, and store it in git config (#226)`)

PR #226 moved a worktree's name and status into its own `config.worktree` and left groups, sidebar
order and grouping mode behind in `<projectPath>/.clearway/groups.json`. This change moves those
three into git config too — the ordered group registry and the grouping mode as repo-level keys in
the shared `.git/config`, each worktree's group membership and position in its own
`config.worktree` — and then deletes `WorktreeGroupStore`, `WorktreeGroupsPayload`, their two
`DispatchSource` watchers (one of which leaks a file descriptor by design), the one-shot
`legacyStatuses` migration and every remaining `groups.json` reference. Nothing is migrated: an
existing `groups.json` is neither read nor deleted, and groups, order and grouping mode start
empty.

## Decisions

| # | Question | Decision | Source |
| --- | --- | --- | --- |
| 1 | What identifies a group? | Its name. Unique per repo, non-empty, compared exactly (case-sensitive). `UUID` and `createdAt` go away; display order is creation order with new groups appended, as today. Renaming rewrites every member worktree's membership. | Operator |
| 2 | Where does sidebar order live? | On each worktree, in its own `config.worktree`. Main is never grouped and never carries a position. A drag rewrites the positions of the rows it moved. Nothing prunes. | Operator |
| 3 | Where does grouping mode live? | Per repo, in the shared `.git/config`, as it was per project in `groups.json`. | Operator |
| 4 | Is anything migrated? | No. An existing `groups.json` is neither read nor deleted. The `legacyStatuses` migration from #226 goes with the store. | Operator |
| 5 | Does anything watch git config? | No, matching #226 decision 2. Values are re-read when the worktree list changes. | Operator |
| 6 | Which keys, exactly? | Repo scope, written with `git config --local`: `clearway.grouping` (one of `group`/`status`/`none`) and `clearway.groupOrder` (a multivar, one group name per value, in creation order). Worktree scope, written with `git config --worktree`: `clearway.group` (the name of the group holding this worktree; absent means ungrouped) and `clearway.position` (a decimal integer; absent means not yet ordered). | Spec author |
| 7 | Why are the two worktree keys single lowercase words? | `git config --list` lowercases key names — a scratchpad probe wrote `clearway.myCamelKey` and read back `clearway.mycamelkey` — and `WorktreeConfigStore.parseList` keys its dictionary on what git printed (`Sources/App/WorktreeConfigStore.swift:70-79`) while callers look up a constant. `clearway.name` and `clearway.status` are already safe by accident; `clearway.group` and `clearway.position` are safe by construction. The repo-level keys are read with `--get`/`--get-all`, which return values and never key names, so `clearway.groupOrder` may keep its camel case. | Spec author |
| 8 | Does `--local` reach the same file from every worktree? | Yes. A probe set `clearway.groupOrder` from linked worktree A and read it back from linked worktree B, and the value landed in the main repository's `.git/config`. This is the same property `WorktreeConfigStore.enableExtension` already relies on (`Sources/App/WorktreeConfigStore.swift:176-179`). So one process reads the registry for the whole project, wherever `projectPath` points. | Spec author |
| 9 | How is the registry rewritten? | Whole-registry rewrite on every group create, rename and delete: `git config --local --unset-all clearway.groupOrder`, then one `--add` per name in order. Not `--replace-all`/`--unset` with a value-regex: a group name is arbitrary user text and a value-regex would need POSIX ERE escaping of it, which is a correctness hazard for a saving of two subprocesses on an action the user takes by hand. A probe confirms `--add` preserves insertion order and `--get-all` returns file order, that values containing spaces and regex metacharacters round-trip unharmed, and that `--unset-all` exits 5 when the key is absent — the case `WorktreeConfigStore.set` already treats as success (`Sources/App/WorktreeConfigStore.swift:128-129`). | Spec author |
| 10 | What happens when a rename fails partway through its members? | The registry is authoritative for which groups exist, and it is written **last**. The manager publishes the rename at once, then enqueues one job on the write chain that rewrites every member's `clearway.group` and only then rewrites the registry — the shape `migrateLegacyStatuses` uses for the same reason (`Sources/App/WorktreeGroupManager.swift:422-454`). If any member write fails the registry keeps the old name, so a wholly failed rename changes nothing on disk and the next reload restores what the sidebar showed before. A partly applied one leaves some worktrees naming a group the registry does not list. | Spec author |
| 11 | How does a worktree naming an unlisted group render? | Ungrouped. The registry is the only source of which groups exist, so no phantom section is invented from a stale membership value, and one more drag repairs it. A stale `clearway.group` is harmless and is overwritten by the next drop; nothing prunes it, on the same terms as decision 2. | Spec author |
| 12 | Are group deletes ordered the same way? | Yes: unset `clearway.group` on every member first, then rewrite the registry without that name. | Spec author |
| 13 | How does a drag map onto integer positions? | A section's order is its worktrees by `clearway.position` ascending, then `Worktree.sorted` order for those without one and as the tie-break. A drag hands the manager the rendered rows in their new order and the manager reassigns exactly the position values those rows already occupied, so a worktree hidden by the detached filter or the search field keeps its own slot. That is the rule `WorktreeGroupManager.repositioned` implements today (`Sources/App/WorktreeGroupManager.swift:473-488`), re-expressed over integers, and its tests carry over. Only the rows whose value actually changed are written. | Spec author |
| 14 | Where do new worktrees get a position? | From the successor to `seedDefaultOrder`, at the same `ContentView` call site (`Sources/App/ContentView.swift:331`): every non-main worktree without a `clearway.position` is assigned one in `Worktree.sorted` order, so click-to-open never re-sorts the sidebar. A row that reaches a drag still without one takes the section's maximum plus one. | Spec author |
| 15 | What position does a drop into a group get? | The target group's maximum position plus one, so it appends, as `addWorktree` does today (`Sources/App/WorktreeGroupManager.swift:113`). A drop onto the Worktrees header unsets `clearway.group` and appends to the ungrouped section the same way. Two keys, two writes, one write-chain job. | Spec author |
| 16 | Are the repo-level writes gated on `extensions.worktreeConfig`? | Yes — they go through the same `enableExtension()` that `set` does, and reads answer empty while the extension is off. A group registry no worktree could ever join is not worth writing, and this is what makes "a project where the extension cannot be enabled shows no groups" one rule rather than two. The cost is that the first group created, or the first change of grouping mode, performs the `core.bare`/`core.worktree` bootstrap #226 already performs for the first name. | Spec author |
| 17 | How many processes does a load cost? | Two: `--local --get clearway.grouping` and `--local --get-all clearway.groupOrder`. Membership and position arrive in the `--worktree --list` read `reloadConfig` already performs once per worktree (`Sources/App/WorktreeGroupManager.swift:387-420`), so no new per-worktree process exists. | Spec author |
| 18 | What does `reconcile` become? | The config reload alone. It prunes nothing: `git worktree remove` deletes the worktree's `config.worktree` with it, so membership and position die with the worktree exactly as name and status already do (#226 decision 16). | Spec author |
| 19 | Where does the duplicate-name rule live? | In a pure `static` on `WorktreeGroup`: trim the input, reject empty, reject a name the registry already holds unless it is the group being renamed. `NameEntrySheet`'s `allowsEmptyName` flag is replaced by an `isValid: (String) -> Bool` its confirm button reads, and the two group call sites pass that rule while Rename Worktree passes one that accepts everything. Nothing in a SwiftUI body is reachable from XCTest, which is why the rule is a static and not a closure — the same split #226 made for `rowTexts`. | Spec author |
| 20 | What happens to `WorktreeGroup`? | It keeps only its name, derives `id` from it for `.sheet(item:)` and `ForEach`, and drops `Codable`, `UUID`, `createdAt`, `sortedByCreation` and `worktreeIds`. Membership becomes a published `[worktreeId: String]` map on the manager, the shape `names` and `statuses` already have. Every `UUID` group parameter in `SidebarView` and `SidebarSheets` becomes the name. | Spec author |
| 21 | What happens to the `deduplicated` guard? | It goes, with its two tests. It exists because a `groups.json` could record one id in two groups and emit the row twice (`Sources/App/WorktreeGroupManager.swift:343-349`); `clearway.group` is a single value per worktree, so the sections are disjoint by construction and the hazard is structurally gone. | Spec author |
| 22 | Do `WorktreeStatus` and `WorktreeGrouping` stay `Encodable`? | No. Both are `Encodable`-and-not-`Codable` only to keep the legacy `groups.json` decode from compiling (`Sources/App/WorktreeStatus.swift:5-8`, `64-65`). Once the payload is gone nothing JSON-encodes either, so both conformances and both comments go. | Spec author |
| 23 | Does the non-git test base survive? | No. `WorktreeGroupManagerTestCase` builds a manager over a plain temp directory (`Tests/TestHelpers.swift:193-223`) and `WorktreeGroupManagerTests` asserts persistence through it. With every value in git config, persistence needs a repository, so that base merges into `WorktreeGroupManagerGitTestCase` and every suite gets the `GitRepoFixture`. The fixed 100ms sleep in `setUp` is replaced by the `waitFor` polling the git suites already use. | Spec author |

## Assumptions

Each verified against the codebase at `ec12656`, or against a git probe run under the session
scratchpad (`.../scratchpad/probe`), never inside the repository.

1. **A worktree's id is its path.** `Worktree.id` is `path ?? branch ?? ""` (`Sources/App/Worktree.swift:19`), so every stored membership and position is keyed by the directory whose `config.worktree` holds it — no mapping table is needed.
2. **`git config --worktree --list` reads only that worktree's `config.worktree`.** Probe: after enabling the extension and writing two keys in worktree A, `--worktree --list` in A printed exactly those two, and in B (which has no `config.worktree`) exited 128. `WorktreeConfigStore.values` already treats a refusal as "stores nothing" (`Sources/App/WorktreeConfigStore.swift:100-101`), so a repo-level key can never leak into a per-worktree read.
3. **`git config --local` from a linked worktree reads and writes the shared `.git/config`.** Probe, decision 8. Assumed by the existing `probeExtension` and `enableExtension` (`Sources/App/WorktreeConfigStore.swift:160-223`).
4. **`git config --list --null` survives a value containing a newline.** Probe: a two-line group name round-tripped, and `parseList` splits at the first newline only (`Sources/App/WorktreeConfigStore.swift:70-79`). A group name is user text, so this matters.
5. **`git config --unset-all` on an absent key exits 5, and `--get-all` on one exits 1.** Probe. Both fall into branches `WorktreeConfigStore` already handles: exit 5 is the success case in `set` (`Sources/App/WorktreeConfigStore.swift:128-129`), and any non-zero exit is `.refused`, which reads treat as "stores nothing" (`Sources/App/WorktreeConfigStore.swift:244-250`).
6. **Optimistic publish then a queued git write is the established shape.** `setStatus` and `setName` both assign the published map and enqueue the write behind `writeChain`, which every read awaits (`Sources/App/WorktreeGroupManager.swift:192-228`, `456-467`). Group, position and grouping writes join the same chain.
7. **The only re-read trigger is the worktree list changing.** `ContentView.swift:330-331` calls `reconcile` and `seedDefaultOrder` inside the guard that skips a failed or empty refresh. No other call site exists (`grep -rn "\.reconcile("`).
8. **The sidebar reads group identity in five places.** `SidebarView.swift:29-34` (`createWorktreeTargetGroupId`, `groupToRename`, `groupToDelete`, `targetedGroupId`), `225-231` (sectioning), `344-362` (`GroupSectionHeader` and the drop target), `537` (`dropIntoGroup`), and `SidebarSheets.swift:6`/`100-102` (`CreateWorktreeSheet.targetGroupId`). All five change type together.
9. **`groups.json` is named in three places outside the store.** `Sources/App/SavedCommandStore.swift:5`, `CLAUDE.md:203` ("the way `WorktreeGroupStore` does"), and `CLAUDE.md:272-275` (the `openFileWatcher` leak). `CLAUDE.md:97` also cites `WorktreeGroupStore` as the safe-`DispatchSource` precedent and needs a replacement subject or removal.
10. **`Tests/TestHelpers.swift` owns the shared `groups.json` probe.** `GroupsFile` (`:175-189`) and `groupsFilePath`/`groupsFileExists` (`:199-205`); `Tests/WorkTaskManagerWatcherTests.swift:7` cites `WorktreeGroupStoreTests` in a comment only.
11. **New Swift files are invisible until `xcodegen generate` runs**, and `project.yml` globs `Sources` as a path rather than listing files (`project.yml:23-24`), so deleting a file needs no spec edit but does need `ci.sh`.

## Objective

Every piece of cross-worktree sidebar state lives in git config, so it is deleted with the worktree
that owns it, readable by any tool, and carried by no file Clearway has to watch, reconcile or
repair. `groups.json` and its store, payload, watchers and migration stop existing.

### Success criteria

- Create, rename and delete a group; add a worktree to a group, remove it, reorder within a group,
  reorder the ungrouped section, switch grouping mode — each survives an app relaunch with no
  `groups.json` on disk.
- `git worktree remove` of a grouped or ordered worktree leaves no trace of it in the sidebar or in
  any remaining config.
- Creating or renaming a group to a name the registry already holds, or to an empty name, is
  refused in the sheet.
- No file under `.clearway/` is created or read by the group manager.
- A project where `extensions.worktreeConfig` cannot be enabled shows no groups and does not crash,
  the same as names and statuses today.
- `Sources/App/WorktreeGroupStore.swift` and `Tests/WorktreeGroupStoreTests.swift` are gone, and
  `grep -rn "groups.json" Sources Tests CLAUDE.md` returns nothing.
- `./scripts/ci.sh` green.

## Commands

Regression check for every build step, and the full gate at sign-off, are the same command:

```bash
./scripts/ci.sh
```

It regenerates the Xcode project, lints, builds and runs the test suite. Lint alone:

```bash
swiftlint lint --quiet
```

`ci.sh` does not refuse on a dirty tree, so run `git status --porcelain` before any CI stamp and
report untracked or ignored files — expect the un-gitignored `default.profraw` after any Debug
launch.

## Files this change touches

**Deleted**

- `Sources/App/WorktreeGroupStore.swift`
- `Tests/WorktreeGroupStoreTests.swift`

**Rewritten or edited**

- `Sources/App/WorktreeConfigStore.swift` — repo-scope read and write (`--local --get`,
  `--get-all`, `--add`, `--unset-all`) beside the per-worktree pair, plus the two new key
  constants; argument building and parsing stay pure `static`s.
- `Sources/App/WorktreeGroupManager.swift` — loads from the config store, publishes groups,
  memberships, positions and grouping, routes every mutation through `enqueueWrite`; loses `save()`,
  the watcher hookup, `migrateLegacyStatuses`, the membership half of `reconcile` and
  `deduplicated`.
- `Sources/App/WorktreeGroup.swift` — name-only model, `id` derived from it, plus the
  name-availability `static`.
- `Sources/App/WorktreeStatus.swift` — both enums drop `Encodable` and the comments explaining it.
- `Sources/App/SidebarView.swift` — group identity becomes the name at the five sites in
  assumption 8; the New Group and Rename Group sheets pass the availability rule.
- `Sources/App/SidebarSheets.swift` — `CreateWorktreeSheet.targetGroupId` becomes a name;
  `NameEntrySheet` swaps `allowsEmptyName` for `isValid`.
- `Sources/App/ContentView.swift` — the seeding call at `:331` follows its rename. No line is
  added: the file is past SwiftLint's `file_length` error and lives on a file-wide disable.
- `Sources/App/SavedCommandStore.swift` — the doc comment's `groups.json` reference.
- `CLAUDE.md` — the `openFileWatcher` leak note (`:272-275`) goes; the `SavedCommandStore`
  (`:203`) and `DispatchSource` (`:97`) references to `WorktreeGroupStore` get a new subject; the
  architecture entry gains the four keys and the registry-last rule.
- `Tests/TestHelpers.swift` — `GroupsFile` and the two `groupsFile*` properties go; the two manager
  base classes merge into the git-backed one.
- `Tests/WorktreeGroupManagerTests.swift`, `Tests/WorktreeGroupManagerStatusTests.swift`,
  `Tests/WorktreeGroupManagerNameTests.swift` — moved onto the git base; the `groups.json`
  migration and duplicate-row cases go; the reorder cases keep their assertions over the new
  storage.
- `Tests/WorktreeConfigStoreTests.swift` — repo-scope round-trip: registry add, whole rewrite,
  order preservation, a name carrying regex metacharacters, grouping mode, and an extension-off
  read answering empty.

**New tests**

- The name-availability `static`: empty, whitespace-only, exact duplicate, a rename to the group's
  own current name, and a case-differing name accepted.
- Position reassignment preserving the slot of a row the caller omitted.
- A rename whose member writes fail leaving the registry untouched.

## Out of scope

- `.clearway/` and `commands.json`; `SavedCommandStore` stays exactly as it is apart from one doc
  comment.
- Reading, migrating or deleting an existing `groups.json`. It is left on disk untouched.
- Any change to how name and status are persisted by #226.
- Watching git config for edits made outside the app.
- Pruning a stale `clearway.group` or `clearway.position`, or an empty group whose last member was
  removed.
- The pre-existing main-actor and freeze concerns recorded as follow-ups by #226.
