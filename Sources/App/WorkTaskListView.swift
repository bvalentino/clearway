import SwiftUI

/// The project home — a backlog showing tasks that need shaping or haven't started.
/// Started/stopped/done tasks live in their worktree's aside panel.
struct WorkTaskListView: View {
    @EnvironmentObject private var workTaskManager: WorkTaskManager
    @EnvironmentObject private var workTaskCoordinator: WorkTaskCoordinator
    @EnvironmentObject private var worktreeManager: WorktreeManager
    @Environment(\.openWindow) private var openWindow
    let projectPath: String

    /// New and ready-to-start tasks appear in the backlog — once started, tasks live in worktrees.
    private var backlogTasks: [WorkTask] {
        workTaskManager.tasks.filter { $0.status.isBacklog }
    }

    /// Count of tasks that have been dispatched to worktrees.
    private var activeTaskCount: Int {
        workTaskManager.tasks.filter { $0.status.isActive }.count
    }

    private var activeTaskLabel: String {
        "\(activeTaskCount) task\(activeTaskCount == 1 ? "" : "s") in worktrees"
    }

    /// Number of in-progress tasks with a live worktree on disk.
    private var inProgressCount: Int {
        let liveBranches = Set(worktreeManager.worktrees.compactMap(\.branch))
        return workTaskManager.tasks.filter { task in
            task.status == .inProgress && task.worktree.map { liveBranches.contains($0) } == true
        }.count
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
            HStack(spacing: 8) {
                if workTaskCoordinator.isAutoProcessingEnabled {
                    autoProcessButton
                }
                createButton
            }
            .padding(12)
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
                        onEdit: { openTaskWindow(task) },
                        onStartNow: { startTask(task) },
                        onReadyToStart: { workTaskManager.setStatus(task, to: .readyToStart) }
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

    private var autoProcessButton: some View {
        AutoProcessButton(
            isAutoProcessing: workTaskCoordinator.isAutoProcessing,
            tickGeneration: workTaskCoordinator.tickGeneration,
            pollingSeconds: workTaskCoordinator.pollingInterval.rawValue,
            inProgressCount: inProgressCount,
            maxConcurrent: workTaskCoordinator.maxConcurrent
        ) {
            workTaskCoordinator.isAutoProcessing.toggle()
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
    }

    private func createAndEdit() {
        if let task = workTaskManager.createTask() {
            openTaskWindow(task)
        }
    }

    private func openTaskWindow(_ task: WorkTask) {
        openWindow(value: WorkTaskIdentifier(projectPath: projectPath, taskId: task.id))
    }

    private func startTask(_ task: WorkTask) {
        NotificationCenter.default.post(
            name: WorkTaskNotification.start,
            object: projectPath,
            userInfo: [WorkTaskNotification.taskKey: task]
        )
    }
}

// MARK: - Task Card

struct WorkTaskCard: View {
    let task: WorkTask
    var showStatusBadge: Bool = true
    var showContextMenu: Bool = true
    var onEdit: () -> Void
    var onStartNow: (() -> Void)?
    var onReadyToStart: (() -> Void)?
    @EnvironmentObject private var workTaskManager: WorkTaskManager

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(task.title.isEmpty ? "Untitled" : task.title)
                    .font(.headline)
                    .foregroundStyle(task.title.isEmpty ? .secondary : .primary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                if showStatusBadge {
                    Spacer()
                    WorkTaskStatusBadge(status: task.status)
                }
            }

            Text(task.createdAt.formatted(.relative(presentation: .named)))
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 12))
        .contentShape(Rectangle())
        .onTapGesture { onEdit() }
        .contextMenu(showContextMenu ? ContextMenu {
            if let onStartNow, task.status == .new || task.status == .readyToStart {
                Button { onStartNow() } label: {
                    Label("Start Now", systemImage: "play.fill")
                }
            }
            if let onReadyToStart, task.status == .new {
                Button { onReadyToStart() } label: {
                    Label("Ready to Start", systemImage: "clock.arrow.circlepath")
                }
            }
            Divider()
            Button(role: .destructive) {
                workTaskManager.deleteTask(task)
            } label: {
                Label("Delete", systemImage: "trash")
            }
        } : nil)
    }

}

// MARK: - Auto-Process Button

private struct AutoProcessButton: View {
    let isAutoProcessing: Bool
    let tickGeneration: Int
    let pollingSeconds: Int
    let inProgressCount: Int
    let maxConcurrent: Int
    let action: () -> Void

    @State private var progress: CGFloat = 0

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                ZStack {
                    // Background ring
                    Circle()
                        .stroke(Color.primary.opacity(0.15), lineWidth: 2)
                        .frame(width: 18, height: 18)

                    // Progress ring (only when auto-processing)
                    if isAutoProcessing {
                        Circle()
                            .trim(from: 0, to: progress)
                            .stroke(Color.primary.opacity(0.5), style: StrokeStyle(lineWidth: 2, lineCap: .round))
                            .frame(width: 18, height: 18)
                            .rotationEffect(.degrees(-90))
                    }

                    Image(systemName: isAutoProcessing ? "pause.fill" : "play.fill")
                        .font(.system(size: 7, weight: .bold))
                }

                Text("\(inProgressCount)/\(maxConcurrent)")
                    .font(.system(size: 11, weight: .medium, design: .monospaced))
            }
            .foregroundStyle(.primary)
            .padding(.horizontal, 10)
            .frame(height: 36)
            .background(.thinMaterial, in: Capsule())
            .shadow(color: .black.opacity(0.15), radius: 4, y: 2)
        }
        .buttonStyle(.plain)
        .onChange(of: tickGeneration) { _ in
            // Reset to 0 instantly, then animate to 1 over the polling interval
            progress = 0
            withAnimation(.linear(duration: Double(pollingSeconds))) {
                progress = 1
            }
        }
        .onChange(of: isAutoProcessing) { running in
            if running {
                // Start the fill animation immediately
                progress = 0
                withAnimation(.linear(duration: Double(pollingSeconds))) {
                    progress = 1
                }
            } else {
                withAnimation(.easeOut(duration: 0.2)) {
                    progress = 0
                }
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
            if status == .inProgress {
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

    private var badgeColor: Color { status.badgeColor }
}

extension WorkTask.Status {
    var badgeColor: Color {
        switch self {
        case .new: return .blue
        case .readyToStart: return .indigo
        case .inProgress: return .green
        case .readyForReview: return .orange
        case .done: return .secondary
        case .canceled: return .red
        }
    }
}
