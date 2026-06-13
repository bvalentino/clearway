import SwiftUI

/// A single action row in the Workflow list, styled after Apple's Shortcuts actions: a leading
/// accent step badge, the action name, and a navigation chevron. Display-only — tapping the row
/// (handled by the parent) pushes the editing form. Editing no longer happens inline, so the row
/// holds no text fields and `List` can host it without the first-click focus delay.
struct WorkflowActionCard: View {
    let stepNumber: Int
    let name: String

    private let cornerRadius: CGFloat = 18

    var body: some View {
        HStack(spacing: 12) {
            stepBadge
            Text(name.isEmpty ? "Untitled" : name)
                .font(.headline)
                .foregroundStyle(name.isEmpty ? AnyShapeStyle(.secondary) : AnyShapeStyle(.primary))
                .lineLimit(1)
            Spacer(minLength: 8)
            Image(systemName: "chevron.right")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.tertiary)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(.controlBackgroundColor), in: RoundedRectangle(cornerRadius: cornerRadius))
        .shadow(color: .black.opacity(0.06), radius: 1.5, y: 1)
        .contentShape(RoundedRectangle(cornerRadius: cornerRadius))
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
}
