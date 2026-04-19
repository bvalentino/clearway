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
        let surface = Ghostty.SurfaceView(app, workingDirectory: projectPath)
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
        openTaskIds.remove(taskId)
        taskTerminalVisible.removeValue(forKey: taskId)
        taskTerminalHeights.removeValue(forKey: taskId)
        surface.closeSurface()
    }

    /// Open a task terminal that runs the given command directly (no login shell).
    /// Replaces any existing task surface for the same task.
    func openTaskTerminalWithCommand(for taskId: UUID, app: ghostty_app_t, projectPath: String?, command: String) {
        ghosttyApp = app
        // Close existing surface if any
        if let old = taskSurfaces.removeValue(forKey: taskId) {
            old.closeSurface()
        }
        let surface = Ghostty.SurfaceView(app, workingDirectory: projectPath, command: command)
        taskSurfaces[taskId] = surface
        openTaskIds.insert(taskId)
        taskTerminalVisible[taskId] = true
    }

    /// Find the task ID that owns the given surface.
    func taskId(for surface: Ghostty.SurfaceView) -> UUID? {
        taskSurfaces.first(where: { $0.value === surface })?.key
    }
}
