import SwiftUI

/// Row view for a single user-created task with toggle, edit, and delete.
struct UserTaskRow: View {
    let task: UserTask
    @EnvironmentObject private var userTaskManager: UserTaskManager
    @State private var isEditing = false
    @State private var editingSubject = ""
    @State private var isHovering = false

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: task.statusSymbol)
                .font(.system(size: 16))
                .foregroundStyle(task.isCompleted ? .green : .secondary)
                .frame(width: 20)
                .onTapGesture {
                    userTaskManager.toggleComplete(task)
                }

            if isEditing {
                TextField("Task", text: $editingSubject)
                    .textFieldStyle(.plain)
                    .onSubmit {
                        userTaskManager.updateTaskSubject(task, to: editingSubject)
                        isEditing = false
                    }
                    .onExitCommand {
                        isEditing = false
                    }
            } else {
                Text(task.subject)
                    .font(.body)
                    .foregroundStyle(task.isCompleted ? .secondary : .primary)
                    .strikethrough(task.isCompleted)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                    .onTapGesture(count: 2) {
                        editingSubject = task.subject
                        isEditing = true
                    }
            }

            if isHovering && !isEditing {
                Button {
                    userTaskManager.deleteTask(task)
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.vertical, 4)
        .onHover { isHovering = $0 }
    }
}
