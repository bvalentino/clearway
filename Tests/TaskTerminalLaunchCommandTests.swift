import XCTest
@testable import Clearway

/// Pins the pure rules behind the doors onto the task terminal: `taskTerminalLaunchCommand`, the
/// choice of what a launch runs (the bare Main Terminal command, or a plain shell);
/// `taskTerminalToggle`, hide vs. reveal vs. launch for the path bar toggle and Cmd+J;
/// `taskWasPromoted`, which both doors re-read the task through once their `await` resumes; and
/// `planNeedsConfirmation` for the Start Now dropdown. `toggleTaskTerminal` and `planTask` are
/// themselves unreachable from XCTest — both take a non-optional `ghostty_app_t` — so these helpers
/// are their whole testable surface.
@MainActor
final class TaskTerminalLaunchCommandTests: TempRootTestCase {

    override static var tempRootPrefix: String { "clearway-task-terminal-launch" }

    /// A Main Terminal command is set: it runs bare, exactly as `buildBareCommand` builds it.
    func testBareMainTerminalCommandWhenConfigured() throws {
        let coordinator = makeCoordinator()
        coordinator.terminalManager.mainCommandProvider = { "claude" }

        let makeCommand = try XCTUnwrap(coordinator.taskTerminalLaunchCommand())
        let command = makeCommand("/usr/bin:/bin")

        XCTAssertEqual(
            command,
            coordinator.terminalManager.buildBareCommand(agentCommand: "claude", path: "/usr/bin:/bin")
        )
    }

    /// Nothing configured at all: no launch to build, so the panel opens on a plain shell. The
    /// provider is `settings.configuredMainTerminalCommand`, which is nil for a blank *or*
    /// whitespace-only setting (`SettingsManagerTests.test_configuredMainTerminalCommand_isNilWhenWhitespaceOnly`);
    /// the raw `UserDefaults` read this replaced saw `"   "` as non-empty and launched three spaces
    /// as a command, opening the panel on an immediately-dead terminal.
    func testNoConfiguredCommandOpensAPlainShell() throws {
        let coordinator = makeCoordinator()
        coordinator.terminalManager.mainCommandProvider = { nil }

        XCTAssertNil(coordinator.taskTerminalLaunchCommand())
    }

    // MARK: - A launch that resumes after a promote

    /// Both doors claim the task's terminal, suspend on `ShellEnvironment.awaitPath()`, and open the
    /// surface when they resume. Start Now → Create can land in that window: it writes the worktree
    /// link and closes the terminal, so a launch that resumed regardless would reopen one for a task
    /// that has left `backlogTasks` — an agent lighting no dot anywhere, which is the state that
    /// close exists to prevent.
    ///
    /// Driven through `confirmCreate` rather than a hand-set `worktree`, so the rule cannot drift
    /// from the write the promote actually performs.
    func testALaunchSeesItsTaskAsPromotedOnceCreateHasWrittenTheLink() throws {
        let taskManager = WorkTaskManager(projectPath: tempRoot)
        guard let seed = taskManager.createTask(title: "Ship it") else {
            XCTFail("createTask returned nil"); return
        }
        let coordinator = makeCoordinator(taskManager)
        XCTAssertFalse(coordinator.taskWasPromoted(seed.id),
                       "a task still in the backlog opens its terminal exactly as before")

        coordinator.confirmCreate(taskId: seed.id, branch: "ship-it", command: nil)

        XCTAssertTrue(coordinator.taskWasPromoted(seed.id),
                      "a launch resuming after the promote must open nothing")
    }

    // MARK: - Confirming a plan

    /// `planTask` closes whatever surface the task terminal already holds and opens a fresh one, so
    /// a plan started over a running agent would take its session away with no warning. A live
    /// foreground process is the whole of the rule; nothing else about the task matters.
    func testPlanNeedsConfirmationOnlyWhenAProcessIsRunning() {
        XCTAssertTrue(WorkTaskCoordinator.planNeedsConfirmation(hasActiveProcess: true))
        XCTAssertFalse(WorkTaskCoordinator.planNeedsConfirmation(hasActiveProcess: false))
    }

    /// A row's items plan their own row, selected or not.
    func testStartNowTargetPrefersTheRowOverTheSelection() {
        let rowTask = WorkTask(title: "Row")
        let selected = WorkTask(title: "Selected")

        XCTAssertEqual(
            WorkTaskCoordinator.startNowTarget(row: rowTask, selection: selected), rowTask)
        XCTAssertEqual(WorkTaskCoordinator.startNowTarget(row: rowTask, selection: nil), rowTask)
    }

    /// The toolbar has no row, so its items plan whatever the caller read from the live selection.
    func testStartNowTargetFallsBackToTheSelectionWithNoRow() {
        let selected = WorkTask(title: "Selected")

        XCTAssertEqual(WorkTaskCoordinator.startNowTarget(row: nil, selection: selected), selected)
    }

    /// Nothing to plan: the view's gate omits the command items on this answer.
    func testStartNowTargetIsNilWithNeitherRowNorSelection() {
        XCTAssertNil(WorkTaskCoordinator.startNowTarget(row: nil, selection: nil))
    }

    /// The regression: the rule keeps no state, so a second call answers with the selection it is
    /// handed and never with the earlier one. That is what lets an item resolve its target at click
    /// time rather than capture a task.
    func testStartNowTargetCarriesNoMemoryOfAnEarlierSelection() {
        let taskA = WorkTask(title: "A")
        let taskB = WorkTask(title: "B")

        XCTAssertEqual(WorkTaskCoordinator.startNowTarget(row: nil, selection: taskA), taskA)

        let second = WorkTaskCoordinator.startNowTarget(row: nil, selection: taskB)
        XCTAssertEqual(second, taskB)
        XCTAssertNotEqual(second, taskA)
    }

    // MARK: - Toggling the task terminal

    /// A visible panel hides, whatever else is true: Cmd+J on an open terminal never launches.
    func testVisiblePanelAlwaysHides() {
        XCTAssertEqual(
            WorkTaskCoordinator.taskTerminalToggle(
                isVisible: true, hasSurface: true, hasLaunchCommand: true),
            .hide
        )
        XCTAssertEqual(
            WorkTaskCoordinator.taskTerminalToggle(
                isVisible: true, hasSurface: true, hasLaunchCommand: false),
            .hide
        )
        XCTAssertEqual(
            WorkTaskCoordinator.taskTerminalToggle(
                isVisible: true, hasSurface: false, hasLaunchCommand: true),
            .hide
        )
        XCTAssertEqual(
            WorkTaskCoordinator.taskTerminalToggle(
                isVisible: true, hasSurface: false, hasLaunchCommand: false),
            .hide
        )
    }

    /// The fix: a hidden surface is revealed even when a Main Terminal command is configured. The
    /// launch path would close that surface, killing the agent running in it.
    func testHiddenSurfaceIsRevealedEvenWithALaunchCommand() {
        XCTAssertEqual(
            WorkTaskCoordinator.taskTerminalToggle(
                isVisible: false, hasSurface: true, hasLaunchCommand: true),
            .reveal
        )
        XCTAssertEqual(
            WorkTaskCoordinator.taskTerminalToggle(
                isVisible: false, hasSurface: true, hasLaunchCommand: false),
            .reveal
        )
    }

    /// With no surface, the configured command launches one and an unset setting reveals a plain
    /// shell — the two branches that shipped before the fix, unchanged.
    func testNoSurfaceLaunchesOnlyWhenACommandIsConfigured() {
        XCTAssertEqual(
            WorkTaskCoordinator.taskTerminalToggle(
                isVisible: false, hasSurface: false, hasLaunchCommand: true),
            .launch
        )
        XCTAssertEqual(
            WorkTaskCoordinator.taskTerminalToggle(
                isVisible: false, hasSurface: false, hasLaunchCommand: false),
            .reveal
        )
    }
}
