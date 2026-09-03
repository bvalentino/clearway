import XCTest
@testable import Clearway

/// Pins the RAII cleanup contract the Swift 6 migration substituted for six explicit teardown
/// calls: the holders must free on release, and every owner whose `deinit` was emptied must
/// still deallocate, since the cleanup now rides on that deallocation.
@MainActor
final class RAIICleanupTests: TempRootTestCase {

    override static var tempRootPrefix: String { "clearway-raii-cleanup" }

    // MARK: - Holders free on release

    func testReleasingScheduledWorkCancelsItsItem() {
        let work = DispatchWorkItem { }
        var holder: ScheduledWork? = ScheduledWork(work)
        XCTAssertFalse(work.isCancelled)

        holder = nil

        XCTAssertNil(holder)
        XCTAssertTrue(work.isCancelled, "releasing a ScheduledWork must cancel its work item")
    }

    /// The debounce contract `scheduleReload` relies on: assigning a new holder cancels the
    /// superseded item, so only the last scheduled reload runs.
    func testReplacingScheduledWorkCancelsTheSupersededItem() {
        let first = DispatchWorkItem { }
        let second = DispatchWorkItem { }
        var holder: ScheduledWork? = ScheduledWork(first)

        holder = ScheduledWork(second)

        XCTAssertTrue(first.isCancelled, "replacing a ScheduledWork must cancel the superseded item")
        XCTAssertFalse(second.isCancelled, "the current item must stay live")
        XCTAssertNotNil(holder)
    }

    /// What `closeAllSurfaces`'s `closeSurfaceObserver = nil` now depends on.
    func testReleasingNotificationObservationDeregistersItsToken() {
        let name = Notification.Name("clearway.raii.\(UUID().uuidString)")
        var fired = 0
        var observation: NotificationObservation? = NotificationObservation(
            NotificationCenter.default.addObserver(forName: name, object: nil, queue: nil) { _ in
                fired += 1
            }
        )
        NotificationCenter.default.post(name: name, object: nil)
        XCTAssertEqual(fired, 1)

        observation = nil

        XCTAssertNil(observation)
        NotificationCenter.default.post(name: name, object: nil)
        XCTAssertEqual(fired, 1, "releasing a NotificationObservation must deregister its token")
    }

    // MARK: - Owners still deallocate

    func testTerminalManagerDeallocates() {
        weak var weakManager: TerminalManager?
        autoreleasepool {
            let manager = TerminalManager()
            weakManager = manager
            XCTAssertNotNil(weakManager)
        }
        XCTAssertNil(weakManager, "TerminalManager leaked; its NotificationObservations never deregister")
    }

    func testWorkTaskCoordinatorDeallocates() {
        weak var weakCoordinator: WorkTaskCoordinator?
        autoreleasepool {
            let coordinator = WorkTaskCoordinator(
                workTaskManager: WorkTaskManager(projectPath: tempRoot),
                terminalManager: TerminalManager(),
                worktreeManager: WorktreeManager(projectPath: tempRoot)
            )
            weakCoordinator = coordinator
            XCTAssertNotNil(weakCoordinator)
        }
        XCTAssertNil(weakCoordinator, "WorkTaskCoordinator leaked; its exit observer never deregisters")
    }

    func testClaudeActivityMonitorDeallocates() {
        weak var weakMonitor: ClaudeActivityMonitor?
        autoreleasepool {
            let monitor = ClaudeActivityMonitor()
            monitor.updateWorktrees([
                makeWorktree(branch: "probe", path: (tempRoot as NSString).appendingPathComponent("wt")),
            ])
            weakMonitor = monitor
            XCTAssertNotNil(weakMonitor)
        }
        XCTAssertNil(weakMonitor, "ClaudeActivityMonitor leaked; its watcher sources are never cancelled")
    }

    func testWorkTaskManagerDeallocates() {
        weak var weakManager: WorkTaskManager?
        autoreleasepool {
            let manager = WorkTaskManager(projectPath: tempRoot)
            manager.setWatchedWorktrees([])
            weakManager = manager
        }
        XCTAssertNil(weakManager, "WorkTaskManager leaked; its pending reload is never cancelled")
    }

    func testPromptAndTodoManagersDeallocate() {
        weak var weakPrompt: PromptManager?
        weak var weakTodo: TodoManager?
        autoreleasepool {
            let prompt = PromptManager(directory: tempRoot)
            let todo = TodoManager()
            weakPrompt = prompt
            weakTodo = todo
        }
        XCTAssertNil(weakPrompt)
        XCTAssertNil(weakTodo)
    }
}
