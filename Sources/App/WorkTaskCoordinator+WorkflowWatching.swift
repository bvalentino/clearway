import Foundation

/// `.clearway/workflow.json` live-reloading for `WorkTaskCoordinator`.
///
/// Unlike `WORKFLOW.md` (which lives at the project root), `workflow.json`
/// is nested inside a `.clearway/` subdirectory. That subdirectory may not
/// exist yet when the project is opened, so the watcher chains up to two
/// directory-creation watchers before settling on a per-file watch:
///
/// 1. If `<project>/.clearway/workflow.json` exists → watch it directly.
/// 2. Else if `<project>/.clearway/` exists → watch that directory; when
///    `workflow.json` appears, switch to per-file watching.
/// 3. Else → watch the project root; when `.clearway/` appears, restart the
///    chain (re-evaluating step 2, which then chains to step 1).
extension WorkTaskCoordinator {
    /// Start watching `.clearway/workflow.json` for the current project.
    /// Performs an initial load, then sets up the watcher chain.
    func startWatchingWorkflowJSON() {
        reloadWorkflowAutomation()
        watchWorkflowJSONFile()
    }

    var workflowJSONDirectoryPath: String {
        (workTaskManager.projectPath as NSString).appendingPathComponent(".clearway")
    }

    var workflowJSONFilePath: String {
        (workflowJSONDirectoryPath as NSString).appendingPathComponent("workflow.json")
    }

    func watchWorkflowJSONFile() {
        workflowJSONWatcherSource?.cancel()
        workflowJSONWatcherSource = nil

        let filePath = workflowJSONFilePath
        let fd = open(filePath, O_EVTONLY)
        guard fd >= 0 else {
            // File doesn't exist — fall back to watching the `.clearway/` dir
            // for the file's creation. If `.clearway/` itself is missing, that
            // helper chains up to a project-root watch.
            watchClearwayDirectoryForFileCreation()
            return
        }

        // File exists — cancel any directory watchers and watch the file directly.
        workflowJSONDirectoryWatcherSource?.cancel()
        workflowJSONDirectoryWatcherSource = nil
        workflowJSONProjectDirectoryWatcherSource?.cancel()
        workflowJSONProjectDirectoryWatcherSource = nil

        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd,
            eventMask: [.write, .delete, .rename],
            queue: .global(qos: .utility)
        )
        source.setEventHandler { [weak self] in
            let data = source.data
            let needsRewatch = data.contains(.delete) || data.contains(.rename)
            self?.scheduleWorkflowJSONReload(rewatch: needsRewatch)
        }
        source.setCancelHandler { close(fd) }
        source.resume()
        workflowJSONWatcherSource = source
    }

    /// Watches `<project>/.clearway/` for `workflow.json` creation. When the
    /// directory itself doesn't exist yet, defers to the project-root watcher
    /// to wait for `.clearway/` to appear first.
    private func watchClearwayDirectoryForFileCreation() {
        workflowJSONDirectoryWatcherSource?.cancel()
        workflowJSONDirectoryWatcherSource = nil

        let dirPath = workflowJSONDirectoryPath
        let fd = open(dirPath, O_EVTONLY)
        guard fd >= 0 else {
            // `.clearway/` doesn't exist — chain up to watching the project
            // root for its creation.
            watchProjectDirectoryForClearwayCreation()
            return
        }

        // `.clearway/` exists — drop the project-root watcher (no longer needed).
        workflowJSONProjectDirectoryWatcherSource?.cancel()
        workflowJSONProjectDirectoryWatcherSource = nil

        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd,
            eventMask: .write,
            queue: .global(qos: .utility)
        )
        source.setEventHandler { [weak self] in
            // Only schedule a reload if workflow.json actually appeared.
            // The fileExists check also filters the spurious initial .write
            // event that fires on resume — the file won't exist yet.
            guard let self, FileManager.default.fileExists(atPath: self.workflowJSONFilePath) else { return }
            self.scheduleWorkflowJSONReload(rewatch: true)
        }
        source.setCancelHandler { close(fd) }
        source.resume()
        workflowJSONDirectoryWatcherSource = source
    }

    /// Watches the project root for `.clearway/` creation. When it appears,
    /// reschedules a reload with `rewatch: true` so the watcher chain
    /// re-evaluates from the top (which then watches `.clearway/` for
    /// `workflow.json`, and so on).
    private func watchProjectDirectoryForClearwayCreation() {
        workflowJSONProjectDirectoryWatcherSource?.cancel()
        workflowJSONProjectDirectoryWatcherSource = nil

        let dirPath = workTaskManager.projectPath
        let fd = open(dirPath, O_EVTONLY)
        guard fd >= 0 else { return }

        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd,
            eventMask: .write,
            queue: .global(qos: .utility)
        )
        source.setEventHandler { [weak self] in
            // Only proceed once `.clearway/` has actually appeared. Spurious
            // initial .write events (or unrelated project-root churn) are
            // filtered by this check.
            guard let self, FileManager.default.fileExists(atPath: self.workflowJSONDirectoryPath) else { return }
            self.scheduleWorkflowJSONReload(rewatch: true)
        }
        source.setCancelHandler { close(fd) }
        source.resume()
        workflowJSONProjectDirectoryWatcherSource = source
    }

    private nonisolated func scheduleWorkflowJSONReload(rewatch: Bool = false) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.pendingWorkflowJSONReload?.cancel()
            let work = DispatchWorkItem { [weak self] in
                guard let self else { return }
                self.reloadWorkflowAutomation()
                if rewatch {
                    self.watchWorkflowJSONFile()
                }
            }
            self.pendingWorkflowJSONReload = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: work)
        }
    }

    func reloadWorkflowAutomation() {
        setWorkflowAutomation(WorkflowAutomation.load(projectPath: workTaskManager.projectPath))
    }
}
