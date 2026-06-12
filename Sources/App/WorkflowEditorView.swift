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
    /// One-shot guard that suppresses the save for a *programmatic* model load. `load()` arms it
    /// only when the assignment will actually change `model` (and thus fire `onChange`); the
    /// `onChange(of: model)` handler disarms it the moment it consumes that change, so opening the
    /// section — or reconciling an external edit — never schedules a save. A real user edit always
    /// arrives with this clear and saves normally. (Resetting it via `defer` in `load()` wouldn't
    /// work: `onChange` fires on the *next* update pass, by which point the flag is already clear.)
    @State private var isLoading = false
    /// Slug of a freshly-added card to create-focus its name field (one-shot, like
    /// `newlyCreatedTaskId`). Bound into each card via `WorkflowActionCard.focus`.
    @FocusState private var focusedSlug: String?

    /// Cached "a file exists on disk but the coordinator couldn't load+validate it." Recomputed at
    /// discrete load/reconcile/save points — never per render — so a transient mid-delete disk state
    /// can't briefly flash a stale "couldn't be read" warning right after the user removed the last
    /// action. The empty state surfaces this so someone hand-fixing a malformed file knows it's there
    /// (and that adding an action replaces it).
    @State private var hasUnreadableFile = false

    /// Slug of the action awaiting delete confirmation, or `nil` when no confirmation is showing.
    /// Only set for a card with content — removing a blank card skips the prompt (see `requestRemove`).
    @State private var pendingRemovalSlug: String?

    /// Selected card's slug — the target of the Delete key (`onDeleteCommand`) and the selection
    /// ring. `nil` = nothing selected.
    @State private var selectedSlug: String?

    /// Slugs whose instructions editor is expanded. Empty = every card collapsed to a name-only row
    /// (the decluttered overview); a freshly-added card is expanded so its prompt is ready to type.
    @State private var expandedSlugs: Set<String> = []

    /// Readable content-column width; long instructions stay legible. Shared by the header and the
    /// card list so they line up.
    private let contentMaxWidth: CGFloat = 680

    private var workflowFilePath: String {
        (projectPath as NSString).appendingPathComponent(WorkflowDefinition.relativePath)
    }

    private func refreshUnreadableFlag() {
        hasUnreadableFile = workTaskCoordinator.workflowDefinition == nil
            && FileManager.default.fileExists(atPath: workflowFilePath)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            if model.actions.isEmpty {
                emptyPlaceholder
            } else {
                editorList
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        // Shortcuts-style canvas: cards float as flat white tiles on the window's gray.
        .background(Color(.windowBackgroundColor))
        .onAppear(perform: load)
        .onChange(of: model) { _ in
            // A programmatic load arms `isLoading`; consume that one change without saving. Real
            // user edits arrive with the flag clear and schedule a save.
            if isLoading { isLoading = false; return }
            scheduleSave()
        }
        .onChange(of: workTaskCoordinator.workflowDefinition) { newValue in
            refreshUnreadableFlag()
            // Reconcile external edits only when idle; a pending local save will win, and its own
            // write echoes back here (suppressed by the equality check in `reconcile`).
            guard pendingSave == nil else { return }
            reconcile(with: newValue)
        }
        .onChange(of: projectPath) { _ in load() }
        .onChange(of: focusedSlug) { newFocus in
            // Editing a card selects it, so `−` targets the card you're working in. Clicking into a
            // text field focuses it without tripping List row selection, so without this the `−`
            // could stay disabled while the user is clearly engaged with a card.
            if let newFocus { selectedSlug = newFocus }
        }
        // Confirm before discarding an action with content — removal is non-undoable (HIG reserves
        // this for uncommon, irreversible destructive actions). A destructive-styled button plus the
        // default Cancel; presenting the slug keeps the bound action stable across the dialog.
        .confirmationDialog(
            "Remove this action?",
            isPresented: Binding(
                get: { pendingRemovalSlug != nil },
                set: { if !$0 { pendingRemovalSlug = nil } }
            ),
            presenting: pendingRemovalSlug
        ) { slug in
            Button("Remove Action", role: .destructive) { remove(slug: slug) }
            Button("Cancel", role: .cancel) {}
        } message: { _ in
            Text("Its instructions will be deleted. This can’t be undone.")
        }
    }

    // MARK: - Header

    private var header: some View {
        Text("Workflow")
            .font(.largeTitle.weight(.bold))
            .padding(.horizontal, 32)
            .padding(.top, 32)
            .padding(.bottom, 16)
            .frame(maxWidth: contentMaxWidth, alignment: .leading)
            .frame(maxWidth: .infinity)
    }

    // MARK: - Empty state

    private var emptyPlaceholder: some View {
        VStack(spacing: 10) {
            Spacer()
            Text("No actions yet.")
                .font(.title3.weight(.medium))
            Text("Actions are the steps the agent runs for each task.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            if hasUnreadableFile {
                Label("An existing WORKFLOW.json couldn’t be read. Adding an action replaces it.",
                      systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .padding(.top, 4)
            }
            // The single most-likely action on an empty screen → prominent (accent) style.
            Button(action: addAction) {
                Label("Add Action", systemImage: "plus")
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .padding(.top, 6)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.horizontal, 32)
    }

    // MARK: - Editor list

    private var editorList: some View {
        List(selection: $selectedSlug) {
            ForEach(Array(zip(model.actions.indices, model.actions)), id: \.1.id) { index, action in
                WorkflowActionCard(
                    action: $model.actions[index],
                    focus: $focusedSlug,
                    stepNumber: index + 1,
                    isSelected: selectedSlug == action.slug,
                    isExpanded: expandedSlugs.contains(action.slug),
                    onToggleExpanded: { toggleExpanded(action.slug) }
                )
                .listRowSeparator(.hidden)
                .listRowBackground(Color.clear)
                .listRowInsets(EdgeInsets(top: 5, leading: 0, bottom: 5, trailing: 0))
                .contextMenu {
                    Button("Delete", role: .destructive) { requestRemove(slug: action.slug) }
                }
            }
            .onMove(perform: move)

            addActionRow
                .listRowSeparator(.hidden)
                .listRowBackground(Color.clear)
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        // Delete key / Edit ▸ Delete removes the selected card (only when the list, not a text field,
        // holds focus — so editing instructions and deleting a step never collide).
        .onDeleteCommand(perform: removeSelected)
        .frame(maxWidth: contentMaxWidth)
        .frame(maxWidth: .infinity)
    }

    /// The Shortcuts-style "Add Action" affordance beneath the last card (no +/− strip, no library —
    /// our actions are free-text, so adding just appends a blank step).
    private var addActionRow: some View {
        Button(action: addAction) {
            Label("Add Action", systemImage: "plus")
        }
        .buttonStyle(.borderless)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .center)
    }

    // MARK: - Loading + reconciliation

    private func load() {
        let definition = workTaskCoordinator.workflowDefinition
        let loaded = definition.map(WorkflowEditorModel.init(from:)) ?? WorkflowEditorModel()
        // Arm the load guard only when the assignment will actually change `model` (and so fire
        // `onChange`). Arming it for a no-op assignment — e.g. (re)loading a no-file project whose
        // model is already empty — would leave it stuck on and swallow the user's next real edit
        // (notably the empty-state "Add action" that creates the file).
        if loaded != model { isLoading = true }
        lastLoaded = definition
        model = loaded
        // Prune selection/expansion of slugs that no longer resolve (an external edit removed the
        // card), so the Delete key can't act on a vanished slug and stale expand flags don't linger.
        let liveSlugs = Set(loaded.actions.map { $0.slug })
        if let slug = selectedSlug, !liveSlugs.contains(slug) { selectedSlug = nil }
        expandedSlugs.formIntersection(liveSlugs)
        refreshUnreadableFlag()
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
        // Expand and select the new card, then focus its name field once the row has rendered
        // (one-shot create-focus) so its prompt is ready to type.
        expandedSlugs.insert(added.slug)
        selectedSlug = added.slug
        DispatchQueue.main.async { focusedSlug = added.slug }
    }

    private func toggleExpanded(_ slug: String) {
        if expandedSlugs.contains(slug) { expandedSlugs.remove(slug) } else { expandedSlugs.insert(slug) }
    }

    /// Delete key / Edit ▸ Delete: removes the selected action (no-op when nothing is selected).
    private func removeSelected() {
        guard let slug = selectedSlug else { return }
        requestRemove(slug: slug)
    }

    /// Confirms first when the action has content (its name or instructions would be lost and
    /// removal can't be undone); a blank, just-added card has nothing to lose, so it's removed
    /// immediately without a prompt.
    private func requestRemove(slug: String) {
        guard let action = model.actions.first(where: { $0.slug == slug }) else { return }
        let isBlank = action.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && action.instructions.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        if isBlank {
            remove(slug: slug)
        } else {
            pendingRemovalSlug = slug
        }
    }

    private func remove(slug: String) {
        // Two things crash SwiftUI here, both verified necessary by removing each and reproducing
        // the crash: (1) a `@FocusState` still pointing at the removed card's slug, and (2) mutating
        // the `ForEach($model.actions)` binding *synchronously from inside that row's own button*,
        // which re-entrantly invalidates the collection the row was rendered from. So resign focus
        // first, then defer the structural mutation one runloop tick (re-finding the index by slug,
        // since the array may have changed) to let the in-flight view update finish.
        if focusedSlug == slug { focusedSlug = nil }
        if selectedSlug == slug { selectedSlug = nil }
        expandedSlugs.remove(slug)
        DispatchQueue.main.async {
            guard let index = model.actions.firstIndex(where: { $0.slug == slug }) else { return }
            model.remove(at: index)
        }
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
            // The user emptied the editor — there's nothing unreadable, so never warn after this.
            hasUnreadableFile = false
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
        // We just wrote a valid file — clear any prior "unreadable" warning.
        hasUnreadableFile = false
    }

    private func ensureClearwayDirectory() {
        let directory = (workflowFilePath as NSString).deletingLastPathComponent
        // 0o700 matches how the rest of the app creates `.clearway/` (NotesManager, WorkTaskManager).
        try? FileManager.default.createDirectory(
            atPath: directory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
    }
}
