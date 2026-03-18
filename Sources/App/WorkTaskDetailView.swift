import SwiftUI

/// A sheet for editing a task's title and markdown body.
struct WorkTaskDetailView: View {
    @EnvironmentObject private var workTaskManager: WorkTaskManager
    @Environment(\.dismiss) private var dismiss

    let task: WorkTask
    @State private var title: String
    @State private var bodyText: String
    @State private var pendingSave: DispatchWorkItem?

    init(task: WorkTask) {
        self.task = task
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
