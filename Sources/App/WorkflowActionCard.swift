import SwiftUI

/// A single action card in the Workflow editor: a drag-affordance glyph, an inline-editable name,
/// and an inline multi-line instructions editor.
///
/// Binds to one `EditorAction` (so name/instructions edits flow straight into the editor model).
/// The card never sees the action's slug, routes, or position — order and linking are the model's
/// job. Removal isn't a card concern either: it's driven by the parent's selection + `−` control
/// (the macOS-native add/remove idiom), so the card only renders its selected state.
struct WorkflowActionCard: View {
    @Binding var action: WorkflowEditorModel.EditorAction
    /// Slug-keyed focus shared with the parent, so a freshly-added card can create-focus its name.
    var focus: FocusState<String?>.Binding
    /// Whether this card is the list's current selection — drawn as an accent ring so the `−`
    /// control's target is unambiguous on these large cards.
    let isSelected: Bool

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
        }
        .padding(14)
        .background(.thickMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(isSelected ? Color.accentColor : .clear, lineWidth: 2)
        )
    }
}
