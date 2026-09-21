# Reconcile WorktreeGroupManager state after a failed git-config write

**Date:** 2026-09-20
**Base:** b4369a5 (`Split buttons for Run and Open in (#237)`)

Every sidebar gesture publishes optimistically and queues its git-config write behind
`WorktreeGroupManager`'s write chain. Since PR #236 a failed write says so — a log line, and an
alert where the change is left half-applied on disk — but the manager keeps the optimistic value it
published, so memory goes on disagreeing with git until the worktree list next changes. That gap is
what makes the three defects the task names possible: the next `writeRegistry` snapshots the wrong
registry and commits it, `reassignedPositions` diffs against memory and so never re-sends a
position whose write was refused, and `deleteGroup`'s two chain entries can half-land. This change
closes the gap once: a write body now reports what it could not land, and the manager re-reads what
git holds for the affected worktrees and publishes that.

## Decisions

| # | Question | Decision | Source |
| --- | --- | --- | --- |
| 1 | Reload the affected worktrees' config from git, or revert the mutation the write belonged to? | **Reload.** A gesture is several independent writes — `addWorktree` writes a group and a position, `deleteGroup` enqueues its positions and its registry as two chain entries — so one of them landing and another failing is the normal failure, not the exception. A revert puts memory into a state neither git nor the user holds, because the half that landed stays on disk; only reading git can describe a half-applied gesture. A revert also needs a per-gesture undo snapshot that is already stale by the time the write fails: later gestures have published and queued behind it, and undoing one key can clobber a newer value that did land. Reload needs none of that, reuses `reloadConfig` (`Sources/App/WorktreeGroupManager.swift:376-410`) including its race guard, and makes the alert copy #236 shipped — "The sidebar will show what git holds" (`Sources/App/WorktreeGroupWriteAlert.swift:30-32`) — true at once instead of at the next worktree-list change. This supersedes decision 9 of `docs/superpowers/specs/2026-09-19-surface-failed-group-and-position-writes.md`. | Spec author |
| 2 | Where does the reconcile run? | In its own `Task`, outside the write chain, awaiting the chain the way `reloadConfig` already does — including the `guard writeChain == chain else { continue }` retry (`:391`). Running it *inside* the chain at the failure site would publish git's older value over a gesture that has already published optimistically and is still queued; that gesture's write would then land and memory would be stale in the other direction, with the sidebar visibly undoing a drag it never redoes. The existing guard is exactly the rule that avoids this, so it is reused rather than re-invented. | Spec author |
| 3 | What does the reconcile re-read? | Both repo-level keys, plus every worktree the manager has published any `clearway.*` value for, unioned with the paths the refused gesture wrote. Not a per-key targeted read: `readConfig` already reads all four worktree keys in one `--list` per worktree (`:423-463`), `reloadConfig` already reads both repo-level keys unconditionally (`:386-387`), and routing by key would add a second publish policy beside the one that exists. The union with the gesture's paths is load-bearing: a refused `setName(nil,…)` on a worktree with no group and no position names an id no published map holds. The published keys are read **inside `reloadConfig`'s retry loop, after it awaits the write chain**, not at the refusal — a `ReloadTargets.refusedWrite` case the reload resolves rather than a list the caller fixes. The publish rewrites `names`, `statuses` and `placement` wholesale, so a worktree taking its *first* gesture while the reads are in flight would be outside a set taken earlier, and the value git had just accepted for it would be erased from memory. | Spec author |
| 4 | How does a failed write reach the manager? | Through `enqueueWrite`, which is the one door every config write already goes through (`:149`, `:168`, `:244`, `:273`, `:281`, `:514`, `:643`). It comes to take the paths the gesture writes — `enqueueWrite(touching:)`, stated by the caller, which knows them before the write runs — and its `work` closure comes to return a `Bool`: whether everything it tried landed. `enqueueWrite`'s own `Task` starts the reconcile over those paths on a `false`. The body therefore still captures no manager, which is the property the note at `:465-468` protects; the one `[weak self]` lives in `enqueueWrite` itself. Making both the signature's terms rather than an opt-in helper is what stops a future write site forgetting, and the `landed` guard is what keeps a gesture whose writes all land from costing a `git` read. A repo-level write touches no worktree and passes `[]`; the reconcile it starts still re-reads both repo-level keys. | Spec author |
| 5 | Which writes trigger it? | Every write on the chain, `clearway.name` and `clearway.status` included. The mechanism is `enqueueWrite`'s contract, so carving out two of seven call sites would cost a special case and buy nothing — the reconcile reads all four worktree keys per worktree either way. **Restated after rebasing onto `origin/main`:** this branch was written when those two keys logged nothing and went through a bare `configStore.set`. PR #241 (`9615e29`) has since routed both through `Self.write`, which logs `clearway.name for <path> was not saved` and returns whether the write landed. The merged shape is that one helper serving both: `setName` and `setStatus` call `Self.write` inside `enqueueWrite(touching: [path])`, so #241 gets its log line and this branch gets the refusal that starts the reconcile, with the line emitted once by `write` and never repeated here. Every worktree-scoped write site is now uniform, which removes the carve-out the original wording protected. What this does supersede is #241's test assertion that a refused name or status *stays* published: decision 4 of that spec already said "the next `reconcile` republishes what git holds", and here the reconcile is immediate, so the value is published and then corrected rather than left standing. | Spec author |
| 6 | Does the reconcile seed positions afterwards, the way `reconcile(_:openIds:)` does? | No. `seedPositions` needs the live worktree list and an open-ids list, which a write body does not have, and a worktree the reconcile leaves unpositioned is seeded by the next `reconcile(_:openIds:)` on the same terms as one git never held a position for. | Spec author |
| 7 | Is the stale registry snapshot (defect one) fully closed? | Yes for every reachable case, with one named residual. `groups` can only disagree with git after a failed `writeRegistry`, and both of its failure modes raise the app-modal alert awaited inline on the chain (`:523`, `:533`; decision 8 of the #236 spec) — Apple, *runModal()* (fetched 2026-09-20): "Runs the alert as an app-modal dialog and returns the constant that identifies the button clicked." No sidebar gesture can be made while it is up, so the reconcile publishes before the next `writeRegistry` can snapshot. The residual is the few milliseconds between the user clicking OK and the reconcile's two `git config` reads returning; a gesture completed inside that window still snapshots unreconciled `groups`. Closing it would mean reading the registry at write time instead of at enqueue time, which does not help — a gesture enqueued before the reconcile runs is written before it too — or moving the reconcile into the chain, which decision 2 rejects. | Spec author |
| 8 | Does the alert or log copy change? | No, by the task brief. Two doc comments that promise the opposite of this change are corrected: `WorktreeGroupWriteAlert.informativeText`'s "which only runs when the worktree list changes" (`Sources/App/WorktreeGroupWriteAlert.swift:25-27`) and `reloadConfig`'s "a lost gesture would stay lost for the session" (`Sources/App/WorktreeGroupManager.swift:374-375`). | Spec author |
| 9 | How do tests wait for the reconcile? | A `private(set) var` holding the task, beside `writeChain` and `loadTask` (`:56`, `:60`), awaited by `WorktreeGroupManagerGitTestCase.settle()` after the chain (`Tests/TestHelpers.swift:232-235`). The handle is created inside the chain task before it returns, so awaiting the chain first is enough to see it. Nothing in production reads it, on the same terms as the two beside it. **Restated after rebasing onto `origin/main`:** PR #245 (`fa40b9c`) added a `reconcileTask` slot of its own, for the reconcile a worktree-list change starts, awaited *before* the chain because that reconcile's `seedPositions` enqueues a write. The two orders are both needed and the two slots are one slot, so the rebased shape is: `reconcile(_:openIds:)` and `reconcileAfterRefusedWrite` both assign it, both chaining on the previous, and `settle()` awaits it on either side of the chain — load, reconcile, chain, reconcile. This supersedes #245's decision 7, which declined to chain in order to keep that task's production diff non-behavioural; that constraint was #245's, not this branch's, and without chaining this branch's invariant — one handle covers every in-flight reconcile — is false, because a worktree-list change fired while a refused write's reconcile is still running would drop it where `tearDown` can no longer await it. Chaining also stops two wholesale publishes landing out of order. | Spec author |
| 10 | Where does the new code live? | The reconcile itself stays in `WorktreeGroupManager.swift`: it publishes `groups`, `grouping`, `names` and `statuses`, which are `private(set)` (`:14`, `:36`, `:39`, `:41`), and an extension in another file cannot set them — widening those to `internal(set)` would open them to every view. Room is made instead by moving the two pure ordering statics, `repositioned` and `reassignedPositions` (`:538-585`), into a new `Sources/App/WorktreeGroupManager+Ordering.swift`. They touch nothing private, they are already `static` and exercised directly by `Tests/WorktreeGroupManagerTests.swift`, and the file is at 667 lines against SwiftLint's 700-line `file_length` warning. | Spec author |
| 11 | What happens when the reconcile's own read fails? | Whatever is published stays, which is `readConfig`'s existing policy for a worktree whose read answered `nil` (`:420-422`, `:435-440`) and `reloadConfig`'s for a repo-level read that did (`:393-396`). The consequence worth stating: `values(forWorktreeAt:)` answers `[:]` for any refusal, because `--list` exits 128 on a worktree that simply has no `config.worktree` (`Sources/App/WorktreeConfigStore.swift:130-132`), so a repo-wide git outage reads as "holds nothing" and the reconcile publishes empty memberships, names and statuses. That is not new behaviour — `reloadConfig` does the same on every worktree-list change today — and it is accepted rather than fixed here. | Spec author |
| 12 | Does the optimistic publish itself change? | No. The sidebar still shows the gesture the instant it is made and never waits on a git subprocess. This change only decides what happens after a write is refused. | Spec author |
| 13 | Is a refused write retried? | No. The user is told (#236) and memory is corrected; retrying a write git has refused is a different feature and is not in this task. | Spec author |

## Assumptions

Each verified against the codebase at `b4369a5`. No probe was written and none was needed; the one
external claim (decision 7) is quoted from Apple's documentation with its fetch date.

1. **`enqueueWrite` is the only door for a config write.** Its seven call sites are the whole write
   surface — `addWorktree` (`:149`), `removeWorktreeFromGroup` (`:168`), `setStatus` (`:244`),
   `setName` (`:273`), `setGrouping` (`:281`), `writeRegistry` (`:514`) and `writePositions`
   (`:643`). Every other `configStore.` reference in the file is a read (`:68-69`, `:386-387`,
   `:428`). So changing its closure's return type reaches every write and can miss none — decision 4.
2. **`reloadConfig` already carries the race guard the reconcile needs.** It samples `writeChain`,
   performs its reads, and restarts if a gesture was enqueued while they were in flight
   (`:382-391`). The same guard is written a second time in `init` for the load
   (`:72-79`), so it is the established rule rather than a local trick.
3. **`readConfig` keeps published values for a worktree whose read could not be performed**
   (`:435-440`), and the store keeps `nil` and `[:]` apart for exactly that reason
   (`Sources/App/WorktreeConfigStore.swift:128-132`). So a reconcile whose own read fails is safe
   by construction — decision 11.
4. **A member's id is its path.** `Worktree.id` is `path ?? branch ?? ""`
   (`Sources/App/Worktree.swift:19`), and every writer of `groupNames`, `positions`, `names` and
   `statuses` refuses a worktree with no path (`:139`, `:162`, `:212`, `:241`, `:264`). So the
   reconcile can build its `(id, path)` targets from the published maps without a lookup.
5. **Main is never a key in any of those maps** (`:21-26`, `:34-39`), so targets built from them
   never name the main worktree, matching the targets `reloadConfig` builds (`:377-380`).
6. **The publish policy the reconcile needs already exists.** `reloadConfig` drops a membership
   naming a group the reloaded registry does not list (`:398-401`) and keeps `groups` when the
   registry read answered `nil` (`:396`). Reusing it is what stops a second, divergent policy.
7. **`repositioned` and `reassignedPositions` are pure statics over their parameters**
   (`:542-585`) and are called from `Tests/WorktreeGroupManagerTests.swift` by type name, so moving
   them to another file changes no call site and needs no access-level change — decision 10.
8. **The file-length budget is real and tight.** `.swiftlint.yml` sets `file_length` warning 700 /
   error 1000; `Sources/App/WorktreeGroupManager.swift` is 667 lines and `swiftlint lint --quiet`
   is currently silent. The ordering move frees 48 lines.
9. **The class body has room.** `type_body_length` warns at 500; the body is 417 non-blank,
   non-comment lines today, and the ordering move takes about 30 of those with it.
10. **`reconcile(_:openIds:)` is the only production caller of `reloadConfig`** (`:298`), reached
    from `ContentView.swift:349` only when the worktree list changes and `git worktree list`
    succeeded (`:347`). That is the whole of "nothing re-reads until the worktree list changes".
11. **The write chain and load task are already exposed as `private(set)` handles for the tests**
    (`:56`, `:60`), awaited by `settle()` (`Tests/TestHelpers.swift:232-235`). A third handle
    follows the pattern rather than establishing one — decision 9.
12. **The test base already replaces the alert presenter everywhere it builds a manager**
    (`Tests/TestHelpers.swift:250-256`), and the one suite that builds managers outside it installs
    its own (`Tests/WorktreeGroupPersistenceTests.swift:356-365`). No test can meet a modal, so the
    new cases inherit that.
13. **Production builds the manager in one place**, `Sources/App/ProjectWindow.swift:92`, and wires
    nothing this change adds.
14. **New files need no `project.yml` edit but do need `ci.sh`.** Both targets glob a directory
    (`project.yml:25-26`, `:303-304`) and `xcodegen generate` runs inside `ci.sh`.

## Objective

After a refused `git config` write, what the sidebar shows is what git holds — promptly, not at the
next worktree-list change. The three defects that follow from the stale optimistic state go with
it: a later registry write can no longer commit a half-applied rename, a position whose write was
refused is included again by the next drag, and a delete whose two chain entries half-land leaves
memory describing the half that landed.

### Success criteria

- A rename or delete whose member writes fail republishes what git holds — the old group name, and
  each member's stored membership — in the same manager, with no relaunch and no worktree-list
  change.
- A position write that is refused leaves `positions` holding git's value, so the next drag that
  assigns that value is a real change and is written.
- A refused `clearway.grouping` write leaves `grouping` holding git's value.
- A gesture whose writes all land triggers no reconcile and no extra `git config` read.
- The reconcile publishes only after the write chain is quiet: a gesture enqueued while its reads
  are in flight is not published over.
- The alert and log text shipped in #236 are unchanged, and the two doc comments that promised the
  old behaviour no longer do.
- `WorktreeConfigStore` is unchanged by this branch. Rebasing onto `origin/main` brings PR #240
  (`3ed10b7`), which makes the store's own failure log public in release builds; that is main's
  change and this branch neither extends nor undoes it.
- No test opens a modal, and `settle()` covers the reconcile so a case can assert on what it
  published — on either side of the write chain, so it covers a `reconcile(_:openIds:)` a body
  dropped as well as the one a refused write starts.
- `./scripts/ci.sh` green, `swiftlint lint --quiet` with zero errors and no new warnings —
  including `file_length` on `Sources/App/WorktreeGroupManager.swift`.

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

**New**

- `Sources/App/WorktreeGroupManager+Ordering.swift` — `repositioned` and `reassignedPositions`,
  moved verbatim with their documentation, to keep the manager under the `file_length` warning.

**Edited**

- `Sources/App/WorktreeGroupManager.swift` — `enqueueWrite`'s closure returns what it could not
  land, and its task starts the reconcile; the seven write bodies report their refusals, which
  means `Self.write` answering `Bool` and the `Bool`s at `:244`, `:273`, `:281`, `:516` and `:527`
  being carried out rather than dropped; `reloadConfig` takes its targets as a parameter so the
  reconcile can build them from the published maps; the reconcile task and its handle; the two
  ordering statics leave; the corrected doc comment at `:374-375`.
- `Sources/App/WorktreeGroupWriteAlert.swift` — the `informativeText` doc comment only.
- `Tests/TestHelpers.swift` — `settle()` awaits the reconcile on both sides of the write chain, and
  the two `GitRepoFixture` helpers a refusal needs: the worktree's own git directory, and the
  permission bits that make git refuse a write while the matching read still succeeds.
- `Tests/WorktreeGroupPersistenceTests.swift` — the two existing abandoned-registry cases assert
  that the manager republishes what git holds, and new cases cover the refused position write, the
  refused `clearway.grouping` write, and a landed gesture triggering nothing.

## Out of scope

- Retrying a refused write, or any change to *why* git refused it.
- Any change to `WorktreeConfigStore`.
- The log lines and alert copy from #236. Lines for `clearway.name` and `clearway.status` are
  PR #241's, rebased over rather than added here — decision 5 widens only the reconcile trigger.
- Pessimistic publishing: the sidebar still shows a gesture before its write lands.
- The reload publishing empty values during a repo-wide git outage — pre-existing in
  `reloadConfig`, recorded in decision 11.
