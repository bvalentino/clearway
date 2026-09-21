import AppKit
import GhosttyKit

extension TerminalManager {
    /// Look up an existing task terminal surface (read-only).
    func existingTaskSurface(for taskId: UUID) -> Ghostty.SurfaceView? {
        taskSurfaces[taskId]
    }

    /// Whether a task's terminal has a running foreground process.
    func taskHasActiveProcess(_ taskId: UUID) -> Bool {
        taskSurfaces[taskId]?.needsConfirmQuit ?? false
    }

    /// Get or create a terminal surface for a task.
    @discardableResult
    func taskSurface(for taskId: UUID, app: ghostty_app_t, projectPath: String?) -> Ghostty.SurfaceView {
        ghosttyApp = app
        if let existing = taskSurfaces[taskId] {
            return existing
        }
        // A task terminal's working directory is the main worktree's path, and a worktree id is
        // its path, so the two are the same string.
        let surface = Ghostty.SurfaceView(app, workingDirectory: projectPath, worktreeId: projectPath)
        taskSurfaces[taskId] = surface
        if !openTaskIds.contains(taskId) {
            openTaskIds.insert(taskId)
        }
        return surface
    }

    /// Whether a task's terminal panel is visible.
    func isTaskTerminalVisible(for taskId: UUID) -> Bool {
        taskTerminalVisible[taskId] ?? false
    }

    /// The stored terminal panel height for a task, or the default.
    func taskTerminalHeight(for taskId: UUID) -> CGFloat {
        taskTerminalHeights[taskId] ?? 200
    }

    /// Store a task's terminal panel height.
    func setTaskTerminalHeight(_ height: CGFloat, for taskId: UUID) {
        guard taskTerminalHeights[taskId] != height else { return }
        taskTerminalHeights[taskId] = height
    }

    /// Toggle a task's terminal panel visibility. Creates the surface on first show.
    func toggleTaskTerminal(for taskId: UUID, app: ghostty_app_t, projectPath: String?) {
        let isVisible = taskTerminalVisible[taskId] ?? false
        if !isVisible { taskSurface(for: taskId, app: app, projectPath: projectPath) }
        taskTerminalVisible[taskId] = !isVisible
    }

    /// Close a task's terminal surface. Removes entry first to prevent auto-restart.
    func closeTaskTerminal(_ taskId: UUID) {
        guard let surface = taskSurfaces.removeValue(forKey: taskId) else { return }
        Self.retireSurface(surface.surfaceId)
        openTaskIds.remove(taskId)
        taskTerminalVisible.removeValue(forKey: taskId)
        taskTerminalHeights.removeValue(forKey: taskId)
        surface.closeSurface()
    }

    /// Claims the task's terminal for a launch that has yet to build its command, and reports
    /// whether the claim is this caller's. `false` means a launch is already in flight and this one
    /// must abandon itself. Release it with `endTaskLaunch` once the surface exists.
    func beginTaskLaunch(for taskId: UUID) -> Bool {
        taskLaunchesInFlight.insert(taskId).inserted
    }

    func endTaskLaunch(for taskId: UUID) {
        taskLaunchesInFlight.remove(taskId)
    }

    /// Open a task terminal on a fresh surface and reveal the panel, replacing any surface the
    /// task already had. A non-nil `command` runs directly, with no login shell in front of it; a
    /// nil one opens a login shell, which is what a caller that means to stage a line wants.
    @discardableResult
    func openTaskTerminal(
        for taskId: UUID,
        app: ghostty_app_t,
        projectPath: String?,
        command: String?
    ) -> Ghostty.SurfaceView {
        ghosttyApp = app
        if let old = taskSurfaces.removeValue(forKey: taskId) {
            Self.retireSurface(old.surfaceId)
            old.closeSurface()
        }
        let surface = Ghostty.SurfaceView(
            app,
            workingDirectory: projectPath,
            command: command,
            worktreeId: projectPath
        )
        taskSurfaces[taskId] = surface
        openTaskIds.insert(taskId)
        taskTerminalVisible[taskId] = true
        return surface
    }

    /// Find the task ID that owns the given surface.
    func taskId(for surface: Ghostty.SurfaceView) -> UUID? {
        taskSurfaces.first(where: { $0.value === surface })?.key
    }
}
