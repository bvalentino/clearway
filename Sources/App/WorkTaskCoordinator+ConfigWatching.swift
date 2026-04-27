import Foundation

/// WORKFLOW.md and PLANNING.md live-reloading for `WorkTaskCoordinator`.
/// When the file exists it's watched directly; when it doesn't, the project
/// directory is watched for its creation, then we switch to per-file watching.
extension WorkTaskCoordinator {
    /// Start watching WORKFLOW.md, PLANNING.md, and `.clearway/workflow.json`
    /// for the current project. Phase 1 of the workflow.json migration: the
    /// JSON watcher coexists with the legacy WORKFLOW.md watcher so the two
    /// systems can run side-by-side until Phase 4 deletes the legacy code.
    func startWatching() {
        guard !isWatching else { return }
        isWatching = true
        reloadWorkflowConfig()
        watchWorkflowFile()
        reloadPlanningConfig()
        watchPlanningFile()
        startWatchingWorkflowJSON()
    }

    // MARK: - WORKFLOW.md

    var workflowFilePath: String {
        (workTaskManager.projectPath as NSString).appendingPathComponent("WORKFLOW.md")
    }

    func watchWorkflowFile() {
        watcherSource?.cancel()
        watcherSource = nil

        let filePath = workflowFilePath
        let fd = open(filePath, O_EVTONLY)
        guard fd >= 0 else {
            // File doesn't exist — watch the parent directory for its creation.
            watchDirectoryForFileCreation()
            return
        }

        // File exists — cancel any directory watcher and watch the file directly.
        directoryWatcherSource?.cancel()
        directoryWatcherSource = nil

        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd,
            eventMask: [.write, .delete, .rename],
            queue: .global(qos: .utility)
        )
        source.setEventHandler { [weak self] in
            let data = source.data
            let needsRewatch = data.contains(.delete) || data.contains(.rename)
            self?.scheduleReload(rewatch: needsRewatch)
        }
        source.setCancelHandler { close(fd) }
        source.resume()
        watcherSource = source
    }

    /// Watches the project directory for entry changes (file creation/deletion).
    /// When WORKFLOW.md appears, switches to per-file watching.
    private func watchDirectoryForFileCreation() {
        directoryWatcherSource?.cancel()
        directoryWatcherSource = nil

        let dirPath = workTaskManager.projectPath
        let fd = open(dirPath, O_EVTONLY)
        guard fd >= 0 else { return }

        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd,
            eventMask: .write,
            queue: .global(qos: .utility)
        )
        source.setEventHandler { [weak self] in
            // Only schedule a reload if WORKFLOW.md actually appeared.
            // The fileExists check also filters the spurious initial .write
            // event that fires on resume — the file won't exist yet.
            guard let self, FileManager.default.fileExists(atPath: self.workflowFilePath) else { return }
            self.scheduleReload(rewatch: true)
        }
        source.setCancelHandler { close(fd) }
        source.resume()
        directoryWatcherSource = source
    }

    private nonisolated func scheduleReload(rewatch: Bool = false) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.pendingReload?.cancel()
            let work = DispatchWorkItem { [weak self] in
                guard let self else { return }
                self.reloadWorkflowConfig()
                if rewatch {
                    self.watchWorkflowFile()
                }
            }
            self.pendingReload = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: work)
        }
    }

    func reloadWorkflowConfig() {
        guard FileManager.default.fileExists(atPath: workflowFilePath) else {
            setWorkflowConfig(nil)
            return
        }
        if let config = WorkflowConfig.load(projectPath: workTaskManager.projectPath) {
            setWorkflowConfig(config)
        }
        // File exists but parse failed — keep last-known-good config
    }

    // MARK: - PLANNING.md

    var planningFilePath: String {
        (workTaskManager.projectPath as NSString).appendingPathComponent("PLANNING.md")
    }

    func watchPlanningFile() {
        planningWatcherSource?.cancel()
        planningWatcherSource = nil

        let filePath = planningFilePath
        let fd = open(filePath, O_EVTONLY)
        guard fd >= 0 else {
            watchDirectoryForPlanningFileCreation()
            return
        }

        planningDirectoryWatcherSource?.cancel()
        planningDirectoryWatcherSource = nil

        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd,
            eventMask: [.write, .delete, .rename],
            queue: .global(qos: .utility)
        )
        source.setEventHandler { [weak self] in
            let data = source.data
            let needsRewatch = data.contains(.delete) || data.contains(.rename)
            self?.schedulePlanningReload(rewatch: needsRewatch)
        }
        source.setCancelHandler { close(fd) }
        source.resume()
        planningWatcherSource = source
    }

    private func watchDirectoryForPlanningFileCreation() {
        planningDirectoryWatcherSource?.cancel()
        planningDirectoryWatcherSource = nil

        let dirPath = workTaskManager.projectPath
        let fd = open(dirPath, O_EVTONLY)
        guard fd >= 0 else { return }

        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd,
            eventMask: .write,
            queue: .global(qos: .utility)
        )
        source.setEventHandler { [weak self] in
            guard let self, FileManager.default.fileExists(atPath: self.planningFilePath) else { return }
            self.schedulePlanningReload(rewatch: true)
        }
        source.setCancelHandler { close(fd) }
        source.resume()
        planningDirectoryWatcherSource = source
    }

    private nonisolated func schedulePlanningReload(rewatch: Bool = false) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.pendingPlanningReload?.cancel()
            let work = DispatchWorkItem { [weak self] in
                guard let self else { return }
                self.reloadPlanningConfig()
                if rewatch {
                    self.watchPlanningFile()
                }
            }
            self.pendingPlanningReload = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: work)
        }
    }

    func reloadPlanningConfig() {
        guard FileManager.default.fileExists(atPath: planningFilePath) else {
            setPlanningConfig(nil)
            return
        }
        if let config = PlanningConfig.load(projectPath: workTaskManager.projectPath, fileName: "PLANNING.md") {
            setPlanningConfig(config)
        }
    }
}
