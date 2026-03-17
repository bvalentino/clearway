import SwiftUI

/// Combines user tasks and Claude Code tasks into a single panel.
struct TasksPanelView: View {
    @EnvironmentObject private var claudeTaskManager: ClaudeTaskManager
    @EnvironmentObject private var userTaskManager: UserTaskManager
    @State private var editingTaskId: Int?
    @State private var isCreatingNew = false
    @State private var newTaskGeneration = 0
    @State private var selectedTask: TaskSelection?
    @State private var taskPendingDeletion: UserTask?
    @FocusState private var isListFocused: Bool

    enum TaskSelection: Hashable {
        case user(Int)
        case claude(sessionId: String, taskId: String)
    }

    private var isEmpty: Bool {
        userTaskManager.tasks.isEmpty && !isCreatingNew && claudeTaskManager.sessions.isEmpty
    }

    var body: some View {
        VStack(spacing: 0) {
            if isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "checklist")
                        .font(.system(size: 28))
                        .foregroundStyle(.tertiary)
                    Text("No tasks")
                        .foregroundStyle(.secondary)
                        .font(.callout)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 16) {
                        VStack(alignment: .leading, spacing: 4) {
                            ForEach(userTaskManager.incompleteTasks) { task in
                                userTaskRow(task)
                            }

                            if isCreatingNew {
                                NewTaskRow(
                                    onCommit: { subject in
                                        commitNewTask(subject: subject)
                                    },
                                    onCancel: {
                                        isCreatingNew = false
                                    }
                                )
                                .id(newTaskGeneration)
                            }

                            ForEach(userTaskManager.completedTasks) { task in
                                userTaskRow(task)
                            }
                        }

                        ForEach(claudeTaskManager.sessions) { session in
                            ClaudeSessionSection(
                                session: session,
                                selectedTaskId: selectedClaudeTaskId(for: session.id),
                                onSelect: { task in
                                    selectTask(.claude(sessionId: session.id, taskId: task.id))
                                }
                            )
                        }
                    }
                    .padding()
                }
                .focusable()
                .focused($isListFocused)
                .onCopyCommand {
                    guard let text = selectedTaskSubject else { return [] }
                    return [NSItemProvider(object: text as NSString)]
                }
            }
        }
        .overlay(alignment: .bottomTrailing) {
            createButton
        }
        .confirmationDialog(
            "Delete \"\(taskPendingDeletion?.subject ?? "")\"?",
            isPresented: Binding(
                get: { taskPendingDeletion != nil },
                set: { if !$0 { taskPendingDeletion = nil } }
            )
        ) {
            Button("Delete", role: .destructive) {
                if let task = taskPendingDeletion {
                    userTaskManager.deleteTask(task)
                    if selectedTask == .user(task.id) { selectedTask = nil }
                }
                taskPendingDeletion = nil
            }
        }
    }

    private var selectedTaskSubject: String? {
        switch selectedTask {
        case .user(let id):
            return userTaskManager.tasks.first { $0.id == id }?.subject
        case .claude(let sessionId, let taskId):
            return claudeTaskManager.sessions
                .first { $0.id == sessionId }?
                .tasks.first { $0.id == taskId }?
                .subject
        case nil:
            return nil
        }
    }

    private func selectedClaudeTaskId(for sessionId: String) -> String? {
        if case .claude(sessionId, let taskId) = selectedTask { return taskId }
        return nil
    }

    private func selectTask(_ selection: TaskSelection) {
        selectedTask = selection
        isCreatingNew = false
        editingTaskId = nil
        DispatchQueue.main.async { isListFocused = true }
    }

    private func userTaskRow(_ task: UserTask) -> some View {
        UserTaskRow(
            task: task,
            isEditing: editingTaskId == task.id,
            isSelected: selectedTask == .user(task.id),
            onSelect: { selectTask(.user(task.id)) },
            onEditStart: { editingTaskId = task.id },
            onEditCommit: { subject in
                saveEdit(task: task, subject: subject)
            },
            onEditCancel: { editingTaskId = nil },
            onDelete: { taskPendingDeletion = task }
        )
    }

    private func startCreating() {
        editingTaskId = nil
        newTaskGeneration += 1
        isCreatingNew = true
    }

    private func commitNewTask(subject: String) {
        isCreatingNew = false
        userTaskManager.createTask(subject: subject)
        startCreating()
    }

    private func saveEdit(task: UserTask, subject: String) {
        let trimmed = subject.trimmingCharacters(in: .whitespacesAndNewlines)
        editingTaskId = nil
        if trimmed.isEmpty {
            taskPendingDeletion = task
        } else if trimmed != task.subject {
            userTaskManager.updateTaskSubject(task, to: trimmed)
        }
        startCreating()
    }

    private var createButton: some View {
        Button {
            startCreating()
        } label: {
            Image(systemName: "plus")
                .font(.system(size: 16, weight: .medium))
                .foregroundStyle(.primary)
                .frame(width: 36, height: 36)
                .background(.thinMaterial, in: Circle())
                .shadow(color: .black.opacity(0.15), radius: 4, y: 2)
        }
        .buttonStyle(.plain)
        .padding(12)
    }
}

/// A group of Claude Code tasks from a single session.
private struct ClaudeSessionSection: View {
    let session: ClaudeSession
    var selectedTaskId: String?
    var onSelect: (ClaudeTask) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Claude")
                .font(.caption)
                .fontWeight(.medium)
                .foregroundStyle(.white)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(.orange, in: Capsule())

            ForEach(session.tasks) { task in
                ClaudeTaskRow(
                    task: task,
                    isSelected: selectedTaskId == task.id,
                    onSelect: { onSelect(task) }
                )
            }
        }
    }
}

/// Displays a single Claude Code task.
private struct ClaudeTaskRow: View {
    let task: ClaudeTask
    var isSelected: Bool
    var onSelect: () -> Void

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: task.status.symbol)
                .font(.system(size: 16))
                .foregroundStyle(task.status.color)
                .frame(width: 20)

            Text(task.subject)
                .font(.body)
                .foregroundStyle(task.status == .completed ? .secondary : .primary)
                .strikethrough(task.status == .completed)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.vertical, 4)
        .padding(.horizontal, 8)
        .background(isSelected ? Color.primary.opacity(0.06) : .clear, in: RoundedRectangle(cornerRadius: 6))
        .contentShape(Rectangle())
        .onTapGesture { onSelect() }
    }
}
