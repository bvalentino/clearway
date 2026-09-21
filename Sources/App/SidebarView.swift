import SwiftUI

/// Sheets presented from the sidebar.
private enum SidebarSheet: String, Identifiable {
    case createWorktree
    case debugTerminal
    case worktreeSettings

    var id: String { rawValue }
}

struct SidebarView: View {
    @EnvironmentObject private var worktreeManager: WorktreeManager
    @EnvironmentObject private var terminalManager: TerminalManager
    @EnvironmentObject private var workTaskManager: WorkTaskManager
    @EnvironmentObject private var agentActivity: AgentActivityMonitor
    @EnvironmentObject private var groupManager: WorktreeGroupManager
    @EnvironmentObject private var caffeine: CaffeineManager
    @EnvironmentObject private var settings: SettingsManager
    @Binding var sidebarSelection: DetailSelection?
    var ctrlHeld: Bool = false
    var onRemoveWorktree: ((Worktree) -> Void)?
    var onSearchActiveChanged: ((Bool) -> Void)?
    @State private var activeSheet: SidebarSheet?
    @State private var searchText = ""
    @State private var worktreeToRemove: Worktree?
    @State private var worktreeToClose: Worktree?
    @State private var worktreeToRename: Worktree?
    @State private var createWorktreeTargetGroupName: String?
    @State private var groupToRename: WorktreeGroup?
    @State private var groupToDelete: WorktreeGroup?
    @State private var showingNewGroupSheet: Bool = false
    @State private var defaultSectionTargeted: Bool = false
    @State private var targetedGroupName: String?
    @State private var targetedStatus: WorktreeStatus?

    private var isSearching: Bool { !searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    private var projectName: String {
        URL(fileURLWithPath: worktreeManager.projectPath).lastPathComponent
    }

    /// All worktrees in sidebar display order (default section then each group), filtered by search.
    private var orderedWorktrees: [Worktree] {
        let titles = workTaskManager.titlesByBranch
        return groupManager.sidebarOrderedWorktrees(
            worktreeManager.worktrees,
            showingDetached: settings.showDetachedWorktrees,
            openIds: terminalManager.openWorktreeIds
        ) { wt in
            groupManager.matches(wt, query: searchText, taskTitle: wt.branch.flatMap { titles[$0] })
        }
    }

    /// Worktrees in sidebar visible order (default section then groups), used to
    /// assign the `⌘N` badge position. Matches the ordering `ContentView` uses for
    /// the Cmd+1…9 key bindings so the badge and the shortcut target the same row.
    private var sortedWorktrees: [Worktree] {
        groupManager.sidebarOrderedWorktrees(
            worktreeManager.worktrees,
            showingDetached: settings.showDetachedWorktrees,
            openIds: terminalManager.openWorktreeIds
        ) { _ in true }
    }

    var body: some View {
        List(selection: $sidebarSelection) {
            tasksRow
            promptsRow
            commandsRow
            worktreeSections
        }
        .overlay(alignment: .bottomLeading) {
            caffeineButton
                .padding(12)
        }
        .listStyle(.sidebar)
        .safeAreaInset(edge: .top, spacing: 0) {
            Text(projectName)
                .font(.system(size: 13))
                .fontWeight(.semibold)
                .lineLimit(1)
                .frame(maxWidth: .infinity)
                .padding(.horizontal, 16)
                .padding(.top, 8)
                .padding(.bottom, 16)
        }
        .frame(minWidth: 200)
        .onChange(of: searchText) { onSearchActiveChanged?(!$0.isEmpty) }
        .onChange(of: worktreeManager.projectPath) { _ in searchText = "" }
        .sheet(item: $activeSheet, onDismiss: { createWorktreeTargetGroupName = nil }) { sheet in
            switch sheet {
            case .createWorktree:
                CreateWorktreeSheet(targetGroupName: createWorktreeTargetGroupName)
            case .debugTerminal:
                DebugTerminalSheet(
                    error: worktreeManager.error ?? "",
                    projectPath: worktreeManager.projectPath
                )
            case .worktreeSettings:
                WorktreeSettingsSheet(projectPath: worktreeManager.projectPath)
            }
        }
        .confirmationDialog(
            "Remove worktree \"\(worktreeToRemove.map { $0.displayName } ?? "")\"?",
            isPresented: Binding(
                get: { worktreeToRemove != nil },
                set: { if !$0 { worktreeToRemove = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("Remove", role: .destructive) {
                if let wt = worktreeToRemove {
                    // Delay so the confirmation dialog dismisses before any hook sheet presents
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                        onRemoveWorktree?(wt)
                    }
                }
                worktreeToRemove = nil
            }
        } message: {
            Text("This will delete the worktree and its working directory.")
        }
        .confirmationDialog(
            "Close worktree \"\(worktreeToClose.map { $0.displayName } ?? "")\"?",
            isPresented: Binding(
                get: { worktreeToClose != nil },
                set: { if !$0 { worktreeToClose = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("Close", role: .destructive) {
                if let wt = worktreeToClose {
                    terminalManager.closeWorktree(wt.id)
                }
                worktreeToClose = nil
            }
        } message: {
            Text("There are processes still running in this worktree's terminals.")
        }
        .sheet(item: $worktreeToRename) { wt in
            NameEntrySheet(
                title: "Rename Worktree",
                confirmTitle: "Save",
                initialName: groupManager.name(for: wt) ?? "",
                isValid: { _ in true }
            ) { newName in
                groupManager.setName(newName, for: wt)
                worktreeToRename = nil
            }
        }
        .sheet(item: $groupToRename) { group in
            NameEntrySheet(
                title: "Rename Group",
                confirmTitle: "Save",
                initialName: group.name,
                isValid: {
                    WorktreeGroup.available($0, in: groupManager.groups.map(\.name), renaming: group.name) != nil
                }
            ) { newName in
                groupManager.renameGroup(named: group.name, to: newName)
                groupToRename = nil
            }
        }
        .sheet(isPresented: $showingNewGroupSheet) {
            NameEntrySheet(
                title: "New Group",
                confirmTitle: "Create",
                isValid: { WorktreeGroup.available($0, in: groupManager.groups.map(\.name)) != nil }
            ) { name in
                groupManager.createGroup(named: name)
                showingNewGroupSheet = false
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .clearwayNewGroup)) { note in
            // Only the sidebar whose group manager matches the post's target should
            // present the sheet — the notification is broadcast to every mounted view.
            guard (note.object as? WorktreeGroupManager) === groupManager else { return }
            showingNewGroupSheet = true
        }
        .confirmationDialog(
            "Delete group \"\(groupToDelete?.name ?? "")\"?",
            isPresented: Binding(
                get: { groupToDelete != nil },
                set: { if !$0 { groupToDelete = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("Delete Group", role: .destructive) {
                if let group = groupToDelete {
                    groupManager.deleteGroup(named: group.name)
                }
                groupToDelete = nil
            }
        } message: {
            Text("Worktrees in this group will be ungrouped, not deleted.")
        }
    }

    // MARK: - Sections

    private var tasksRow: some View {
        let icon = workTaskManager.tasks.contains(where: { $0.worktree == nil }) ? "tray.full" : "tray"
        return destinationRow("Tasks", systemImage: icon, shortcutHint: "⌃1")
            .tag(DetailSelection.tasks)
    }

    private var promptsRow: some View {
        destinationRow("Prompts", systemImage: "text.quote", shortcutHint: "⌃2")
            .tag(DetailSelection.prompts)
    }

    private var commandsRow: some View {
        destinationRow("Commands", systemImage: "bolt", shortcutHint: "⌃3")
            .tag(DetailSelection.commands)
    }

    /// Top-level destination row whose icon gives way to its `⌃N` hint while
    /// Control is held, mirroring the worktree rows' `⌘N` badge style.
    private func destinationRow(_ title: String, systemImage: String, shortcutHint: String) -> some View {
        Label {
            Text(title)
        } icon: {
            SidebarIcon(systemImage: systemImage, shortcut: ctrlHeld ? shortcutHint : nil)
        }
    }

    /// Resolves the ordering, the task titles and the ⌘N positions once and hands each section
    /// its rows. Reading them inside a section re-ran the whole ordering once per section, and
    /// once more per rendered row.
    @ViewBuilder
    private var worktreeSections: some View {
        let ordered = orderedWorktrees
        let titles = workTaskManager.titlesByBranch
        let shortcuts = shortcutIndexes
        switch groupManager.grouping {
        case .group:
            let byGroup = Dictionary(grouping: ordered) { groupManager.groupName(for: $0.id) }
            worktreesSection(rows: byGroup[nil] ?? [], titles: titles, shortcuts: shortcuts, reorderable: true)
            ForEach(groupManager.groups) { group in
                groupSection(group, rows: byGroup[group.name] ?? [], titles: titles, shortcuts: shortcuts)
            }
        case .status:
            let byStatus = Dictionary(grouping: ordered) { groupManager.status(for: $0) }
            worktreesSection(rows: byStatus[nil] ?? [], titles: titles, shortcuts: shortcuts, reorderable: false)
            ForEach(WorktreeStatus.allCases) { status in
                statusSection(status, rows: byStatus[status] ?? [], titles: titles, shortcuts: shortcuts)
            }
        case .none:
            worktreesSection(rows: ordered, titles: titles, shortcuts: shortcuts, reorderable: false)
        }
    }

    /// Hands the manager the rendered rows in their new order, plus the whole worktree list the
    /// slots are numbered from — `rows` is only what survived the detached filter and the search
    /// field. `nil` names the ungrouped section.
    private func reorder(_ rows: [Worktree], from: IndexSet, to: Int, inGroupNamed name: String?) {
        var reordered = rows
        reordered.move(fromOffsets: from, toOffset: to)
        let ids = reordered.filter { !$0.isMain }.map(\.id)
        let worktrees = worktreeManager.worktrees
        let openIds = terminalManager.openWorktreeIds
        if let name {
            groupManager.setGroupOrder(named: name, ids: ids, in: worktrees, openIds: openIds)
        } else {
            groupManager.setUngroupedOrder(ids, in: worktrees, openIds: openIds)
        }
    }

    private func worktreesSection(
        rows: [Worktree],
        titles: [String: String],
        shortcuts: [String: Int],
        reorderable: Bool
    ) -> some View {
        Section {
            SearchField(text: $searchText, placeholder: "Filter")
                .listRowInsets(EdgeInsets(top: 4, leading: -4, bottom: 4, trailing: -4))
                .listRowSeparator(.hidden)

            ForEach(rows) { wt in
                worktreeRowView(
                    for: wt,
                    titles: titles,
                    shortcuts: shortcuts,
                    moveDisabled: !reorderable || wt.isMain || isSearching
                )
            }
            .onMove { from, to in reorder(rows, from: from, to: to, inGroupNamed: nil) }

            if worktreeManager.isLoading {
                HStack {
                    ProgressView().controlSize(.small)
                    Text("Loading...").foregroundStyle(.secondary)
                }
            }

            if let error = worktreeManager.error {
                VStack(alignment: .leading, spacing: 6) {
                    Label("Error loading worktrees", systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.red)
                        .font(.caption.bold())
                    Text(error)
                        .foregroundStyle(.secondary)
                        .font(.caption)
                        .lineLimit(3)
                    Text("Click to open debug terminal")
                        .foregroundStyle(.tertiary)
                        .font(.caption2)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(8)
                .background(Color(.controlBackgroundColor).opacity(0.5))
                .cornerRadius(4)
                .contentShape(Rectangle())
                .onTapGesture { activeSheet = .debugTerminal }
                .accessibilityAddTraits(.isButton)
                .accessibilityLabel("Open debug terminal")
            }
        } header: {
            worktreesSectionHeader
        }
    }

    @ViewBuilder
    private var worktreesSectionHeader: some View {
        let header = HStack {
            Text("Worktrees")
            Spacer()
            SidebarHeaderButton(systemImage: "arrow.clockwise") {
                worktreeManager.refresh()
            }
            .padding(.trailing, -6)

            GroupByMenu { activeSheet = .worktreeSettings }
                .padding(.trailing, -6)

            SidebarHeaderButton(systemImage: "plus") {
                createWorktreeTargetGroupName = nil
                activeSheet = .createWorktree
            }
            .padding(.trailing, 6)
        }
        .background(defaultSectionTargeted ? Color.accentColor.opacity(0.12) : Color.clear)

        // `.none` sections by nothing, so a drop here would silently rewrite the group
        // membership that view does not show.
        if groupManager.grouping == .none {
            header
        } else {
            header.dropDestination(for: String.self) { ids, _ in
                dropIntoWorktreesHeader(ids)
                return true
            } isTargeted: { defaultSectionTargeted = $0 }
        }
    }

    @ViewBuilder
    private func groupSection(
        _ group: WorktreeGroup,
        rows: [Worktree],
        titles: [String: String],
        shortcuts: [String: Int]
    ) -> some View {
        // Only an active filter with zero matches hides the section — empty (new) groups stay visible.
        if !(isSearching && rows.isEmpty) {
            let isGroupTargeted = Binding(
                get: { targetedGroupName == group.name },
                set: { targetedGroupName = $0 ? group.name : nil }
            )
            Section {
                ForEach(rows) { wt in
                    worktreeRowView(for: wt, titles: titles, shortcuts: shortcuts, moveDisabled: isSearching)
                }
                .onMove { from, to in reorder(rows, from: from, to: to, inGroupNamed: group.name) }
            } header: {
                GroupSectionHeader(
                    group: group,
                    onPlus: {
                        createWorktreeTargetGroupName = group.name
                        activeSheet = .createWorktree
                    },
                    onRename: { groupToRename = group },
                    onDelete: { groupToDelete = group }
                )
                .background(isGroupTargeted.wrappedValue ? Color.accentColor.opacity(0.12) : Color.clear)
                .dropDestination(for: String.self) { ids, _ in
                    dropIntoGroup(ids, groupNamed: group.name)
                    return true
                } isTargeted: { isGroupTargeted.wrappedValue = $0 }
            }
        }
    }

    /// All five statuses render even when empty, the rule groups follow.
    @ViewBuilder
    private func statusSection(
        _ status: WorktreeStatus,
        rows: [Worktree],
        titles: [String: String],
        shortcuts: [String: Int]
    ) -> some View {
        if !(isSearching && rows.isEmpty) {
            Section {
                ForEach(rows) { wt in
                    worktreeRowView(for: wt, titles: titles, shortcuts: shortcuts, moveDisabled: true)
                }
            } header: {
                // A row's own `Label` over a row's own icon slot, so the header's two columns are
                // the rows' rather than numbers of its own. The style is stated because a header
                // is free to resolve `Label` to another one.
                Label {
                    Text(status.displayName)
                        .foregroundStyle(.primary)
                } icon: {
                    SidebarIcon(systemImage: status.symbol)
                        .foregroundStyle(status.color)
                }
                .labelStyle(.titleAndIcon)
                .padding(.leading, SidebarRowMetrics.headerLeadingInset)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(targetedStatus == status ? Color.accentColor.opacity(0.12) : Color.clear)
                .dropDestination(for: String.self) { ids, _ in
                    applyStatus(status, to: ids)
                    return true
                } isTargeted: { targetedStatus = $0 ? status : nil }
            }
        }
    }

    // MARK: - Context Menu

    @ViewBuilder
    private func worktreeContextMenu(_ wt: Worktree) -> some View {
        Button("Close Worktree") {
            if terminalManager.worktreeNeedsConfirmClose(wt.id) {
                worktreeToClose = wt
            } else {
                terminalManager.closeWorktree(wt.id)
            }
        }
        .disabled(wt.isMain || !terminalManager.isOpen(wt))

        Button("Remove Worktree") {
            worktreeToRemove = wt
        }
        .disabled(wt.isMain || wt.branch == nil)

        Divider()

        if !wt.isMain {
            Button("Rename…") {
                worktreeToRename = wt
            }

            Menu("Status") {
                Picker("Status", selection: Binding(
                    get: { groupManager.status(for: wt) },
                    set: { groupManager.setStatus($0, for: wt) }
                )) {
                    Text("None").tag(WorktreeStatus?.none)
                    ForEach(WorktreeStatus.allCases) { status in
                        WorktreeStatusLabel(status: status)
                            .tag(Optional(status))
                    }
                }
                .pickerStyle(.inline)
                .labelsHidden()
            }

            Divider()
        }

        if !settings.openInApps.isEmpty, let path = wt.path {
            OpenInMenu(path: path)
        }

        Button("Reveal in Finder") {
            if let path = wt.path {
                NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: path)
            }
        }

        Button("Copy Path") {
            if let path = wt.path {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(path, forType: .string)
            }
        }
    }

    // MARK: - Floating Buttons

    private var caffeineButton: some View {
        FloatingSidebarButton(
            systemImage: caffeine.isActive ? "cup.and.saucer.fill" : "cup.and.saucer",
            isActive: caffeine.isActive,
            help: caffeine.isActive
                ? "Caffeine on — your Mac won't sleep or start the screensaver. Click to turn off."
                : "Keep your Mac awake: prevents display sleep and the screensaver while long tasks run. Click to turn on.",
            action: caffeine.toggle
        )
    }

    // MARK: - Helpers

    /// The ⌘1…9 position of each worktree that has one, keyed by ID.
    private var shortcutIndexes: [String: Int] {
        Dictionary(
            uniqueKeysWithValues: sortedWorktrees.prefix(9).enumerated().map { ($1.id, $0 + 1) }
        )
    }

    @ViewBuilder
    private func worktreeRowView(
        for wt: Worktree,
        titles: [String: String],
        shortcuts: [String: Int],
        moveDisabled: Bool
    ) -> some View {
        let isOpen = terminalManager.isOpen(wt)
        let hasNotification = terminalManager.notifiedWorktrees.contains(wt.id)
        let phase = isOpen ? agentActivity.worktreePhases[wt.id] ?? .idle : .idle
        let subagents = isOpen ? agentActivity.worktreeSubagents[wt.id] ?? [] : []
        let shortcut = isSearching || !isOpen ? nil : shortcuts[wt.id]
        let (primaryText, subtitle) = WorktreeRow.rowTexts(
            for: wt,
            name: groupManager.name(for: wt),
            taskTitle: wt.branch.flatMap { titles[$0] }
        )
        WorktreeRow(
            worktree: wt,
            primaryText: primaryText,
            subtitle: subtitle,
            hasNotification: hasNotification,
            phase: phase,
            shortcutIndex: shortcut,
            status: groupManager.grouping == .status ? nil : groupManager.status(for: wt)
        )
            .tag(DetailSelection.worktree(wt))
            .opacity(isOpen ? 1.0 : 0.5)
            .contextMenu { worktreeContextMenu(wt) }
            .draggableIf(!wt.isMain && groupManager.grouping != .none, id: wt.id) { WorktreeDragChip() }
            .moveDisabled(moveDisabled)
        // No `.tag`, so these carry no selection, the way the search, loading and error rows do.
        ForEach(subagents) { subagent in
            SubagentRow(subagent: subagent)
                .moveDisabled(true)
        }
    }

    // Defer @Published mutation past the NSTableView drop delegate to avoid a reentrant-list warning.
    private func withDroppedWorktrees(_ ids: [String], _ apply: @escaping (Worktree) -> Void) {
        DispatchQueue.main.async {
            let wts = worktreeManager.worktrees
            ids.compactMap { id in wts.first { $0.id == id } }.forEach(apply)
        }
    }

    private func dropIntoGroup(_ ids: [String], groupNamed name: String) {
        withDroppedWorktrees(ids) { groupManager.addWorktree($0, toGroupNamed: name) }
    }

    /// The Worktrees header clears whichever axis the current view sections by, never both.
    private func dropIntoWorktreesHeader(_ ids: [String]) {
        switch groupManager.grouping {
        case .group:
            withDroppedWorktrees(ids) { groupManager.removeWorktreeFromGroup($0) }
        case .status: applyStatus(nil, to: ids)
        case .none: break
        }
    }

    private func applyStatus(_ status: WorktreeStatus?, to ids: [String]) {
        withDroppedWorktrees(ids) { groupManager.setStatus(status, for: $0) }
    }
}

// MARK: - Drag Preview

/// Chip shown under the cursor while dragging a worktree. Replaces SwiftUI's
/// default live-snapshot drag preview, which lingers on screen after drop
/// because of a macOS rendering quirk.
private struct WorktreeDragChip: View {
    var body: some View {
        Image(systemName: "square.on.square.intersection.dashed")
            .font(.system(size: 14, weight: .medium))
            .foregroundStyle(.primary)
            .frame(width: 28, height: 28)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 6))
    }
}

// MARK: - Group Section Header

private struct GroupSectionHeader: View {
    let group: WorktreeGroup
    let onPlus: () -> Void
    let onRename: () -> Void
    let onDelete: () -> Void

    var body: some View {
        HStack {
            Text(group.name)
                .lineLimit(1)
            Spacer()
            SidebarHeaderMenu(systemImage: "ellipsis") {
                Button("Rename Group", action: onRename)
                Button("Delete Group", role: .destructive, action: onDelete)
            }
            .padding(.trailing, -6)
            SidebarHeaderButton(systemImage: "plus", action: onPlus)
                .padding(.trailing, 6)
        }
        .contextMenu {
            Button("Rename Group", action: onRename)
            Button("Delete Group", role: .destructive, action: onDelete)
        }
    }
}

/// Native NSSearchField wrapped for SwiftUI — matches the system search field appearance.
private struct SearchField: NSViewRepresentable {
    @Binding var text: String
    var placeholder: String

    func makeNSView(context: Context) -> NSSearchField {
        let field = NSSearchField()
        field.placeholderString = placeholder
        field.delegate = context.coordinator
        field.focusRingType = .none
        field.bezelStyle = .roundedBezel
        field.controlSize = .regular
        return field
    }

    func updateNSView(_ nsView: NSSearchField, context: Context) {
        if nsView.stringValue != text {
            nsView.stringValue = text
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(text: $text)
    }

    class Coordinator: NSObject, NSSearchFieldDelegate {
        @Binding var text: String
        init(text: Binding<String>) { _text = text }

        func controlTextDidChange(_ notification: Notification) {
            guard let field = notification.object as? NSSearchField else { return }
            text = field.stringValue
        }
    }
}

/// Circular floating button used in the sidebar's bottom-leading overlay
/// (caffeine). Matches the shared 36pt thinMaterial + shadow pattern.
private struct FloatingSidebarButton: View {
    let systemImage: String
    let isActive: Bool
    let help: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 16, weight: .medium))
                .foregroundStyle(isActive ? .primary : .secondary)
                .frame(width: 36, height: 36)
                .background(.thinMaterial, in: Circle())
                .shadow(color: .black.opacity(0.15), radius: 4, y: 2)
        }
        .buttonStyle(.plain)
        .help(help)
    }
}

// MARK: - View Helpers

// Using `.draggable`/`.dropDestination` (macOS 13+); fall back to `.onDrag`/`.onDrop` if sidebar gesture conflicts surface in QA.
extension View {
    @ViewBuilder
    fileprivate func draggableIf<Preview: View>(
        _ condition: Bool,
        id: String,
        @ViewBuilder preview: () -> Preview
    ) -> some View {
        if condition { self.draggable(id, preview: preview) } else { self }
    }
}
