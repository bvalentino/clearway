# Clear the three pre-existing SwiftLint warnings

**Date:** 2026-09-19
**Base:** 484482d3fe5e7e539176c4c1f8ae5720d5414836

`swiftlint lint --quiet` prints three warnings and zero errors, none of them recent: two
`optional_data_string_conversion` hits on the two places `WorktreeConfigStore` turns git's stdout
into text, and one `unneeded_synthesized_initializer` hit on `WorktreeDraft`'s `init() {}`. This
change clears all three at the call sites — the two decodings adopt the failable
`String(data:encoding:)` the rest of the app already uses for git output, and the initializer keeps
its job behind a one-line suppression, because deleting it would widen the type's API. After it,
lint output is empty and the next warning to appear is a new one.

## Decisions

| # | Question | Decision | Source |
| --- | --- | --- | --- |
| 1 | Fix the three sites, or add the two rules to `disabled_rules` in `.swiftlint.yml`? | Fix the sites. The config's `disabled_rules` list (`.swiftlint.yml:10-19`) is for rules the project rejects wholesale; both of these are right in general and the project wants them on new code (`CLAUDE.md`, "Linting"). Turning either off repo-wide would hide future genuine hits, which is the opposite of what the task asks for. | Spec author |
| 2 | What replaces `String(decoding: data, as: UTF8.self)`? | `String(data: data, encoding: .utf8)`, listed verbatim as a non-triggering example in the rule's documentation (realm.github.io/SwiftLint/optional_data_string_conversion.html, fetched 2026-09-19). It is also the shape the rest of the app already uses on process stdout — `Worktree.swift:357`, `Worktree.swift:401`, `OpenInAppLauncher.swift:98` — so this makes the file consistent rather than novel. | Spec author |
| 3 | What does `values(forWorktreeAt:)` (`:99`) answer when the bytes are not valid UTF-8? | `nil`. The function's own contract keeps `nil` and `[:]` apart on purpose (`WorktreeConfigStore.swift:82-89`): `nil` means the read could not be performed and the caller keeps showing the name and status it has, `[:]` means the worktree genuinely holds nothing and the caller drops them. Output that cannot be decoded is the first kind, so `guard let text = String(data: data, encoding: .utf8) else { return nil }`. A `?? ""` here would quietly claim the second. | Spec author |
| 4 | What does `trimmed(_:)` (`:266`) answer for the same bytes? | `""`, via `String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""` — the exact shape at `Worktree.swift:401`. All three callers already treat an empty result as "nothing usable": `trimmed(data) == "true"` falls to `.off` (`:163`), the common dir hits `guard !commonDir.isEmpty` and logs (`:191-195`), and a moved key hits `guard !value.isEmpty else { continue }` (`:201-202`). Returning `String?` instead would add three nil branches for a condition the store cannot produce. | Spec author |
| 5 | Delete `WorktreeDraft.init() {}` as the rule suggests, or suppress the rule? | Suppress, with `// swiftlint:disable:next unneeded_synthesized_initializer` above the existing declaration. The rule triggers on exactly this shape by design — "empty initializers when all properties have defaults" — and its only documented escape is an init with `private`/`fileprivate` access (realm.github.io/SwiftLint/unneeded_synthesized_initializer.html, fetched 2026-09-19), which this init must not have. It cannot see that the init exists to suppress the *memberwise* one, and assumption 5 shows deleting it restores an internal `init(name:branch:branchIsHandEdited:)` that can build a state no mutator can reach. The rule is correctable, so leaving the warning standing also leaves a `--fix` run able to delete the guard. | Spec author |
| 6 | Instead of suppressing, restructure so the memberwise initializer is private by construction? | No. Assumption 6 shows one `private` stored property would do it, but `branchIsHandEdited` would then need a private store plus an internal computed forwarder: indirection with no product meaning, added only to satisfy a linter. The tidier-looking model — a single `private var handEditedBranch: String?` with `branch` computed as `handEditedBranch ?? slug(name)` — is also wrong: `Tests/WorktreeDraftTests.swift:67-77` pins that clearing the branch leaves the field empty until the next name keystroke, and that model refills it immediately. | Spec author |
| 7 | Does the doc comment above `init()` stay? | Yes, unchanged. It already states why the initializer exists (`WorktreeDraft.swift:13-16`), which is what makes the suppression legitimate rather than noise; the directive goes between it and the declaration. This is a comment that "preserves context and prevents a regression" in the sense `CLAUDE.md` allows. | Spec author |
| 8 | Any new tests? | None. Every behaviour the existing suites exercise is untouched — `Tests/WorktreeConfigStoreTests.swift` drives `parseList` and a real repository, `Tests/WorktreeDraftTests.swift` drives the draft through its mutators. The only delta is git stdout that is not valid UTF-8, which the store cannot produce (values reach git as Swift `String`s through `setArgs`), so pinning it would mean writing raw bytes into `config.worktree` behind the store's back to cover a path with no product meaning. | Spec author |
| 9 | Make warnings fail the gate, e.g. `swiftlint lint --strict` in `scripts/ci.sh`? | Not here. The task asks for clean output, not a policy change, and `CLAUDE.md` states the current policy ("Warnings are acceptable for now but should not be introduced in new code"). Recorded as a follow-up. | Spec author |

## Assumptions

Each verified against the codebase at base `484482d`. Two Swift access-level probes (assumptions 5
and 6) ran entirely in the scratchpad as throwaway `swiftc -typecheck` files; nothing was written
into the repository.

1. **The three warnings are the whole of the lint output.** `swiftlint lint --quiet` (SwiftLint
   0.63.2) at base printed exactly `WorktreeConfigStore.swift:99:35`,
   `WorktreeConfigStore.swift:266:9` and `WorktreeDraft.swift:17:5`, and nothing else. So clearing
   them empties the output rather than merely shortening it.
2. **Both rules are on by default and neither is configured here.** Each rule page states
   "Opt-in: No (enabled by default)" (fetched 2026-09-19), and `.swiftlint.yml` names neither in its
   nine `disabled_rules` nor in any per-rule block.
3. **The third `String(decoding:as:)` in the repository is out of the linter's reach.**
   `Sources/Ghostty/Ghostty.App.swift:104` decodes an `UnsafeBufferPointer`, not `Data`, and
   `Sources/Ghostty` is excluded from linting (`.swiftlint.yml:6-7`). It is untouched.
4. **The two initializers differ only on invalid UTF-8.** `String(decoding:as:)` substitutes U+FFFD
   and always succeeds; `String(data:encoding:)` returns `nil`. For every byte sequence git produces
   from values Clearway wrote — all of them Swift strings — the two are identical, so the existing
   tests keep covering the same behaviour.
5. **`private(set)` does not suppress or narrow the synthesized memberwise initializer**, which is
   what `WorktreeDraft.swift:13-16` asserts and what makes `init() {}` load-bearing. Probe: a struct
   with three `private(set) var` properties, all defaulted, compiled against
   `DraftA(name: "n", branch: "", handEdited: true)` from a second file.
6. **A `private` stored property makes the memberwise initializer unreachable from another file
   while the no-argument default initializer stays internal.** Probe: the same struct with
   `handEdited` as `private var` rejected the memberwise call with "extra argument 'handEdited' in
   call" while `DraftB()` from that other file compiled. This is the alternative decision 6 turns
   down, not a hypothetical.
7. **Nothing constructs `WorktreeDraft` memberwise today.** The only construction sites are
   `SidebarSheets.swift:10` and the `WorktreeDraft()` calls in `Tests/WorktreeDraftTests.swift`. So
   deleting `init()` would not break the build — it would silently open the door, which is precisely
   why the warning must be answered deliberately rather than autocorrected.
8. **Warnings do not fail the gate today.** `scripts/ci.sh:13-14` runs `swiftlint lint --quiet`,
   which exits non-zero on errors only, so this change alters no gate behaviour.

## Objective

`swiftlint lint --quiet` prints nothing, with no behaviour lost and no guard weakened, so that the
next line it prints is a warning the current change introduced.

Success criteria:

1. `swiftlint lint --quiet` produces no output at all.
2. No suppression is added that a reader cannot justify from the line above it: the only
   `swiftlint:disable` this change adds is the one on `WorktreeDraft.init()`, and nothing is added
   to `.swiftlint.yml`.
3. `WorktreeDraft`'s memberwise initializer stays unavailable outside the type.
4. `./scripts/ci.sh` is green.

## Verification

```bash
swiftlint lint --quiet   # must print nothing
./scripts/ci.sh
```

`ci.sh` is the project's one runner: it regenerates the Xcode project, lints, builds and runs the
suite. A hand-written `xcodebuild` line is not a substitute (`CLAUDE.md`, "Verifying a change").

Before sign-off, `git status --porcelain`, and report anything untracked — including the
un-gitignored `default.profraw` a Debug launch leaves behind.

## Files touched

- `Sources/App/WorktreeConfigStore.swift` — the decoding at `:99` and the `trimmed(_:)` helper at
  `:265-267`.
- `Sources/App/WorktreeDraft.swift` — one directive line above `init()`.
- `docs/superpowers/specs/2026-09-19-clear-the-three-pre-existing-swiftlint-warnings.md` — this file.

## Out of scope

- **`.swiftlint.yml`.** No rule is disabled, enabled or reconfigured; see decision 1.
- **`scripts/ci.sh` and `--strict`.** Making warnings fail the gate is a policy change the task does
  not ask for; see decision 9.
- **`Sources/Ghostty`.** Excluded from linting, and its one `String(decoding:as:)` decodes a buffer
  rather than `Data`; see assumption 3.
- **`WorktreeDraft`'s state model.** The draft's rules and its tests stay exactly as they are; this
  change adds one comment line to the file and nothing else.
- **Every other pre-existing defect in the touched files**, including the deliberate
  `WorktreeGroupStore.openFileWatcher` leak recorded in `CLAUDE.md`.
