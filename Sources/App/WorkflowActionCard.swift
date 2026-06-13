import SwiftUI

/// A single action row in the Workflow list. Display-only: opening and reordering are the parent's
/// job, so the card holds no navigation state. In edit mode it shows a delete control and a reorder
/// grip (the drag itself is the enclosing `List`'s `onMove`); otherwise a tap-to-open chevron.
struct WorkflowActionCard: View {
    let name: String
    let instructions: String
    var isEditing: Bool = false
    /// Invoked when the leading delete control is tapped (edit mode only).
    var onDelete: (() -> Void)?

    /// Shared so the row's press style clips its highlight to the same shape.
    static let cornerRadius: CGFloat = 18
    private var cornerRadius: CGFloat { Self.cornerRadius }

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
        // Frosted material reads lighter than the editor's gray pane behind it, so the card elevates.
        .background(.thickMaterial, in: RoundedRectangle(cornerRadius: cornerRadius))
        .contentShape(RoundedRectangle(cornerRadius: cornerRadius))
    }

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

/// Button style for a tappable action row: a translucent foreground-color fill while pressed, so the
/// card darkens in light mode and lightens in dark mode. Clipped to the card's shape.
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
