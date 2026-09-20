import SwiftUI

// MARK: - Chip subviews

/// A tab chip: the title and the close button that appears on hover or while active.
private struct TabChip: View {
    let title: String
    let toolName: String?
    let isActive: Bool
    let onActivate: () -> Void
    let onClose: () -> Void
    let onCloseOthers: () -> Void
    let onCloseAll: () -> Void

    @State private var isHovering = false

    var body: some View {
        HStack(spacing: 4) {
            HStack(spacing: 4) {
                Text(title)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .font(.system(size: 12))
                    .layoutPriority(1)

                if let toolName {
                    Text(toolName)
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            if isHovering || isActive {
                Button {
                    onClose()
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 9, weight: .bold))
                        .frame(width: 14, height: 14)
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
            } else {
                // Reserve space so chip width is stable on hover
                Color.clear
                    .frame(width: 14, height: 14)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background {
            if isActive {
                Capsule().fill(Color.accentColor)
            } else {
                Capsule().fill(Color(nsColor: .quaternaryLabelColor))
            }
        }
        .foregroundStyle(isActive ? Color.white : Color.primary)
        .onHover { hovering in isHovering = hovering }
        .onTapGesture { onActivate() }
        .contextMenu {
            Button("Close Tab") { onClose() }
            Button("Close Other Tabs") { onCloseOthers() }
            Button("Close All Tabs") { onCloseAll() }
        }
    }
}

/// Wraps `TabChip` for a surface tab, observing only its own surface for title changes.
/// Scoping `@ObservedObject` here prevents whole-strip rebuilds on every title update.
private struct TerminalTabChip: View {
    @ObservedObject var surface: Ghostty.SurfaceView
    let toolName: String?
    let isActive: Bool
    let onActivate: () -> Void
    let onClose: () -> Void
    let onCloseOthers: () -> Void
    let onCloseAll: () -> Void

    var body: some View {
        TabChip(
            title: surface.title.isEmpty ? "Terminal" : surface.title,
            toolName: toolName,
            isActive: isActive,
            onActivate: onActivate,
            onClose: onClose,
            onCloseOthers: onCloseOthers,
            onCloseAll: onCloseAll
        )
    }
}

// MARK: - Main tab strip

/// Horizontal scrollable strip of tab chips for the main terminal panel of a worktree.
struct MainTerminalTabStrip: View {
    let worktreeId: String
    let onCloseTab: (UUID, String) -> Void

    @EnvironmentObject private var ghosttyApp: Ghostty.App
    @EnvironmentObject private var terminalManager: TerminalManager
    @EnvironmentObject private var worktreeManager: WorktreeManager
    @EnvironmentObject private var settings: SettingsManager
    @EnvironmentObject private var agentActivity: AgentActivityMonitor

    var body: some View {
        let tabs = terminalManager.mainTabs(for: worktreeId)
        // Only the zero-tab state hides the strip — `ContentView` renders its own "⌘T for a new
        // tab" placeholder there, which a strip holding nothing but a `+` would duplicate.
        if tabs.isEmpty {
            EmptyView()
        } else {
            HStack(spacing: 8) {
                tabsCapsule
                plusMenu
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 12)
        }
    }

    @ViewBuilder
    private var tabsCapsule: some View {
        if #available(macOS 26.0, *) {
            tabsContainer
                .padding(4)
                .glassEffect(in: Capsule())
                .overlay(
                    Capsule()
                        .strokeBorder(Color(nsColor: .separatorColor), lineWidth: 0.5)
                )
        } else {
            tabsContainer
                .padding(4)
                .background(.bar)
        }
    }

    private static let chipMinWidth: CGFloat = 140

    private var tabsContainer: some View {
        let tabs = terminalManager.mainTabs(for: worktreeId)
        let activeId = terminalManager.mainActiveTabId(for: worktreeId)
        return ViewThatFits(in: .horizontal) {
            equalWidthLayout(tabs: tabs, activeId: activeId)
            scrollableLayout(tabs: tabs, activeId: activeId)
        }
        .frame(height: 28)
    }

    private func equalWidthLayout(tabs: [TerminalTab], activeId: UUID?) -> some View {
        HStack(spacing: 4) {
            ForEach(tabs, id: \.id) { tab in
                chip(for: tab, isActive: tab.id == activeId)
                    .frame(minWidth: Self.chipMinWidth, maxWidth: .infinity)
            }
        }
    }

    private func scrollableLayout(tabs: [TerminalTab], activeId: UUID?) -> some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 4) {
                    ForEach(tabs, id: \.id) { tab in
                        chip(for: tab, isActive: tab.id == activeId)
                            .frame(width: Self.chipMinWidth)
                            .id(tab.id)
                    }
                }
            }
            .onChange(of: tabs.last?.id) { newLastId in
                guard let newLastId else { return }
                // Defer to the next runloop tick so SwiftUI finishes laying out
                // the appended chip before we ask for the new trailing offset — an agent
                // tab is appended from a `Task`, so the chip arrives after this fires.
                DispatchQueue.main.async {
                    withAnimation(.easeOut(duration: 0.2)) {
                        proxy.scrollTo(newLastId, anchor: .trailing)
                    }
                }
            }
        }
    }

    /// ⌘T and ⌥⌘T are declared here a second time — the File menu items declare them first. Both
    /// declarations run the same action on the same worktree, so whichever layer wins is correct,
    /// and `.keyboardShortcut` is the only way SwiftUI draws the glyph beside a menu row. Do not
    /// "fix" this by dropping them.
    ///
    /// That equivalence is what the `.disabled` below protects. The view hierarchy is offered a key
    /// equivalent before the main menu, so this menu answers ⌘T whenever it is enabled — and it
    /// resolves its worktree out of `worktreeManager.worktrees`, which `ContentView` deliberately
    /// lets go empty on a transient `git worktree list` failure rather than pruning live panes. The
    /// File menu's twin reads the stored `detailSelection` and survives that. Disabling on a nil
    /// worktree is what hands ⌘T back to it instead of swallowing the key.
    private var plusMenu: some View {
        Menu {
            Button("New Terminal") { newTerminal() }
                .keyboardShortcut("t", modifiers: .command)
            ForEach(
                agentMenuRows(agents: agentAllowlist, mainCommand: settings.configuredMainTerminalCommand),
                id: \.command
            ) { row in
                // Only the row carrying ⌥⌘T is the ⌥⌘T door, so only it refuses a launch already
                // in flight; picking a different agent is never a repeat of that press.
                Button(row.title) { newAgent(row.command, refuseWhenInFlight: row.carriesMainTerminalShortcut) }
                    .keyboardShortcut(
                        row.carriesMainTerminalShortcut
                            ? KeyboardShortcut("t", modifiers: [.command, .option])
                            : nil
                    )
            }
        } label: {
            Image(systemName: "plus")
                .font(.system(size: 12, weight: .medium))
                .frame(width: 28, height: 28)
                .contentShape(Rectangle())
        }
        .menuIndicator(.hidden)
        .menuStyle(.button)
        .buttonStyle(.plain)
        // Both preconditions its actions guard, or the menu opens and every row does nothing: a
        // transient `git worktree list` failure zeroes `worktrees` while these panes stay alive.
        .disabled(ghosttyApp.app == nil || worktree == nil)
    }

    private var worktree: Worktree? {
        worktreeManager.worktrees.first(where: { $0.id == worktreeId })
    }

    private func newTerminal() {
        guard let app = ghosttyApp.app, let worktree else { return }
        terminalManager.appendTab(for: worktree, app: app)
    }

    private func newAgent(_ command: String, refuseWhenInFlight: Bool) {
        guard let app = ghosttyApp.app, let worktree else { return }
        terminalManager.startAgentTab(
            for: worktree,
            app: app,
            command: command,
            refuseWhenInFlight: refuseWhenInFlight
        )
    }

    private func chip(for tab: TerminalTab, isActive: Bool) -> some View {
        let onActivate = { terminalManager.activateMainTab(id: tab.id, in: worktreeId) }
        let onClose = { onCloseTab(tab.id, worktreeId) }
        let onCloseOthers = {
            for other in terminalManager.mainTabs(for: worktreeId) where other.id != tab.id {
                onCloseTab(other.id, worktreeId)
            }
        }
        let onCloseAll = {
            for other in terminalManager.mainTabs(for: worktreeId) {
                onCloseTab(other.id, worktreeId)
            }
        }

        return TerminalTabChip(
            surface: tab.surface,
            toolName: agentActivity.surfaceToolNames[tab.surface.surfaceId.uuidString],
            isActive: isActive,
            onActivate: onActivate,
            onClose: onClose,
            onCloseOthers: onCloseOthers,
            onCloseAll: onCloseAll
        )
    }
}
