# cway: explicit error messages instead of git's raw output

**Date:** 2026-10-03
**Base:** 8a11de5 (Add cway CLI: create, list, and show tasks, #265)

Every message `cway` prints on failure is rewritten in its own words: what went wrong, the
directory, path or id involved, and what to do next. Outside a git repository it now says the
current directory is not inside a git repository and that `cway` must be run from inside a
project, instead of passing through git's `fatal: not a git repository (or any of the parent
directories): .git`. A git failure `cway` does not recognise is framed by a sentence saying what
`cway` was trying to do, followed by git's own stderr, so the cause is never hidden and never
misnamed. Running `cway` from a deleted directory, which today aborts with an uncaught
Objective-C exception, becomes an ordinary error. Exit codes, the stderr/stdout split and the
JSON success output do not change.

## Decisions

The operator made no decisions beyond the brief (`.clearway/TASK.md`). Every row below is a call
made in this spec.

| # | Question | Decision | Why |
| --- | --- | --- | --- |
| D1 | Which git failures does `cway` recognise? | Exactly one: no repository found while walking up from the working directory. Every other non-zero git exit, dubious ownership included, takes the generic path (D4). | Brief, criterion 4: never claim a cause that is not the real one. Dubious ownership is already self-explanatory in git's text and its fix (`safe.directory`) is git's to state; recognising more causes means more string matching that can misfire. The brief's in-scope list names "git failing for another reason" as one case. |
| D2 | How is "outside a repository" recognised? | git exits 128 **and** the first stderr line starts with `fatal: not a git repository (or any `. Nothing else matches. | That prefix covers both texts git prints when discovery finds nothing: `(or any of the parent directories): .git` and `(or any parent up to mount point …)` (the `GIT_DISCOVERY_ACROSS_FILESYSTEM` stop). It must **not** match `fatal: not a git repository: <path>` (no parenthesis), which git prints for a broken `.git` gitfile or a bad `GIT_DIR` — that is a broken repository, not "outside one" (probe P2). Exit 128 alone is git's status for every fatal error, so the text is required. |
| D3 | How is that text kept stable across user locales? | `cway` runs git with its inherited environment plus `LC_ALL=C`. | gettext manual, "Locale Environment Variables" (fetched 2026-10-03): "LC_ALL is an environment variable that overrides all of these. It is typically used in scripts that run particular programs." "The LANGUAGE variable" page (same date): "Note: The variable LANGUAGE is ignored if the locale is set to 'C'." So `LC_ALL=C` selects git's untranslated messages whatever `LANG`, `LC_MESSAGES` or `LANGUAGE` the user has. Probe P3: under `LC_ALL=C`, `git worktree list --porcelain` prints a non-ASCII worktree path byte-identical to the default locale, so the porcelain parse is unaffected. The installed `/usr/bin/git` (Apple Git-157) ships no translations, so a translated message could not be observed here; the doc line is the evidence. |
| D4 | What does an unrecognised git failure print? | A `cway` sentence naming the working directory, the git command and its exit status, then git's whole stderr: blank lines dropped, each remaining line indented by two spaces. If git printed nothing, the sentence says so. Exit 1. | Criterion 3: git's reason stays visible, framed by what `cway` was doing. The whole stderr, not the first `fatal:` line as today: for dubious ownership the actionable part is git's `git config --global --add safe.directory <path>` hint, which is on later lines (probe P1). |
| D5 | Single line or several? | Every message is one line, except D4's, which appends git's lines. | One line per failure is what an agent greps or quotes back. D4 is the one case carrying third-party text that is itself multi-line. |
| D6 | Message form | `cway: <sentence>.` Sentences start lower-case after `cway: `, end with a period, put paths and user-supplied arguments in single quotes, and print task ids unquoted in uppercase `uuidString` form (as `cway` outputs them elsewhere). A message that ends in a Foundation `localizedDescription` (R4, R12, R13) takes no extra period, since that text carries its own. | Consistent, and quoted paths stay readable when they contain spaces. |
| D7 | What do usage errors say? | Each names the subcommand and the offending flag or argument, and every one ends with ` Run 'cway help' for usage.` Exit 2. Usage text itself is not printed on error. | Points the reader at the fix without dumping usage into stderr on every mistake. One suffix rule, applied in one place, instead of per-site wording. |
| D8 | The working directory does not exist | Before starting git, `cway` checks that the working directory exists and is a directory. If not: exit 1 with catalogue message R1. | Proven pre-existing crash (probe P4): run from a deleted directory, `FileManager.currentDirectoryPath` returns `""`, and the built `cway` aborts with `NSInvalidArgumentException … -[NSConcreteTask setCurrentDirectoryURL:]: non-file URL argument`, exit 134, raised inside `TaskCommand.git` (`TaskCommand.swift:175`). An Objective-C exception cannot be caught in Swift, so the check has to come first. Brief: "git failing to start" is in scope. |
| D9 | Exit codes for malformed id and stdin not UTF-8 | Unchanged: 1. | Criterion 5: exit codes unchanged. Malformed id is 1 today (`TaskCommand.swift:146`). |
| D10 | Order of checks | Unchanged: argument errors are reported before any git or filesystem check. | Keeps a usage error independent of where `cway` is run, as today. |
| D11 | How are the env-dependent failures tested? | "git not found" and dubious ownership run the embedded `Contents/MacOS/cway` with a controlled `environment` (`PATH` without git; `GIT_TEST_ASSUME_DIFFERENT_OWNER=1`), capturing stderr. Everything else goes through `TaskCommand.run` directly. `TaskCommand.run`'s signature does not change. | `cway` inherits its environment, so the real binary with a set environment tests exactly what ships, with no test-only parameter. `GIT_TEST_ASSUME_DIFFERENT_OWNER` makes git report dubious ownership without a second user (probe P1); it is the only way to exercise the D1/D4 regression for the historic mistake on one machine. A broken gitfile (`.git` containing `gitdir: /nonexistent`) exercises the D2 near-miss in-process. |

### Message catalogue

`<wd>` is the working directory exactly as `cway` received it; `<cmd>` is the subcommand
(`task create`, `task list`, `task show`). Every line is printed as `cway: <message>\n` on stderr
with empty stdout.

Usage errors, exit 2. Each message below is followed by ` Run 'cway help' for usage.` (D7).

| # | When | Message |
| --- | --- | --- |
| U1 | first two arguments are not a known command | `unknown command '<args>'.` (first two arguments joined by a space, as today) |
| U2 | unknown flag | `'<cmd>' has no option '<flag>'.` |
| U3 | stray positional argument, or an extra one to `list` / `show` | `'<cmd>' does not take the argument '<arg>'.` |
| U4 | flag without a value | `<flag> needs a value.` |
| U5 | flag repeated | `<flag> is given more than once.` |
| U6 | `create` without `--title` | `'task create' needs --title <title>.` |
| U7 | title empty after trimming | `--title is empty; give the task a title.` |
| U8 | `show` without an id | `'task show' needs a task id.` |

Runtime failures, exit 1.

| # | When | Message |
| --- | --- | --- |
| R1 | working directory missing (D8) | `the current directory '<wd>' does not exist. cd into a project and run cway again.`; when `<wd>` is empty (the deleted-directory case): `the current directory no longer exists. cd into a project and run cway again.` |
| R2 | outside a repository (D2) | `the current directory '<wd>' is not inside a git repository. Run cway from inside a project or one of its worktrees.` |
| R3 | main worktree is bare | `the main worktree of this repository, '<path>', is a bare repository with no task backlog. cway needs a project whose main worktree is checked out.` (`<path>` from the first porcelain entry) |
| R4 | git could not be started | `could not start git in '<wd>': <reason>` |
| R5 | `/usr/bin/env` exits 127 | `git was not found on PATH. cway runs git to find the project; install git or add it to PATH.` |
| R6 | any other non-zero git exit (D4) | `could not find the project for '<wd>': 'git worktree list --porcelain' exited with status <n>. git said:` followed by git's stderr lines, each `  `-indented; or `… exited with status <n> and printed nothing.` |
| R7 | git output not UTF-8 | `'git worktree list --porcelain' in '<wd>' printed output that is not UTF-8.` |
| R8 | git listed no worktrees | `'git worktree list --porcelain' in '<wd>' listed no worktrees.` |
| R9 | `show` id is not a UUID | `'<arg>' is not a task id. A task id is a UUID; run 'cway task list' to see the ids.` |
| R10 | `show` id not in the pool | `no task with id <ID> in the project at '<main>'. Run 'cway task list' to see the tasks.` |
| R11 | `--body -` and stdin is not UTF-8 | `the body read from stdin (--body -) is not valid UTF-8.` |
| R12 | the task file cannot be written | `could not write the task file '<path>': <reason>` |
| R13 | JSON encoding fails | `could not encode the output as JSON: <reason>` |

R7, R8 and R13 cannot be provoked from a test without faking git or `JSONEncoder`; they get the
wording above and no test. R4 is reached only if `/usr/bin/env` itself cannot launch once D8
has ruled out the working directory; same.

## Assumptions

Checked against the tree at `8a11de5`. Probes ran in the session scratchpad, never in the repo.

| # | Assumption | Evidence |
| --- | --- | --- |
| A1 | Every failure message comes from one `catch` in `TaskCommand.run` that prints `cway: <message>\n` with empty stdout. | `TaskCommand.swift:40-42`; `Failure.usage` exit 2, `Failure.runtime` exit 1 (`:45-51`). |
| A2 | The only git invocation is `git worktree list --porcelain`, through `TaskCommand.git`. | `TaskCommand.swift:161`, `:171-198`. |
| A3 | Today's git failure path prints git's first `fatal:` line (else first line, else the exit status). | `TaskCommand.swift:191-195`. |
| A4 | git exits 128 both outside a repository and for dubious ownership, so the status alone cannot tell them apart. | Probe P1/P2 below. |
| A5 | `main.swift` passes `FileManager.default.currentDirectoryPath`, which is `""` in a deleted directory. | `Sources/CLI/main.swift:5`; probe P4. |
| A6 | The bare-main check reads the first porcelain block before parsing, and that block's `worktree` line carries the bare repository's path. | `TaskCommand.swift:162-165`; probe P5 printed `worktree …/bare.git` then `bare`. |
| A7 | `TaskFiles.write` throws on a failed create, so R12 is reachable by making `.clearway/tasks` read-only. | `TaskFiles.swift:27-33` (`createFile` false → `CocoaError(.fileWriteUnknown)`). |
| A8 | Tests can run the embedded `cway` binary with a chosen working directory and capture its output. | `TaskCommandTests.swift:367-380` (`runHelper`), `:79-95`. |
| A9 | Nothing outside `TaskCommand.swift` and `TaskCommandTests.swift` depends on the message text. | `grep -rl cway` over the repo (excluding `ghostty/`): only `project.yml`, `CLAUDE.md`, `TaskFiles.swift` (a doc comment), the two files above and the predecessor spec and plan. The Clearway skill (`025C4523-…`) is not written yet. |

Probes (scratchpad, git 2.54.0 Apple Git-157):

- P1 In a repo with `GIT_TEST_ASSUME_DIFFERENT_OWNER=1`: exit 128, stderr `fatal: detected dubious ownership in repository at '<path>'`, `To add an exception for this directory, call:`, a blank line, then a tab-indented `git config --global --add safe.directory <path>`.
- P2 Outside any repo: exit 128, `fatal: not a git repository (or any of the parent directories): .git`, unchanged with `LC_ALL=fr_FR.UTF-8` and with `LANGUAGE=de`. A `.git` file holding `gitdir: /nonexistent/x`: exit 128, `fatal: not a git repository: (null)`. `GIT_DIR=/nonexistent`: `fatal: not a git repository: '/nonexistent'`. Inside `.git/` and `.git/objects/`: exit 0 with the normal listing.
- P3 A linked worktree at `…/wé ü`: `LC_ALL=C git worktree list --porcelain` prints the path as raw UTF-8, same as the default locale.
- P4 Built Debug `cway task list` run from a directory removed after `cd`: uncaught `NSInvalidArgumentException` from `TaskCommand.git`, exit 134. A Swift probe printed `currentDirectoryPath` as `""` there.
- P5 `git clone --bare` plus a linked worktree, listed from the linked one: first block `worktree …/bare.git`, `bare`.
- P6 `/usr/bin/env git-nope`: exit 127.

## Objective and success criteria

The reader is an agent using `cway` through the Clearway skill. From the message alone it must
tell "I am in the wrong place" from "my arguments are wrong" from "something is broken", and see
the next step.

1. Outside a git repository, every command prints R2, exit 1, empty stdout. The message contains
   neither `.git` nor `parent directories`.
2. Each U and R message in the catalogue that a test can provoke is asserted exactly (R6 by its
   framing sentence plus the presence of git's line).
3. A broken `.git` gitfile prints R6 with git's `not a git repository:` line, never R2.
4. Dubious ownership (via the embedded binary with `GIT_TEST_ASSUME_DIFFERENT_OWNER=1`) prints
   R6 with git's `detected dubious ownership` and `safe.directory` lines, never R2.
5. `PATH` without git prints R5, exit 1.
6. A working directory of `""` and a nonexistent path print R1, exit 1, and do not crash.
7. Exit codes: 2 for U1-U8, 1 for R1-R13. stdout is empty on every failure. Success output is
   byte-identical to `8a11de5`.
8. `./scripts/ci.sh` passes.

## Commands

From the project's `## Pipeline` section:

| Step | Command |
| --- | --- |
| Regression check (every build task, simplify) | `./scripts/ci.sh` |
| Full gate (sign-off, once) | `./scripts/ci.sh` |

## Files touched

- `Sources/Shared/TaskCommand.swift`: message text at every throw site; the D7 suffix in
  `Failure.usage`; the D8 directory check before git; `LC_ALL=C` on the git process (D3); the
  D2 recognition and D4 framing on the git failure path.
- `Tests/TaskCommandTests.swift`: `assertFailed` takes the expected stderr; new cases for each
  testable U/R message, the broken gitfile, the empty and missing working directory, stdin not
  UTF-8, the read-only tasks directory; `runHelper` gains an `environment` and returns stderr for
  the R5 and dubious-ownership cases.

No change to `Sources/CLI/main.swift`, `TaskCommand.run`'s signature, `project.yml` or any doc.

## Testing

XCTest through `./scripts/ci.sh`, in `TaskCommandTests` with `GitRepoFixture` repos.

- T1 Outside a repo, `create`, `list`, `show`: exact R2 with the directory as passed (crit. 1).
- T2 Each usage error U1-U8 asserted exactly, exit 2; existing "writes nothing" checks kept.
- T3 Broken gitfile: R6 framing, git's line present, R2 absent (crit. 3).
- T4 Bare main worktree, all three commands: exact R3 with the canonical bare path.
- T5 `show` malformed id (R9) and unknown id (R10, with the canonical main path).
- T6 `TaskCommand.run` with `workingDirectory: ""` and with a nonexistent path: R1 forms (crit. 6).
- T7 `--body -` with invalid UTF-8 stdin: R11.
- T8 `.clearway/tasks` at mode `0500`: R12 prefix naming a path under it; mode restored in the
  test so the temp root cleans up.
- T9 Embedded binary, `PATH=/nonexistent`: R5, exit 1, empty stdout (crit. 5).
- T10 Embedded binary, `GIT_TEST_ASSUME_DIFFERENT_OWNER=1`, in a fixture repo: R6 with git's
  dubious-ownership and `safe.directory` lines, no R2 (crit. 4).
- Existing success tests stay unchanged, which pins crit. 7's second half.

## Boundaries

- Always: run `./scripts/ci.sh` after the last edit; keep `swiftlint lint` at zero new warnings;
  keep every message inside `TaskCommand.swift`.
- Ask first: recognising any further git failure by its text; changing an exit code.
- Never: print an error on stdout; launch the app or take screenshots.

## Out of scope

- Errors as JSON on stdout (brief).
- Recognising dubious ownership or any git cause beyond D1.
- Changes to the success output or the command surface.
- Localising `cway`'s own messages.
