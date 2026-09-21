import SwiftUI

/// The geometry of the sidebar's icon column. Worktree rows, the top-level destinations and the
/// status section headers all draw their glyph through `SidebarIcon`, which is what keeps the
/// three on one column.
enum SidebarRowMetrics {
    fileprivate static let iconWidth: CGFloat = 18
    static let headerIconSpacing: CGFloat = 6
    /// A status `Section` header is inset less than a list row; this makes up the difference.
    static let headerLeadingInset: CGFloat = 4
}

/// One slot of that column: the `⌘N` / `⌃N` hint while there is one, else the symbol. Leading
/// alignment rather than centred, so a narrow glyph starts where a wide one does — centring inset
/// each glyph by half its own slack inside the slot and left the column visibly ragged.
struct SidebarIcon: View {
    let systemImage: String
    var shortcut: String? = nil

    var body: some View {
        Group {
            if let shortcut {
                ShortcutBadge(text: shortcut)
            } else {
                Image(systemName: systemImage)
            }
        }
        .frame(width: SidebarRowMetrics.iconWidth, alignment: .leading)
    }
}

private struct ShortcutBadge: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.caption2.monospaced())
            .foregroundStyle(.tertiary)
    }
}
