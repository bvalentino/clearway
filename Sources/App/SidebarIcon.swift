import SwiftUI

/// The geometry of the sidebar's icon column. Worktree rows, the top-level destinations and the
/// status section headers all draw their glyph through `SidebarIcon`, which is what keeps the
/// three on one column.
enum SidebarRowMetrics {
    fileprivate static let iconWidth: CGFloat = 18
    /// A status `Section` header is inset 6 pt less than a list row; this makes up the difference.
    /// Measured, not tuned: on the operator's 2x screenshots a header's glyph inks 2 px inside its
    /// own slot and a row's 0 px (the `⌘N` badge) or 3 px (a symbol), which puts the header's slot
    /// at 13 pt and the row's at 15 pt while this constant already stood at 4.
    static let headerLeadingInset: CGFloat = 6
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

/// The `└` a terminal draws before a child line, centred in that same slot so a child row's text
/// keeps the title column. Drawn rather than typed: the character's shape belongs to the font, and
/// the sidebar's is not the monospaced one it is cut for.
struct SidebarChildConnector: View {
    var body: some View {
        ChildConnector()
            .stroke(.secondary, lineWidth: 1)
            .frame(width: SidebarRowMetrics.iconWidth, height: SidebarRowMetrics.iconWidth)
    }
}

private struct ChildConnector: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.midX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.midX, y: rect.midY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.midY))
        return path
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
