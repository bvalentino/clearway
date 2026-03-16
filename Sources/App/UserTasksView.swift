import AppKit
import SwiftUI

/// Row view for a single user-created task with toggle, edit, and delete.
struct UserTaskRow: View {
    let task: UserTask
    var isEditing: Bool
    var isSelected: Bool
    var onSelect: () -> Void
    var onEditStart: () -> Void
    var onEditCommit: (String) -> Void
    var onEditCancel: () -> Void
    var onDelete: () -> Void
    @EnvironmentObject private var userTaskManager: UserTaskManager
    @State private var editingSubject = ""
    @State private var lastClickTime: Date = .distantPast
    @FocusState private var isFocused: Bool

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: task.status.symbol)
                .font(.system(size: 16))
                .foregroundStyle(task.status.color)
                .frame(width: 20)
                .onTapGesture {
                    userTaskManager.cycleStatus(task)
                }

            if isEditing {
                TextField("New task", text: $editingSubject)
                    .textFieldStyle(.plain)
                    .focused($isFocused)
                    .onSubmit { onEditCommit(editingSubject) }
                    .onExitCommand { onEditCancel() }
            } else {
                Text(task.subject)
                    .font(.body)
                    .foregroundStyle(task.status == .completed ? .secondary : .primary)
                    .strikethrough(task.status == .completed)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                    .onTapGesture {
                        let now = Date()
                        if now.timeIntervalSince(lastClickTime) < NSEvent.doubleClickInterval {
                            editingSubject = task.subject
                            onEditStart()
                        } else {
                            onSelect()
                        }
                        lastClickTime = now
                    }
            }
        }
        .padding(.vertical, 4)
        .padding(.horizontal, 8)
        .background(isSelected ? Color.primary.opacity(0.06) : .clear, in: RoundedRectangle(cornerRadius: 6))
        .contextMenu {
            ForEach(UserTask.Status.allCases, id: \.self) { status in
                Button {
                    userTaskManager.setStatus(task, to: status)
                } label: {
                    Label(status.label, systemImage: status.symbol)
                }
                .disabled(task.status == status)
            }
            Divider()
            Button(role: .destructive) { onDelete() } label: {
                Label("Delete", systemImage: "trash")
            }
        }
        .onChange(of: isEditing) { editing in
            if editing {
                editingSubject = task.subject
                DispatchQueue.main.async { isFocused = true }
            }
        }
        .onAppear {
            if isEditing {
                editingSubject = task.subject
                DispatchQueue.main.async { isFocused = true }
            }
        }
    }
}

/// Inline text field for creating a new task (not yet persisted).
struct NewTaskRow: View {
    var onCommit: (String) -> Void
    var onCancel: () -> Void
    @State private var subject = ""
    @FocusState private var isFocused: Bool

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: "circle")
                .font(.system(size: 16))
                .foregroundStyle(.secondary)
                .frame(width: 20)

            TextField("New task", text: $subject)
                .textFieldStyle(.plain)
                .focused($isFocused)
                .onSubmit { onCommit(subject) }
                .onExitCommand { onCancel() }
        }
        .padding(.vertical, 4)
        .padding(.horizontal, 8)
        .onAppear {
            DispatchQueue.main.async { isFocused = true }
        }
    }
}
