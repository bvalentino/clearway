import SwiftUI

// MARK: - Chip subviews

/// A tab chip: an optional workflow step badge, the title, and the close button that appears on
/// hover or while active.
private struct TabChip: View {
    let stepName: String?
    let title: String
    let isActive: Bool
    let onActivate: () -> Void
    let onClose: () -> Void
    let onCloseOthers: () -> Void
    let onCloseAll: () -> Void

    @State private var isHovering = false

    var body: some View {
        HStack(spacing: 4) {
            if let stepName {
                WorkflowStepBadge(name: stepName, tint: isActive ? .white : .primary)
            }

            Text(title)
                .lineLimit(1)
                .truncationMode(.tail)
                .font(.system(size: 12))
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
    let stepName: String?
    let isActive: Bool
    let onActivate: () -> Void
    let onClose: () -> Void
    let onCloseOthers: () -> Void
    let onCloseAll: () -> Void

    var body: some View {
        TabChip(
            stepName: stepName,
            title: surface.title.isEmpty ? "Terminal" : surface.title,
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
    @EnvironmentObject private var workTaskCoordinator: WorkTaskCoordinator

    var body: some View {
        let tabs = terminalManager.mainTabs(for: worktreeId)
        // Only the zero-tab state hides the strip — `ContentView` renders its own "⌘T for a new
        // tab" placeholder there, which a strip holding nothing but a `+` would duplicate.
        if tabs.isEmpty {
            EmptyView()
        } else {
            HStack(spacing: 8) {
                tabsCapsule
                plusButton
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

    /// A badged chip spends width on the step name before the title gets any, so the strip
    /// widens its chips whenever a workflow step is on screen.
    private static let badgedChipMinWidth: CGFloat = 200

    private var tabsContainer: some View {
        let tabs = terminalManager.mainTabs(for: worktreeId)
        let activeId = terminalManager.mainActiveTabId(for: worktreeId)
        let minWidth = tabs.contains(where: { $0.stepSlug != nil }) ? Self.badgedChipMinWidth : Self.chipMinWidth
        return ViewThatFits(in: .horizontal) {
            equalWidthLayout(tabs: tabs, activeId: activeId, minWidth: minWidth)
            scrollableLayout(tabs: tabs, activeId: activeId, minWidth: minWidth)
        }
        .frame(height: 28)
    }

    private func equalWidthLayout(tabs: [TerminalTab], activeId: UUID?, minWidth: CGFloat) -> some View {
        HStack(spacing: 4) {
            ForEach(tabs, id: \.id) { tab in
                chip(for: tab, isActive: tab.id == activeId)
                    .frame(minWidth: minWidth, maxWidth: .infinity)
            }
        }
    }

    private func scrollableLayout(tabs: [TerminalTab], activeId: UUID?, minWidth: CGFloat) -> some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 4) {
                    ForEach(tabs, id: \.id) { tab in
                        chip(for: tab, isActive: tab.id == activeId)
                            .frame(width: minWidth)
                            .id(tab.id)
                    }
                }
            }
            .onChange(of: tabs.last?.id) { newLastId in
                guard let newLastId else { return }
                // Defer to the next runloop tick so SwiftUI finishes laying out
                // the appended chip (and any synchronous follow-up mutations like
                // `promoteLauncher`) before we ask for the new trailing offset.
                DispatchQueue.main.async {
                    withAnimation(.easeOut(duration: 0.2)) {
                        proxy.scrollTo(newLastId, anchor: .trailing)
                    }
                }
            }
        }
    }

    private var plusButton: some View {
        Button {
            guard let app = ghosttyApp.app,
                  let worktree = worktreeManager.worktrees.first(where: { $0.id == worktreeId }) else { return }
            terminalManager.appendLauncherTab(for: worktree, app: app)
        } label: {
            Image(systemName: "plus")
                .font(.system(size: 12, weight: .medium))
                .frame(width: 28, height: 28)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(ghosttyApp.app == nil)
    }

    /// The action's current name from `WORKFLOW.json`, so a rename shows up without touching the
    /// tab, falling back to the frozen slug's humanized form.
    private func stepName(for tab: TerminalTab) -> String? {
        guard let slug = tab.stepSlug else { return nil }
        return workTaskCoordinator.workflowActionName(slug) ?? WorkTask.displayLabel(for: slug)
    }

    @ViewBuilder
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

        switch tab.kind {
        case .launcher:
            TabChip(
                stepName: stepName(for: tab),
                title: "New Tab",
                isActive: isActive,
                onActivate: onActivate,
                onClose: onClose,
                onCloseOthers: onCloseOthers,
                onCloseAll: onCloseAll
            )
        case .surface(let surface):
            TerminalTabChip(
                surface: surface,
                stepName: stepName(for: tab),
                isActive: isActive,
                onActivate: onActivate,
                onClose: onClose,
                onCloseOthers: onCloseOthers,
                onCloseAll: onCloseAll
            )
        }
    }
}
