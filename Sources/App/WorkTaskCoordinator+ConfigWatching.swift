import Foundation

/// PLANNING.md live-reloading for `WorkTaskCoordinator`. When the file exists
/// it's watched directly; when it doesn't, the project directory is watched
/// for its creation, then we switch to per-file watching. Workflow automation
/// (`.clearway/workflow.json`) is set up alongside in `startWatching` and
/// implemented in `WorkTaskCoordinator+WorkflowWatching.swift`.
extension WorkTaskCoordinator {
    /// Start watching PLANNING.md and `.clearway/workflow.json` for the
    /// current project.
    func startWatching() {
        guard !isWatching else { return }
        isWatching = true
        reloadPlanningConfig()
        watchPlanningFile()
        startWatchingWorkflowJSON()
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
