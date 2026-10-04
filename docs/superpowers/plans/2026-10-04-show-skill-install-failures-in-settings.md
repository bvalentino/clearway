# Plan: Show skill install failures in Settings

Breaks down `docs/superpowers/specs/2026-10-04-show-skill-install-failures-in-settings.md`.

**Date:** 2026-10-04
**Base:** be4a80f (Bundle clearway skill and add skill installer to Settings, #268)

The spec's Decisions table (E1-E9) is the source of truth, on top of D1-D15 of
`2026-10-04-clearway-skills.md`. This plan orders the work and says how each piece is verified.
Where it fixes a detail the spec leaves open, it says so.

## Architecture decisions carried from the spec

- E1: `SkillInstaller.install(home:bundlePath:)` and `uninstall(home:bundlePath:)` return
  `[SkillInstaller.Failure]`, one per entry whose link or removal threw. `Failure` holds the entry's
  `displayPath`, an action (`link` or `remove`) and a `reason: String`, and exposes `message`.
  Nothing is written to disk; `SkillInstallStatus` stays a pure disk read.
- E2: `Failure.message` is "`<displayPath>` could not be linked: `<reason>`." or
  "`<displayPath>` could not be removed: `<reason>`."
- E3: `reason` is the `strerror` text of the POSIX error under the thrown `NSError`'s
  `NSUnderlyingErrorKey` (domain `NSPOSIXErrorDomain`), e.g. "Permission denied"; for `rename(2)` it
  is `strerror(errno)`; with no POSIX error underneath, `localizedDescription`.
- E4: new `EntryState.unreadable(reason: String)`. `state()` returns `.missing` only when
  `attributesOfItem` fails with POSIX `ENOENT`; any other failure is `.unreadable` with the E3 reason.
  Install and Uninstall skip it. `SkillInstallStatus.messages` adds
  "`<displayPath>` could not be read: `<reason>`." It does not block `isInstalled`.
- E5: Install replaces a `stale` link by creating the new link at `<container>/.<linkName>.<UUID>`
  and `rename(2)`-ing it over the stale one. Temp creation fails: stale link untouched. Rename fails:
  temp link removed, stale link untouched. `missing` still creates the link directly at its path.
  Never remove a stale link before its replacement exists.
- E6: the view keeps the last action's failures in `@State`, replaced by the next action's result,
  cleared on appear.
- E7: lines render failures first, then `status.messages`, all in the existing red `Label`
  (`exclamationmark.triangle`, `.callout`).
- E8: every `\(error)` interpolation in `SkillInstaller` and `AgentHookInstaller` log calls is
  `privacy: .public`.
- E9: Uninstall reports a `remove` failure per entry whose removal threw; an unstat-able entry is
  already shown via E4.

**Detail this plan fixes (not in the spec):** in `SkillInstallStatus.messages`, the per-entry lines
(foreign and unreadable) come in `Target` order, followed by the no-agent line. Foreign-only output is
unchanged from today, so existing tests hold.

## Constraints for every task

- Verify with `./scripts/ci.sh` (the regression check). It regenerates the project, lints, builds and
  tests. Never hand-write an `xcodebuild` line and never launch the app or take screenshots.
- Tests live in `SkillInstallerTests` (a `TempRootTestCase`); `home` is the temp root, never the real
  home. Every mode or ACL change is undone in a `defer` so the temp root can be deleted
  (pattern: `Tests/TaskFilesTests.swift:83-84`).
- Existing test assertions stay unchanged (spec criterion 6). Extending a test with new assertions is
  fine.
- No new comments unless they preserve context or prevent a regression (user CLAUDE.md).

## Dependency graph

```
T1 (Failure, return values, unreadable state)
 ├── T2 (rename replace of stale links)
 └── T3 (Settings renders failures)
        T2 + T3 ──> T4 (log privacy in AgentHookInstaller, Sources/App/CLAUDE.md)
```

T2 and T3 touch disjoint files and may run in either order.

### T1: Return failures and add the unreadable state

**Files:** `Sources/App/SkillInstaller.swift`, `Tests/SkillInstallerTests.swift`

**What:**
- Add `SkillInstaller.Failure` (E1/E2) and a private helper that turns a thrown `Error` into the E3
  reason.
- `install` and `uninstall` return `[Failure]`, appending one per `catch`. Keep the existing log
  lines, with `privacy: .public` on `\(error)` (E8 for this file).
- `EntryState` gains `unreadable(reason: String)`; `state()` uses `try`/`catch` on
  `attributesOfItem`, returning `.missing` only for POSIX `ENOENT` under `NSUnderlyingErrorKey`,
  else `.unreadable(reason)`. `EntryState` stays `Equatable`. Existing `[.current, .stale].contains`
  and `[.missing, .stale].contains` checks keep compiling (array `contains` on an `Equatable` enum).
- Install's switch skips `.unreadable` (with `.agentAbsent, .current, .foreign`). Uninstall's guard
  already skips it.
- `SkillInstallStatus.messages`: add the E4 line, ordered per "Detail this plan fixes" above.
  `isInstalled` is unchanged in logic (unreadable does not block it).
- Tests: the private `install()`/`uninstall()` helpers return the failures and are
  `@discardableResult`. Add:
  - F1: `~/.claude/skills` exists with mode `0555`; Install returns exactly one failure, `link`, for
    `~/.claude/skills/clearway`, reason "Permission denied", message
    "~/.claude/skills/clearway could not be linked: Permission denied."; CLI and Codex links point into
    the bundle.
  - F2: extend `testOneEntryFailingDoesNotStopTheOthers`: the Claude Code entry's state is
    `.unreadable(reason: "Not a directory")`, `status().messages` contains
    "~/.claude/skills/clearway could not be read: Not a directory.", and Install returns `[]`.
  - F4: Install, then `~/.claude/skills` to `0600`: the entry reads
    `.unreadable(reason: "Permission denied")` with its message, `isInstalled` is `true` (CLI and Codex
    current); Uninstall returns `[]`, removes the CLI and Codex links, and after restoring the mode the
    Claude Code link is still there.
  - F5: Install, then `~/.claude/skills` to `0555`: Uninstall returns exactly one `remove` failure for
    `~/.claude/skills/clearway` with reason "Permission denied" and removes the other two links.
  - Assert Install and Uninstall return `[]` in `testInstallWithBothAgentsLinksAllThreeIntoTheBundle`
    (or the closest existing success-path test) and in a successful uninstall.

**Acceptance criteria:**
- F1, F2, F4, F5 and the success-returns-`[]` assertions pass; every pre-existing test passes with its
  assertions unchanged.
- `SkillSettingsSection` still compiles (ignore or `_ =` the returned value for now; T3 consumes it).
- `./scripts/ci.sh` exits 0, with no new SwiftLint warnings in the touched files.

**Verify:** `./scripts/ci.sh`; report the command and its exit status.

### T2: Replace a stale link by rename, never by remove-then-create

**Files:** `Sources/App/SkillInstaller.swift`, `Tests/SkillInstallerTests.swift`

**What:**
- Write F3 first and watch it fail on the T1 code (the stale link is gone after Install): a stale
  Claude Code link in `~/.claude/skills`, then an ACL on that directory set with
  `/bin/chmod +a "user:<NSUserName()> deny add_file" <dir>` via `Process`, cleared in `defer` with
  `/bin/chmod -N <dir>`. Assert after Install: the link exists, `destination(claudeLink)` is still the
  old destination, exactly one `link` failure for `~/.claude/skills/clearway` is returned, and no entry
  in the container has the prefix `.clearway.`. Record the observed failure in the build log.
- Implement E5 in Install's `.stale` branch: create the link at
  `(container as NSString).appendingPathComponent(".\(linkName).\(UUID().uuidString)")`, then
  `Darwin.rename(temp, path)`. On a non-zero return capture `strerror(errno)` immediately, remove the
  temp link (ignore a failure there, but log it with `privacy: .public`), and return a `link` failure
  with that reason. The `.missing` branch is unchanged. `Location` needs to expose the link name (or
  the temp path) for this.
- F6: extend `testStaleAndDanglingLinksAreRepointedByInstallAndRemovedByUninstall`: Install returns
  `[]`, and no `.cway.*` / `.clearway.*` entry remains in `~/.clearway`, `~/.claude/skills` or
  `~/.agents/skills`.

**Acceptance criteria:**
- F3 fails on the pre-change code and passes after; F6 passes; all T1 tests still pass.
- No code path in Install calls `removeItem` on a stale link's path.
- `./scripts/ci.sh` exits 0.

**Verify:** `./scripts/ci.sh`; report the command and its exit status, plus the F3 failure seen before
the fix.

### T3: Settings shows the last action's failures

**Files:** `Sources/App/SkillSettingsSection.swift`

**What:**
- Add `@State private var failures: [SkillInstaller.Failure] = []`.
- The button assigns `failures = act(NSHomeDirectory(), Bundle.main.bundlePath)`, then `refresh()`.
- `onAppear` clears `failures` and refreshes `status` (E6).
- Render `failures.map(\.message)` followed by `status.messages` in the existing `ForEach` with the
  same `Label` styling (E7). Use an `id` that cannot collide between a failure line and a status
  line, e.g. iterate the concatenated array with `\.self` (the texts differ by construction:
  "could not be linked/removed" vs "could not be read"/"already exists").
- No new subtitle or helper copy.

**Acceptance criteria:**
- Builds and lints clean; the button no longer discards the returned failures.
- Code review against E6/E7: failures are replaced on every click, cleared on appear, listed before
  status messages, same styling.
- `./scripts/ci.sh` exits 0. (No UI test; the operator checks the screen by hand.)

**Verify:** `./scripts/ci.sh`; report the command and its exit status.

### T4: Public error logging in AgentHookInstaller and the per-file notes

**Files:** `Sources/App/AgentHookInstaller.swift`, `Sources/App/CLAUDE.md`

**What:**
- Add `privacy: .public` to the three `\(error)` interpolations (lines 82, 135, 160 at base). Then
  `grep -n '\\(error)' Sources/App/SkillInstaller.swift Sources/App/AgentHookInstaller.swift` must show
  none without `privacy: .public`.
- Update the `SkillInstaller.swift` and `SkillSettingsSection.swift` entries in `Sources/App/CLAUDE.md`:
  failures are returned per action and held in view `@State`, not stored; `unreadable` vs `missing`
  (only `ENOENT` is missing); the stale replace is temp-link-plus-`rename(2)` so a failed Install never
  loses the old link; a mode change cannot test that path (remove and create both need write on the
  directory), so the test uses a `deny add_file` ACL. Edit surgically; keep the file's existing tone.

**Acceptance criteria:**
- The grep above returns only lines carrying `privacy: .public` (spec criterion 7).
- The two CLAUDE.md entries describe the shipped behavior, with no claim that contradicts the code.
- `./scripts/ci.sh` exits 0.

**Verify:** the grep, then `./scripts/ci.sh`; report both.

## Risks

| Risk | Mitigation |
| --- | --- |
| `chmod +a` ACL left on the temp dir blocks its deletion | `defer { /bin/chmod -N }` registered before the ACL is set; F3 runs it even on assertion failure. |
| Mode `0600`/`0555` dirs left behind break `TempRootTestCase` teardown | Restore `0755` in `defer`, as `TaskFilesTests` does. |
| Running as root (CI) ignores modes and ACLs, so F1/F3/F4/F5 would not fail | GitHub's macOS runner runs as a non-root user; if a test cannot provoke the error, it must fail rather than pass vacuously (assert the failure list is non-empty). |

## Build log

### T1: Return failures and add the unreadable state

| File | State |
| --- | --- |
| `Sources/App/SkillInstaller.swift` | `Failure` (`displayPath`, `Action.link`/`.remove`, `reason`, `message`); `install`/`uninstall` return `[Failure]`; `EntryState.unreadable(reason:)`; `state()` returns `.missing` only for POSIX `ENOENT`; private `posixError(in:)` and `reason(for:)` (E3); Install skips `.unreadable`; `messages` lists foreign and unreadable lines in `Target` order, then the no-agent line; both `\(error)` log interpolations are `privacy: .public`. |
| `Sources/App/SkillSettingsSection.swift` | `_ = act(...)`, so the returned failures are discarded until T3. |
| `Tests/SkillInstallerTests.swift` | `install()`/`uninstall()` helpers return the failures (`@discardableResult`); `setMode` helper. New: `testAnUnwritableSkillsDirectoryIsReportedAndTheOthersAreLinked` (F1), `testAnUnremovableLinkIsReportedAndTheOthersAreRemoved` (F5), `testAnEntryThatCannotBeStatedIsUnreadableAndSkippedByUninstall` (F4). Extended: `testOneEntryFailingDoesNotStopTheOthers` (F2), `testInstallWithBothAgentsLinksAllThreeIntoTheBundle` (Install returns `[]`), `testStaleAndDanglingLinksAreRepointedByInstallAndRemovedByUninstall` (Uninstall returns `[]`). |

**Evidence.**

- RED before implementation: `./scripts/ci.sh` exit 65, `type 'SkillInstaller' has no member 'Failure'` and
  `type 'SkillInstaller.EntryState?' has no member 'unreadable'`.
- Behavioral RED: with the implementation in place but `state()` mutated to read every stat error as
  `.missing` (the pre-change behavior), `./scripts/ci.sh` exit 65:
  - `testAnEntryThatCannotBeStatedIsUnreadableAndSkippedByUninstall`: `("Optional(Clearway.SkillInstaller.EntryState.missing)") is not equal to ("Optional(Clearway.SkillInstaller.EntryState.unreadable(reason: "Permission denied"))")`; `("[]") is not equal to ("["~/.claude/skills/clearway could not be read: Permission denied."]")`.
  - `testOneEntryFailingDoesNotStopTheOthers`: `("[Clearway.SkillInstaller.Failure(displayPath: "~/.claude/skills/clearway", action: ...link, reason: "File exists")]") is not equal to ("[]")`; `("Optional(...EntryState.missing)") is not equal to ("Optional(...EntryState.unreadable(reason: "Not a directory"))")`.
  The file was restored from a scratchpad copy afterwards.
- F1 and F5 have no pre-change form to fail against (the return value is new); each asserts an exact
  one-element failure list, so a run that cannot provoke the error (root) fails rather than passing.

**Deviations.**

- `testUninstallRemovesLinksIntoAnotherExistingBundle` calls `SkillInstaller.install` directly; it now
  reads `_ = SkillInstaller.install(...)`. No assertion changed.
- `state()` qualifies the outer helpers as `SkillInstaller.posixError` / `SkillInstaller.reason` from inside
  the nested `Location`.
- With `~/.claude/skills` a regular file, the pre-change Install's failure reason is "File exists"
  (from `createDirectory`), not "Not a directory"; under T1 the entry is skipped as unreadable, so it
  never reaches that call.

**Gate.** `./scripts/ci.sh` exit 0 after the last source edit; all 19 `SkillInstallerTests` pass;
`swiftlint lint --quiet` on the three touched files reports nothing.

### T2: Replace a stale link by rename, never by remove-then-create

| File | State |
| --- | --- |
| `Sources/App/SkillInstaller.swift` | Install's `.stale` branch calls `Location.replaceLink()`: creates `<container>/.<linkName>.<UUID>`, then `rename(2)`s it over the stale link; on a rename failure it removes the temporary link (logging a failure there with `privacy: .public`) and throws a POSIX `NSError` built from `errno`. `.missing` creates the link directly, as before. `Location` exposes `linkName`. `posixError(in:)` also accepts an error that is itself in `NSPOSIXErrorDomain`, so the rename reason comes out as `strerror` text (E3). Install no longer calls `removeItem` on a stale link's path. |
| `Tests/SkillInstallerTests.swift` | New: `testAStaleLinkSurvivesAnInstallThatCannotCreateItsReplacement` (F3), with `chmod(_:)` (runs `/bin/chmod` via `Process`, ACL cleared with `-N` in `defer`) and `temporaryEntries(in:)` helpers. Extended: `testStaleAndDanglingLinksAreRepointedByInstallAndRemovedByUninstall` asserts Install returns `[]` and leaves no `.cway.*`/`.clearway.*` entry in any of the three containers (F6). |

**Evidence.**

- RED: F3 written first, run against the T1 code. `./scripts/ci.sh` exit 65, 954 tests, 1 failure:
  `testAStaleLinkSurvivesAnInstallThatCannotCreateItsReplacement, XCTAssertEqual failed: threw error "Error Domain=NSCocoaErrorDomain Code=260 "The file “clearway” couldn’t be opened because there is no such file." ... NSUnderlyingError=... {Error Domain=NSPOSIXErrorDomain ...`
  — the stale link was removed and its re-creation refused, so `destination(claudeLink)` found nothing.
- GREEN: same test passes after `replaceLink()`; the temporary link's creation is what the ACL refuses, so the
  stale link is never touched and no `.clearway.*` entry is left.
- F6's new assertions pass on both the T1 code and T2 (the old path made no temporary entry); they guard the
  rename path against leaving one behind.

**Deviations.**

- The rename-failure branch (temp created, `rename(2)` refused) has no test: no ACL or mode found in the spec's
  probes allows creating an entry in a directory while refusing a rename over a sibling in the same directory.
  It is covered by review only.
- `replaceLink()` carries a two-line doc comment ("Never remove the stale link first"), kept as a regression
  guard; the test's doc comment records why a mode change cannot reach the path. T4 restates both in
  `Sources/App/CLAUDE.md`.

**Gate.** `./scripts/ci.sh` exit 0 after the last source edit (954 tests, 0 failures);
`swiftlint lint --quiet` on the two touched source files reports nothing.
