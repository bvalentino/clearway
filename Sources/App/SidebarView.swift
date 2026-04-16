import SwiftUI

/// Sheets presented from the sidebar.
private enum SidebarSheet: String, Identifiable {
    case createWorktree
    case debugTerminal

    var id: String { rawValue }
}

struct SidebarView: View {
    @EnvironmentObject private var worktreeManager: WorktreeManager
    @EnvironmentObject private var terminalManager: TerminalManager
    @EnvironmentObject private var workTaskManager: WorkTaskManager
    @EnvironmentObject private var claudeActivityMonitor: ClaudeActivityMonitor
    @EnvironmentObject private var groupManager: WorktreeGroupManager
    @Binding var sidebarSelection: DetailSelection?
    @Binding var detailSelection: DetailSelection?
    var onRemoveWorktree: ((Worktree) -> Void)?
    var onSearchActiveChanged: ((Bool) -> Void)?
    @State private var activeSheet: SidebarSheet?
    @State private var searchText = ""
    @State private var worktreeToRemove: Worktree?
    @State private var worktreeToClose: Worktree?
    @State private var selectionBeforeSettings: DetailSelection?
    @State private var createWorktreeTargetGroupId: UUID?
    @State private var groupToRename: WorktreeGroup?
    @State private var groupToDelete: WorktreeGroup?
    @State private var showingNewGroupSheet: Bool = false
    @State private var defaultSectionTargeted: Bool = false
    @State private var targetedGroupId: UUID?

    private var isSearching: Bool { !searchText.isEmpty }

    private var projectName: String {
        URL(fileURLWithPath: worktreeManager.projectPath).lastPathComponent
    }

    /// All worktrees in sidebar display order (default section then each group), filtered by search.
    private var orderedWorktrees: [Worktree] {
        let titles = workTaskManager.titlesByBranch
        return groupManager.sidebarOrderedWorktrees(
            worktreeManager.worktrees,
            openIds: terminalManager.openWorktreeIds
        ) { wt in
            guard isSearching else { return true }
            if wt.displayName.localizedCaseInsensitiveContains(searchText) { return true }
            if let branch = wt.branch,
               let title = titles[branch],
               title.localizedCaseInsensitiveContains(searchText) { return true }
            // Match the worktree when its containing group's name matches the query,
            // so filtering by group surfaces all members under that header.
            if let groupId = groupManager.groupId(for: wt.id),
               let group = groupManager.groups.first(where: { $0.id == groupId }),
               group.name.localizedCaseInsensitiveContains(searchText) { return true }
            return false
        }
    }

    /// Worktrees in sidebar visible order (default section then groups), used to
    /// assign the `⌘N` badge position. Matches the ordering `ContentView` uses for
    /// the Cmd+1…9 key bindings so the badge and the shortcut target the same row.
    private var sortedWorktrees: [Worktree] {
        groupManager.sidebarOrderedWorktrees(
            worktreeManager.worktrees,
            openIds: terminalManager.openWorktreeIds
        ) { _ in true }
    }

    var body: some View {
        List(selection: $sidebarSelection) {
            planningRow
            promptsRow
            defaultWorktreeSection
            ForEach(groupManager.groups) { group in
                groupSection(group)
            }
        }
        .overlay(alignment: .bottomLeading) {
            Button {
                if detailSelection == .settings {
                    detailSelection = selectionBeforeSettings ?? .planning
                    selectionBeforeSettings = nil
                } else {
                    selectionBeforeSettings = detailSelection
                    detailSelection = .settings
                }
            } label: {
                Image(systemName: "gear")
                    .font(.system(size: 16, weight: .medium))
                    .foregroundStyle(detailSelection == .settings ? .primary : .secondary)
                    .frame(width: 36, height: 36)
                    .background(.thinMaterial, in: Circle())
                    .shadow(color: .black.opacity(0.15), radius: 4, y: 2)
            }
            .buttonStyle(.plain)
            .help("Project Settings")
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
        .sheet(item: $activeSheet, onDismiss: { createWorktreeTargetGroupId = nil }) { sheet in
            switch sheet {
            case .createWorktree:
                CreateWorktreeSheet(targetGroupId: createWorktreeTargetGroupId)
            case .debugTerminal:
                DebugTerminalSheet(
                    error: worktreeManager.error ?? "",
                    projectPath: worktreeManager.projectPath
                )
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
        .sheet(item: $groupToRename) { group in
            RenameGroupSheet(group: group) { newName in
                groupManager.renameGroup(id: group.id, to: newName)
                groupToRename = nil
            }
        }
        .sheet(isPresented: $showingNewGroupSheet) {
            NewGroupSheet { name in
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
                    groupManager.deleteGroup(id: group.id)
                }
                groupToDelete = nil
            }
        } message: {
            Text("Worktrees in this group will be ungrouped, not deleted.")
        }
    }

    // MARK: - Sections

    private var planningRow: some View {
        let icon = workTaskManager.tasks.contains(where: { $0.status.isBacklog }) ? "tray.full" : "tray"
        return Label("Planning", systemImage: icon)
            .tag(DetailSelection.planning)
    }

    private var promptsRow: some View {
        Label("Prompts", systemImage: "text.quote")
            .tag(DetailSelection.prompts)
    }

    private var defaultWorktreeSection: some View {
        let rows = orderedWorktrees.filter { groupManager.groupId(for: $0.id) == nil }
        let titles = workTaskManager.titlesByBranch
        return Section {
            SearchField(text: $searchText, placeholder: "Filter")
                .listRowInsets(EdgeInsets(top: 4, leading: -4, bottom: 4, trailing: -4))
                .listRowSeparator(.hidden)

            ForEach(rows) { wt in
                worktreeRowView(for: wt, titles: titles, moveDisabled: wt.isMain || isSearching)
            }
            .onMove { from, to in
                guard !isSearching else { return }
                var reordered = rows
                reordered.move(fromOffsets: from, toOffset: to)
                groupManager.setDefaultOrder(reordered.filter { !$0.isMain }.map(\.id))
            }

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
            HStack {
                Text("Worktrees")
                Spacer()
                SidebarHeaderButton(systemImage: "arrow.clockwise") {
                    worktreeManager.refresh()
                }
                .padding(.trailing, -6)

                SidebarHeaderButton(systemImage: "plus") {
                    createWorktreeTargetGroupId = nil
                    activeSheet = .createWorktree
                }
                .padding(.trailing, 6)
            }
            .background(defaultSectionTargeted ? Color.accentColor.opacity(0.12) : Color.clear)
            .dropDestination(for: String.self) { ids, _ in
                dropIntoDefault(ids)
                return true
            } isTargeted: { defaultSectionTargeted = $0 }
        }
    }

    @ViewBuilder
    private func groupSection(_ group: WorktreeGroup) -> some View {
        let rows = orderedWorktrees.filter { groupManager.groupId(for: $0.id) == group.id }
        let titles = workTaskManager.titlesByBranch
        // Only an active filter with zero matches hides the section — empty (new) groups stay visible.
        if !(isSearching && rows.isEmpty) {
            let isGroupTargeted = Binding(get: { targetedGroupId == group.id }, set: { targetedGroupId = $0 ? group.id : nil })
            Section {
                ForEach(rows) { wt in
                    worktreeRowView(for: wt, titles: titles, moveDisabled: isSearching)
                }
                .onMove { from, to in
                    guard !isSearching else { return }
                    var reordered = rows
                    reordered.move(fromOffsets: from, toOffset: to)
                    groupManager.setGroupOrder(id: group.id, ids: reordered.map(\.id))
                }
            } header: {
                GroupSectionHeader(
                    group: group,
                    onPlus: {
                        createWorktreeTargetGroupId = group.id
                        activeSheet = .createWorktree
                    },
                    onRename: { groupToRename = group },
                    onDelete: { groupToDelete = group }
                )
                .background(isGroupTargeted.wrappedValue ? Color.accentColor.opacity(0.12) : Color.clear)
                .dropDestination(for: String.self) { ids, _ in
                    dropIntoGroup(ids, groupId: group.id)
                    return true
                } isTargeted: { isGroupTargeted.wrappedValue = $0 }
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

    // MARK: - Helpers

    private func shortcutIndex(for wt: Worktree) -> Int? {
        guard let i = sortedWorktrees.firstIndex(where: { $0.id == wt.id }), i < 9 else { return nil }
        return i + 1
    }

    /// Whether the row should render as visually primary (full opacity, shortcut shown).
    /// Main stays visually primary even when no pane exists so it never looks unreachable.
    private func showsAsPrimary(_ wt: Worktree) -> Bool {
        wt.isMain || terminalManager.isOpen(wt)
    }

    /// Computes the (primaryText, subtitle) pair for a worktree row.
    /// For the main worktree the stable branch name is the primary label.
    /// For non-main worktrees a linked task title (if any) is primary, with the branch as subtitle.
    private func rowTexts(
        for wt: Worktree,
        titles: [String: String]
    ) -> (primaryText: String?, subtitle: String?) {
        let primaryText = wt.branch.flatMap { titles[$0] }
        let subtitle: String? = primaryText == nil ? nil : wt.displayName
        return (primaryText, subtitle)
    }

    @ViewBuilder
    private func worktreeRowView(
        for wt: Worktree,
        titles: [String: String],
        moveDisabled: Bool
    ) -> some View {
        let isPrimary = showsAsPrimary(wt)
        let isOpen = terminalManager.isOpen(wt)
        let hasNotification = terminalManager.notifiedWorktrees.contains(wt.id)
        let isWorking = isOpen && !wt.isMain && claudeActivityMonitor.workingWorktreeIds.contains(wt.id)
        let shortcut = isSearching || !isPrimary ? nil : shortcutIndex(for: wt)
        let (primaryText, subtitle) = rowTexts(
            for: wt,
            titles: titles
        )
        WorktreeRow(
            worktree: wt,
            primaryText: primaryText,
            subtitle: subtitle,
            hasNotification: hasNotification,
            isWorking: isWorking,
            shortcutIndex: shortcut
        )
            .tag(DetailSelection.worktree(wt))
            .opacity(isPrimary ? 1.0 : 0.5)
            .contextMenu { worktreeContextMenu(wt) }
            .draggableIf(!wt.isMain, id: wt.id) { WorktreeDragChip() }
            .moveDisabled(moveDisabled)
    }

    // Defer @Published mutation past the NSTableView drop delegate to avoid a reentrant-list warning.
    private func dropIntoGroup(_ ids: [String], groupId: UUID) {
        DispatchQueue.main.async {
            let wts = worktreeManager.worktrees
            ids.compactMap { id in wts.first { $0.id == id } }
                .forEach { groupManager.addWorktree($0, toGroup: groupId) }
        }
    }

    private func dropIntoDefault(_ ids: [String]) {
        DispatchQueue.main.async { ids.forEach { groupManager.removeWorktreeFromAllGroups($0) } }
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

// MARK: - Worktree Row

struct WorktreeRow: View {
    let worktree: Worktree
    var primaryText: String? = nil
    var subtitle: String? = nil
    var hasNotification: Bool = false
    var isWorking: Bool = false
    var shortcutIndex: Int? = nil
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
            if let index = shortcutIndex {
                Text("⌘\(index)")
                    .font(.caption2.monospaced())
                    .foregroundStyle(.tertiary)
            } else {
                Image(systemName: "square.on.square.intersection.dashed")
            }
        }
    }
}

// MARK: - Create Worktree Sheet

struct CreateWorktreeSheet: View {
    let targetGroupId: UUID?
    @EnvironmentObject private var worktreeManager: WorktreeManager
    @EnvironmentObject private var groupManager: WorktreeGroupManager
    @Environment(\.dismiss) private var dismiss
    @State private var branchName = ""
    @State private var baseBranch = ""
    @State private var fetchBeforeCreate = true
    @State private var isCreating = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("New Worktree")
                .font(.headline)
                .frame(maxWidth: .infinity, alignment: .center)

            TextField("Branch name", text: $branchName)
                .textFieldStyle(.roundedBorder)
                .onChange(of: branchName) { newValue in
                    let sanitized = newValue.replacingOccurrences(of: " ", with: "-")
                    if sanitized != newValue { branchName = sanitized }
                }
                .disabled(isCreating)

            TextField("Base branch (new branches only)", text: $baseBranch)
                .textFieldStyle(.roundedBorder)
                .disabled(isCreating)
                .opacity(isCreating ? 0.5 : 1.0)

            Toggle("Fetch before creating", isOn: $fetchBeforeCreate)
                .disabled(isCreating)

            HStack {
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                    .disabled(isCreating)
                Spacer()
                Button {
                    isCreating = true
                    Task {
                        let created = await worktreeManager.createWorktree(
                            branch: branchName,
                            base: baseBranch.isEmpty ? nil : baseBranch,
                            fetch: fetchBeforeCreate
                        )
                        if worktreeManager.error == nil {
                            if let created, let targetGroupId {
                                groupManager.addWorktree(created, toGroup: targetGroupId)
                            } else if targetGroupId != nil {
                                Ghostty.logger.warning("CreateWorktreeSheet: worktree creation succeeded but return lookup failed; new worktree will be ungrouped")
                            }
                            dismiss()
                        } else {
                            isCreating = false
                        }
                    }
                } label: {
                    if isCreating {
                        HStack(spacing: 6) {
                            ProgressView()
                                .controlSize(.small)
                            Text("Creating…")
                        }
                    } else {
                        Text("Create")
                    }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(branchName.isEmpty || isCreating)
            }
        }
        .padding(20)
        .frame(width: 320)
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
            Menu {
                Button("Rename Group", action: onRename)
                Button("Delete Group", role: .destructive, action: onDelete)
            } label: {
                Image(systemName: "ellipsis")
                    .font(.body)
                    .frame(width: 24, height: 24)
                    .contentShape(Rectangle())
                    .foregroundStyle(.secondary)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
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

// MARK: - Rename Group Sheet

private struct RenameGroupSheet: View {
    let group: WorktreeGroup
    let onSave: (String) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var name: String

    init(group: WorktreeGroup, onSave: @escaping (String) -> Void) {
        self.group = group
        self.onSave = onSave
        _name = State(initialValue: group.name)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Rename Group")
                .font(.headline)
                .frame(maxWidth: .infinity, alignment: .center)

            TextField("Group name", text: $name)
                .textFieldStyle(.roundedBorder)

            HStack {
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Spacer()
                Button("Save") {
                    onSave(name)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 320)
    }
}

// MARK: - New Group Sheet

private struct NewGroupSheet: View {
    let onCreate: (String) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var name: String = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("New Group")
                .font(.headline)
                .frame(maxWidth: .infinity, alignment: .center)

            TextField("Group name", text: $name)
                .textFieldStyle(.roundedBorder)

            HStack {
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Spacer()
                Button("Create") {
                    onCreate(name)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 320)
    }
}

// MARK: - Sidebar Header Button

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

private struct SidebarHeaderButton: View {
    let systemImage: String
    let action: () -> Void
    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.body)
                .frame(width: 24, height: 24)
                .contentShape(Rectangle())
                .foregroundStyle(isHovering ? .primary : .secondary)
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
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
