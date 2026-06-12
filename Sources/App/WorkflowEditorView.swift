import SwiftUI

/// The **Workflow** section's detail pane: authors a project's `.clearway/WORKFLOW.json` as a
/// vertical stack of reorderable action cards (or an empty-state prompt when there's no file).
///
/// The user only ever sees ordered, named cards — slugs, the `start` pointer, and `routes` stay
/// hidden. Top-to-bottom card order *is* the v1 linear flow; `WorkflowEditorModel.toDefinition`
/// turns it into pointers on save.
///
/// Persistence mirrors the proven `ProjectSettingsView` pattern: a debounced autosave, a
/// skip-on-own-write guard (`pendingSave`), and reconciliation from the coordinator's already-live
/// `workflowDefinition` cache (no second file watcher). The writer always preserves `agent`/`hooks`
/// and per-action reserved fields via `toDefinition(preserving:)`, so the editor only ever rewrites
/// the bits it surfaces.
struct WorkflowEditorView: View {
    let projectPath: String

    @EnvironmentObject private var workTaskCoordinator: WorkTaskCoordinator

    @State private var model = WorkflowEditorModel()
    /// The last definition loaded from disk — the base every save preserves (`agent`/`hooks`/
    /// `version` + per-action reserved fields). `nil` = no valid file yet (empty state / first add).
    @State private var lastLoaded: WorkflowDefinition?
    @State private var pendingSave: DispatchWorkItem?
    /// Suppresses `scheduleSave` while the model is being (re)loaded programmatically.
    @State private var isLoading = false
    /// Slug of a freshly-added card to create-focus its name field (one-shot, like
    /// `newlyCreatedTaskId`). Bound into each card via `WorkflowActionCard.focus`.
    @FocusState private var focusedSlug: String?

    private var workflowFilePath: String {
        (projectPath as NSString).appendingPathComponent(WorkflowDefinition.relativePath)
    }

    /// A file exists on disk but the coordinator couldn't load+validate it. The empty state warns
    /// rather than silently presenting "no actions", so a user hand-fixing a malformed file knows
    /// it's there (and that adding an action will replace it).
    private var hasUnreadableFile: Bool {
        workTaskCoordinator.workflowDefinition == nil
            && FileManager.default.fileExists(atPath: workflowFilePath)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            if model.actions.isEmpty {
                emptyState
            } else {
                editorList
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .onAppear(perform: load)
        .onChange(of: model) { _ in
            guard !isLoading else { return }
            scheduleSave()
        }
        .onChange(of: workTaskCoordinator.workflowDefinition) { newValue in
            // Reconcile external edits only when idle; a pending local save will win, and its own
            // write echoes back here (suppressed by the equality check in `reconcile`).
            guard pendingSave == nil else { return }
            reconcile(with: newValue)
        }
        .onChange(of: projectPath) { _ in load() }
    }

    // MARK: - Header

    private var header: some View {
        Text("Workflow")
            .font(.largeTitle.weight(.bold))
            .padding(.horizontal, 32)
            .padding(.top, 32)
            .padding(.bottom, 16)
            .frame(maxWidth: 680, alignment: .leading)
            .frame(maxWidth: .infinity)
    }

    // MARK: - Empty state

    private var emptyState: some View {
        VStack(spacing: 10) {
            Spacer()
            Text("No actions yet.")
                .font(.title3.weight(.medium))
            Text("Actions are the steps the agent runs for each task.")
                .font(.callout)
                .foregroundStyle(.secondary)
            if hasUnreadableFile {
                Label("An existing WORKFLOW.json couldn’t be read. Adding an action replaces it.",
                      systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .padding(.top, 4)
            }
            Button(action: addAction) {
                Label("Add action", systemImage: "plus")
            }
            .controlSize(.large)
            .padding(.top, 6)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.horizontal, 32)
    }

    // MARK: - Editor list

    private var editorList: some View {
        List {
            ForEach($model.actions) { $action in
                WorkflowActionCard(
                    action: $action,
                    focus: $focusedSlug,
                    onRemove: { remove(slug: action.slug) }
                )
                .listRowSeparator(.hidden)
                .listRowBackground(Color.clear)
                .listRowInsets(EdgeInsets(top: 6, leading: 0, bottom: 6, trailing: 0))
            }
            .onMove(perform: move)

            addActionRow
                .listRowSeparator(.hidden)
                .listRowBackground(Color.clear)
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .frame(maxWidth: 680)
        .frame(maxWidth: .infinity)
    }

    private var addActionRow: some View {
        HStack {
            Spacer()
            Button(action: addAction) {
                Label("Add action", systemImage: "plus")
            }
            .buttonStyle(.borderless)
            Spacer()
        }
        .padding(.vertical, 10)
    }

    // MARK: - Loading + reconciliation

    private func load() {
        isLoading = true
        defer { isLoading = false }
        if let definition = workTaskCoordinator.workflowDefinition {
            lastLoaded = definition
            model = WorkflowEditorModel(from: definition)
        } else {
            lastLoaded = nil
            model = WorkflowEditorModel()
        }
    }

    /// Pulls an external edit into the editor. Skips the no-op case where the incoming value is the
    /// one we just wrote (our save round-trips back through the coordinator), so the user's cursor
    /// and in-memory state aren't disturbed by their own writes.
    private func reconcile(with newValue: WorkflowDefinition?) {
        guard newValue != lastLoaded else { return }
        load()
    }

    // MARK: - Mutations

    private func addAction() {
        let added = model.add()
        // Focus the new card's name field once the row has rendered (one-shot create-focus).
        DispatchQueue.main.async { focusedSlug = added.slug }
    }

    private func remove(slug: String) {
        guard let index = model.actions.firstIndex(where: { $0.slug == slug }) else { return }
        model.remove(at: index)
    }

    private func move(from source: IndexSet, to destination: Int) {
        model.move(from: source, to: destination)
    }

    // MARK: - Autosave

    private func scheduleSave() {
        pendingSave?.cancel()
        let work = DispatchWorkItem { performSave() }
        pendingSave = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: work)
    }

    private func performSave() {
        defer { pendingSave = nil }
        let fileManager = FileManager.default

        // No actions left → remove the file so the project returns to the empty state rather than
        // holding an invalid (action-less) workflow that would fail `validate()`.
        guard !model.actions.isEmpty else {
            try? fileManager.removeItem(atPath: workflowFilePath)
            lastLoaded = nil
            return
        }

        let definition = model.toDefinition(preserving: lastLoaded)
        guard let data = try? definition.encoded() else { return }

        // Skip the write (and its file-watcher round-trip) when disk already matches.
        if let existing = fileManager.contents(atPath: workflowFilePath), existing == data {
            lastLoaded = definition
            return
        }

        ensureClearwayDirectory()
        guard fileManager.createFile(
            atPath: workflowFilePath,
            contents: data,
            attributes: [.posixPermissions: 0o600]
        ) else { return }
        lastLoaded = definition
    }

    private func ensureClearwayDirectory() {
        let directory = (workflowFilePath as NSString).deletingLastPathComponent
        try? FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
    }
}
