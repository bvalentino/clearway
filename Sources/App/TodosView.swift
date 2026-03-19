import AppKit
import SwiftUI

/// Row view for a single user-created todo with toggle, edit, and delete.
struct TodoRow: View {
    let todo: Todo
    var isEditing: Bool
    var isSelected: Bool
    var canSend: Bool
    var onSelect: () -> Void
    var onSend: () -> Void
    var onEditStart: () -> Void
    var onEditCommit: (String) -> Void
    var onEditCancel: () -> Void
    var onDelete: () -> Void
    @EnvironmentObject private var todoManager: TodoManager
    @State private var editingSubject = ""
    @State private var lastClickTime: Date = .distantPast
    @FocusState private var isFocused: Bool

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: todo.status.symbol)
                .font(.system(size: 16))
                .foregroundStyle(todo.status.color)
                .frame(width: 20)
                .onTapGesture {
                    todoManager.cycleStatus(todo)
                }

            if isEditing {
                TextField("New todo", text: $editingSubject, axis: .vertical)
                    .textFieldStyle(.plain)
                    .fixedSize(horizontal: false, vertical: true)
                    .focused($isFocused)
                    .onSubmit { onEditCommit(editingSubject) }
                    .onExitCommand { onEditCancel() }
            } else {
                Text(todo.subject)
                    .font(.body)
                    .foregroundStyle(todo.status == .completed ? .secondary : .primary)
                    .strikethrough(todo.status == .completed)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                    .onTapGesture {
                        let now = Date()
                        if now.timeIntervalSince(lastClickTime) < NSEvent.doubleClickInterval {
                            editingSubject = todo.subject
                            onEditStart()
                        } else {
                            onSelect()
                        }
                        lastClickTime = now
                    }

                if todo.status == .pending {
                    SendToTerminalButton(action: onSend, disabled: !canSend)
                }
            }
        }
        .padding(.vertical, 4)
        .padding(.horizontal, 8)
        .background(isSelected ? Color.primary.opacity(0.06) : .clear, in: RoundedRectangle(cornerRadius: 6))
        .contextMenu {
            ForEach(Todo.Status.allCases, id: \.self) { status in
                Button {
                    todoManager.setStatus(todo, to: status)
                } label: {
                    Label(status.label, systemImage: status.symbol)
                }
                .disabled(todo.status == status)
            }
            Divider()
            if todo.status == .pending {
                Button { onSend() } label: {
                    Label("Send to Terminal", systemImage: "play.fill")
                }
                .disabled(!canSend)
            }
            Divider()
            Button(role: .destructive) { onDelete() } label: {
                Label("Delete", systemImage: "trash")
            }
        }
        .onChange(of: isEditing) { editing in
            if editing {
                editingSubject = todo.subject
                DispatchQueue.main.async { isFocused = true }
            }
        }
        .onAppear {
            if isEditing {
                editingSubject = todo.subject
                DispatchQueue.main.async { isFocused = true }
            }
        }
    }
}

/// Inline text field for creating a new todo (not yet persisted).
struct NewTodoRow: View {
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

            TextField("New todo", text: $subject, axis: .vertical)
                .textFieldStyle(.plain)
                .fixedSize(horizontal: false, vertical: true)
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
