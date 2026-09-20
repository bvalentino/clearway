# Plan: Clear the three pre-existing SwiftLint warnings

**Date:** 2026-09-19
**Base:** 484482d3fe5e7e539176c4c1f8ae5720d5414836

Breaks down `docs/superpowers/specs/2026-09-19-clear-the-three-pre-existing-swiftlint-warnings.md`.

## Architecture decisions carried from the spec

1. The three warnings are fixed at their call sites. Nothing is added to `.swiftlint.yml` — no rule
   is disabled, enabled or reconfigured. Both rules are right in general and the project wants them
   live on new code (spec decision 1).
2. `String(decoding: data, as: UTF8.self)` becomes `String(data: data, encoding: .utf8)` — the
   rule's own non-triggering example, and the shape the rest of the app already uses on process
   stdout (`Worktree.swift:357`, `Worktree.swift:401`, `OpenInAppLauncher.swift:98`). Not
   `String(bytes:encoding:)`, despite the warning text naming it (spec decision 2).
3. `values(forWorktreeAt:)` answers `nil` on bytes that are not valid UTF-8. The function keeps
   `nil` and `[:]` apart on purpose: `nil` means the read could not be performed and the caller
   keeps the name and status it is showing, `[:]` means the worktree genuinely holds nothing. A
   `?? [:]` or `?? ""` here would quietly claim the second (spec decision 3).
4. `trimmed(_:)` answers `""` for the same bytes, via `?? ""`. All three of its callers already
   treat an empty result as "nothing usable" (`:163`, `:191-195`, `:201-202`), so returning
   `String?` would add three nil branches for a condition the store cannot produce (spec decision 4).
5. `WorktreeDraft.init() {}` is **kept** and the rule suppressed with one
   `// swiftlint:disable:this unneeded_synthesized_initializer` directive. Deleting it — what the rule
   and `--fix` would do — restores an internal memberwise `init(name:branch:branchIsHandEdited:)`
   that can build a hand-edited draft with an empty branch, a state no mutator can reach. The rule's
   only documented escape is a `private`/`fileprivate` init, which this one must not have (spec
   decision 5).
6. The `private` stored-property restructure that would make the memberwise initializer unreachable
   by construction is rejected: it needs a private store plus an internal computed forwarder for
   `branchIsHandEdited`, indirection with no product meaning, and the tidier single-property variant
   contradicts what `Tests/WorktreeDraftTests.swift:67-77` pins (spec decision 6).
7. The doc comment above `init()` (`WorktreeDraft.swift:13-16`) stays unchanged. The directive goes
   **on the declaration line** as `disable:this`, not on a separate `disable:next` line between the
   comment and the declaration: a `//` line there detaches the `///` block from what it documents
   and trips `orphaned_doc_comment` (spec decision 7, revised during T2).
8. No new tests. The only behavioural delta is git stdout that is not valid UTF-8, which the store
   cannot produce — every value reaches git as a Swift `String` through `setArgs` — so pinning it
   would mean writing raw bytes into `config.worktree` behind the store's back (spec decision 8).
9. `swiftlint lint --strict` in `scripts/ci.sh` is out of scope. Warnings not failing the gate is
   current stated policy; changing it is a policy change the task does not ask for (spec decision 9).
10. `Sources/Ghostty/Ghostty.App.swift:104` is untouched: it decodes an `UnsafeBufferPointer`, not
    `Data`, and `Sources/Ghostty` is excluded from linting (`.swiftlint.yml:6-7`).

## Dependency graph

```
T1 (WorktreeConfigStore: two decodings)
T2 (WorktreeDraft: one directive)
```

No edges. The two tasks touch different files, answer different rules, and neither reads anything
the other writes. They may run in either order or in parallel. Lint output is empty only after both
have landed, so each task's lint check is scoped to its own file.

## Task list

### T1: Decode git stdout failably in `WorktreeConfigStore`

**Files**

- `Sources/App/WorktreeConfigStore.swift`

**What it does**

Replaces the file's two `String(decoding:as:)` calls with the failable
`String(data:encoding:)`, giving each site the answer its own contract already implies.

At `:99`, inside `values(forWorktreeAt:)`'s `case .output(let data):`, currently:

```swift
return Self.parseList(String(decoding: data, as: UTF8.self))
```

becomes a guard that returns `nil` when the bytes do not decode:

```swift
guard let text = String(data: data, encoding: .utf8) else { return nil }
return Self.parseList(text)
```

`nil`, not `[:]` — see decision 3. Do not add a `log(...)` call on that branch; the surrounding
`.unavailable` case logs because git reported a message, and there is none here. The doc comment
above the function (`:82-89`) already describes the `nil`/`[:]` split and needs no change.

At `:265-267`, the private helper currently:

```swift
private func trimmed(_ data: Data) -> String {
    String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
}
```

becomes, matching `Worktree.swift:401` exactly:

```swift
private func trimmed(_ data: Data) -> String {
    String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
}
```

Its return type stays `String` — see decision 4. Its three callers (`:163`, `:191-195`, `:201-202`)
are untouched.

Add no comment at either site, and change nothing else in the file — in particular not the
deliberate behaviour of `parseList`, `extensionState`, or any other pre-existing defect there.

**Acceptance criteria**

- `Sources/App/WorktreeConfigStore.swift` contains no `String(decoding:` occurrence.
- `values(forWorktreeAt:)` returns `nil`, not `[:]`, when `.output` data fails to decode;
  `trimmed(_:)` still returns a non-optional `String` and answers `""` in the same case.
- Nothing is added to `.swiftlint.yml`, and no `swiftlint:disable` appears in this file.
- Every existing test in `Tests/WorktreeConfigStoreTests.swift` passes unmodified.

**Verification**

`swiftlint lint --quiet` prints no warning for `WorktreeConfigStore.swift` (the
`WorktreeDraft.swift:17` warning may still stand until T2 lands). `./scripts/ci.sh` is green.

### T2: Keep `WorktreeDraft.init()` behind a one-line suppression

**Files**

- `Sources/App/WorktreeDraft.swift`

**What it does**

Appends one directive to `init() {}` (`:17`), leaving the existing doc comment (`:13-16`) attached
to it, so the file reads:

```swift
    /// Declared so the synthesized memberwise initializer is not: `private(set)` does not
    /// suppress it, and it would let a caller build a hand-edited draft with an empty branch —
    /// a state no mutator can reach, which neither regenerates from the name nor creates.
    init() {} // swiftlint:disable:this unneeded_synthesized_initializer
```

`disable:this`, not a file-wide `swiftlint:disable` and not a `disable`/`enable` pair — the
suppression must cover this one declaration and nothing else. A separate `disable:next` line
between the doc comment and the declaration covers the same one declaration but detaches the
comment from it, trading the target warning for `orphaned_doc_comment`; see decision 7 and the
build log. The doc comment is not reworded, reordered or extended; the directive does not restate
it. `init()` keeps internal access: making it
`private` or `fileprivate` would also silence the rule but would break `SidebarSheets.swift:10` and
the `WorktreeDraft()` calls in `Tests/WorktreeDraftTests.swift`.

Do not delete `init()`, do not run `swiftlint --fix` against this file, and change nothing else —
no property access levels, no mutators, no `slug`.

**Acceptance criteria**

- `WorktreeDraft.init() {}` still exists with internal access, and the three stored properties keep
  their `private(set) var` declarations, so the memberwise initializer stays unavailable outside the
  type.
- The file's only diff is the directive appended to the `init()` line.
- `swiftlint lint --quiet` reports neither `unneeded_synthesized_initializer` nor
  `superfluous_disable_command` for this file — the second is the check that the directive is
  actually silencing something rather than sitting unused.
- Every existing test in `Tests/WorktreeDraftTests.swift` passes unmodified.

**Verification**

`swiftlint lint --quiet` prints no warning for `WorktreeDraft.swift`. `./scripts/ci.sh` is green.

## Exit condition

After both tasks: `swiftlint lint --quiet` prints nothing at all, `./scripts/ci.sh` is green, and
the diff against base is four changed lines across two files, with
`.swiftlint.yml` and `scripts/ci.sh` untouched.

## Risks

| Risk | Impact | Mitigation |
| --- | --- | --- |
| `--fix` or a future autocorrect run deletes `WorktreeDraft.init()` | High — silently reopens the memberwise initializer | T2's directive stops the rule firing at all, so there is nothing left for `--fix` to correct |
| `String(data:encoding:)` does not satisfy `optional_data_string_conversion` | Blocks the objective | Both replacement shapes were run through `swiftlint lint --quiet` on a scratchpad file at plan time and produced no output |
| A build agent "tidies" the `?? ""` in `trimmed(_:)` into an optional return | Medium — three new nil branches for an unreachable condition | Decision 4 and T1's acceptance criteria pin the non-optional return type |

## Build log

### T1: Decode git stdout failably in `WorktreeConfigStore`

**What landed**

| File | State |
| --- | --- |
| `Sources/App/WorktreeConfigStore.swift` | `values(forWorktreeAt:)` `:99` now guards `String(data:encoding:)` and returns `nil` when the bytes do not decode; `trimmed(_:)` `:266` now uses `String(data:encoding:)?.trimmingCharacters(...) ?? ""` and keeps its non-optional `String` return. No other change; no `swiftlint:disable` added. |
| `.swiftlint.yml`, `scripts/ci.sh` | Untouched. |
| `Tests/WorktreeConfigStoreTests.swift` | Unmodified; passes. |

**Evidence**

Both warnings observed at base `484482d` before the change, via `swiftlint lint --quiet`:

```
Sources/App/WorktreeConfigStore.swift:99:35: warning: Optional Data -> String Conversion Violation: Prefer failable `String(bytes:encoding:)` initializer when converting `Data` to `String` (optional_data_string_conversion)
Sources/App/WorktreeConfigStore.swift:266:9: warning: Optional Data -> String Conversion Violation: Prefer failable `String(bytes:encoding:)` initializer when converting `Data` to `String` (optional_data_string_conversion)
```

After the change `swiftlint lint --quiet` prints only the `WorktreeDraft.swift:17:5` warning T2
owns, and `grep -n 'String(decoding:' Sources/App/WorktreeConfigStore.swift` returns nothing.

No new test. Spec decision 8 stands unchanged: the only behavioural delta is git stdout that is not
valid UTF-8, which the store cannot produce because every value reaches git as a Swift `String`
through `setArgs`. There is therefore no failure to watch go red, and no regression test is claimed
here — the lint output above is the whole of the evidence.

**Deviations from the plan**

None. Both replacements are the exact shapes T1 specifies, and `trimmed(_:)`'s three callers were
not touched.

**Gate**

`./scripts/ci.sh` — green. `Executed 535 tests, with 0 failures (0 unexpected)`; the script runs
under `set -euo pipefail` and reached its final `==> CI passed.` line, so exit status 0.

### T2: Keep `WorktreeDraft.init()` behind a one-line suppression

**What landed**

| File | State |
| --- | --- |
| `Sources/App/WorktreeDraft.swift` | `init() {}` at `:17` now carries a trailing `// swiftlint:disable:this unneeded_synthesized_initializer`. Internal access kept; the three stored properties keep `private(set) var`; the doc comment at `:14-16` is unchanged and still attached to the declaration. |
| `.swiftlint.yml`, `scripts/ci.sh` | Untouched. |
| `Tests/WorktreeDraftTests.swift` | Unmodified; passes. |

**Evidence**

The warning T2 owns, observed before the change via `swiftlint lint --quiet`:

```
Sources/App/WorktreeDraft.swift:17:5: warning: Unneeded Synthesized Initializer Violation: This default initializer would be synthesized automatically - you do not need to define it (unneeded_synthesized_initializer)
```

After the change `swiftlint lint --quiet --no-cache` prints nothing at all, which is the plan's
exit condition now that T1 has landed.

That the directive is load-bearing rather than decorative was checked directly, not assumed. The
plan's third acceptance criterion rests on `superfluous_disable_command` staying silent, so that
rule was first confirmed to be live in this configuration: appending a second, non-violated rule to
the same directive produced

```
Sources/App/WorktreeDraft.swift:17:1: warning: Superfluous Disable Command Violation: SwiftLint rule 'todo' did not trigger a violation in the disabled region; remove the disable command (superfluous_disable_command)
```

and removing it returned the file to clean. So the absence of that warning for
`unneeded_synthesized_initializer` is evidence the directive suppresses a real violation.

No new test. Spec decision 8 stands: the change adds no reachable behaviour — it is a linter
directive — so there is no failure to watch go red, and no regression test is claimed. The lint
output above is the whole of the evidence.

**Deviations from the plan**

One, forced by the linter, and since accepted by the operator: spec decision 7, carried decision 7
above and T2's body have been rewritten to the landed placement, so what follows is the record of
why it changed. T2 originally specified `// swiftlint:disable:next unneeded_synthesized_initializer`
on its own line *between* the doc comment and `init()`. That placement clears the
target warning but introduces a new one, because a `//` line between a `///` block and its
declaration detaches the two:

```
Sources/App/WorktreeDraft.swift:14:5: warning: Orphaned Doc Comment Violation: A doc comment should be attached to a declaration (orphaned_doc_comment)
```

Trading one warning for another fails the objective, so the directive moved onto the declaration
line itself as `disable:this`. This keeps every constraint the plan and spec actually argue for:
the suppression still covers exactly one declaration and no region, the doc comment is unchanged
and stays attached — which is what decision 7 set out to protect — and the diff is still a
single line. `disable:next` above the doc comment was rejected as well: it would cover the comment
line rather than the declaration, leaving the rule to fire and adding a superfluous command.

**Gate**

`./scripts/ci.sh` — green, run after the final edit. `Executed 535 tests, with 0 failures
(0 unexpected)`; the script runs under `set -euo pipefail` and reached its final `==> CI passed.`
line, so exit status 0.

### Simplify

Nothing simplified: the four-line code diff came back clean on reuse and efficiency, and the two
quality findings were both declined. Collapsing `values(forWorktreeAt:)`'s guard into
`String(data:encoding:).map(Self.parseList)` loses the explicit failure branch decision 3 pins and
reads as `Sequence.map` over the dictionary it returns; `WorkTaskManager.swift:410` already uses the
same guard shape. Extracting `trimmed(_:)`'s decode-trim-fallback into a helper shared with
`Worktree.swift:401` would edit a file outside this change for two call sites of a one-liner —
recorded as a follow-up instead.

Docs only: spec decision 7 (and decision 5, "Files touched" and "Out of scope", plus the plan's
carried decisions 5 and 7, T2's body, its second acceptance criterion and the exit condition) now
state the landed `disable:this` placement and why `disable:next` was rejected. No code changed.

**Gate**

`./scripts/ci.sh` — green, run after the final edit. `Executed 535 tests, with 0 failures
(0 unexpected)`, `==> CI passed.`, exit status 0. `swiftlint lint --quiet --no-cache` prints
nothing, exit status 0.

A first run of the gate, made while four review subagents were running, exited 65 on
`ShellPathStoreTests.testADegradedValueIsReturnedWithoutWaiting()` — a wall-clock assertion
(`XCTAssertLessThan(Date().timeIntervalSince(started), 0.2)` against a 0.3s fake delay,
`Tests/ShellPathStoreTests.swift:120-132`) that this branch does not touch and that predates it
(`d7768d4`, PR #202). It passed on the unloaded re-run. Recorded as a follow-up, not fixed here.

## Changelog

### Log the non-UTF-8 read in `values(forWorktreeAt:)` (review follow-up)

Review approved the branch with one accepted suggestion. The guard added by T1 in
`Sources/App/WorktreeConfigStore.swift` returned `nil` silently while the `.unavailable` branch
three lines below logged, so it now calls the file's `log(_:_:)` helper first:

```swift
guard let text = String(data: data, encoding: .utf8) else {
    log("read \(path)", "git printed bytes that are not UTF-8")
    return nil
}
```

Recorded as spec decision 10. No behaviour change beyond the warning line — the function still
answers `nil`, which spec decision 3 fixed. No test added: the store cannot produce non-UTF-8 git
stdout (spec decision 8), and that is unchanged by logging.

**Gate**

`./scripts/ci.sh` — green, run after the edit. `swiftlint lint --quiet` prints nothing.

### PR review (`code tests errors types`)

Four reviewers read `git diff main...HEAD` from fresh context. The code reviewer found nothing at
or above threshold; the type reviewer agreed with every binding decision and returned "ship as-is".
No code changed. One docs correction landed, and three follow-ups were recorded rather than taken.

**Corrected**

Spec decision 4's rationale claimed "all three callers already treat an empty result as 'nothing
usable'" and that the empty case is "a condition the store cannot produce". Two reviewers
independently showed both halves are loose: the third caller (`:205-206`) concludes *the key is not
set* and the bootstrap then enables the extension, which is not "nothing usable"; and none of
`trimmed(_:)`'s three inputs is a value Clearway wrote — they are git's canonicalised bool, a
`rev-parse` path, and `core.bare`/`core.worktree` as another tool left them. The decision's outcome
(`?? ""`, non-optional return) is unchanged and still right; only the reasoning a future editor
would rely on was rewritten.

**Follow-ups, not taken here**

1. **No log beside the `continue` at `WorktreeConfigStore.swift:206`.** Raised by two reviewers. An
   undecodable `core.worktree` now yields `""`, skips the key, and the bootstrap still enables the
   extension — leaving `core.worktree` in `$GIT_DIR/config`, the state git-worktree(1) warns about,
   with no log, where the sibling failure at `:222-224` does log. Both reviewers rated it low and
   both noted the change is a strict improvement here: at base the U+FFFD-mangled path was *written*
   into `config.worktree` and the real one unset. The branch is pre-existing — it already fires
   un-logged for genuinely empty output — and spec decision 4 and T1 both pin `trimmed(_:)`'s three
   callers as untouched, so the Decisions table wins. Same one-line fix would correct the
   misattributed "git printed no path" message at `:197`.
2. **A test pinning the non-UTF-8 read as `nil`.** An explicit disagreement with spec decision 8,
   rated 5 of 10 by its author, who wrote they "would not hold the branch for them". Decision 8's
   premise is right about what Clearway *writes* and loose about what the store *reads*: the
   reviewer verified against git 2.54.0 that `git config --worktree clearway.name "$(printf
   'caf\xe9')"` stores and echoes raw bytes at exit 0, so the branch is reachable by a hand edit or
   a foreign-locale script. The table wins here too; the value of the test would be regression
   cover on decision 3's `nil`/`[:]` split, not on the scenario.
3. **`values(forWorktreeAt:)` returns `[String: String]?` where the file names the same distinction
   as an enum twice** (`ExtensionState.unknown`, `GitOutcome.unavailable`). `?? [:]` compiles, reads
   naturally, and silently converts "unreadable" into "genuinely empty" — the mistake decisions 3
   and 10 exist to prevent. Worth an enum if this API ever gains a second caller; it has exactly
   one today (`WorktreeGroupManager.swift:394`).

**Gate**

Not run — `sign-off` owns the single full gate run. This entry and the spec edit are docs only.
