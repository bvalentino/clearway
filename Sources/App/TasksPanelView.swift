import SwiftUI

/// Combines user tasks and Claude Code tasks into a single panel.
struct TasksPanelView: View {
    @EnvironmentObject private var claudeTaskManager: ClaudeTaskManager
    @EnvironmentObject private var userTaskManager: UserTaskManager
    @State private var newTaskSubject = ""

    var body: some View {
        VStack(spacing: 0) {
            // Create task input — always visible
            HStack(spacing: 8) {
                Image(systemName: "plus.circle.fill")
                    .foregroundStyle(Color.accentColor)
                    .font(.system(size: 16))

                TextField("Add a task...", text: $newTaskSubject)
                    .textFieldStyle(.plain)
                    .onSubmit {
                        userTaskManager.createTask(subject: newTaskSubject)
                        newTaskSubject = ""
                    }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)

            Divider()

            if userTaskManager.tasks.isEmpty && claudeTaskManager.sessions.isEmpty {
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
                        if !userTaskManager.tasks.isEmpty {
                            VStack(alignment: .leading, spacing: 4) {
                                ForEach(userTaskManager.tasks) { task in
                                    UserTaskRow(task: task)
                                }
                            }
                        }

                        ForEach(claudeTaskManager.sessions) { session in
                            ClaudeSessionSection(session: session)
                        }
                    }
                    .padding()
                }
            }
        }
    }
}

/// A group of Claude Code tasks from a single session.
private struct ClaudeSessionSection: View {
    let session: ClaudeSession

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
                ClaudeTaskRow(task: task)
            }
        }
    }
}

/// Displays a single Claude Code task.
private struct ClaudeTaskRow: View {
    let task: ClaudeTask

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: task.statusSymbol)
                .font(.system(size: 16))
                .foregroundStyle(statusColor)
                .frame(width: 20)

            Text(task.subject)
                .font(.body)
                .foregroundStyle(task.status == .completed ? .secondary : .primary)
                .strikethrough(task.status == .completed)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var statusColor: Color {
        switch task.status {
        case .completed: return .green
        case .inProgress: return .orange
        case .pending: return .secondary
        }
    }
}
