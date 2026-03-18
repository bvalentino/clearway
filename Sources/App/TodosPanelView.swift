import SwiftUI

/// Inline play button that sends a todo to the active terminal.
struct SendToTerminalButton: View {
    var action: () -> Void
    var disabled: Bool = false

    var body: some View {
        Button { action() } label: {
            Image(systemName: "play.fill")
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
        }
        .buttonStyle(.plain)
        .help("Send to Terminal")
        .disabled(disabled)
    }
}

/// Combines user todos and Claude Code todos into a single panel.
struct TodosPanelView: View {
    @EnvironmentObject private var claudeTodoManager: ClaudeTodoManager
    @EnvironmentObject private var todoManager: TodoManager
    @EnvironmentObject private var terminalManager: TerminalManager
    @State private var editingTodoId: Int?
    @State private var isCreatingNew = false
    @State private var newTodoGeneration = 0
    @State private var selectedTodo: TodoSelection?
    @State private var todoPendingDeletion: Todo?
    @FocusState private var isListFocused: Bool

    enum TodoSelection: Hashable {
        case todo(Int)
        case claude(sessionId: String, todoId: String)
    }

    private var isEmpty: Bool {
        todoManager.todos.isEmpty && !isCreatingNew && claudeTodoManager.sessions.isEmpty
    }

    private var canSend: Bool {
        terminalManager.activePane != nil
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

                        ForEach(claudeTodoManager.sessions) { session in
                            ClaudeSessionSection(
                                session: session,
                                selectedTodoId: selectedClaudeTodoId(for: session.id),
                                canSend: canSend,
                                onSelect: { todo in
                                    selectTodo(.claude(sessionId: session.id, todoId: todo.id))
                                },
                                onSend: { todo in
                                    sendToTerminal(todo.subject)
                                }
                            )
                        }
                    }
                    .padding()
                }
                .focusable()
                .focused($isListFocused)
                .onCopyCommand {
                    guard let text = selectedTodoSubject else { return [] }
                    return [NSItemProvider(object: text as NSString)]
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
                    if selectedTodo == .todo(todo.id) { selectedTodo = nil }
                }
                todoPendingDeletion = nil
            }
        }
    }

    private var selectedTodoSubject: String? {
        switch selectedTodo {
        case .todo(let id):
            return todoManager.todos.first { $0.id == id }?.subject
        case .claude(let sessionId, let todoId):
            return claudeTodoManager.sessions
                .first { $0.id == sessionId }?
                .todos.first { $0.id == todoId }?
                .subject
        case nil:
            return nil
        }
    }

    private func selectedClaudeTodoId(for sessionId: String) -> String? {
        if case .claude(sessionId, let todoId) = selectedTodo { return todoId }
        return nil
    }

    private func selectTodo(_ selection: TodoSelection) {
        selectedTodo = selection
        isCreatingNew = false
        editingTodoId = nil
        DispatchQueue.main.async { isListFocused = true }
    }

    private func todoRow(_ todo: Todo) -> some View {
        TodoRow(
            todo: todo,
            isEditing: editingTodoId == todo.id,
            isSelected: selectedTodo == .todo(todo.id),
            canSend: canSend,
            onSelect: { selectTodo(.todo(todo.id)) },
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
        guard let surface = terminalManager.activePane?.main else { return }
        surface.sendCommand(text)
        surface.window?.makeFirstResponder(surface)
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

/// A group of Claude Code todos from a single session.
private struct ClaudeSessionSection: View {
    let session: ClaudeSession
    var selectedTodoId: String?
    var canSend: Bool
    var onSelect: (ClaudeTodo) -> Void
    var onSend: (ClaudeTodo) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Claude")
                .font(.caption)
                .fontWeight(.medium)
                .foregroundStyle(.white)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(.orange, in: Capsule())

            ForEach(session.todos) { todo in
                ClaudeTodoRow(
                    todo: todo,
                    isSelected: selectedTodoId == todo.id,
                    canSend: canSend,
                    onSelect: { onSelect(todo) },
                    onSend: { onSend(todo) }
                )
            }
        }
    }
}

/// Displays a single Claude Code todo.
private struct ClaudeTodoRow: View {
    let todo: ClaudeTodo
    var isSelected: Bool
    var canSend: Bool
    var onSelect: () -> Void
    var onSend: () -> Void

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: todo.status.symbol)
                .font(.system(size: 16))
                .foregroundStyle(todo.status.color)
                .frame(width: 20)

            Text(todo.subject)
                .font(.body)
                .foregroundStyle(todo.status == .completed ? .secondary : .primary)
                .strikethrough(todo.status == .completed)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)

            if todo.status != .completed {
                SendToTerminalButton(action: onSend, disabled: !canSend)
            }
        }
        .padding(.vertical, 4)
        .padding(.horizontal, 8)
        .background(isSelected ? Color.primary.opacity(0.06) : .clear, in: RoundedRectangle(cornerRadius: 6))
        .contentShape(Rectangle())
        .onTapGesture { onSelect() }
        .contextMenu {
            if todo.status != .completed {
                Button { onSend() } label: {
                    Label("Send to Terminal", systemImage: "play.fill")
                }
                .disabled(!canSend)
            }
        }
    }
}
