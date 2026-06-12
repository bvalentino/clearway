import SwiftUI

/// A single action card in the Workflow editor, styled after Apple's Shortcuts actions: a leading
/// step badge, an inline-editable name, and a disclosure chevron that expands the multi-line
/// instructions editor.
///
/// Binds to one `EditorAction`; the card never sees the slug, routes, or position — order/linking
/// are the model's job. Selection, expansion, and removal are parent-owned (passed in), so the card
/// only renders state and forwards the disclosure toggle. Reordering is the List's row drag, grabbed
/// from the non-interactive badge/padding (no separate handle, matching Shortcuts).
struct WorkflowActionCard: View {
    @Binding var action: WorkflowEditorModel.EditorAction
    /// Slug-keyed focus shared with the parent, so a freshly-added card can create-focus its name.
    var focus: FocusState<String?>.Binding
    /// 1-based position shown in the step badge; updates as cards reorder.
    let stepNumber: Int
    /// Drawn as an accent ring so the Delete key / context menu target is unambiguous.
    let isSelected: Bool
    /// Whether the instructions editor is revealed. Collapsed = name-only compact row.
    let isExpanded: Bool
    let onToggleExpanded: () -> Void

    /// Leading inset that aligns the expanded instructions under the name (badge width + spacing).
    private let contentInset: CGFloat = 36

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                stepBadge
                TextField("Action name", text: $action.name)
                    .textFieldStyle(.plain)
                    .font(.headline)
                    .focused(focus, equals: action.slug)
                    .accessibilityLabel("Action name")
                Spacer(minLength: 8)
                disclosure
            }
            if isExpanded {
                instructionsEditor
                    .padding(.leading, contentInset)
            }
        }
        .padding(12)
        .background(Color(.controlBackgroundColor), in: RoundedRectangle(cornerRadius: 12))
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(isSelected ? Color.accentColor : Color(.separatorColor),
                              lineWidth: isSelected ? 2 : 0.5)
        )
        .shadow(color: .black.opacity(0.06), radius: 1.5, y: 1)
    }

    /// Accent rounded-square badge with the step number — Shortcuts' per-action glyph, generalized
    /// to a position indicator since our free-text actions have no category.
    private var stepBadge: some View {
        Text("\(stepNumber)")
            .font(.system(size: 13, weight: .semibold))
            .monospacedDigit()
            .foregroundStyle(.white)
            .frame(width: 26, height: 26)
            .background(Color.accentColor, in: RoundedRectangle(cornerRadius: 6))
            .accessibilityLabel("Step \(stepNumber)")
    }

    private var disclosure: some View {
        Button(action: onToggleExpanded) {
            Image(systemName: "chevron.right")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.secondary)
                .rotationEffect(.degrees(isExpanded ? 90 : 0))
                .frame(width: 24, height: 24)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(isExpanded ? "Hide instructions" : "Show instructions")
        .accessibilityLabel(isExpanded ? "Hide instructions" : "Show instructions")
    }

    private var instructionsEditor: some View {
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
