import SwiftUI

/// A single action row in the Workflow list, styled after Apple's Shortcuts/Settings actions.
///
/// Two appearances, switched by `isEditing` (mirroring iOS Settings):
/// - **Normal:** name + instructions excerpt, with a trailing chevron signalling "tap to open."
/// - **Editing:** a leading red delete control + a trailing reorder grip; no chevron. Tapping the
///   delete control calls `onDelete`; the actual drag-to-reorder is the enclosing `List`'s `onMove`,
///   so the grip is an affordance, not its own gesture.
///
/// Display-only — opening and reordering are handled by the parent, so the card holds no navigation
/// state and `List` can host it cleanly.
struct WorkflowActionCard: View {
    let name: String
    let instructions: String
    /// Edit-mode appearance: show the delete control and reorder grip instead of the chevron.
    var isEditing: Bool = false
    /// Invoked when the leading delete control is tapped (edit mode only).
    var onDelete: (() -> Void)?

    /// Shared so the row's press style can clip its highlight to the same shape.
    static let cornerRadius: CGFloat = 18
    private var cornerRadius: CGFloat { Self.cornerRadius }

    /// One-line excerpt of the instructions — newlines collapsed so the preview never starts blank.
    private var preview: String {
        instructions
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var body: some View {
        HStack(spacing: 12) {
            if isEditing {
                deleteControl
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(name.isEmpty ? "Untitled" : name)
                    .font(.headline)
                    .foregroundStyle(name.isEmpty ? AnyShapeStyle(.secondary) : AnyShapeStyle(.primary))
                    .lineLimit(1)
                if !preview.isEmpty {
                    Text(preview)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            }
            Spacer(minLength: 8)
            trailingAccessory
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        // A frosted material as the elevated card surface — reads lighter than the gray pane behind
        // it (set on the editor), the way macOS Settings rows sit above their grouped background.
        // Material adapts to light/dark automatically, so the elevation reads correctly in both.
        .background(.thickMaterial, in: RoundedRectangle(cornerRadius: cornerRadius))
        .contentShape(RoundedRectangle(cornerRadius: cornerRadius))
    }

    /// Red minus control (edit mode), matching the iOS Settings delete affordance.
    private var deleteControl: some View {
        Button { onDelete?() } label: {
            Image(systemName: "minus.circle.fill")
                .font(.system(size: 20))
                .foregroundStyle(.white, .red)
        }
        .buttonStyle(.plain)
        .help("Delete action")
        .accessibilityLabel("Delete action")
    }

    /// Trailing accessory: a reorder grip in edit mode (the row is dragged via the List's `onMove`),
    /// otherwise a navigation chevron signalling the row opens on tap.
    @ViewBuilder
    private var trailingAccessory: some View {
        if isEditing {
            Image(systemName: "line.3.horizontal")
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(.secondary)
                .accessibilityLabel("Drag to reorder")
        } else {
            Image(systemName: "chevron.right")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.tertiary)
        }
    }
}

/// Button style for a tappable action row: strips the default button chrome and darkens the card
/// while the click is held (a translucent fill from the foreground color, so it darkens in light
/// mode and lightens in dark mode — the macOS Settings press behavior). Clipped to the card's shape.
struct PressableCardButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .overlay {
                if configuration.isPressed {
                    RoundedRectangle(cornerRadius: WorkflowActionCard.cornerRadius)
                        .fill(Color.primary.opacity(0.06))
                }
            }
            .contentShape(RoundedRectangle(cornerRadius: WorkflowActionCard.cornerRadius))
    }
}
