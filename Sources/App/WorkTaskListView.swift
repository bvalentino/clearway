import SwiftUI

/// The project home — a backlog showing tasks that need shaping or haven't started.
/// Started/stopped/done tasks live in their worktree's aside panel.
struct WorkTaskListView: View {
    @EnvironmentObject private var workTaskManager: WorkTaskManager
    @Environment(\.openWindow) private var openWindow
    let projectPath: String

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
        .overlay(alignment: .bottomTrailing) {
            createButton
        }
    }

    private var emptyState: some View {
        VStack(spacing: 16) {
            Image(systemName: "tray")
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
                        onEdit: { openTaskWindow(task) }
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
    }

    private var createButton: some View {
        Button {
            createAndEdit()
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

    private func createAndEdit() {
        if let task = workTaskManager.createTask(title: "New Task") {
            openTaskWindow(task)
        }
    }

    private func openTaskWindow(_ task: WorkTask) {
        openWindow(value: WorkTaskIdentifier(projectPath: projectPath, taskId: task.id))
    }
}

// MARK: - Task Card

private struct WorkTaskCard: View {
    let task: WorkTask
    var onEdit: () -> Void
    @EnvironmentObject private var workTaskManager: WorkTaskManager

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(task.title)
                .font(.headline)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)

            Text(task.createdAt.formatted(.relative(presentation: .named)))
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 12))
        .contentShape(Rectangle())
        .onTapGesture { onEdit() }
        .contextMenu {
            Button { onEdit() } label: {
                Label("Edit", systemImage: "pencil")
            }
            Divider()
            Button(role: .destructive) {
                workTaskManager.deleteTask(task)
            } label: {
                Label("Delete", systemImage: "trash")
            }
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
