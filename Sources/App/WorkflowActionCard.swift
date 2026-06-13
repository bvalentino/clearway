import SwiftUI

/// A single action row in the Workflow list, styled after Apple's Shortcuts actions: a leading
/// reorder handle, the action name, and a navigation chevron. Display-only — tapping the row
/// (handled by the parent) pushes the editing form. Editing no longer happens inline, so the row
/// holds no text fields and `List` can host it without the first-click focus delay.
struct WorkflowActionCard: View {
    let name: String

    private let cornerRadius: CGFloat = 18

    var body: some View {
        HStack(spacing: 12) {
            reorderHandle
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
        // System hierarchical fill: a translucent gray from the foreground color, so the card reads
        // darker than the pane in light mode and lighter than it in dark mode (an elevated surface).
        .background(.quaternary, in: RoundedRectangle(cornerRadius: cornerRadius))
        .shadow(color: .black.opacity(0.06), radius: 1.5, y: 1)
        .contentShape(RoundedRectangle(cornerRadius: cornerRadius))
    }

    /// Plain gray reorder grip — signals that rows can be dragged to sort (the actual reorder is the
    /// List's row drag). The fixed width keeps the name's leading edge aligned across rows.
    private var reorderHandle: some View {
        Image(systemName: "line.3.horizontal")
            .font(.system(size: 14, weight: .medium))
            .foregroundStyle(.secondary)
            .frame(width: 26, height: 26)
            .accessibilityLabel("Drag to reorder")
    }
}
