import SwiftUI

// MARK: - Worktree Row

struct WorktreeRow: View {
    let worktree: Worktree
    var primaryText: String? = nil
    var subtitle: String? = nil
    var hasNotification: Bool = false
    var isWorking: Bool = false
    var shortcutIndex: Int? = nil
    var status: WorktreeStatus? = nil
    @State private var glowExpanded = false

    var body: some View {
        Label {
            HStack(spacing: 4) {
                VStack(alignment: .leading, spacing: 2) {
                    if let primaryText, let subtitle, !subtitle.isEmpty {
                        Text(primaryText)
                            .lineLimit(1)
                        Text(subtitle)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    } else {
                        Text(primaryText ?? worktree.displayName)
                            .lineLimit(1)
                    }
                }
                if worktree.isMain {
                    PrimaryBadge()
                } else if let status {
                    StatusBadge(status: status)
                }
                Spacer()
                Group {
                    if isWorking {
                        Circle()
                            .fill(.orange)
                            .frame(width: 7, height: 7)
                            .shadow(color: .orange, radius: glowExpanded ? 4 : 1)
                            .shadow(color: .orange.opacity(0.5), radius: glowExpanded ? 6 : 2)
                            .animation(.easeInOut(duration: 1.5).repeatForever(autoreverses: true), value: glowExpanded)
                            .onAppear { glowExpanded = true }
                            .onDisappear { glowExpanded = false }
                            .transition(.opacity)
                            .help("Claude is working")
                    } else if hasNotification {
                        Circle()
                            .fill(.blue)
                            .frame(width: 7, height: 7)
                            .help("Terminal notification")
                    }
                }
                .animation(.easeOut(duration: 0.6), value: isWorking)
            }
        } icon: {
            SidebarIcon(
                systemImage: "square.on.square.intersection.dashed",
                shortcut: shortcutIndex.map { "⌘\($0)" }
            )
        }
    }
}

// MARK: - Primary Badge

private struct PrimaryBadge: View {
    var body: some View {
        Text("primary")
            .foregroundStyle(.secondary)
            .rowBadge(.quaternary)
    }
}

// MARK: - Status Badge

private struct StatusBadge: View {
    let status: WorktreeStatus

    var body: some View {
        HStack(spacing: 3) {
            Image(systemName: status.symbol)
            Text(status.displayName.lowercased())
        }
        .foregroundStyle(status.color)
        .rowBadge(status.color.opacity(0.15))
    }
}

private extension View {
    func rowBadge(_ fill: some ShapeStyle) -> some View {
        font(.caption2)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(fill, in: Capsule())
            .fixedSize()
    }
}
