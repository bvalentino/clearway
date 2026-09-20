# Refuse a terminal-kind command when planning a task

**Date:** 2026-09-20
**Base:** b4369a5 (`Split buttons for Run and Open in (#237)`)

Planning a task runs a saved command in the task's own bottom terminal. Saved commands come in two
kinds, and only `.agent` means anything to a plan run: `TerminalManager.run(_:inTaskTerminalFor:…)`
opens on `guard case .agent` and returns for a `.terminal` command, having done nothing. The
coordinator has already claimed the task's launch slot and posted `taskTerminalOpened` by then, so
the detail view flips to preview and no terminal work follows, with nothing logged anywhere. This
change makes the refusal explicit and early: `planCommand` — the testable half `planTask` already
guards on — returns `nil` for a non-agent command and logs why, before anything touches the
terminal, and a unit test pins both directions so a future caller cannot reintroduce the dead press.

## Decisions

| # | Question | Decision | Source |
| --- | --- | --- | --- |
| 1 | Where does the guard live? | In `planCommand(for:using:)` (`Sources/App/WorkTaskCoordinator.swift:173`). That method exists for exactly this reason — its doc says it was "split out of `planTask` because that one needs a `ghostty_app_t` XCTest cannot produce" — and `planTask`'s first line is already `guard let resolved = planCommand(…) else { return }` (`WorkTaskCoordinator+TaskTerminal.swift:68`), which returns ahead of `beginTaskLaunch`, the `Task`, and the `taskTerminalOpened` post. So the refusal is up front and directly testable with no new symbol. The alternative — a third symbol, `static func plannable(_:) -> Bool` beside `planNeedsConfirmation`, called from `planTask` — loses: it adds a second gate to a method that already has one, and `planTask` would still need `planCommand` to succeed afterwards. | Spec author |
| 2 | Does `planTask` itself change? | No. Its existing `guard let resolved` is the refusal. Adding a second `guard command.kind == .agent` there would state the rule twice and leave the untestable copy as the one a future caller reads. | Spec author |
| 3 | What is logged? | One `Ghostty.logger.error` line from `planCommand`, matching the two refusal logs already in that file (`WorkTaskCoordinator.swift:109`, `130`): `"planCommand: command <id> is <kind>-kind; only an agent command can plan a task"`. The command **id** and the **kind** rawValue, both `privacy: .public`; the command's name and text are user content and stay out of it. `.error` rather than `.warning` because the sibling refusals in this file are `.error` and this one means a caller passed something the door does not accept. | Spec author |
| 4 | Which guard runs first? | The kind check, ahead of `freshTask(id:)`. The refusal is a property of the command alone, so it should not depend on the task resolving, and a terminal-kind command handed an unresolvable task should log the reason the caller can fix. | Spec author |
| 5 | Does the user see an alert? | No. Every live caller already filters to `savedCommandManager.agentCommands` (`Sources/App/WorkTaskListView.swift:268` → `SavedCommandManager.swift:72`), so this path is unreachable from the UI today. This is a programming-error guard, and a log is the right weight; an `NSAlert` would be copy nobody can ever be shown. | Spec author |
| 6 | Is the `guard case .agent` in `TerminalManager.run` removed now that the caller refuses? | No. It is kept out of caution, as the terminal layer's last line of defence. `run(_:inTaskTerminalFor:app:directory:)` has exactly one caller today — `planTask` (`WorkTaskCoordinator+TaskTerminal.swift:79`) — so the guard is unreachable once `planCommand` refuses; it stays because `planCommand` hands back a plain `SavedCommand` carrying no proof of its kind, leaving the terminal layer the one place that checks before launching. Two guards at different layers is correct here; this task adds the early one. | Spec author |
| 7 | Where does the test go? | `Tests/WorkTaskCoordinatorTests.swift`, in the existing `// MARK: - Plan` section beside the four `planCommand` tests, using the file's `agentCommand(text:)` helper (`:546`) plus a sibling `terminalCommand(text:)`. `TaskTerminalLaunchCommandTests` is about `taskTerminalLaunchCommand` and `planNeedsConfirmation`; `planCommand` is tested here. | Spec author |
| 8 | Does the test assert on the log? | No. `Ghostty.logger` is an `os.Logger` with no injectable seam and nothing in the suite reads back from `OSLog`; adding one for a single line is speculative indirection. The test asserts the return value in both directions, which is the behaviour the empty-panel case turns on. | Spec author |

## Assumptions

Each verified against the codebase at `b4369a5`. No probe was needed and none was written.

1. **A terminal-kind command reaches the terminal layer and is dropped there.** `TerminalManager.run(_:inTaskTerminalFor:app:directory:)` begins `guard case .agent(let agent, let prompt, let submit) = CommandLaunch.launch(for: command) else { return }` (`Sources/App/TerminalManager+Commands.swift:56`), and `CommandLaunch.launch` maps `.terminal` to `.shell` (`Sources/App/SavedCommand.swift:76-80`). So the whole body — both the staged and the submitted branch, and the `openTaskTerminal` call in each — is skipped.
2. **`planTask` has already acted by then.** It claims the launch slot with `beginTaskLaunch` (`WorkTaskCoordinator+TaskTerminal.swift:75`), spawns the `Task`, and posts `WorkTaskNotification.taskTerminalOpened` (`:82`). The observer in `TaskDetailView` (`Sources/App/TaskDetailView.swift:163-169`) switches the editor to `.preview` when the body is non-empty. That is the visible half of "reveals the panel and then does nothing": the panel itself is only revealed by `openTaskTerminal`, which sets `taskTerminalVisible[taskId] = true` (`Sources/App/TerminalManager+TaskTerminals.swift:90`) and is never reached — so a task whose terminal was already open keeps the *previous* surface and the operator sees a stale terminal, and one whose terminal was closed sees no terminal at all. Either way nothing runs and nothing says so.
3. **`planCommand` is reachable from XCTest and already covered.** Four tests call it directly (`Tests/WorkTaskCoordinatorTests.swift:455`, `480`, `489`, `508`) through `makeCoordinator` (`Tests/TestHelpers.swift:43-49`), which needs no `ghostty_app_t`.
4. **`planCommand` has exactly two callers.** `planTask` (`WorkTaskCoordinator+TaskTerminal.swift:68`) and those tests — a repo-wide grep for `planCommand` returns nothing else. So tightening its contract to `.agent` breaks no other reader.
5. **No live UI path can pass a terminal-kind command.** `startNowItems` builds its rows from `savedCommandManager.agentCommands` (`Sources/App/WorkTaskListView.swift:268`), and both doors — the toolbar split button (`:80`) and the row context menu (`:233`) — render the same helper. The defect is therefore latent, which is what makes the test the deliverable rather than a bug fix anyone can observe today.
6. **`SavedCommand.Kind` is a two-case `String` enum** (`Sources/App/SavedCommand.swift:13-16`), so `kind.rawValue` is a stable, non-sensitive log token and `kind == .agent` is the whole of the rule.
7. **`Ghostty.logger` is the file's logging convention.** `Logger(subsystem:category:)` on the `Ghostty` namespace (`Sources/Ghostty/Ghostty.swift:7`), used with `privacy: .public` interpolation at `WorkTaskCoordinator.swift:109` and `:130`.

## Objective

`planTask` refuses a non-agent saved command before it touches the task's terminal, says so in the
log, and is pinned by a test.

### Success criteria

1. `planCommand(for:using:)` returns `nil` for a `.terminal`-kind command, regardless of whether the
   task resolves.
2. It returns a substituted command for an `.agent`-kind command, unchanged from today — the four
   existing `planCommand` tests still pass untouched.
3. A refused command produces one `Ghostty.logger.error` line naming the command id and the kind,
   both `privacy: .public`.
4. On the refusal path `planTask` makes no call to `beginTaskLaunch`, spawns no `Task`, and posts no
   `taskTerminalOpened`.
5. Two new tests in `Tests/WorkTaskCoordinatorTests.swift`: a terminal-kind command is refused, an
   agent-kind command is accepted.
6. `./scripts/ci.sh` is green, and `swiftlint lint --quiet` reports no new warning.

## Verification

```bash
./scripts/ci.sh
```

The only runner of the test suite, and the same gate `.github/workflows/ci.yml` applies. It
regenerates the Xcode project first, which the added test cases do not strictly need — no Swift file
is added — but it is the project's single command and it is what the build stage and the sign-off
gate both run. Before sign-off, `git status --porcelain`, expecting the un-gitignored
`default.profraw` only if the app was launched.

## Files touched

| File | Change |
| --- | --- |
| `Sources/App/WorkTaskCoordinator.swift` | `planCommand(for:using:)` gains the leading kind guard and the log line; its doc comment gains the sentence that says why. |
| `Tests/WorkTaskCoordinatorTests.swift` | Two test cases in the `// MARK: - Plan` section, plus a `terminalCommand(text:)` helper beside `agentCommand(text:)`. |

## Out of scope

- **Removing the `guard case .agent` in `TerminalManager.run`** (decision 6). It stays.
- **A second guard, an alert, or any UI change.** The Start Now dropdown already lists agent
  commands only and is not touched.
- **`planNeedsConfirmation`, `planWorkingDirectory`, `taskTerminalLaunchCommand`.** Unrelated rules
  in the same extension.
- **The other `run(_:in:app:)` overload** and every non-plan path a `.terminal` command legitimately
  takes.
- **A log-assertion seam on `Ghostty.logger`** (decision 8). If the project later wants logs under
  test, it is its own change across every call site, not a hook added for one line.
