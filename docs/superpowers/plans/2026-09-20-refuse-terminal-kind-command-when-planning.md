# Plan: Refuse a terminal-kind command when planning a task

Breaks down `docs/superpowers/specs/2026-09-20-refuse-terminal-kind-command-when-planning.md`.

**Date:** 2026-09-20
**Base:** b4369a5 (`Split buttons for Run and Open in (#237)`)

## Architecture decisions carried from the spec

- The refusal lives in `WorkTaskCoordinator.planCommand(for:using:)`
  (`Sources/App/WorkTaskCoordinator.swift:173`). No new symbol: `planTask`'s existing
  `guard let resolved = planCommand(…) else { return }` is already the refusal, and it returns ahead
  of `beginTaskLaunch`, the `Task`, and the `taskTerminalOpened` post (decisions 1, 2).
- `planTask` (`Sources/App/WorkTaskCoordinator+TaskTerminal.swift`) is **not** edited. A second
  `guard command.kind == .agent` there would state the rule twice and leave the XCTest-unreachable
  copy as the one a future caller reads (decision 2).
- The kind check runs **first**, ahead of the existing `freshTask(id:)` guard. The refusal is a
  property of the command alone, so it must not depend on the task resolving, and a terminal-kind
  command handed an unresolvable task should log the reason the caller can fix (decision 4).
- One `Ghostty.logger.error` line, matching the two refusal logs already in the file
  (`WorkTaskCoordinator.swift:109`, `:130`). Exact string, to be reproduced verbatim:
  `planCommand: command <id> is <kind>-kind; only an agent command can plan a task`
  with the command `id` and the `kind` rawValue both interpolated `privacy: .public`. The command's
  `name` and `text` are user content and stay out of the line (decision 3).
- No alert and no UI change. Every live caller already filters to `savedCommandManager.agentCommands`
  (`Sources/App/WorkTaskListView.swift:268`), so this path is unreachable from the UI today — it is
  a programming-error guard and a log is the right weight (decision 5).
- The `guard case .agent` in `TerminalManager.run(_:inTaskTerminalFor:app:directory:)`
  (`Sources/App/TerminalManager+Commands.swift:56`) **stays**. Two guards at different layers is
  correct; this change adds the early one (decision 6).
- Tests go in `Tests/WorkTaskCoordinatorTests.swift`, in the existing `// MARK: - Plan` section
  beside the four `planCommand` tests, using a new `terminalCommand(text:)` helper beside
  `agentCommand(text:)` (`:546`). Not `TaskTerminalLaunchCommandTests`, which is about
  `taskTerminalLaunchCommand` and `planNeedsConfirmation` (decision 7).
- The tests assert the **return value** in both directions, never the log. `Ghostty.logger` is an
  `os.Logger` with no injectable seam and nothing in the suite reads back from `OSLog`; adding one
  for a single line is speculative indirection (decision 8).
- The four existing `planCommand` tests must pass **untouched** — the `.agent` path is unchanged.
- `planCommand` has exactly two callers, `planTask` and those tests, so tightening its contract
  breaks no other reader.

## Dependency graph

```
T1 (guard + log in planCommand, tests in WorkTaskCoordinatorTests)
```

One task. The guard and the test that pins it are the same change: the spec's deliverable is the
pinned contract, and a guard landed without its test leaves nothing to verify beyond "no
regression". Two files, well inside the five-file limit.

## T1: Refuse a non-agent command in `planCommand`, and pin both directions

**Files touched**

- `Sources/App/WorkTaskCoordinator.swift`
- `Tests/WorkTaskCoordinatorTests.swift`

**What it does**

1. In `Sources/App/WorkTaskCoordinator.swift`, add a leading guard to
   `planCommand(for:using:)`, **above** the existing `guard let current = workTaskManager.freshTask(id: task.id)`:

   ```swift
   guard command.kind == .agent else {
       Ghostty.logger.error(
           "planCommand: command \(command.id, privacy: .public) is \(command.kind.rawValue, privacy: .public)-kind; only an agent command can plan a task")
       return nil
   }
   ```

   Keep the rest of the body exactly as it is.

2. Extend that method's doc comment with one sentence saying why the guard is there and why it
   comes first — that only an `.agent` command means anything to a plan run, that
   `TerminalManager.run` would otherwise drop it after `planTask` had already claimed the launch
   slot and posted `taskTerminalOpened`, and that the check precedes `freshTask` because the
   refusal is a property of the command alone. Do not restate what the code says; state the reason
   the code does not carry. No other comment is added anywhere in this change.

3. In `Tests/WorkTaskCoordinatorTests.swift`, add a `terminalCommand(text:)` private helper beside
   `agentCommand(text:)` (`:546`), mirroring it with `kind: .terminal`.

4. In the `// MARK: - Plan` section, beside the four existing `planCommand` tests, add two cases:

   - A terminal-kind command is refused. Seed a real task with `WorkTaskManager(projectPath: tempRoot)`
     + `createTask`, build the coordinator with `makeCoordinator(taskManager)`, call
     `planCommand(for: seed, using: terminalCommand(text: "echo {{ task_path }}"))`, assert the
     result is `nil`. The task resolving is the point: it isolates the kind as the sole reason for
     the refusal.
   - An agent-kind command is accepted. Same seed and coordinator, call with
     `agentCommand(text: "plan {{ task_path }}")`, assert the result is non-`nil`. This is the
     other direction of the same rule, so a future change that refuses everything cannot pass.

   Each carries a one-line doc comment in the style of its four neighbours.

**Acceptance criteria**

- `planCommand(for:using:)` returns `nil` for a `.terminal`-kind command whether or not the task
  resolves, and the kind check is the first statement in the body.
- It returns a substituted command for an `.agent`-kind command, unchanged from today; the four
  existing `planCommand` tests pass with no edit to them.
- The refusal logs exactly one `Ghostty.logger.error` line carrying the command id and the kind
  rawValue, both `privacy: .public`.
- `planTask` is unedited, so on the refusal path it reaches no `beginTaskLaunch`, spawns no `Task`,
  and posts no `taskTerminalOpened`.
- `Tests/WorkTaskCoordinatorTests.swift` carries the two new cases and the `terminalCommand(text:)`
  helper.
- No change to `TerminalManager+Commands.swift`, to any view, or to `planNeedsConfirmation`,
  `planWorkingDirectory` or `taskTerminalLaunchCommand`.

**How the criteria are verified**

- `./scripts/ci.sh` is green. It is the only runner of the test suite and it lints; the two new
  cases fail before the guard exists and pass after.
- `swiftlint lint --quiet` reports no new warning. The added log line is long — check it against
  the file's existing `Ghostty.logger.error` calls (`:109`, `:130`), which wrap the interpolated
  string onto its own continuation line for the same reason.
- `git diff --stat` shows two files changed and nothing else.

## Build log

### T1: Refuse a non-agent command in `planCommand`, and pin both directions

**What landed**

| File | State |
| --- | --- |
| `Sources/App/WorkTaskCoordinator.swift` | `planCommand(for:using:)` gained the leading `guard command.kind == .agent` with the `Ghostty.logger.error` line, and a doc-comment paragraph saying why it comes first. Body otherwise untouched. |
| `Tests/WorkTaskCoordinatorTests.swift` | `testPlanCommandRefusesATerminalKindCommand`, `testPlanCommandAcceptsAnAgentKindCommand`, and the `terminalCommand(text:)` helper beside `agentCommand(text:)`. |

`WorkTaskCoordinator+TaskTerminal.swift`, `TerminalManager+Commands.swift` and every view are
unedited, as the plan requires.

**Evidence: the watched failure**

`./scripts/ci.sh` with the tests in place and the guard absent — the refusal case is red, the
acceptance case already green (it is the unchanged direction):

```
Test Suite 'WorkTaskCoordinatorTests' started at 2026-09-20 18:34:12.594.
    ✖ testPlanCommandRefusesATerminalKindCommand, XCTAssertNil failed: "SavedCommand(id: 7FF2D653-537D-4434-B042-5255B8136905, name: "Plan", kind: Clearway.SavedCommand.Kind.terminal, text: "echo /var/folders/.../tasks/DA511133-39BE-4949-976A-0430C52878DF.md", agent: "claude", autoRun: true)"
Executed 28 tests, with 1 failure (0 unexpected) in 3.203 (3.216) seconds
...
Executed 678 tests, with 1 failure (0 unexpected) in 106.033 (106.270) seconds
```

The failure is the substituted terminal-kind command coming back where `nil` was expected — the
defect the spec describes, reproduced at the return value rather than at the terminal.

**Deviations from the plan**

None.

**The gate**

`./scripts/ci.sh` after the last edit: `Executed 678 tests, with 0 failures (0 unexpected)` /
`CI passed.` (exit 0). `swiftlint lint --quiet` exits 0 with no output; the log line is one
continuation line, matching `:109` and `:130`. `git status --porcelain` before the commit listed
only the two changed source files — no `default.profraw`, since the app was not launched.

### Simplify pass

Nothing changed. Reuse and efficiency found nothing: no `isAgent` predicate exists to call (the
codebase states this rule as an inline `kind == .agent` at `SavedCommand.swift:46`, `:63`), no
shared cross-file terminal-command fixture exists for `terminalCommand(text:)` to reuse, and the
kind check ahead of `freshTask` is the cheaper order because `freshTask` reads from disk. Two
findings were raised and skipped: merging the two new tests into one would drop the intent-naming
and contradict spec criterion 5 (their five-line setup is this file's pattern, repeated 19 times,
so extracting it is a refactor outside this diff), and tightening the new doc comment was judged
churn — both halves state context the code does not carry, at the length of its neighbours.
`./scripts/ci.sh` after the pass: exit 0, `Executed 678 tests, with 0 failures (0 unexpected)`.
