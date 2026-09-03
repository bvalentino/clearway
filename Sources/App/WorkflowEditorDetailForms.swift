import SwiftUI

// The workflow editor's detail forms (planning + action) and the labeled fields they share with the
// editor's pinned sections.

// MARK: - Planning detail form

/// The editing form for the pinned planning entry: its multi-line instructions plus an optional model.
/// Unlike an action, planning has no name, slug, or routes. Back navigation and Remove live in the
/// window toolbar.
struct WorkflowPlanningDetailView: View {
    @Binding var planning: WorkflowEditorModel.EditorPlanning
    let contentMaxWidth: CGFloat
    /// The agent this entry inherits when it names none, or names one the allowlist rejects.
    let inheritedAgent: String

    @FocusState private var focused: Bool

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                VStack(alignment: .leading, spacing: 8) {
                    workflowDetailField("Instructions") {
                        // TextEditor (not TextField) so Return inserts a line break.
                        TextEditor(text: $planning.instructions)
                            .font(.body)
                            .scrollContentBackground(.hidden)
                            .frame(minHeight: 200)
                            .focused($focused)
                            .accessibilityLabel("Planning instructions")
                    }
                    Text("Runs when you tap Plan, before the worktree exists. "
                        + "Use {{ task.title }}, {{ task.body }}, {{ task.id }}, {{ task.path }}.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                workflowAgentField($planning.command,
                                   accessibilityLabel: "Planning agent",
                                   ignoredFallback: inheritedAgent)
                workflowModelField($planning.model, accessibilityLabel: "Planning model")
            }
                .workflowDetailFormContainer(maxWidth: contentMaxWidth)
        }
        .onAppear { if planning.instructions.isEmpty { focused = true } }
    }
}

// MARK: - Action detail form

/// The editing form for one action: its name and multi-line instructions. Back navigation and Delete
/// live in the window toolbar, not in this content.
struct WorkflowActionDetailView: View {
    @Binding var action: WorkflowEditorModel.EditorAction
    let contentMaxWidth: CGFloat
    /// The agent this entry inherits when it names none, or names one the allowlist rejects.
    let inheritedAgent: String
    /// Forces the "Required" indicators on regardless of which fields were touched.
    let forceValidation: Bool

    @FocusState private var nameFocused: Bool
    /// "Required" shows only after a field is edited and left empty, so a fresh action isn't pre-flagged.
    @State private var nameEdited = false
    @State private var instructionsEdited = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                workflowDetailField("Name", warning: requiredWarning(nameEdited, action.name)) {
                    TextField("Action name", text: $action.name)
                        .textFieldStyle(.plain)
                        .font(.body)
                        .focused($nameFocused)
                        .accessibilityLabel("Action name")
                }
                workflowDetailField(
                    "Instructions",
                    warning: requiredWarning(instructionsEdited, action.instructions)
                ) {
                    // TextEditor (not TextField) so Return inserts a line break.
                    TextEditor(text: $action.instructions)
                        .font(.body)
                        .scrollContentBackground(.hidden)
                        .frame(minHeight: 160)
                        .accessibilityLabel("Action instructions")
                }
                workflowAgentField($action.command,
                                   accessibilityLabel: "Action agent",
                                   ignoredFallback: inheritedAgent)
                workflowModelField($action.model, accessibilityLabel: "Action model")
            }
                .workflowDetailFormContainer(maxWidth: contentMaxWidth)
        }
        .onChange(of: action.name) { _ in nameEdited = true }
        .onChange(of: action.instructions) { _ in instructionsEdited = true }
        .onAppear {
            if action.name.isEmpty && action.instructions.isEmpty { nameFocused = true }
        }
    }

    private func requiredWarning(_ edited: Bool, _ text: String) -> String? {
        guard edited || forceValidation,
              text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return "Required"
    }
}

/// The Agent picker. `Default` means inherit. A stored value that is not one of the three names
/// keeps its own row and stays selected, so opening the editor never silently rewrites a
/// hand-authored file.
private func workflowAgentPicker(_ command: Binding<String>, accessibilityLabel: String) -> some View {
    Picker("", selection: command) {
        Text("Default").tag("")
        ForEach(agentAllowlist, id: \.self) { agent in
            Text(agent).tag(agent)
        }
        let stored = command.wrappedValue
        if !stored.isEmpty, !agentAllowlist.contains(stored) {
            Text(stored).tag(stored)
        }
    }
    .labelsHidden()
    .accessibilityLabel(accessibilityLabel)
}

/// What happens to a value the allowlist rejects — stated rather than merely flagged, because the
/// fall-through is otherwise silent at launch. `nil` for `Default` and for any allowlisted agent,
/// a path to one included (that launches verbatim, so it is honored and reads unflagged).
private func workflowAgentWarning(_ command: String, ignoredFallback: String) -> String? {
    let trimmed = command.trimmingCharacters(in: .whitespaces)
    guard !trimmed.isEmpty, !isAllowlistedAgentCommand(trimmed) else { return nil }
    return "Ignored — \(ignoredFallback) is used"
}

/// The Agent field, used by both detail forms and the editor's pinned workflow-wide row.
/// `ignoredFallback` is the agent a rejected value actually falls through to, resolved by the same
/// `resolveAgentCommand` that launches it — naming the level instead would state the wrong
/// consequence whenever the level above is itself unset.
func workflowAgentField(
    _ command: Binding<String>,
    accessibilityLabel: String,
    ignoredFallback: String
) -> some View {
    VStack(alignment: .leading, spacing: 6) {
        workflowFieldLabel(
            "Agent",
            warning: workflowAgentWarning(command.wrappedValue, ignoredFallback: ignoredFallback)
        )
        workflowAgentPicker(command, accessibilityLabel: accessibilityLabel)
    }
}

/// The Model field, shared by both detail forms. `Invalid` flags a multi-word value, which
/// `applyModel` drops at launch with no flag and no message anywhere. A typo (`sonet`) is not
/// caught — it reaches the agent and errors visibly in its terminal.
@ViewBuilder
private func workflowModelField(_ model: Binding<String>, accessibilityLabel: String) -> some View {
    let trimmed = model.wrappedValue.trimmingCharacters(in: .whitespaces)
    workflowDetailField("Model", warning: trimmed.isEmpty || isModelValueSafe(trimmed) ? nil : "Invalid") {
        TextField("Default", text: model)
            .textFieldStyle(.plain)
            .font(.body)
            .accessibilityLabel(accessibilityLabel)
    }
}

/// One labeled field in the editor's detail forms. `warning` renders beside the label and tints the
/// border — "Required" for a missing required field, "Invalid" for an unusable model.
private func workflowDetailField<Content: View>(
    _ title: String,
    warning: String? = nil,
    @ViewBuilder content: () -> Content
) -> some View {
    VStack(alignment: .leading, spacing: 6) {
        workflowFieldLabel(title, warning: warning)
        content()
            .padding(8)
            .background(Color(.textBackgroundColor), in: RoundedRectangle(cornerRadius: 6))
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .strokeBorder(warning != nil ? Color.red.opacity(0.7) : Color(.separatorColor),
                                  lineWidth: 1)
            )
    }
}

/// Shared by the detail forms, the pinned sections, and the Agent field so all three read as one set.
func workflowFieldLabel(_ title: String, warning: String? = nil) -> some View {
    HStack(spacing: 6) {
        Text(title)
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(.secondary)
        if let warning {
            Text(warning)
                .font(.caption)
                .foregroundStyle(.red)
        }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
}

private extension View {
    /// Shared chrome for the editor's detail forms (planning + action): a material card with content
    /// padding, centered to the editor's max content width.
    func workflowDetailFormContainer(maxWidth: CGFloat) -> some View {
        self
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.thickMaterial, in: RoundedRectangle(cornerRadius: 12))
            .padding(.horizontal, 32)
            .padding(.top, 20)
            .padding(.bottom, 24)
            .frame(maxWidth: maxWidth, alignment: .leading)
            .frame(maxWidth: .infinity)
    }
}
