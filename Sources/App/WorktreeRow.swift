import SwiftUI

// MARK: - Worktree Row

struct WorktreeRow: View {
    let worktree: Worktree
    var primaryText: String? = nil
    var subtitle: String? = nil
    var hasNotification: Bool = false
    var phase: AgentPhase = .idle
    var isOpen: Bool = true
    var shortcutIndex: Int? = nil
    var status: WorktreeStatus? = nil

    /// The row's text precedence: a stored name wins, the linked task title fills the slot when
    /// there is none, and the branch is the subtitle behind whichever won. With neither, both are
    /// `nil` and the body falls back to `worktree.displayName` alone. Main carries no name because
    /// `WorktreeGroupManager.name(for:)` refuses it, not because of a branch here.
    static func rowTexts(
        for wt: Worktree,
        name: String?,
        taskTitle: String?
    ) -> (primaryText: String?, subtitle: String?) {
        guard let primaryText = name ?? taskTitle else { return (nil, nil) }
        return (primaryText, wt.displayName)
    }

    /// Which dot the trailing edge carries, or none. `isOpen` gates the agent phase alone: a closed
    /// worktree's surfaces are already retired, so its phase is stale, while a notification it
    /// raised before it closed is still unread and still worth a dot.
    static func dot(phase: AgentPhase, hasNotification: Bool, isOpen: Bool) -> AgentActivityDot.Kind? {
        switch isOpen ? phase : .idle {
        case .waiting: return .waiting
        case .working: return .working
        case .idle: return hasNotification ? .notification : nil
        }
    }

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
                    if let kind = Self.dot(phase: phase, hasNotification: hasNotification, isOpen: isOpen) {
                        AgentActivityDot(kind: kind)
                    }
                }
                .animation(.easeOut(duration: 0.6), value: phase)
            }
        } icon: {
            SidebarIcon(
                systemImage: "square.on.square.intersection.dashed",
                shortcut: shortcutIndex.map { "⌘\($0)" }
            )
        }
    }
}

/// The dot on the trailing edge of a row that can carry agent activity. One shape and one size for
/// every state; the working dot's pulsing glow is the only thing that varies, and it belongs here
/// rather than to the callers so the two rows cannot drift.
struct AgentActivityDot: View {
    enum Kind {
        case waiting
        case working
        case notification
    }

    let kind: Kind
    @State private var glowExpanded = false

    var body: some View {
        switch kind {
        case .waiting:
            circle(.purple, help: "Waiting for permission")
                .transition(.opacity)
        case .working:
            circle(.orange, help: "Agent is working")
                .shadow(color: .orange, radius: glowExpanded ? 4 : 1)
                .shadow(color: .orange.opacity(0.5), radius: glowExpanded ? 6 : 2)
                .animation(.easeInOut(duration: 1.5).repeatForever(autoreverses: true), value: glowExpanded)
                .onAppear { glowExpanded = true }
                .onDisappear { glowExpanded = false }
                .transition(.opacity)
        case .notification:
            circle(.blue, help: "Terminal notification")
        }
    }

    private func circle(_ color: Color, help: String) -> some View {
        Circle()
            .fill(color)
            .frame(width: 7, height: 7)
            .help(help)
    }
}

// MARK: - Subagent Row

/// One live subagent under its worktree. Its text starts on the worktree row's title column,
/// because it is laid out in the same `Label` over the same icon slot; the slot carries the `└` a
/// terminal draws before a child line, so the row reads as a child without a second leading edge.
///
/// The description sits beside the type, the way Claude Code's own status line writes the pair, and
/// yields the width first: the type is what identifies the row, so it keeps its layout priority and
/// the description truncates around it.
struct SubagentRow: View {
    let subagent: AgentSubagent

    var body: some View {
        Label {
            HStack(spacing: 6) {
                Text(subagent.type ?? "Subagent")
                    .lineLimit(1)
                    .layoutPriority(1)
                if let description = subagent.description {
                    Text(description)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        } icon: {
            SidebarChildConnector()
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
