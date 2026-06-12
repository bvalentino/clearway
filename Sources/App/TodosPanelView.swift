import SwiftUI

/// Inline play button that sends a todo to the active terminal.
struct SendToTerminalButton: View {
    var action: () -> Void
    var disabled: Bool = false
    var help: String = "Send to Terminal"

    var body: some View {
        Button { action() } label: {
            Image(systemName: "play.fill")
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
                .frame(width: 24, height: 24)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
        .disabled(disabled)
        .padding(.trailing, -10)
        .pointerCursorOnHover()
    }
}

/// Displays the user's todos for the selected worktree.
struct TodosPanelView: View {
    @EnvironmentObject private var todoManager: TodoManager
    @EnvironmentObject private var terminalManager: TerminalManager
    @State private var editingTodoId: Int?
    @State private var isCreatingNew = false
    @State private var newTodoGeneration = 0
    @State private var selectedTodoId: Int?
    @State private var todoPendingDeletion: Todo?

    private var isEmpty: Bool {
        todoManager.todos.isEmpty && !isCreatingNew
    }

    private var canSend: Bool {
        terminalManager.canSendToActiveMainTab
    }

    var body: some View {
        VStack(spacing: 0) {
            if isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "checklist")
                        .font(.system(size: 28))
                        .foregroundStyle(.tertiary)
                    Text("No todos")
                        .foregroundStyle(.secondary)
                        .font(.callout)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 16) {
                        VStack(alignment: .leading, spacing: 4) {
                            ForEach(todoManager.incompleteTodos) { todo in
                                todoRow(todo)
                            }

                            if isCreatingNew {
                                NewTodoRow(
                                    onCommit: { subject in
                                        commitNewTodo(subject: subject)
                                    },
                                    onCancel: {
                                        isCreatingNew = false
                                    }
                                )
                                .id(newTodoGeneration)
                            }

                            ForEach(todoManager.completedTodos) { todo in
                                todoRow(todo)
                            }
                        }
                    }
                    .padding()
                }
            }
        }
        .overlay(alignment: .bottomTrailing) {
            createButton
        }
        .confirmationDialog(
            "Delete \"\(todoPendingDeletion?.subject ?? "")\"?",
            isPresented: Binding(
                get: { todoPendingDeletion != nil },
                set: { if !$0 { todoPendingDeletion = nil } }
            )
        ) {
            Button("Delete", role: .destructive) {
                if let todo = todoPendingDeletion {
                    todoManager.deleteTodo(todo)
                    if selectedTodoId == todo.id { selectedTodoId = nil }
                }
                todoPendingDeletion = nil
            }
        }
    }

    private func selectTodo(_ id: Int) {
        selectedTodoId = id
        isCreatingNew = false
        editingTodoId = nil
    }

    private func todoRow(_ todo: Todo) -> some View {
        TodoRow(
            todo: todo,
            isEditing: editingTodoId == todo.id,
            isSelected: selectedTodoId == todo.id,
            canSend: canSend,
            onSelect: { selectTodo(todo.id) },
            onSend: { sendTodoToTerminal(todo) },
            onEditStart: { editingTodoId = todo.id },
            onEditCommit: { subject in
                saveEdit(todo: todo, subject: subject)
            },
            onEditCancel: { editingTodoId = nil },
            onDelete: { todoPendingDeletion = todo }
        )
    }

    private func startCreating() {
        editingTodoId = nil
        newTodoGeneration += 1
        isCreatingNew = true
    }

    private func commitNewTodo(subject: String) {
        isCreatingNew = false
        todoManager.createTodo(subject: subject)
        startCreating()
    }

    private func saveEdit(todo: Todo, subject: String) {
        let trimmed = subject.trimmingCharacters(in: .whitespacesAndNewlines)
        editingTodoId = nil
        if trimmed.isEmpty {
            todoPendingDeletion = todo
        } else if trimmed != todo.subject {
            todoManager.updateTodoSubject(todo, to: trimmed)
        }
        startCreating()
    }

    private func sendToTerminal(_ text: String) {
        terminalManager.sendToActiveMainTab(text, asCommand: true)
    }

    private func sendTodoToTerminal(_ todo: Todo) {
        sendToTerminal(todo.subject)
        if todo.status == .pending {
            todoManager.setStatus(todo, to: .inProgress)
        }
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
