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

            LabeledField("Name") {
                TextField("", text: Binding(
                    get: { draft.name },
                    set: { draft.setName($0) }
                ))
                .textFieldStyle(.roundedBorder)
                .disabled(isCreating)
            }

            LabeledField("Branch name") {
                TextField("", text: Binding(
                    get: { draft.branch },
                    set: { draft.setBranch($0) }
                ))
                .textFieldStyle(.roundedBorder)
                .disabled(isCreating)
            }

            LabeledField("Status") {
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
                .labelsHidden()
                .disabled(isCreating)
            }

            // A `DisclosureGroup` in a plain VStack only toggles on the triangle itself —
            // measured at roughly 4x8pt of a 280pt row — so the row is built by hand to
            // make the whole width a single-click target.
            Button {
                showingAdvanced.toggle()
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.semibold))
                        .rotationEffect(.degrees(showingAdvanced ? 90 : 0))
                    Text("Advanced")
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if showingAdvanced {
                VStack(alignment: .leading, spacing: 16) {
                    LabeledField("Base branch") {
                        TextField("", text: $baseBranch)
                            .textFieldStyle(.roundedBorder)
                            .disabled(isCreating)
                            .opacity(isCreating ? 0.5 : 1.0)
                    }

                    Toggle("Fetch before creating", isOn: $fetchBeforeCreate)
                        .disabled(isCreating)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
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

// MARK: - Rename Worktree Sheet

struct RenameWorktreeSheet: View {
    let onSave: (String) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var name: String

    init(currentName: String, onSave: @escaping (String) -> Void) {
        self.onSave = onSave
        _name = State(initialValue: currentName)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Rename Worktree")
                .font(.headline)
                .frame(maxWidth: .infinity, alignment: .center)

            LabeledField("Name") {
                TextField("", text: $name)
                    .textFieldStyle(.roundedBorder)
            }

            HStack {
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Spacer()
                // Unlike RenameGroupSheet, an empty field saves: it is how a name is cleared.
                Button("Save") {
                    onSave(name)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
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

            LabeledField("Name") {
                TextField("", text: $name)
                    .textFieldStyle(.roundedBorder)
            }

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

            LabeledField("Name") {
                TextField("", text: $name)
                    .textFieldStyle(.roundedBorder)
            }

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
