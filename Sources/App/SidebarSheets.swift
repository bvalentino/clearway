import SwiftUI

// MARK: - Create Worktree Sheet

struct CreateWorktreeSheet: View {
    let targetGroupId: UUID?
    @EnvironmentObject private var worktreeManager: WorktreeManager
    @EnvironmentObject private var groupManager: WorktreeGroupManager
    @Environment(\.dismiss) private var dismiss
    @State private var branchName = ""
    @State private var baseBranch = ""
    @State private var fetchBeforeCreate = true
    @State private var isCreating = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("New Worktree")
                .font(.headline)
                .frame(maxWidth: .infinity, alignment: .center)

            TextField("Branch name", text: $branchName)
                .textFieldStyle(.roundedBorder)
                .onChange(of: branchName) { newValue in
                    let sanitized = newValue.replacingOccurrences(of: " ", with: "-")
                    if sanitized != newValue { branchName = sanitized }
                }
                .disabled(isCreating)

            TextField("Base branch (new branches only)", text: $baseBranch)
                .textFieldStyle(.roundedBorder)
                .disabled(isCreating)
                .opacity(isCreating ? 0.5 : 1.0)

            Toggle("Fetch before creating", isOn: $fetchBeforeCreate)
                .disabled(isCreating)

            HStack {
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                    .disabled(isCreating)
                Spacer()
                Button {
                    isCreating = true
                    Task {
                        let created = await worktreeManager.createWorktree(
                            branch: branchName,
                            base: baseBranch.isEmpty ? nil : baseBranch,
                            fetch: fetchBeforeCreate
                        )
                        if worktreeManager.error == nil {
                            if let created, let targetGroupId {
                                groupManager.addWorktree(created, toGroup: targetGroupId)
                            } else if targetGroupId != nil {
                                Ghostty.logger.warning("CreateWorktreeSheet: worktree creation succeeded but return lookup failed; new worktree will be ungrouped")
                            }
                            dismiss()
                        } else {
                            isCreating = false
                        }
                    }
                } label: {
                    if isCreating {
                        HStack(spacing: 6) {
                            ProgressView()
                                .controlSize(.small)
                            Text("Creating…")
                        }
                    } else {
                        Text("Create")
                    }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(branchName.isEmpty || isCreating)
            }
        }
        .padding(20)
        .frame(width: 320)
    }
}

// MARK: - Rename Group Sheet

struct RenameGroupSheet: View {
    let group: WorktreeGroup
    let onSave: (String) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var name: String

    init(group: WorktreeGroup, onSave: @escaping (String) -> Void) {
        self.group = group
        self.onSave = onSave
        _name = State(initialValue: group.name)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Rename Group")
                .font(.headline)
                .frame(maxWidth: .infinity, alignment: .center)

            TextField("Group name", text: $name)
                .textFieldStyle(.roundedBorder)

            HStack {
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Spacer()
                Button("Save") {
                    onSave(name)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 320)
    }
}

// MARK: - Rename Worktree Sheet

struct RenameWorktreeSheet: View {
    let worktree: Worktree
    let onSave: (String) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var name: String

    init(worktree: Worktree, onSave: @escaping (String) -> Void) {
        self.worktree = worktree
        self.onSave = onSave
        _name = State(initialValue: worktree.branch ?? "")
    }

    private var trimmedName: String {
        name.trimmingCharacters(in: .whitespaces)
    }

    private var canSave: Bool {
        guard !trimmedName.isEmpty else { return false }
        guard trimmedName != worktree.branch else { return false }
        return WorktreeManager.isValidBranchName(trimmedName)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Rename Worktree")
                .font(.headline)
                .frame(maxWidth: .infinity, alignment: .center)

            TextField("Branch name", text: $name)
                .textFieldStyle(.roundedBorder)

            HStack {
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Spacer()
                Button("Save") {
                    onSave(trimmedName)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!canSave)
            }
        }
        .padding(20)
        .frame(width: 320)
    }
}

// MARK: - New Group Sheet

struct NewGroupSheet: View {
    let onCreate: (String) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var name: String = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("New Group")
                .font(.headline)
                .frame(maxWidth: .infinity, alignment: .center)

            TextField("Group name", text: $name)
                .textFieldStyle(.roundedBorder)

            HStack {
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Spacer()
                Button("Create") {
                    onCreate(name)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 320)
    }
}
