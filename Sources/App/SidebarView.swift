import SwiftUI

struct SidebarView: View {
    @EnvironmentObject private var worktreeManager: WorktreeManager
    @Binding var selectedWorktree: Worktree?
    var onRunCommand: ((_ command: String, _ worktree: Worktree) -> Void)?
    @State private var showingCreateSheet = false

    var body: some View {
        List(selection: $selectedWorktree) {
            if !worktreeManager.projectPaths.isEmpty {
                projectSection
            }

            if let _ = worktreeManager.activeProjectPath {
                worktreeSection
            }
        }
        .listStyle(.sidebar)
        .frame(minWidth: 200)
        .toolbar {
            ToolbarItemGroup {
                Button { pickProject() } label: {
                    Image(systemName: "folder.badge.plus")
                }
                .help("Add project")

                Button { worktreeManager.refresh() } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .help("Refresh")
            }
        }
        .sheet(isPresented: $showingCreateSheet) {
            CreateWorktreeSheet()
        }
        .overlay {
            if worktreeManager.projectPaths.isEmpty && !worktreeManager.isLoading {
                emptyState
            }
        }
    }

    // MARK: - Sections

    private var projectSection: some View {
        Section("Projects") {
            ForEach(worktreeManager.projectPaths, id: \.self) { path in
                ProjectRow(
                    path: path,
                    isActive: path == worktreeManager.activeProjectPath
                )
                .contentShape(Rectangle())
                .onTapGesture {
                    worktreeManager.activeProjectPath = path
                }
                .contextMenu {
                    Button("Remove Project") {
                        worktreeManager.removeProject(path)
                    }
                    Button("Reveal in Finder") {
                        NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: path)
                    }
                }
            }
        }
    }

    private var worktreeSection: some View {
        Section {
            ForEach(worktreeManager.worktrees) { wt in
                WorktreeRow(worktree: wt)
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
                Label(error, systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.secondary)
                    .font(.caption)
            }
        } header: {
            HStack {
                Text("Worktrees")
                Spacer()
                Button { showingCreateSheet = true } label: {
                    Image(systemName: "plus")
                        .font(.body)
                        .frame(width: 24, height: 24)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(worktreeManager.activeProjectPath == nil)
                .padding(.trailing, 6)
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "folder")
                .font(.system(size: 36))
                .foregroundStyle(.secondary)
            Text("No project selected")
                .font(.headline)
                .foregroundStyle(.secondary)
            Text("Add a git project to see its worktrees")
                .font(.caption)
                .foregroundStyle(.tertiary)
            Button("Add Project") { pickProject() }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
        }
    }

    // MARK: - Context Menu

    @ViewBuilder
    private func worktreeContextMenu(_ wt: Worktree) -> some View {
        Button("Merge to Main") {
            onRunCommand?("wt merge -y", wt)
        }
        .disabled(wt.isMain)

        Divider()

        Button("Remove Worktree") {
            if let branch = wt.branch {
                worktreeManager.removeWorktree(branch: branch)
                if selectedWorktree?.id == wt.id {
                    selectedWorktree = worktreeManager.worktrees.first(where: \.isMain)
                }
            }
        }
        .disabled(wt.isMain)

        Button("Force Remove") {
            if let branch = wt.branch {
                worktreeManager.removeWorktree(branch: branch, force: true)
                if selectedWorktree?.id == wt.id {
                    selectedWorktree = worktreeManager.worktrees.first(where: \.isMain)
                }
            }
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

    private func pickProject() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.message = "Choose a git project directory"
        panel.prompt = "Add Project"

        if panel.runModal() == .OK, let url = panel.url {
            worktreeManager.addProject(url.path)
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

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 4) {
                branchIcon
                Text(worktree.displayName)
                    .fontWeight(worktree.isCurrent ? .semibold : .regular)
                    .lineLimit(1)
                Spacer()
                ciIndicator
                statusBadges
            }

            HStack(spacing: 8) {
                Text(worktree.commit.message)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)

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

    var body: some View {
        VStack(spacing: 16) {
            Text("New Worktree")
                .font(.headline)

            TextField("Branch name", text: $branchName)
                .textFieldStyle(.roundedBorder)

            TextField("Base branch (optional)", text: $baseBranch)
                .textFieldStyle(.roundedBorder)

            HStack {
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Spacer()
                Button("Create") {
                    worktreeManager.createWorktree(
                        branch: branchName,
                        base: baseBranch.isEmpty ? nil : baseBranch
                    )
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(branchName.isEmpty)
            }
        }
        .padding(20)
        .frame(width: 320)
    }
}
