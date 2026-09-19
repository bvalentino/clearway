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
                        WorktreeStatusLabel(status: option)
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

// MARK: - Name Entry Sheet

/// The one sheet behind Rename Worktree, Rename Group and New Group: a headline, a single Name
/// field and a Cancel/confirm row. `allowsEmptyName` is what separates them — a worktree name is
/// cleared by saving an empty field, while a group must always have one.
struct NameEntrySheet: View {
    let title: String
    let confirmTitle: String
    let allowsEmptyName: Bool
    let onConfirm: (String) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var name: String

    init(
        title: String,
        confirmTitle: String,
        initialName: String = "",
        allowsEmptyName: Bool = false,
        onConfirm: @escaping (String) -> Void
    ) {
        self.title = title
        self.confirmTitle = confirmTitle
        self.allowsEmptyName = allowsEmptyName
        self.onConfirm = onConfirm
        _name = State(initialValue: initialName)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(title)
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
                Button(confirmTitle) {
                    onConfirm(name)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!allowsEmptyName && name.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 320)
    }
}
