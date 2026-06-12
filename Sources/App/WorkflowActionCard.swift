import SwiftUI

/// A single action card in the Workflow editor: a drag-affordance glyph, an inline-editable name,
/// an inline multi-line instructions editor, and a remove button.
///
/// Binds to one `EditorAction` (so name/instructions edits flow straight into the editor model);
/// removal is surfaced via a callback the parent wires to `WorkflowEditorModel.remove`. The card
/// never sees the action's slug, routes, or position — order and linking are the model's job.
struct WorkflowActionCard: View {
    @Binding var action: WorkflowEditorModel.EditorAction
    /// Slug-keyed focus shared with the parent, so a freshly-added card can create-focus its name.
    var focus: FocusState<String?>.Binding
    let onRemove: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "line.3.horizontal")
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(.tertiary)
                .padding(.top, 4)
                .accessibilityLabel("Reorder action")
                .help("Drag to reorder")

            VStack(alignment: .leading, spacing: 8) {
                TextField("Action name", text: $action.name)
                    .textFieldStyle(.plain)
                    .font(.headline)
                    .focused(focus, equals: action.slug)
                    .accessibilityLabel("Action name")

                TextField("Instructions for this step", text: $action.instructions, axis: .vertical)
                    .textFieldStyle(.plain)
                    .font(.body)
                    .lineLimit(3...12)
                    .padding(8)
                    .background(Color(.textBackgroundColor))
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                    .overlay(
                        RoundedRectangle(cornerRadius: 6)
                            .strokeBorder(Color(.separatorColor), lineWidth: 1)
                    )
                    .accessibilityLabel("Action instructions")
            }

            Button(action: onRemove) {
                Image(systemName: "xmark")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.secondary)
                    // Enlarge the pointer target toward the HIG 44×44pt button minimum (macOS
                    // pointer precision lets a card affordance sit below the full touch size).
                    .frame(width: 24, height: 24)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Remove action")
            // macOS surfaces a hover tooltip for icon-only buttons; spell out the unlabeled glyph.
            .help("Remove action")
        }
        .padding(14)
        .background(.thickMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }
}
