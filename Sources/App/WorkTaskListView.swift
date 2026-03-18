import SwiftUI

/// The project home — a backlog showing tasks that need shaping or haven't started.
/// Started/stopped/done tasks live in their worktree's aside panel.
struct WorkTaskListView: View {
    @EnvironmentObject private var workTaskManager: WorkTaskManager
    var onStart: (WorkTask) -> Void
    var onOpen: (WorkTask) -> Void
    var onContinue: ((WorkTask) -> Void)?

    @State private var editingTask: WorkTask?

    /// Only open tasks appear in the backlog — once started, tasks live in worktrees.
    private var backlogTasks: [WorkTask] {
        workTaskManager.tasks.filter { $0.status == .open }
    }

    /// Count of tasks that have been dispatched to worktrees.
    private var activeTaskCount: Int {
        workTaskManager.tasks.filter { $0.status != .open }.count
    }

    private var activeTaskLabel: String {
        "\(activeTaskCount) task\(activeTaskCount == 1 ? "" : "s") in worktrees"
    }

    var body: some View {
        Group {
            if backlogTasks.isEmpty {
                emptyState
            } else {
                taskList
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .sheet(item: $editingTask) { task in
            WorkTaskDetailView(
                task: task,
                onStart: { onStart($0) },
                onContinue: { onContinue?($0) }
            )
        }
    }

    private var emptyState: some View {
        VStack(spacing: 16) {
            Image(systemName: "ticket")
                .font(.system(size: 48))
                .foregroundStyle(.tertiary)
            Text(activeTaskCount > 0 ? "Backlog is empty" : "No tasks yet")
                .font(.title3)
                .foregroundStyle(.secondary)
            if activeTaskCount > 0 {
                Text(activeTaskLabel)
                    .font(.callout)
                    .foregroundStyle(.tertiary)
            }
            Button("New Task") {
                createAndEdit()
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
        }
    }

    private var taskList: some View {
        ScrollView {
            LazyVStack(spacing: 12) {
                ForEach(backlogTasks) { task in
                    WorkTaskCard(
                        task: task,
                        onEdit: { editingTask = task },
                        onStart: { onStart(task) },
                        onOpen: { onOpen(task) },
                        onContinue: { onContinue?(task) }
                    )
                }

                if activeTaskCount > 0 {
                    Text(activeTaskLabel)
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .padding(.top, 4)
                }
            }
            .padding(20)
        }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    createAndEdit()
                } label: {
                    Image(systemName: "plus")
                }
                .help("New Task")
            }
        }
    }

    private func createAndEdit() {
        if let task = workTaskManager.createTask(title: "New Task") {
            editingTask = task
        }
    }
}

// MARK: - Task Card

private struct WorkTaskCard: View {
    let task: WorkTask
    var onEdit: () -> Void
    var onStart: () -> Void
    var onOpen: () -> Void
    var onContinue: () -> Void
    @EnvironmentObject private var workTaskManager: WorkTaskManager

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 6) {
                Text(task.title)
                    .font(.headline)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)

                HStack(spacing: 6) {
                    WorkTaskStatusBadge(status: task.status)

                    if let tokens = task.totalTokens {
                        Text("\(WorkTask.formatTokenCount(tokens)) tokens")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                }

                if task.status == .stopped, let error = task.errorMessage {
                    Text(error.components(separatedBy: "\n").first ?? error)
                        .font(.caption)
                        .foregroundStyle(.red.opacity(0.8))
                        .lineLimit(1)
                } else if !task.body.isEmpty {
                    Text(task.body.prefix(120))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            actionButton
        }
        .padding(16)
        .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 12))
        .contentShape(Rectangle())
        .onTapGesture { onEdit() }
        .contextMenu {
            Button { onEdit() } label: {
                Label("Edit", systemImage: "pencil")
            }
            Divider()
            if task.status == .started || task.status == .open || task.status == .stopped {
                Button {
                    workTaskManager.setStatus(task, to: .done)
                } label: {
                    Label("Mark Done", systemImage: "checkmark.circle")
                }
            }
            if task.status == .done || task.status == .stopped {
                Button {
                    workTaskManager.setStatus(task, to: .open)
                } label: {
                    Label("Reopen", systemImage: "arrow.uturn.backward")
                }
            }
            Divider()
            Button(role: .destructive) {
                workTaskManager.deleteTask(task)
            } label: {
                Label("Delete", systemImage: "trash")
            }
        }
    }

    @ViewBuilder
    private var actionButton: some View {
        switch task.status {
        case .open:
            Button("Start", action: onStart)
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
        case .started:
            Button("Open", action: onOpen)
                .buttonStyle(.bordered)
                .controlSize(.regular)
        case .done:
            if task.worktree != nil {
                Button("Continue", action: onContinue)
                    .buttonStyle(.bordered)
                    .controlSize(.regular)
            } else {
                Image(systemName: "checkmark.circle.fill")
                    .font(.title2)
                    .foregroundStyle(.green)
            }
        case .stopped:
            Button("Restart", action: onStart)
                .buttonStyle(.bordered)
                .tint(.orange)
                .controlSize(.regular)
        }
    }
}

// MARK: - Status Badge

struct WorkTaskStatusBadge: View {
    let status: WorkTask.Status
    @State private var pulsing = false

    var body: some View {
        HStack(spacing: 4) {
            if status == .started {
                Circle()
                    .fill(.green)
                    .frame(width: 6, height: 6)
                    .scaleEffect(pulsing ? 1.3 : 1.0)
                    .opacity(pulsing ? 0.6 : 1.0)
                    .animation(.easeInOut(duration: 1.0).repeatForever(autoreverses: true), value: pulsing)
                    .onAppear { pulsing = true }
            }
            Text(status.label)
        }
        .font(.caption2)
        .fontWeight(.medium)
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .foregroundStyle(badgeColor)
        .background(badgeColor.opacity(0.12), in: Capsule())
    }

    private var badgeColor: Color {
        switch status {
        case .open: return .blue
        case .started: return .green
        case .done: return .secondary
        case .stopped: return .orange
        }
    }
}
