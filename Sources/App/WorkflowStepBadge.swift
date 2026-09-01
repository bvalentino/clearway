import SwiftUI

/// The step marker a tab chip carries: the workflow action's name on a translucent fill.
///
/// `tint` is the host chip's own foreground colour, so the badge reads correctly on both chip
/// states without knowing about either — `.primary` on an inactive chip (white in dark mode,
/// black in light), white on the accent-filled active chip.
struct WorkflowStepBadge: View {
    let name: String
    let tint: Color

    var body: some View {
        Text(name)
            .lineLimit(1)
            .truncationMode(.tail)
            .font(.system(size: 10, weight: .semibold))
            .padding(.horizontal, 7)
            .padding(.vertical, 2)
            .background { Capsule().fill(tint.opacity(0.25)) }
            .foregroundStyle(tint)
            .layoutPriority(1)
    }
}
