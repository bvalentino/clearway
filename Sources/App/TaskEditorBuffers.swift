import Foundation

/// Local editor buffers shared by `TaskDetailView` and `WorkTaskWindow`.
struct TaskEditorBufferState {
    var title: String = ""
    var bodyText: String = ""
    var editorText: String = ""
    var frontmatterError: Bool = false
    var reloadingCount: Int = 0
}

/// Shared local-buffer policy for task editors.
///
/// Callers adopt pool content only when no autosave is pending (`pendingSave == nil`), so
/// in-flight local keystrokes are not clobbered by our own write echoing through the pool.
/// Late autosaves still compare-and-swap against disk so they cannot ghost-clobber an
/// external/agent rewrite.
enum TaskEditorBuffers {

    /// Adopt pool content into local buffers. Caller must only invoke when no autosave is
    /// pending. Bumps `reloadingCount` for each buffer that changes so the matching
    /// `onChange` does not schedule a save of the discarded content.
    static func adoptFromPool(
        _ task: WorkTask,
        state: inout TaskEditorBufferState,
        showFrontmatter: Bool
    ) {
        if task.title != state.title {
            state.reloadingCount += 1
            state.title = task.title
        }
        if task.body != state.bodyText {
            state.reloadingCount += 1
            state.bodyText = task.body
        }
        if showFrontmatter {
            let newSer = task.serialized()
            if newSer != state.editorText {
                state.reloadingCount += 1
                state.editorText = newSer
                state.frontmatterError = false
            }
        }
    }

    /// Whether local buffers differ from the pool task.
    static func isDirty(
        task: WorkTask,
        state: TaskEditorBufferState,
        showFrontmatter: Bool
    ) -> Bool {
        if showFrontmatter {
            return state.editorText != task.serialized()
        }
        return state.title != task.title || state.bodyText != task.body
    }

    /// Returns false when a buffer change was caused by adopt/reload and must not autosave.
    static func shouldAutosave(reloadingCount: inout Int) -> Bool {
        if reloadingCount > 0 {
            reloadingCount -= 1
            return false
        }
        return true
    }

    /// Enter or leave frontmatter mode. Returns false when leaving fails (invalid frontmatter).
    @discardableResult
    static func setShowFrontmatter(
        _ show: Bool,
        task: WorkTask?,
        taskId: UUID,
        state: inout TaskEditorBufferState
    ) -> Bool {
        if show {
            if var updated = task {
                updated.title = state.title
                updated.body = state.bodyText
                state.editorText = updated.serialized()
            }
            state.frontmatterError = false
            return true
        }
        // YAML.bodyText falls back to the full document when frontmatter delimiters are
        // malformed, so a bad buffer would turn into body text and get committed by the
        // body-only autosave. Keep the error raised instead; save blocks until fixed.
        let createdAt = task?.createdAt ?? Date()
        guard WorkTask.parse(from: state.editorText, id: taskId, createdAt: createdAt) != nil else {
            state.frontmatterError = true
            return false
        }
        if let parsed = WorkTask.parseTitle(from: state.editorText) {
            state.title = parsed
        }
        state.bodyText = YAML.bodyText(in: state.editorText)
        state.frontmatterError = false
        return true
    }

    /// Persist local buffers via the manager's re-base-by-id writers.
    ///
    /// Compare-and-swap on editor-owned fields: `existing` is the pool snapshot the dirty
    /// check used. If disk title/body have already moved (agent/external rewrite) relative
    /// to that base, abort the write and adopt disk into local buffers so a late autosave
    /// cannot stamp pre-agent content onto a fresher document.
    @MainActor
    static func save(
        taskId: UUID,
        existing: WorkTask,
        state: inout TaskEditorBufferState,
        showFrontmatter: Bool,
        manager: WorkTaskManager
    ) {
        if showFrontmatter {
            guard state.editorText != existing.serialized() else { return }
            guard let disk = manager.freshTask(id: taskId) else { return }
            if disk.title != existing.title || disk.body != existing.body {
                adoptFromPool(disk, state: &state, showFrontmatter: true)
                return
            }
            let success = manager.applyEditorBuffer(state.editorText, expectedId: taskId)
            if success {
                state.frontmatterError = false
                if let updated = manager.tasks.first(where: { $0.id == taskId }) {
                    let newSerialized = updated.serialized()
                    if newSerialized != state.editorText {
                        state.reloadingCount += 1
                        state.editorText = newSerialized
                    }
                }
            } else {
                state.frontmatterError = true
            }
        } else {
            // Honor the "changes won't save until fixed" banner: if the last known
            // buffer had invalid frontmatter, a body-only write would silently clear
            // the error and commit state the user was told wouldn't save.
            guard !state.frontmatterError else { return }
            guard state.title != existing.title || state.bodyText != existing.body else { return }
            guard let disk = manager.freshTask(id: taskId) else { return }
            if disk.title != existing.title || disk.body != existing.body {
                adoptFromPool(disk, state: &state, showFrontmatter: false)
                return
            }
            manager.updateFields(id: taskId) {
                $0.title = state.title
                $0.body = state.bodyText
            }
        }
    }
}
