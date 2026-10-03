import XCTest
@testable import Clearway

/// Behavioral contract for the two halves of Start Now. `resolveStart` resolves the task fresh from
/// disk and decides what would happen, writing nothing; `confirmCreate` carries the write, stamping
/// the worktree link and nothing else.
@MainActor
final class WorkTaskCoordinatorTests: TempRootTestCase {

    // MARK: - Resolving a start

    /// Start Now opens a sheet the operator can cancel, so resolving must leave the task exactly as
    /// it was.
    func testResolveStartWritesNothing() throws {
        let taskManager = WorkTaskManager(projectPath: tempRoot)
        guard let seed = taskManager.createTask(title: "Ship it") else {
            XCTFail("createTask returned nil"); return
        }
        let coordinator = makeCoordinator(taskManager)
        let path = taskManager.filePath(for: seed)
        let before = try String(contentsOfFile: path, encoding: .utf8)

        guard case .prefill(let prefill) = coordinator.resolveStart(seed) else {
            XCTFail("expected prefill"); return
        }

        XCTAssertEqual(prefill.taskId, seed.id)
        XCTAssertEqual(prefill.title, "Ship it")
        XCTAssertEqual(try String(contentsOfFile: path, encoding: .utf8), before,
                       "resolving writes nothing to the task file")
        XCTAssertNil(coordinator.pendingCreate, "resolving records nothing to complete")
    }

    func testResolveStartDerivesTheBranchWhenTheTaskNamesNone() throws {
        let taskManager = WorkTaskManager(projectPath: tempRoot)
        guard let seed = taskManager.createTask(title: "Ship It Now") else {
            XCTFail("createTask returned nil"); return
        }

        guard case .prefill(let prefill) = makeCoordinator(taskManager).resolveStart(seed) else {
            XCTFail("expected prefill"); return
        }

        XCTAssertEqual(prefill.branch, "ship-it-now")
    }

    /// A branch that is already live is focused rather than created a second time.
    func testResolveStartReusesALiveWorktree() throws {
        let taskManager = WorkTaskManager(projectPath: tempRoot)
        guard let seed = taskManager.createTask(title: "Reuse me") else {
            XCTFail("createTask returned nil"); return
        }
        taskManager.updateFields(id: seed.id) { $0.worktree = "reuse-me" }
        guard let linked = taskManager.freshTask(id: seed.id) else {
            XCTFail("task missing"); return
        }
        let coordinator = makeCoordinator(taskManager)
        let live = makeWorktree(branch: "reuse-me", path: "/tmp/reuse-me")
        coordinator.worktreeManager.worktrees = [live]

        guard case .reuse(let wt) = coordinator.resolveStart(linked) else {
            XCTFail("expected reuse"); return
        }

        XCTAssertEqual(wt, live)
    }

    /// The gate is the worktree link, not the file's old `status:` line: an unlinked task starts
    /// whatever that line says.
    func testResolveStartPrefillsAnUnlinkedTaskWhoseFileSaysInProgress() throws {
        let taskManager = WorkTaskManager(projectPath: tempRoot)
        guard let seed = taskManager.createTask(title: "Old file") else {
            XCTFail("createTask returned nil"); return
        }
        let raw = """
            ---
            id: \(seed.id.uuidString)
            title: Old file
            status: in_progress
            ---
            """
        try raw.write(toFile: taskManager.filePath(for: seed), atomically: true, encoding: .utf8)
        taskManager.reloadFromDisk()

        guard case .prefill(let prefill) = makeCoordinator(taskManager).resolveStart(seed) else {
            XCTFail("expected prefill"); return
        }

        XCTAssertEqual(prefill.branch, "old-file")
    }

    /// A link with no live worktree is the window between Create and the worktree going live:
    /// a second Start Now must not open another sheet for a branch already being created.
    func testResolveStartIgnoresALinkedTaskWithNoLiveWorktree() throws {
        let taskManager = WorkTaskManager(projectPath: tempRoot)
        guard let seed = taskManager.createTask(title: "Being created") else {
            XCTFail("createTask returned nil"); return
        }
        taskManager.updateFields(id: seed.id) { $0.worktree = "being-created" }

        guard case .ignored = makeCoordinator(taskManager).resolveStart(seed) else {
            XCTFail("expected ignored"); return
        }
    }

    // MARK: - Confirming a create

    /// Create writes the branch the operator confirmed — which may not be the branch the prefill
    /// proposed.
    func testConfirmCreateWritesTheConfirmedBranch() throws {
        let taskManager = WorkTaskManager(projectPath: tempRoot)
        guard let seed = taskManager.createTask(title: "Ship it") else {
            XCTFail("createTask returned nil"); return
        }
        let coordinator = makeCoordinator(taskManager)
        let command = agentCommand(text: "claude {{ task_path }}")

        coordinator.confirmCreate(taskId: seed.id, branch: "hand-typed", command: command)

        XCTAssertEqual(taskManager.freshTask(id: seed.id)?.worktree, "hand-typed")
        XCTAssertEqual(
            coordinator.pendingCreate,
            WorkTaskCoordinator.PendingCreate(
                task: WorkTaskCoordinator.PendingCreate.TaskLink(
                    id: seed.id,
                    priorWorktree: nil
                ),
                branch: "hand-typed",
                command: command
            )
        )
    }

    /// The link is the whole of the write: dropping the `worktree:` line from the file Create wrote
    /// gives back the file it started from.
    func testConfirmCreateWritesOnlyTheWorktreeLink() throws {
        let taskManager = WorkTaskManager(projectPath: tempRoot)
        guard let seed = taskManager.createTask(title: "Ship it") else {
            XCTFail("createTask returned nil"); return
        }
        let path = taskManager.filePath(for: seed)
        let before = try String(contentsOfFile: path, encoding: .utf8)

        makeCoordinator(taskManager).confirmCreate(taskId: seed.id, branch: "ship-it", command: nil)

        let after = try String(contentsOfFile: path, encoding: .utf8)
        let linkLine = "worktree: \"ship-it\"\n"
        XCTAssertTrue(after.contains(linkLine), "Create writes the link")
        XCTAssertEqual(after.replacingOccurrences(of: linkLine, with: ""), before,
                       "Create writes nothing but the link")
    }

    /// The same sheet creates hand-made worktrees, which carry no task to write to.
    func testConfirmCreateWithoutATaskWritesNoTaskFileAndStillRecordsThePendingCreate() throws {
        let taskManager = WorkTaskManager(projectPath: tempRoot)
        let coordinator = makeCoordinator(taskManager)

        coordinator.confirmCreate(taskId: nil, branch: "manual", command: nil)

        XCTAssertEqual(
            coordinator.pendingCreate,
            WorkTaskCoordinator.PendingCreate(task: nil, branch: "manual", command: nil)
        )
        XCTAssertTrue(taskManager.tasks.isEmpty, "a hand-made worktree creates no task")
        let files = (try? FileManager.default.contentsOfDirectory(atPath: taskManager.tasksDirectory)) ?? []
        XCTAssertTrue(files.filter { $0.hasSuffix(".md") }.isEmpty, "no task file is written")
    }

    /// A promoted task leaves `backlogTasks`, the only renderer of `taskPhases`, so an agent left
    /// running in its bottom terminal would light no dot anywhere. Create closes that terminal.
    ///
    /// The surface half of the close needs a `ghostty_app_t` XCTest cannot produce. The panel
    /// bookkeeping is the observable half, and a height the operator dragged is the one piece of it
    /// a test can seed through the manager's own API — so this pins that `confirmCreate` reaches
    /// `closeTaskTerminal`, not each collection that call clears.
    func testConfirmCreateClosesThePromotedTasksTerminal() throws {
        let taskManager = WorkTaskManager(projectPath: tempRoot)
        guard let seed = taskManager.createTask(title: "Ship it") else {
            XCTFail("createTask returned nil"); return
        }
        let coordinator = makeCoordinator(taskManager)
        coordinator.terminalManager.setTaskTerminalHeight(320, for: seed.id)
        XCTAssertEqual(coordinator.terminalManager.taskTerminalHeights[seed.id], 320,
                       "the seed must land, or the assertion below holds for a task that never had a height")

        coordinator.confirmCreate(taskId: seed.id, branch: "ship-it", command: nil)

        XCTAssertNil(coordinator.terminalManager.taskTerminalHeights[seed.id],
                     "a promoted task keeps no terminal of its own")
    }

    // MARK: - Abandoning a create

    /// `git worktree add` can fail after the frontmatter is already written — a branch that exists
    /// with no worktree is enough. Unwinding must leave the file byte-for-byte as it was, because a
    /// link naming a branch with no worktree is one `resolveStart` ignores, and the task can then
    /// never be started from the UI.
    func testAbandonPendingCreateRestoresTheTaskExactlyAsItWas() throws {
        let taskManager = WorkTaskManager(projectPath: tempRoot)
        guard let seed = taskManager.createTask(title: "Ship it") else {
            XCTFail("createTask returned nil"); return
        }
        let coordinator = makeCoordinator(taskManager)
        let path = taskManager.filePath(for: seed)
        let before = try String(contentsOfFile: path, encoding: .utf8)

        coordinator.confirmCreate(taskId: seed.id, branch: "ship-it", command: nil)
        coordinator.abandonPendingCreate()

        XCTAssertNil(coordinator.pendingCreate, "abandoning consumes the pending create")
        XCTAssertEqual(try String(contentsOfFile: path, encoding: .utf8), before,
                       "a failed create leaves the task file untouched")
        let restored = taskManager.freshTask(id: seed.id)
        XCTAssertNil(restored?.worktree, "no branch link survives a failed create")

        guard case .prefill = coordinator.resolveStart(try XCTUnwrap(restored)) else {
            XCTFail("the task must still be startable"); return
        }
    }

    /// A hand-made worktree writes no task, so its unwind clears the pending create and nothing
    /// else — there is no file to put back.
    func testAbandonPendingCreateWithoutATaskWritesNothing() throws {
        let taskManager = WorkTaskManager(projectPath: tempRoot)
        let coordinator = makeCoordinator(taskManager)

        coordinator.confirmCreate(taskId: nil, branch: "manual", command: nil)
        coordinator.abandonPendingCreate()

        XCTAssertNil(coordinator.pendingCreate)
        XCTAssertTrue(taskManager.tasks.isEmpty)
    }

    // MARK: - Pending create

    /// `completePendingCreate` relocates only for the branch it is holding, and consumes the
    /// pending create so a later worktree creation cannot move the file a second time.
    func testCompletePendingCreateRelocatesOnlyForTheBranchItIsHolding() throws {
        let taskManager = WorkTaskManager(projectPath: tempRoot)
        guard let seed = taskManager.createTask(title: "Relocate me") else {
            XCTFail("createTask returned nil"); return
        }
        let coordinator = makeCoordinator(taskManager)
        guard case .prefill(let prefill) = coordinator.resolveStart(seed) else {
            XCTFail("expected prefill"); return
        }
        let branch = prefill.branch
        coordinator.confirmCreate(taskId: prefill.taskId, branch: branch, command: nil)
        let centralPath = taskManager.filePath(for: seed)

        let otherPath = (tempRoot as NSString).appendingPathComponent("wt-other")
        coordinator.completePendingCreate(
            branch: "unrelated",
            worktree: makeWorktree(branch: "unrelated", path: otherPath)
        )
        XCTAssertTrue(FileManager.default.fileExists(atPath: centralPath),
                      "an unrelated branch must not relocate this task")
        XCTAssertNotNil(coordinator.pendingCreate, "an unrelated branch must not consume the pending create")

        let worktreePath = (tempRoot as NSString).appendingPathComponent("wt-\(branch)")
        taskManager.worktreeResolver = { [(branch: branch, path: worktreePath)] }
        coordinator.completePendingCreate(
            branch: branch,
            worktree: makeWorktree(branch: branch, path: worktreePath)
        )
        XCTAssertNil(coordinator.pendingCreate, "the matching branch consumes the pending create")
        XCTAssertFalse(FileManager.default.fileExists(atPath: centralPath),
                       "the central file moves into the worktree")
        let taskMd = (worktreePath as NSString).appendingPathComponent(".clearway/TASK.md")
        XCTAssertTrue(FileManager.default.fileExists(atPath: taskMd),
                      "the task lands at the worktree's TASK.md")
    }

    /// The command comes back with `{{ task_path }}` pointing at the file the relocation just
    /// wrote, absolute — the agent is handed the brief it is being asked to work from.
    func testCompletePendingCreateResolvesTheTokenToTheRelocatedTaskFile() throws {
        let taskManager = WorkTaskManager(projectPath: tempRoot)
        guard let seed = taskManager.createTask(title: "Resolve me") else {
            XCTFail("createTask returned nil"); return
        }
        let coordinator = makeCoordinator(taskManager)
        let branch = "resolve-me"
        let worktreePath = (tempRoot as NSString).appendingPathComponent("wt-\(branch)")
        coordinator.confirmCreate(
            taskId: seed.id, branch: branch, command: agentCommand(text: "plan {{ task_path }} now")
        )
        taskManager.worktreeResolver = { [(branch: branch, path: worktreePath)] }

        let resolved = coordinator.completePendingCreate(
            branch: branch,
            worktree: makeWorktree(branch: branch, path: worktreePath)
        )

        let taskMd = (worktreePath as NSString).appendingPathComponent(".clearway/TASK.md")
        XCTAssertEqual(resolved?.text, "plan \(taskMd) now")
        XCTAssertTrue(taskMd.hasPrefix("/"), "the substituted path is absolute")
    }

    /// A hand-made worktree carries no task, so there is no path to name: the token stays verbatim
    /// rather than becoming a blank argument the agent would read as a malformed path.
    func testCompletePendingCreateWithoutATaskLeavesTheTokenVerbatim() throws {
        let taskManager = WorkTaskManager(projectPath: tempRoot)
        let coordinator = makeCoordinator(taskManager)
        let worktreePath = (tempRoot as NSString).appendingPathComponent("wt-manual")
        coordinator.confirmCreate(
            taskId: nil, branch: "manual", command: agentCommand(text: "read {{ task_path }}")
        )

        let resolved = coordinator.completePendingCreate(
            branch: "manual",
            worktree: makeWorktree(branch: "manual", path: worktreePath)
        )

        XCTAssertEqual(resolved?.text, "read {{ task_path }}")
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: (worktreePath as NSString).appendingPathComponent(".clearway/TASK.md")
            ),
            "a pending create with no task relocates nothing"
        )
    }

    /// No command picked means nothing to run — the relocation still happens.
    func testCompletePendingCreateWithoutACommandReturnsNil() throws {
        let taskManager = WorkTaskManager(projectPath: tempRoot)
        guard let seed = taskManager.createTask(title: "No command") else {
            XCTFail("createTask returned nil"); return
        }
        let coordinator = makeCoordinator(taskManager)
        let branch = "no-command"
        let worktreePath = (tempRoot as NSString).appendingPathComponent("wt-\(branch)")
        coordinator.confirmCreate(taskId: seed.id, branch: branch, command: nil)
        taskManager.worktreeResolver = { [(branch: branch, path: worktreePath)] }

        let resolved = coordinator.completePendingCreate(
            branch: branch,
            worktree: makeWorktree(branch: branch, path: worktreePath)
        )

        XCTAssertNil(resolved)
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: (worktreePath as NSString).appendingPathComponent(".clearway/TASK.md")
            ),
            "the relocation still runs"
        )
    }

    /// `.clearway` is committed, so a branch can carry a `TASK.md` of its own. The relocation
    /// refuses that slot and leaves the task central, so the command must not name the worktree
    /// file — handing the agent a path it did resolve would hand it a different task's brief.
    func testCompletePendingCreateLeavesTheTokenVerbatimWhenTheSlotIsTaken() throws {
        let taskManager = WorkTaskManager(projectPath: tempRoot)
        guard let seed = taskManager.createTask(title: "Mine") else {
            XCTFail("createTask returned nil"); return
        }
        let coordinator = makeCoordinator(taskManager)
        let branch = "slot-taken"
        let worktreePath = (tempRoot as NSString).appendingPathComponent("wt-\(branch)")
        let occupant = (worktreePath as NSString).appendingPathComponent(".clearway/TASK.md")
        try FileManager.default.createDirectory(
            atPath: (occupant as NSString).deletingLastPathComponent,
            withIntermediateDirectories: true
        )
        let occupantContent = "---\nid: \(UUID().uuidString)\n---\nSomeone else's brief\n"
        try occupantContent.write(toFile: occupant, atomically: true, encoding: .utf8)
        let centralPath = taskManager.filePath(for: seed)

        coordinator.confirmCreate(
            taskId: seed.id, branch: branch, command: agentCommand(text: "work {{ task_path }}")
        )
        let resolved = coordinator.completePendingCreate(
            branch: branch,
            worktree: makeWorktree(branch: branch, path: worktreePath)
        )

        XCTAssertEqual(resolved?.text, "work {{ task_path }}",
                       "a refused relocation names no path")
        XCTAssertTrue(FileManager.default.fileExists(atPath: centralPath),
                      "the task stays central when the slot is taken")
        XCTAssertEqual(try String(contentsOfFile: occupant, encoding: .utf8), occupantContent,
                       "the worktree's own TASK.md is untouched")
    }

    /// The task's file can vanish between Start Now and Create. The worktree is still created, but
    /// nothing was written, so the record carries no link to unwind and names no path to relocate.
    /// The terminal still goes: the close is keyed on the task id, not on the write landing, and a
    /// task whose file is gone renders no row for an agent left running there to report to.
    func testConfirmCreateRecordsNoLinkWhenTheTaskIsGone() throws {
        let taskManager = WorkTaskManager(projectPath: tempRoot)
        let coordinator = makeCoordinator(taskManager)
        let command = agentCommand(text: "work {{ task_path }}")
        let gone = UUID()
        coordinator.terminalManager.setTaskTerminalHeight(320, for: gone)

        coordinator.confirmCreate(taskId: gone, branch: "vanished", command: command)

        XCTAssertEqual(
            coordinator.pendingCreate,
            WorkTaskCoordinator.PendingCreate(task: nil, branch: "vanished", command: command)
        )
        XCTAssertNil(coordinator.terminalManager.taskTerminalHeights[gone],
                     "a task whose file vanished still loses its terminal")

        coordinator.abandonPendingCreate()
        XCTAssertNil(coordinator.pendingCreate)
        XCTAssertTrue(taskManager.tasks.isEmpty, "there was nothing to put back")
    }

    // MARK: - Clearing the selection after a create

    func testStartedTaskIsSelectedOnlyForItsOwnBranchAndSelection() {
        let taskId = UUID()
        let pending = WorkTaskCoordinator.PendingCreate(
            task: WorkTaskCoordinator.PendingCreate.TaskLink(
                id: taskId, priorWorktree: nil
            ),
            branch: "ship-it",
            command: nil
        )

        XCTAssertTrue(
            WorkTaskCoordinator.startedTaskIsSelected(pending, branch: "ship-it", selectedTaskId: taskId))
        XCTAssertFalse(
            WorkTaskCoordinator.startedTaskIsSelected(pending, branch: "other", selectedTaskId: taskId),
            "a create for another branch leaves the selection alone")
        XCTAssertFalse(
            WorkTaskCoordinator.startedTaskIsSelected(pending, branch: "ship-it", selectedTaskId: UUID()),
            "a create for another task leaves the selection alone")
    }

    /// A hand-made worktree started no task, so it must not clear a selection — including when
    /// nothing is selected, where two `nil`s would otherwise read as a match.
    func testStartedTaskIsSelectedIsFalseWithoutATask() {
        let pending = WorkTaskCoordinator.PendingCreate(task: nil, branch: "manual", command: nil)

        XCTAssertFalse(
            WorkTaskCoordinator.startedTaskIsSelected(pending, branch: "manual", selectedTaskId: nil))
        XCTAssertFalse(
            WorkTaskCoordinator.startedTaskIsSelected(pending, branch: "manual", selectedTaskId: UUID()))
        XCTAssertFalse(
            WorkTaskCoordinator.startedTaskIsSelected(nil, branch: "manual", selectedTaskId: nil))
    }

    // MARK: - Plan

    /// Plan runs against a backlog task, so the token resolves to the central file the task still
    /// lives in.
    func testPlanCommandResolvesTheTokenToTheCentralTaskFile() throws {
        let taskManager = WorkTaskManager(projectPath: tempRoot)
        guard let seed = taskManager.createTask(title: "Shape me") else {
            XCTFail("createTask returned nil"); return
        }
        let coordinator = makeCoordinator(taskManager)

        let resolved = coordinator.planCommand(for: seed, using: agentCommand(text: "plan {{ task_path }}"))

        let central = (taskManager.tasksDirectory as NSString)
            .appendingPathComponent("\(seed.id.uuidString).md")
        XCTAssertEqual(resolved?.text, "plan \(central)")
        XCTAssertTrue(central.hasPrefix("/"), "the substituted path is absolute")
    }

    /// The rule is `filePath(for:)`, not a second path convention: a task already linked to a live
    /// worktree resolves to that worktree's `TASK.md`.
    func testPlanCommandResolvesALinkedTaskThroughFilePath() throws {
        let taskManager = WorkTaskManager(projectPath: tempRoot)
        guard let seed = taskManager.createTask(title: "Already linked") else {
            XCTFail("createTask returned nil"); return
        }
        let branch = "already-linked"
        let worktreePath = (tempRoot as NSString).appendingPathComponent("wt-\(branch)")
        taskManager.worktreeResolver = { [(branch: branch, path: worktreePath)] }
        taskManager.updateFields(id: seed.id) { $0.worktree = branch }
        taskManager.relocateTaskToWorktree(id: seed.id, worktreePath: worktreePath)
        guard let linked = taskManager.freshTask(id: seed.id) else {
            XCTFail("task missing after relocate"); return
        }
        let coordinator = makeCoordinator(taskManager)

        let resolved = coordinator.planCommand(for: linked, using: agentCommand(text: "plan {{ task_path }}"))

        XCTAssertEqual(resolved?.text, "plan \(taskManager.filePath(for: linked))")
    }

    /// A task that no longer resolves by id has no path to name, so there is nothing to run.
    func testPlanCommandReturnsNilForAnUnresolvableTask() throws {
        let coordinator = makeCoordinator()

        let resolved = coordinator.planCommand(
            for: WorkTask(title: "Never written"),
            using: agentCommand(text: "plan {{ task_path }}")
        )

        XCTAssertNil(resolved)
    }

    /// Plan hands an agent the brief and leaves the task unlinked, in the file it was already in.
    func testPlanCommandWritesNothingToTheTask() throws {
        let taskManager = WorkTaskManager(projectPath: tempRoot)
        guard let seed = taskManager.createTask(title: "Untouched") else {
            XCTFail("createTask returned nil"); return
        }
        let path = taskManager.filePath(for: seed)
        let before = try String(contentsOfFile: path, encoding: .utf8)
        let coordinator = makeCoordinator(taskManager)

        _ = coordinator.planCommand(for: seed, using: agentCommand(text: "plan {{ task_path }}"))

        XCTAssertEqual(try String(contentsOfFile: path, encoding: .utf8), before,
                       "planning rewrites no frontmatter")
        XCTAssertNil(taskManager.freshTask(id: seed.id)?.worktree)
    }

    /// Only an agent command means anything to a plan run, so the kind alone refuses it — the task
    /// here resolves, isolating the kind as the reason.
    func testPlanCommandRefusesATerminalKindCommand() throws {
        let taskManager = WorkTaskManager(projectPath: tempRoot)
        guard let seed = taskManager.createTask(title: "Shape me") else {
            XCTFail("createTask returned nil"); return
        }
        let coordinator = makeCoordinator(taskManager)

        let resolved = coordinator.planCommand(
            for: seed, using: terminalCommand(text: "echo {{ task_path }}"))

        XCTAssertNil(resolved)
    }

    /// The other direction of the same rule: an agent command still resolves, so a future change
    /// that refuses everything cannot pass.
    func testPlanCommandAcceptsAnAgentKindCommand() throws {
        let taskManager = WorkTaskManager(projectPath: tempRoot)
        guard let seed = taskManager.createTask(title: "Shape me") else {
            XCTFail("createTask returned nil"); return
        }
        let coordinator = makeCoordinator(taskManager)

        let resolved = coordinator.planCommand(
            for: seed, using: agentCommand(text: "plan {{ task_path }}"))

        XCTAssertNotNil(resolved)
    }

    /// A plan run starts where the backlog task's file lives: the primary checkout, not whichever
    /// worktree happens to be selected.
    func testPlanWorkingDirectoryIsThePrimaryWorktree() {
        let worktrees = [
            makeWorktree(branch: "feature", path: "/repo/.worktrees/feature"),
            makeWorktree(branch: "main", path: "/repo", isMain: true)
        ]

        XCTAssertEqual(
            WorkTaskCoordinator.planWorkingDirectory(worktrees: worktrees, projectPath: "/elsewhere"),
            "/repo"
        )
    }

    /// The worktree list is empty until the first `git worktree list` returns, and a plan run in
    /// that window has to land somewhere rather than silently do nothing.
    func testPlanWorkingDirectoryFallsBackToTheProjectPath() {
        XCTAssertEqual(
            WorkTaskCoordinator.planWorkingDirectory(worktrees: [], projectPath: "/repo"),
            "/repo"
        )
        XCTAssertEqual(
            WorkTaskCoordinator.planWorkingDirectory(
                worktrees: [makeWorktree(branch: "main", path: nil, isMain: true)],
                projectPath: "/repo"
            ),
            "/repo"
        )
    }

    private func agentCommand(text: String) -> SavedCommand {
        SavedCommand(id: UUID(), name: "Plan", kind: .agent, text: text, agent: "claude", autoRun: true)
    }

    private func terminalCommand(text: String) -> SavedCommand {
        SavedCommand(id: UUID(), name: "Plan", kind: .terminal, text: text, agent: "claude", autoRun: true)
    }

    // MARK: - Start Now freshness

    /// `resolveStart` must re-resolve by id so a pre-plan UI snapshot cannot clobber post-plan disk
    /// content before relocate moves the central file into the worktree.
    func testResolveStartUsesFreshDiskContentNotStaleSnapshot() throws {
        let taskManager = WorkTaskManager(projectPath: tempRoot)
        guard let seed = taskManager.createTask(title: "Pre-plan draft") else {
            XCTFail("createTask returned nil"); return
        }
        taskManager.updateFields(id: seed.id) { $0.body = "Short draft" }

        // Whatever ran in the task terminal rewrote the central file.
        var planned = seed
        planned.title = "Post-plan title"
        planned.body = "Full planned brief."
        try planned.serialized().write(
            toFile: taskManager.filePath(for: seed),
            atomically: true,
            encoding: .utf8
        )
        taskManager.reloadFromDisk()

        let coordinator = makeCoordinator(taskManager)

        // Stale pre-plan snapshot as the UI might still hold.
        var staleSnapshot = seed
        staleSnapshot.title = "Pre-plan draft"
        staleSnapshot.body = "Short draft"

        let result = coordinator.resolveStart(staleSnapshot)
        guard case .prefill(let prefill) = result else {
            XCTFail("expected prefill, got \(result)"); return
        }
        let branch = prefill.branch
        coordinator.confirmCreate(taskId: prefill.taskId, branch: branch, command: nil)

        // Central file after bookkeeping must still carry post-plan content.
        let centralPath = (taskManager.tasksDirectory as NSString)
            .appendingPathComponent("\(seed.id.uuidString).md")
        let central = try String(contentsOfFile: centralPath, encoding: .utf8)
        let reparsed = WorkTask.parse(from: central, id: seed.id, createdAt: seed.createdAt)
        XCTAssertEqual(reparsed?.title, "Post-plan title")
        XCTAssertEqual(reparsed?.body, "Full planned brief.")
        XCTAssertEqual(reparsed?.worktree, branch)

        // Relocate into a worktree and confirm content survives.
        let worktreePath = (tempRoot as NSString).appendingPathComponent("wt-start")
        taskManager.worktreeResolver = { [(branch: branch, path: worktreePath)] }
        taskManager.relocateTaskToWorktree(id: seed.id, worktreePath: worktreePath)
        guard let relocated = taskManager.tasks.first(where: { $0.id == seed.id }) else {
            XCTFail("task missing after relocate"); return
        }
        let moved = try String(contentsOfFile: taskManager.filePath(for: relocated), encoding: .utf8)
        let movedTask = WorkTask.parse(from: moved, id: seed.id, createdAt: seed.createdAt)
        XCTAssertEqual(movedTask?.title, "Post-plan title")
        XCTAssertEqual(movedTask?.body, "Full planned brief.")
    }
}
