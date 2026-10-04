import XCTest
@testable import Clearway

final class TaskFilesTests: TempRootTestCase {

    private var tasksDirectory: String { TaskFiles.tasksDirectory(inProject: tempRoot) }

    private func writeFile(_ content: String, atPath path: String, created: Date? = nil) throws {
        let fm = FileManager.default
        try fm.createDirectory(atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        XCTAssertTrue(fm.createFile(atPath: path, contents: Data(content.utf8)))
        if let created {
            try fm.setAttributes([.creationDate: created], ofItemAtPath: path)
        }
    }

    private func makeWorktree(_ name: String) -> String {
        (tempRoot as NSString).appendingPathComponent(name)
    }

    func testWorktreeCopyWinsOverCentralFileWithSameId() throws {
        let id = UUID()
        let central = TaskFiles.centralPath(for: id, tasksDirectory: tasksDirectory)
        try writeFile(WorkTask(id: id, title: "Central").serialized(), atPath: central)
        let worktree = makeWorktree("feature")
        let taskMd = TaskFiles.taskMarkdownPath(inWorktree: worktree)
        try writeFile(WorkTask(id: id, title: "Worktree", worktree: "feature").serialized(), atPath: taskMd)

        let pool = TaskFiles.loadPool(tasksDirectory: tasksDirectory, worktreePaths: [worktree]).tasks

        XCTAssertEqual(pool.count, 1)
        XCTAssertEqual(pool.first?.task.title, "Worktree")
        XCTAssertEqual(pool.first?.path, taskMd)
    }

    func testTaskMarkdownWithoutFrontmatterIdIsSkipped() throws {
        let worktree = makeWorktree("feature")
        try writeFile("---\ntitle: No id\n---", atPath: TaskFiles.taskMarkdownPath(inWorktree: worktree))

        let taskMd = TaskFiles.taskMarkdownPath(inWorktree: worktree)

        let pool = TaskFiles.loadPool(tasksDirectory: tasksDirectory, worktreePaths: [worktree])

        XCTAssertEqual(pool.tasks, [])
        XCTAssertEqual(pool.skipped, [TaskFiles.SkippedFile(path: taskMd, reason: .noFrontmatterID)])
    }

    func testPoolIsNewestFirst() throws {
        let older = WorkTask(title: "Older")
        let newer = WorkTask(title: "Newer")
        let worktreeTask = WorkTask(title: "Middle", worktree: "feature")
        let worktree = makeWorktree("feature")
        let now = Date()
        try writeFile(older.serialized(), atPath: TaskFiles.centralPath(for: older.id, tasksDirectory: tasksDirectory),
                      created: now.addingTimeInterval(-300))
        try writeFile(newer.serialized(), atPath: TaskFiles.centralPath(for: newer.id, tasksDirectory: tasksDirectory),
                      created: now.addingTimeInterval(-100))
        try writeFile(worktreeTask.serialized(), atPath: TaskFiles.taskMarkdownPath(inWorktree: worktree),
                      created: now.addingTimeInterval(-200))

        let pool = TaskFiles.loadPool(tasksDirectory: tasksDirectory, worktreePaths: [worktree]).tasks

        XCTAssertEqual(pool.map(\.task.title), ["Newer", "Middle", "Older"])
    }

    func testLegacyCentralFileWithoutIdLoadsUnderFilenameUUID() throws {
        let id = UUID()
        let path = TaskFiles.centralPath(for: id, tasksDirectory: tasksDirectory)
        try writeFile("---\ntitle: Legacy\n---", atPath: path)

        let pool = TaskFiles.loadPool(tasksDirectory: tasksDirectory, worktreePaths: []).tasks

        XCTAssertEqual(pool.map(\.task.id), [id])
        XCTAssertEqual(pool.first?.task.title, "Legacy")
        XCTAssertEqual(pool.first?.path, path)
    }

    func testUnreadableAndUnparseableFilesAreReportedAlongsideValidTasks() throws {
        let valid = WorkTask(title: "Valid")
        try writeFile(valid.serialized(), atPath: TaskFiles.centralPath(for: valid.id, tasksDirectory: tasksDirectory))
        let unreadable = TaskFiles.centralPath(for: UUID(), tasksDirectory: tasksDirectory)
        try writeFile(WorkTask(title: "Locked").serialized(), atPath: unreadable)
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: unreadable)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: unreadable) }
        let noFrontmatter = TaskFiles.centralPath(for: UUID(), tasksDirectory: tasksDirectory)
        try writeFile("Just a body", atPath: noFrontmatter)
        let worktree = makeWorktree("feature")
        let idless = TaskFiles.taskMarkdownPath(inWorktree: worktree)
        try writeFile("---\ntitle: No id\n---", atPath: idless)

        let pool = TaskFiles.loadPool(tasksDirectory: tasksDirectory, worktreePaths: [worktree])

        XCTAssertEqual(pool.tasks.map(\.task.id), [valid.id])
        let expected = [
            TaskFiles.SkippedFile(path: unreadable, reason: .unreadable),
            TaskFiles.SkippedFile(path: noFrontmatter, reason: .unparseable),
            TaskFiles.SkippedFile(path: idless, reason: .noFrontmatterID),
        ]
        XCTAssertEqual(pool.skipped, expected.sorted { $0.path < $1.path })
    }

    func testUnlistableTasksDirectoryIsReported() throws {
        let worktreeTask = WorkTask(title: "Worktree", worktree: "feature")
        let worktree = makeWorktree("feature")
        try writeFile(worktreeTask.serialized(), atPath: TaskFiles.taskMarkdownPath(inWorktree: worktree))
        try FileManager.default.createDirectory(atPath: tasksDirectory, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: tasksDirectory)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: tasksDirectory) }

        let pool = TaskFiles.loadPool(tasksDirectory: tasksDirectory, worktreePaths: [worktree])

        XCTAssertEqual(pool.tasks.map(\.task.id), [worktreeTask.id])
        XCTAssertEqual(pool.skipped, [TaskFiles.SkippedFile(path: tasksDirectory, reason: .unlistable)])
    }

    func testMissingFilesAndNonTaskNamesAreNotReported() throws {
        try writeFile("not a task", atPath: (tasksDirectory as NSString).appendingPathComponent("notes.md"))
        let missingWorktree = makeWorktree("no-task")

        XCTAssertEqual(TaskFiles.loadPool(tasksDirectory: tasksDirectory, worktreePaths: [missingWorktree]), TaskFiles.LoadedPool(tasks: [], skipped: []))
        let missingDirectory = (tempRoot as NSString).appendingPathComponent("absent/.clearway/tasks")
        XCTAssertEqual(TaskFiles.loadPool(tasksDirectory: missingDirectory, worktreePaths: []), TaskFiles.LoadedPool(tasks: [], skipped: []))
    }

    func testWriteCreatesPrivateDirectoryAndFile() throws {
        let task = WorkTask(title: "Written", body: "Body")
        let path = TaskFiles.centralPath(for: task.id, tasksDirectory: tasksDirectory)

        try TaskFiles.write(task, toPath: path)

        let fm = FileManager.default
        let directoryMode = try fm.attributesOfItem(atPath: tasksDirectory)[.posixPermissions] as? NSNumber
        let fileMode = try fm.attributesOfItem(atPath: path)[.posixPermissions] as? NSNumber
        XCTAssertEqual(directoryMode?.intValue, 0o700)
        XCTAssertEqual(fileMode?.intValue, 0o600)
        XCTAssertEqual(try String(contentsOfFile: path, encoding: .utf8), task.serialized())
    }
}
