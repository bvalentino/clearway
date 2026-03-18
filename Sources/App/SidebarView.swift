import SwiftUI

/// Sheets presented from the sidebar.
private enum SidebarSheet: String, Identifiable {
    case createWorktree
    case projectSettings
    case debugTerminal

    var id: String { rawValue }
}

struct SidebarView: View {
    @EnvironmentObject private var worktreeManager: WorktreeManager
    @EnvironmentObject private var terminalManager: TerminalManager
    @EnvironmentObject private var projectList: ProjectListManager
    @EnvironmentObject private var workTaskManager: WorkTaskManager
    @Environment(\.openWindow) private var openWindow
    @Binding var detailSelection: DetailSelection?
    var onRemoveWorktree: ((Worktree) -> Void)?
    var onSearchActiveChanged: ((Bool) -> Void)?
    @State private var activeSheet: SidebarSheet?
    @State private var searchText = ""
    @State private var worktreeToRemove: Worktree?
    @State private var worktreeToClose: Worktree?

    private var isSearching: Bool { !searchText.isEmpty }

    private var sortedWorktrees: [Worktree] {
        Worktree.sorted(worktreeManager.worktrees, openIds: terminalManager.openWorktreeIds)
    }

    private var filteredWorktrees: [Worktree] {
        guard isSearching else { return sortedWorktrees }
        return sortedWorktrees.filter { wt in
            wt.displayName.localizedCaseInsensitiveContains(searchText)
            || (worktreeManager.subtitle(for: wt)?.localizedCaseInsensitiveContains(searchText) ?? false)
        }
    }

    private var selectedWorktree: Worktree? { detailSelection?.worktree }

    var body: some View {
        List(selection: $detailSelection) {
            projectSection
            tasksRow
            worktreeSection
        }
        .listStyle(.sidebar)
        .searchable(text: $searchText, placement: .sidebar, prompt: "Filter")
        .frame(minWidth: 200)
        .onChange(of: searchText) { onSearchActiveChanged?(!$0.isEmpty) }
        .onChange(of: worktreeManager.projectPath) { _ in searchText = "" }
        .sheet(item: $activeSheet) { sheet in
            switch sheet {
            case .createWorktree:
                CreateWorktreeSheet()
            case .projectSettings:
                ProjectSettingsView(projectPath: worktreeManager.projectPath)
            case .debugTerminal:
                DebugTerminalSheet(
                    error: worktreeManager.error ?? "",
                    projectPath: worktreeManager.projectPath
                )
            }
        }
        .confirmationDialog(
            "Remove worktree \"\(worktreeToRemove?.displayName ?? "")\"?",
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
            "Close worktree \"\(worktreeToClose?.displayName ?? "")\"?",
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
    }

    // MARK: - Sections

    private var filteredProjectPaths: [String] {
        guard isSearching else { return projectList.projectPaths }
        return projectList.projectPaths.filter {
            ($0 as NSString).lastPathComponent.localizedCaseInsensitiveContains(searchText)
        }
    }

    private var projectSection: some View {
        Section {
            ForEach(filteredProjectPaths, id: \.self) { path in
                ProjectRow(
                    path: path,
                    isActive: path == worktreeManager.projectPath
                )
                .contentShape(Rectangle())
                .onTapGesture {
                    if path != worktreeManager.projectPath {
                        projectList.lastActiveProjectPath = path
                        openWindow(value: path)
                    }
                }
                .contextMenu {
                    Button("Project Settings\u{2026}") {
                        activeSheet = .projectSettings
                    }
                    .disabled(path != worktreeManager.projectPath)

                    Divider()

                    Button("Remove Project") {
                        projectList.removeProject(path)
                    }
                    Button("Reveal in Finder") {
                        NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: path)
                    }
                }
            }
        } header: {
            HStack {
                Text("Projects")
                Spacer()
                SidebarHeaderButton(systemImage: "plus") {
                    pickProject()
                }
                .padding(.trailing, 6)
            }
        }
    }

    private var tasksRow: some View {
        HStack(spacing: 6) {
            Image(systemName: "ticket")
                .font(.caption)
                .foregroundStyle(selectedWorktree == nil ? .blue : .secondary)
            Text("Tasks")
                .fontWeight(selectedWorktree == nil ? .semibold : .regular)
            Spacer()
        }
        .padding(.vertical, 2)
        .listRowBackground(selectedWorktree == nil ? Color.accentColor.opacity(0.15) : Color.clear)
        .contentShape(Rectangle())
        .onTapGesture { detailSelection = .tasks }
    }

    private var worktreeSection: some View {
        Section {
            ForEach(filteredWorktrees) { wt in
                let isOpen = wt.isMain || terminalManager.openWorktreeIds.contains(wt.id)
                WorktreeRow(worktree: wt, subtitle: worktreeManager.subtitle(for: wt), hasNotification: terminalManager.notifiedWorktrees.contains(wt.id), taskStatus: wt.branch.flatMap { workTaskManager.task(forWorktree: $0)?.status }, shortcutIndex: isSearching || !isOpen ? nil : shortcutIndex(for: wt))
                    .tag(DetailSelection.worktree(wt))
                    .opacity(!isOpen ? 0.5 : 1.0)
                    .contextMenu {
                        worktreeContextMenu(wt)
                    }
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
                    activeSheet = .createWorktree
                }
                .padding(.trailing, 6)
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
        .disabled(wt.isMain || !terminalManager.openWorktreeIds.contains(wt.id))

        Button("Remove Worktree") {
            worktreeToRemove = wt
        }
        .disabled(wt.isMain)

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

    private func pickProject() {
        if let path = projectList.pickAndAddProject() {
            openWindow(value: path)
        }
    }
}

// MARK: - Project Row

struct ProjectRow: View {
    let path: String
    let isActive: Bool

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: isActive ? "folder.fill" : "folder")
                .foregroundStyle(isActive ? .blue : .secondary)
                .font(.caption)
            Text(URL(fileURLWithPath: path).lastPathComponent)
                .fontWeight(isActive ? .semibold : .regular)
                .lineLimit(1)
            Spacer()
        }
        .contentShape(Rectangle())
    }
}

// MARK: - Worktree Row

struct WorktreeRow: View {
    let worktree: Worktree
    var subtitle: String? = nil
    var hasNotification: Bool = false
    var taskStatus: WorkTask.Status? = nil
    var shortcutIndex: Int? = nil

    @State private var pulsing = false

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 4) {
                if worktree.isMain {
                    Image(systemName: "crown.fill")
                        .font(.caption2)
                        .foregroundStyle(.orange)
                }
                Text(worktree.displayName)
                    .lineLimit(1)
                Spacer()
                if let taskStatus {
                    taskStatusIndicator(taskStatus)
                }
                if hasNotification {
                    Circle()
                        .fill(.blue)
                        .frame(width: 7, height: 7)
                        .help("Terminal notification")
                }
                if let index = shortcutIndex {
                    Text("⌘\(index)")
                        .font(.caption2.monospaced())
                        .foregroundStyle(.tertiary)
                }
            }

            if let subtitle {
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .padding(.vertical, 2)
    }

    @ViewBuilder
    private func taskStatusIndicator(_ status: WorkTask.Status) -> some View {
        switch status {
        case .started:
            Circle()
                .fill(.green)
                .frame(width: 7, height: 7)
                .scaleEffect(pulsing ? 1.3 : 1.0)
                .opacity(pulsing ? 0.6 : 1.0)
                .animation(.easeInOut(duration: 1.0).repeatForever(autoreverses: true), value: pulsing)
                .onAppear { pulsing = true }
                .help("Task running")
        case .done:
            Image(systemName: "checkmark.circle.fill")
                .font(.caption2)
                .foregroundStyle(.green)
                .help("Task done")
        case .stopped:
            Circle()
                .fill(.orange)
                .frame(width: 7, height: 7)
                .help("Task stopped")
        case .open:
            EmptyView()
        }
    }
}

// MARK: - Create Worktree Sheet

struct CreateWorktreeSheet: View {
    @EnvironmentObject private var worktreeManager: WorktreeManager
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
                        await worktreeManager.createWorktree(
                            branch: branchName,
                            base: baseBranch.isEmpty ? nil : baseBranch,
                            fetch: fetchBeforeCreate
                        )
                        if worktreeManager.error == nil {
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

// MARK: - Sidebar Header Button

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
