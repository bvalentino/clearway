# Show skill install failures in Settings

**Date:** 2026-10-04
**Base:** be4a80f (Bundle clearway skill and add skill installer to Settings, #268)

Today `SkillInstaller` only logs a link or removal that fails, so Settings leaves the button on
"Install" with no explanation. This change makes `install` and `uninstall` return the entries they
could not link or remove, and Settings shows one red line per failure, in the style the foreign-entry
lines already use. An entry whose path cannot be stat'ed for any reason other than "does not exist"
gets its own state with its own line, instead of reading as missing. A stale link is now replaced by
renaming a new link over it, so a failed Install never deletes the link the user already had. The
installers' logged errors become readable in Console.

## Decisions

Decisions D1-D15 of `2026-10-04-clearway-skills.md` stand. In particular D5 (which links are
Clearway's) and the foreign-entry and no-agent messages of D10 are not changed (brief, Out of scope).

| # | Question | Decision | Why |
| --- | --- | --- | --- |
| E1 | How does a failure reach Settings? | `install(home:bundlePath:)` and `uninstall(home:bundlePath:)` return `[SkillInstaller.Failure]`, one per entry whose link or removal threw. `Failure` holds the entry's `displayPath`, the action (`link` or `remove`) and the reason, and exposes `message`. The view keeps the last action's failures in `@State` and renders them. Nothing is written to disk and `SkillInstallStatus` stays a pure disk read. | D6 judges state from disk and stores nothing. A failed syscall is an outcome of one action, not a disk state: after it, the disk looks the same as if Install was never pressed, so re-reading cannot say why. Rejected: a stored flag (contradicts D6); folding failures into `SkillInstallStatus` (it would stop being a disk read). |
| E2 | What does a failure line say? | One line per failed entry: "`<~/path>` could not be linked: `<reason>`." or "`<~/path>` could not be removed: `<reason>`." Same `Label`, icon, `.callout` font and red as the existing lines (`SkillSettingsSection.swift:17-21`). | Brief, In scope: "naming the entry that failed and why". One line per entry matches how foreign entries are already listed (`SkillInstaller.swift:122`). The project copy rule allows a line that prevents error (brief, Background). |
| E3 | Where does `<reason>` come from? | The `strerror` text of the POSIX error under the thrown `NSError`'s `NSUnderlyingErrorKey` (domain `NSPOSIXErrorDomain`), e.g. "Permission denied", "Not a directory". For the `rename(2)` call (E5) it is `strerror(errno)`. Fallback when there is no POSIX error underneath: `localizedDescription`. | Scratchpad probe: every FileManager call the installer makes carries the POSIX errno underneath (see A3). Its `localizedDescription` is a sentence about saving a file in a folder, which repeats the path the line already names and reads oddly after "could not be linked:". |
| E4 | How is a stat error other than "not found" told apart from "missing"? | New `EntryState` case `unreadable(reason: String)`. `state()` returns `.missing` only when `attributesOfItem` fails with POSIX `ENOENT`; any other failure is `.unreadable` with the E3 reason. Install and Uninstall skip an `unreadable` entry. `SkillInstallStatus.messages` adds "`<~/path>` could not be read: `<reason>`." for it. It does not block `isInstalled` (D9 treats it like `foreign`). | Brief, In scope: "A stat error is distinguished from missing". Being a disk state, it belongs in the status and shows whether or not a button was pressed, which is what makes "Uninstall reports a link it could not stat" hold: the line is on screen before and after Uninstall. Install cannot create where it cannot stat, so attempting it would only add a second line for the same entry. Not blocking `isInstalled` keeps Uninstall reachable for the entries it can remove, the same reasoning D9 gives for `foreign`. `ENOTDIR` (a `skills` path that is a regular file) lands here too, see A4. |
| E5 | How does Install replace a stale link without losing it on failure? | Create the new link at a temporary name in the same directory, `.<linkName>.<UUID>`, then `rename(2)` it over the stale link. If the temporary link cannot be created, the stale link is untouched. If the rename fails, the temporary link is removed and the stale link is untouched. `missing` still creates the link directly at its path. | Brief, In scope: "Install does not leave a stale link deleted when re-creating it fails." `rename(2)` replaces in one step (A5), so there is no moment with no link at the path. Rejected: remove-then-create with a re-create on failure, which still has a window with no link and a second failure path of its own. Rejected: `FileManager.replaceItemAt(_:withItemAt:)`, a document safe-save API with backup-item and metadata semantics, where `rename(2)` is the exact primitive needed. A process killed between the two calls leaves a dot-named link in the container; Claude Code loads one skill once when several entries point at the same target (spec 2026-10-04 A1), so it costs nothing and is accepted. |
| E6 | When do the failure lines go away? | They are replaced by the next action's result (empty on success), and cleared when the section appears. | A line about an action the user took in a previous visit to Settings may be out of date, and Settings has no watcher. The `unreadable` lines are re-read from disk on appear, so a stat problem stays visible across visits. |
| E7 | In what order are lines shown? | The last action's failures first, then `SkillInstallStatus.messages` in their current order. | The failure answers the click the user just made. |
| E8 | Logging | Every `\(error)` interpolation in `SkillInstaller` (2 today) and `AgentHookInstaller` (3: lines 82, 135, 160) gets `privacy: .public`. | Brief, In scope. Unified logging redacts a non-public interpolation as `<private>`. The error text is a path the line already logs as public, plus an errno. |
| E9 | What does Uninstall report? | A `remove` failure per entry whose removal threw. An entry it cannot stat is already on screen as `unreadable` (E4), so Uninstall adds nothing for it. | Brief, acceptance: "Uninstall reports a link it could not stat or remove." Both are covered, by E4 and by this row. |

## Assumptions

Checked against the tree at `be4a80f`. Two probes ran in the session scratchpad, never in the repo:
a Swift script printing the errors FileManager throws (A3), and a shell check of a macOS ACL that
denies creating entries (A6).

| # | Assumption | Evidence |
| --- | --- | --- |
| A1 | `install`/`uninstall` return nothing and log only; the view re-reads `status` after acting. | `SkillInstaller.swift:27-58`; `SkillSettingsSection.swift:11-15`. |
| A2 | `state()` reads every `attributesOfItem` failure as `.missing`, and Install's stale branch removes before it creates. | `SkillInstaller.swift:94`; `SkillInstaller.swift:34-39`. |
| A3 | FileManager's errors carry the errno under `NSUnderlyingErrorKey`. | Probe output: `attributesOfItem` on a missing path → Cocoa 260 over POSIX 2 "No such file or directory"; through a regular file → Cocoa 256 over POSIX 20 "Not a directory"; inside a mode-`0600` directory → Cocoa 257 over POSIX 13 "Permission denied"; `createSymbolicLink` and `removeItem` in a mode-`0555` directory → Cocoa 513 over POSIX 13; `createDirectory` under a regular file → Cocoa 512 over POSIX 20. |
| A4 | With `~/.claude/skills` a regular file, the entry's stat fails with `ENOTDIR`, so under E4 it reads `.unreadable("Not a directory")` and Install skips it, showing a line. | A3's second probe line. Today it reads `.missing` and Install throws from `createContainer` (`SkillInstaller.swift:101-105`); `testOneEntryFailingDoesNotStopTheOthers` (`Tests/SkillInstallerTests.swift:95-103`) builds this case. |
| A5 | `rename(2)` replaces an existing symlink at the destination without following it, and leaves no moment with nothing at the destination. | `man 2 rename` (macOS 26.6): "The rename() system call guarantees that an instance of new will always exist, even if the system should crash in the middle of the operation." Probe: renaming a link to `/new` over a link to `/old` left the destination reading `/new`. |
| A6 | The "stale link deleted, re-create fails" bug can be reproduced on HEAD in a test. A mode change cannot do it, because removing and creating an entry both need write on the directory. A macOS ACL entry `user:<me> deny add_file` on the container can: it refuses creation and allows removal. | Probe: with that ACL on a directory, `ln -s` into it failed with "Permission denied" (also for a dot-named entry), `rm` of an existing link in it succeeded, and `chmod -N` cleared it. |
| A7 | Tests already change modes under the temp root and restore them in `defer`. | `Tests/TaskFilesTests.swift:83-84, 107-108`; `Tests/TaskCommandTests.swift:245-246`. |
| A8 | `SkillInstaller.install`/`uninstall` have one call site, the Settings button. | `grep` over `Sources/`: only `SkillSettingsSection.swift:12`. |
| A9 | The view's existing lines are a red `Label` with `exclamationmark.triangle` in `.callout`. | `SkillSettingsSection.swift:17-21`. |

## Objective and success criteria

When Install or Uninstall cannot do part of its work, Settings names the entry and the reason, and a
failed Install never leaves the user with less than they had.

1. Install with `~/.claude/skills` mode `0555` returns a `link` failure for `~/.claude/skills/clearway`
   with reason "Permission denied", Settings shows its line, and the CLI and Codex links are made.
2. With `~/.claude/skills` a regular file, the Claude Code entry is `unreadable("Not a directory")`,
   its line shows, and Install skips it while linking the others.
3. A stale Claude Code link in a directory carrying `deny add_file` is still present, with its old
   destination, after Install, and Install returns a `link` failure for it. (Fails on HEAD: the link
   is gone.)
4. With `~/.claude/skills` mode `0600` (no search permission) after a successful Install, the entry
   is `unreadable("Permission denied")` and its line shows; Uninstall removes the other links and
   leaves the line.
5. Uninstall with `~/.claude/skills` mode `0555` returns a `remove` failure for that entry.
6. Successful Install and Uninstall return `[]`; existing tests still pass with their assertions
   unchanged.
7. Every `\(error)` in both installers' log calls is `privacy: .public`. (Review check.)
8. `./scripts/ci.sh` passes.

## Commands

From the project's `## Pipeline` section:

| Step | Command |
| --- | --- |
| Regression check (every build task, simplify) | `./scripts/ci.sh` |
| Full gate (sign-off, once) | `./scripts/ci.sh` |

## Files touched

- `Sources/App/SkillInstaller.swift`: `Failure`, return values, `EntryState.unreadable`, the
  `ENOENT` check, the temp-link-and-rename replace, the E3 reason, the E4 message, `privacy: .public`.
- `Sources/App/SkillSettingsSection.swift`: `@State` failures, set by the button, cleared on appear,
  rendered before `status.messages`.
- `Sources/App/AgentHookInstaller.swift`: `privacy: .public` on three error interpolations.
- `Tests/SkillInstallerTests.swift`: the `install()`/`uninstall()` helpers return the failures; new
  tests below.
- `Sources/App/CLAUDE.md`: the `SkillInstaller.swift` and `SkillSettingsSection.swift` entries (failures
  are returned, not stored; `unreadable`; the rename replace and why a mode change cannot test it).

## Testing

XCTest through `./scripts/ci.sh`, in `SkillInstallerTests` (a `TempRootTestCase`; `home` is the temp
root, never the real home). Every mode or ACL change is undone in a `defer` so the temp root can be
deleted.

- F1 Unwritable skills directory (`0555`): Install returns one `link` failure for
  `~/.claude/skills/clearway` reading "Permission denied"; CLI and Codex links point into the bundle
  (crit. 1).
- F2 `~/.claude/skills` a regular file: state `unreadable("Not a directory")`, message
  "~/.claude/skills/clearway could not be read: Not a directory.", Install returns `[]` and links the
  other two (crit. 2). Extends `testOneEntryFailingDoesNotStopTheOthers`.
- F3 Stale link plus `deny add_file` ACL on its container, set with `/bin/chmod +a` and cleared with
  `/bin/chmod -N`: after Install the link exists with its old destination, one `link` failure is
  returned, and no `.clearway.*` entry is left in the container (crit. 3).
- F4 Stat error: Install, then `~/.claude/skills` to `0600`: the entry reads `unreadable("Permission
  denied")` with its message, `isInstalled` follows D9 for the rest; Uninstall removes the CLI and
  Codex links and returns `[]` (crit. 4).
- F5 Remove failure: Install, then `~/.claude/skills` to `0555`: Uninstall returns one `remove`
  failure for that entry and removes the others (crit. 5).
- F6 Stale repoint still works through the rename path and leaves no temporary entry (extends
  `testStaleAndDanglingLinksAreRepointedByInstallAndRemovedByUninstall`); successful calls return
  `[]` (crit. 6).

## Boundaries

- Always: run `./scripts/ci.sh` after the last edit; pass `home` and `bundlePath`; read entries
  without following links; restore modes and ACLs the test changed.
- Ask first: storing anything about an install on disk; changing D5 or the D10 messages.
- Never: touch the real home directory from a test; remove a stale link before its replacement
  exists; launch the app or take screenshots from a build agent.

## Out of scope

- Which links count as Clearway's (D5), and the foreign-entry and no-agent messages (brief).
- A watcher on the link paths; lines refresh on appear and after each action, as today.
- `AgentHookInstaller` behaviour beyond the log privacy, and its health line.
- `SettingsView`'s fixed frame height; the `Form` scrolls.
