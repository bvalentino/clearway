import SwiftUI

// MARK: - Create Worktree Sheet

struct CreateWorktreeSheet: View {
    let targetGroupName: String?
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
                        switch Self.outcome(created: created, error: worktreeManager.error) {
                        case .apply(let worktree):
                            groupManager.setName(draft.name, for: worktree)
                            groupManager.setStatus(status, for: worktree)
                            if let targetGroupName {
                                groupManager.addWorktree(worktree, toGroupNamed: targetGroupName)
                            }
                            dismiss()
                        case .reportedFailure:
                            isCreating = false
                        case .silentFailure:
                            Ghostty.logger.warning("CreateWorktreeSheet: creation returned no worktree and no error; the sheet stays open")
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

extension CreateWorktreeSheet {

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
