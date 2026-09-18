import SwiftUI

// MARK: - Create Worktree Sheet

struct CreateWorktreeSheet: View {
    let targetGroupId: UUID?
    @EnvironmentObject private var worktreeManager: WorktreeManager
    @EnvironmentObject private var groupManager: WorktreeGroupManager
    @Environment(\.dismiss) private var dismiss
    @State private var draft = WorktreeDraft()
    @State private var status: WorktreeStatus = .inProgress
    @State private var showingAdvanced = false
    @State private var baseBranch = ""
    @State private var fetchBeforeCreate = true
    @State private var isCreating = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("New Worktree")
                .font(.headline)
                .frame(maxWidth: .infinity, alignment: .center)

            TextField("Name", text: Binding(
                get: { draft.name },
                set: { draft.setName($0) }
            ))
            .textFieldStyle(.roundedBorder)
            .disabled(isCreating)

            TextField("Branch name", text: Binding(
                get: { draft.branch },
                set: { draft.setBranch($0) }
            ))
            .textFieldStyle(.roundedBorder)
            .disabled(isCreating)

            Picker("Status", selection: $status) {
                ForEach(WorktreeStatus.allCases) { option in
                    Label {
                        Text(option.displayName)
                    } icon: {
                        Image(systemName: option.symbol)
                            .foregroundStyle(option.color)
                    }
                    .tag(option)
                }
            }
            .disabled(isCreating)

            DisclosureGroup("Advanced", isExpanded: $showingAdvanced) {
                VStack(alignment: .leading, spacing: 16) {
                    TextField("Base branch (new branches only)", text: $baseBranch)
                        .textFieldStyle(.roundedBorder)
                        .disabled(isCreating)
                        .opacity(isCreating ? 0.5 : 1.0)

                    Toggle("Fetch before creating", isOn: $fetchBeforeCreate)
                        .disabled(isCreating)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.top, 8)
            }

            HStack {
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                    .disabled(isCreating)
                Spacer()
                Button {
                    isCreating = true
                    Task {
                        let created = await worktreeManager.createWorktree(
                            branch: draft.branch,
                            base: baseBranch.isEmpty ? nil : baseBranch,
                            fetch: fetchBeforeCreate
                        )
                        if worktreeManager.error == nil {
                            if let created {
                                groupManager.setName(draft.name, for: created)
                                groupManager.setStatus(status, for: created)
                                if let targetGroupId {
                                    groupManager.addWorktree(created, toGroup: targetGroupId)
                                }
                            } else {
                                Ghostty.logger.warning("CreateWorktreeSheet: worktree creation succeeded but return lookup failed; new worktree keeps no name, status or group")
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
                .disabled(draft.branch.isEmpty || isCreating)
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
