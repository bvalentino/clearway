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
    @Binding var detailSelection: DetailSelection?
    var onRemoveWorktree: ((Worktree) -> Void)?
    var onSearchActiveChanged: ((Bool) -> Void)?
    @State private var activeSheet: SidebarSheet?
    @State private var searchText = ""
    @State private var worktreeToRemove: Worktree?
    @State private var worktreeToClose: Worktree?
    @State private var selectionBeforeSettings: DetailSelection?

    private var isSearching: Bool { !searchText.isEmpty }

    private var projectName: String {
        URL(fileURLWithPath: worktreeManager.projectPath).lastPathComponent
    }

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
            tasksRow
            promptsRow
            worktreeSection
        }
        .overlay(alignment: .bottomLeading) {
            Button {
                if detailSelection == .settings {
                    detailSelection = selectionBeforeSettings ?? .tasks
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
        .sheet(item: $activeSheet) { sheet in
            switch sheet {
            case .createWorktree:
                CreateWorktreeSheet()
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

    private var tasksRow: some View {
        let icon = workTaskManager.tasks.contains(where: { $0.status.isBacklog }) ? "tray.full" : "tray"
        return Label("Tasks", systemImage: icon)
            .tag(DetailSelection.tasks)
    }

    private var promptsRow: some View {
        Label("Prompts", systemImage: "text.quote")
            .tag(DetailSelection.prompts)
    }

    private var worktreeSection: some View {
        Section {
            SearchField(text: $searchText, placeholder: "Filter")
                .listRowInsets(EdgeInsets(top: 4, leading: -4, bottom: 4, trailing: -4))
                .listRowSeparator(.hidden)

            ForEach(filteredWorktrees) { wt in
                let isOpen = wt.isMain || terminalManager.openWorktreeIds.contains(wt.id)
                WorktreeRow(worktree: wt, subtitle: worktreeManager.subtitle(for: wt), hasNotification: terminalManager.notifiedWorktrees.contains(wt.id), isWorking: isOpen && !wt.isMain && claudeActivityMonitor.workingWorktreeIds.contains(wt.id), shortcutIndex: isSearching || !isOpen ? nil : shortcutIndex(for: wt))
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

}

// MARK: - Worktree Row

struct WorktreeRow: View {
    let worktree: Worktree
    var subtitle: String? = nil
    var hasNotification: Bool = false
    var isWorking: Bool = false
    var shortcutIndex: Int? = nil
    @State private var glowExpanded = false

    var body: some View {
        Label {
            HStack(spacing: 4) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(worktree.displayName)
                        .lineLimit(1)
                    if let subtitle {
                        Text(subtitle)
                            .font(.caption)
                            .foregroundStyle(.secondary)
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
                Image(systemName: "arrow.triangle.branch")
            }
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
