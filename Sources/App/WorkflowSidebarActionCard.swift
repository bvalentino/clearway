import SwiftUI

/// One action in the worktree sidebar's vertical flow list — read **and** act, not editable. Shows
/// the action's name, a prompt preview, and a state glyph reflecting its place in the journey
/// (completed / current / next / upcoming), plus a trailing ellipsis "more" menu (no chevron) whose
/// three items the parent wires. Pure presentation: it reaches into no coordinator or manager — the
/// parent injects the state and the action closures. Distinct from the editor's `WorkflowActionCard`
/// (which carries edit/reorder/chevron affordances the sidebar deliberately omits).
struct WorkflowSidebarActionCard: View {
    let name: String
    let instructions: String
    let state: WorkflowDefinition.ActionProgressState
    let onSetCurrent: () -> Void
    let onRunInCurrentTerminal: () -> Void
    let onRunInNewTerminal: () -> Void

    private static let cornerRadius: CGFloat = 12

    /// Instructions flattened to a single line for the 1–2 line preview, matching the editor card.
    private var preview: String {
        instructions
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var body: some View {
        HStack(spacing: 10) {
            stateGlyph
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
            moreMenu
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(cardBackground)
        .overlay(
            RoundedRectangle(cornerRadius: Self.cornerRadius)
                .strokeBorder(Color.accentColor, lineWidth: state == .current ? 1 : 0)
        )
        // Completed steps recede; the rest stay at full strength.
        .opacity(state == .completed ? 0.6 : 1)
    }

    @ViewBuilder
    private var cardBackground: some View {
        // The current step is accent-tinted to stand out; the others use the neutral content material.
        if state == .current {
            RoundedRectangle(cornerRadius: Self.cornerRadius)
                .fill(Color.accentColor.opacity(0.12))
        } else {
            RoundedRectangle(cornerRadius: Self.cornerRadius)
                .fill(.thickMaterial)
        }
    }

    /// State is carried by glyph *shape* (not color alone), per HIG: a filled check for done, an
    /// accent inset-filled dot for the active step, a dashed ring for what's next, a plain ring for
    /// the rest — so done / current / next read apart at a glance.
    private var stateGlyph: some View {
        let glyph = Self.glyph(for: state)
        return Image(systemName: glyph.name)
            .font(.system(size: 15))
            .foregroundStyle(glyph.style)
            .accessibilityLabel(glyph.accessibilityLabel)
    }

    private static func glyph(for state: WorkflowDefinition.ActionProgressState)
        -> (name: String, style: AnyShapeStyle, accessibilityLabel: String) {
        switch state {
        case .completed: return ("checkmark.circle.fill", AnyShapeStyle(.secondary), "Completed")
        case .current: return ("circle.inset.filled", AnyShapeStyle(Color.accentColor), "Current")
        case .next: return ("circle.dashed", AnyShapeStyle(.secondary), "Next")
        case .upcoming: return ("circle", AnyShapeStyle(.tertiary), "Upcoming")
        }
    }

    private var moreMenu: some View {
        Menu {
            Button("Set as Current", action: onSetCurrent)
            Button("Run in Current Terminal", action: onRunInCurrentTerminal)
            Button("Run in New Terminal", action: onRunInNewTerminal)
        } label: {
            Image(systemName: "ellipsis")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(.secondary)
                .frame(width: 24, height: 24)
                .contentShape(Rectangle())
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Action options")
        .accessibilityLabel("Action options")
    }
}
