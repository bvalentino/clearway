import SwiftUI

// MARK: - Create Worktree Sheet

struct CreateWorktreeSheet: View {
    let targetGroupName: String?
    /// Non-nil when Start Now opened the sheet: it retitles the sheet, adds the read-only Task row
    /// and seeds the draft, and its task id is what `confirmCreate` links to the new branch.
    let startPrefill: WorkTaskCoordinator.StartPrefill?
    @EnvironmentObject private var worktreeManager: WorktreeManager
    @EnvironmentObject private var groupManager: WorktreeGroupManager
    @EnvironmentObject private var workTaskCoordinator: WorkTaskCoordinator
    @EnvironmentObject private var savedCommandManager: SavedCommandManager
    @Environment(\.dismiss) private var dismiss
    @State private var draft: WorktreeDraft
    @State private var status: WorktreeStatus = .inProgress
    @State private var showingAdvanced = false
    @State private var baseBranch = ""
    @State private var fetchBeforeCreate = true
    @State private var isCreating = false
    @State private var afterCreateCommandId: UUID?

    init(targetGroupName: String?, startPrefill: WorkTaskCoordinator.StartPrefill? = nil) {
        self.targetGroupName = targetGroupName
        self.startPrefill = startPrefill
        _draft = State(initialValue: startPrefill.map {
            Self.prefill(name: $0.title, branch: $0.branch)
        } ?? WorktreeDraft())
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(startPrefill == nil ? "New Worktree" : "Start Task")
                .font(.headline)
                .frame(maxWidth: .infinity, alignment: .center)

            if let startPrefill {
                LabeledField("Task") {
                    Text(startPrefill.title)
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }

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

                    LabeledField("Run after create") {
                        Picker("Run after create", selection: $afterCreateCommandId) {
                            Text("None").tag(UUID?.none)
                            ForEach(savedCommandManager.agentCommands) { command in
                                Text(command.name).tag(UUID?.some(command.id))
                            }
                        }
                        .labelsHidden()
                        .disabled(isCreating)
                    }
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
                    let command = CommandDefaults.resolve(
                        afterCreateCommandId, in: savedCommandManager.commands
                    )
                    workTaskCoordinator.confirmCreate(
                        taskId: startPrefill?.taskId, branch: draft.branch, command: command
                    )
                    Task {
                        let created = await worktreeManager.createWorktree(
                            branch: draft.branch,
                            base: baseBranch.isEmpty ? nil : baseBranch,
                            fetch: fetchBeforeCreate
                        )
                        switch Self.outcome(created: created, error: worktreeManager.error) {
                        case .apply(let worktree):
                            groupManager.setName(draft.name, for: worktree)
                            groupManager.setStatus(status, for: worktree)
                            if let targetGroupName {
                                groupManager.addWorktree(worktree, toGroupNamed: targetGroupName)
                            }
                            savedCommandManager.setAfterCreateDefault(command?.id)
                            dismiss()
                        case .reportedFailure:
                            workTaskCoordinator.abandonPendingCreate()
                            isCreating = false
                        case .silentFailure:
                            Ghostty.logger.warning("CreateWorktreeSheet: creation returned no worktree and no error; the sheet stays open")
                            workTaskCoordinator.abandonPendingCreate()
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
        .onAppear {
            afterCreateCommandId = savedCommandManager.afterCreateCommand?.id
        }
    }
}

extension CreateWorktreeSheet {

    /// A draft seeded from a task. The branch goes through `setBranch`, which marks it
    /// hand-edited, so a later Name keystroke cannot regenerate over a collision-resolved branch.
    static func prefill(name: String, branch: String) -> WorktreeDraft {
        var draft = WorktreeDraft()
        draft.setName(name)
        draft.setBranch(branch)
        return draft
    }

    enum Outcome: Equatable {
        case apply(Worktree)
        case reportedFailure
        case silentFailure
    }

    /// The returned worktree is the only signal that creation worked: `createWorktree` leaves a
    /// non-fatal fetch failure in `WorktreeManager.error` and a banner from an earlier refresh
    /// survives there too, so keying the apply step on `error == nil` dropped the name and status
    /// the operator had just typed over a creation that succeeded.
    static func outcome(created: Worktree?, error: String?) -> Outcome {
        if let created { return .apply(created) }
        return error == nil ? .silentFailure : .reportedFailure
    }
}

// MARK: - Name Entry Sheet

/// The one sheet behind Rename Worktree, Rename Group and New Group: a headline, a single Name
/// field and a Cancel/confirm row. `isValid` is what separates them — a worktree name is cleared
/// by saving an empty field, while a group's must be non-empty and not already taken.
struct NameEntrySheet: View {
    let title: String
    let confirmTitle: String
    let isValid: (String) -> Bool
    let onConfirm: (String) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var name: String

    init(
        title: String,
        confirmTitle: String,
        initialName: String = "",
        isValid: @escaping (String) -> Bool,
        onConfirm: @escaping (String) -> Void
    ) {
        self.title = title
        self.confirmTitle = confirmTitle
        self.isValid = isValid
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
                .disabled(!isValid(name))
            }
        }
        .padding(20)
        .frame(width: 320)
    }
}
