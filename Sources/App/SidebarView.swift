import SwiftUI

struct SidebarView: View {
    @EnvironmentObject private var worktreeManager: WorktreeManager
    @EnvironmentObject private var terminalManager: TerminalManager
    @EnvironmentObject private var projectList: ProjectListManager
    @Environment(\.openWindow) private var openWindow
    @Binding var selectedWorktree: Worktree?
    @Binding var showingCreateSheet: Bool
    var onSearchActiveChanged: ((Bool) -> Void)?
    @State private var showingDebugTerminal = false
    @State private var searchText = ""
    @State private var worktreeToRemove: Worktree?

    private var isSearching: Bool { !searchText.isEmpty }

    private var filteredWorktrees: [Worktree] {
        guard isSearching else { return worktreeManager.worktrees }
        return worktreeManager.worktrees.filter { wt in
            wt.displayName.localizedCaseInsensitiveContains(searchText)
            || (worktreeManager.subtitle(for: wt)?.localizedCaseInsensitiveContains(searchText) ?? false)
        }
    }

    var body: some View {
        List(selection: $selectedWorktree) {
            projectSection
            worktreeSection
        }
        .listStyle(.sidebar)
        .searchable(text: $searchText, placement: .sidebar, prompt: "Filter")
        .frame(minWidth: 200)
        .onChange(of: searchText) { onSearchActiveChanged?(!$0.isEmpty) }
        .onChange(of: worktreeManager.projectPath) { _ in searchText = "" }
        .sheet(isPresented: $showingDebugTerminal) {
            DebugTerminalSheet(
                error: worktreeManager.error ?? "",
                projectPath: worktreeManager.projectPath
            )
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
                if let branch = worktreeToRemove?.branch {
                    if selectedWorktree?.id == worktreeToRemove?.id {
                        selectedWorktree = worktreeManager.worktrees.first(where: \.isMain)
                    }
                    worktreeManager.removeWorktree(branch: branch)
                }
                worktreeToRemove = nil
            }
        } message: {
            Text("This will delete the worktree and its working directory.")
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

    private var worktreeSection: some View {
        Section {
            ForEach(filteredWorktrees) { wt in
                WorktreeRow(worktree: wt, subtitle: worktreeManager.subtitle(for: wt), hasNotification: terminalManager.notifiedWorktrees.contains(wt.id), shortcutIndex: isSearching ? nil : shortcutIndex(for: wt))
                    .tag(wt)
                    .opacity(wt.isDimmed ? 0.5 : 1.0)
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
                .onTapGesture { showingDebugTerminal = true }
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
                    showingCreateSheet = true
                }
                .padding(.trailing, 6)
            }
        }
    }

    // MARK: - Context Menu

    @ViewBuilder
    private func worktreeContextMenu(_ wt: Worktree) -> some View {
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
        guard let i = worktreeManager.worktrees.firstIndex(where: { $0.id == wt.id }), i < 9 else { return nil }
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
        }
    }
}

// MARK: - Worktree Row

struct WorktreeRow: View {
    let worktree: Worktree
    var subtitle: String? = nil
    var hasNotification: Bool = false
    var shortcutIndex: Int? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 4) {
                branchIcon
                Text(worktree.displayName)
                    .fontWeight(worktree.isCurrent ? .semibold : .regular)
                    .lineLimit(1)
                Spacer()
                notificationIndicator
                ciIndicator
                statusBadges
                if let index = shortcutIndex {
                    Text("⌘\(index)")
                        .font(.caption2.monospaced())
                        .foregroundStyle(.tertiary)
                }
            }

            HStack(spacing: 8) {
                if let subtitle {
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                Spacer()

                divergenceInfo
            }
        }
        .padding(.vertical, 2)
    }

    @ViewBuilder
    private var branchIcon: some View {
        if worktree.isMain {
            Image(systemName: "crown.fill")
                .font(.caption2)
                .foregroundStyle(.orange)
        } else if worktree.hasConflicts {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.caption2)
                .foregroundStyle(.red)
        } else if worktree.isRebase {
            Image(systemName: "arrow.triangle.2.circlepath")
                .font(.caption2)
                .foregroundStyle(.purple)
        }
    }

    @ViewBuilder
    private var notificationIndicator: some View {
        if hasNotification {
            Circle()
                .fill(.blue)
                .frame(width: 7, height: 7)
                .help("Terminal notification")
        }
    }

    @ViewBuilder
    private var ciIndicator: some View {
        if let ci = worktree.ci {
            Circle()
                .fill(ci.statusColor)
                .frame(width: 7, height: 7)
                .opacity(ci.stale == true ? 0.5 : 1.0)
                .help(ci.statusLabel)
        }
    }

    @ViewBuilder
    private var statusBadges: some View {
        let wt = worktree.workingTree
        HStack(spacing: 1) {
            if wt?.staged == true { Text("+").foregroundStyle(.green) }
            if wt?.modified == true { Text("!").foregroundStyle(.cyan) }
            if wt?.untracked == true { Text("?").foregroundStyle(.cyan) }
        }
        .font(.caption.monospaced())
    }

    @ViewBuilder
    private var divergenceInfo: some View {
        HStack(spacing: 6) {
            if let main = worktree.main {
                if main.ahead > 0 || main.behind > 0 {
                    HStack(spacing: 2) {
                        if main.ahead > 0 {
                            Text("↑\(main.ahead)")
                                .foregroundStyle(.green)
                        }
                        if main.behind > 0 {
                            Text("↓\(main.behind)")
                                .foregroundStyle(.red)
                        }
                    }
                }
            }

            if let diff = worktree.workingTree?.diff,
               (diff.added > 0 || diff.deleted > 0) {
                HStack(spacing: 2) {
                    if diff.added > 0 {
                        Text("+\(diff.added)")
                            .foregroundStyle(.green)
                    }
                    if diff.deleted > 0 {
                        Text("-\(diff.deleted)")
                            .foregroundStyle(.red)
                    }
                }
            }
        }
        .font(.caption2.monospaced())
    }
}

// MARK: - Create Worktree Sheet

struct CreateWorktreeSheet: View {
    @EnvironmentObject private var worktreeManager: WorktreeManager
    @Environment(\.dismiss) private var dismiss
    @State private var branchName = ""
    @State private var baseBranch = ""
    @State private var isCreating = false

    var body: some View {
        VStack(spacing: 16) {
            Text("New Worktree")
                .font(.headline)

            TextField("Branch name", text: $branchName)
                .textFieldStyle(.roundedBorder)
                .onChange(of: branchName) { newValue in
                    let sanitized = newValue.replacingOccurrences(of: " ", with: "-")
                    if sanitized != newValue { branchName = sanitized }
                }
                .disabled(isCreating)

            TextField("Base branch (optional)", text: $baseBranch)
                .textFieldStyle(.roundedBorder)
                .disabled(isCreating)
                .opacity(isCreating ? 0.5 : 1.0)

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
                            base: baseBranch.isEmpty ? nil : baseBranch
                        )
                        dismiss()
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
