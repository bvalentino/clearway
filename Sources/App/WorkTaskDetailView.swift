import SwiftUI

/// A sheet for editing a task's title and markdown body.
/// Shows agent status, token usage, error messages, and Continue/Restart actions.
struct WorkTaskDetailView: View {
    @EnvironmentObject private var workTaskManager: WorkTaskManager
    @Environment(\.dismiss) private var dismiss

    let task: WorkTask
    var onStart: ((WorkTask) -> Void)?
    var onContinue: ((WorkTask) -> Void)?

    @State private var title: String
    @State private var bodyText: String
    @State private var pendingSave: DispatchWorkItem?

    init(task: WorkTask, onStart: ((WorkTask) -> Void)? = nil, onContinue: ((WorkTask) -> Void)? = nil) {
        self.task = task
        self.onStart = onStart
        self.onContinue = onContinue
        _title = State(initialValue: task.title)
        _bodyText = State(initialValue: task.body)
    }

    var body: some View {
        VStack(spacing: 0) {
            // Title bar
            HStack {
                TextField("Title", text: $title)
                    .textFieldStyle(.plain)
                    .font(.title2.bold())

                Spacer()

                WorkTaskStatusBadge(status: currentTask.status)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 16)

            // Agent metadata bar
            if currentTask.status != .open {
                agentMetadataBar
            }

            Divider()

            // Body editor
            TextEditor(text: $bodyText)
                .font(.system(.body, design: .monospaced))
                .scrollContentBackground(.hidden)
                .padding(4)
        }
        .frame(minWidth: 600, minHeight: 400)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Done") { dismiss() }
            }
            ToolbarItem(placement: .destructiveAction) {
                Button(role: .destructive) {
                    workTaskManager.deleteTask(currentTask)
                    dismiss()
                } label: {
                    Image(systemName: "trash")
                }
            }
        }
        .onChange(of: title) { _ in scheduleSave() }
        .onChange(of: bodyText) { _ in scheduleSave() }
        .onDisappear {
            // Flush any pending save — guard against deleted task
            pendingSave?.cancel()
            guard workTaskManager.tasks.contains(where: { $0.id == task.id }) else { return }
            saveNow()
        }
    }

    // MARK: - Agent Metadata

    private var agentMetadataBar: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 12) {
                // Token usage
                if let input = currentTask.inputTokens, let output = currentTask.outputTokens {
                    Label {
                        Text("\(WorkTask.formatTokenCount(input)) in / \(WorkTask.formatTokenCount(output)) out")
                    } icon: {
                        Image(systemName: "gauge.with.dots.needle.bottom.50percent")
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }

                // Attempt count
                if let attempt = currentTask.attempt, attempt > 0 {
                    Label("Attempt \(attempt + 1)", systemImage: "arrow.counterclockwise")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                // Action buttons
                if currentTask.status == .stopped {
                    Button {
                        dismiss()
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                            onStart?(currentTask)
                        }
                    } label: {
                        Label("Restart", systemImage: "arrow.clockwise")
                    }
                    .buttonStyle(.bordered)
                    .tint(.orange)
                    .controlSize(.small)
                }

                if currentTask.status == .done, currentTask.worktree != nil {
                    Button {
                        dismiss()
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                            onContinue?(currentTask)
                        }
                    } label: {
                        Label("Continue", systemImage: "play")
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
            }

            // Error message
            if let error = currentTask.errorMessage {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red.opacity(0.8))
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(.horizontal, 20)
        .padding(.bottom, 12)
    }

    // MARK: - Helpers

    /// The latest version of this task from the manager.
    private var currentTask: WorkTask {
        workTaskManager.tasks.first { $0.id == task.id } ?? task
    }

    private func scheduleSave() {
        pendingSave?.cancel()
        let work = DispatchWorkItem { saveNow() }
        pendingSave = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: work)
    }

    private func saveNow() {
        var updated = currentTask
        updated.title = title
        updated.body = bodyText
        workTaskManager.updateTask(updated)
    }
}
