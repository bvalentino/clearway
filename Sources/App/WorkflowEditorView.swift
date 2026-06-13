import SwiftUI

/// The **Workflow** section's detail pane: authors a project's `.clearway/WORKFLOW.json` as a
/// reorderable list of action cards (or an empty-state prompt when there's no file). Tapping a card
/// pushes an editing form (`WorkflowActionDetailView`) with a back button; the list itself holds no
/// text fields, so editing is never inline.
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

    /// Slug of the action awaiting delete confirmation, or `nil` when no confirmation is showing.
    /// Only set for a card with content — removing a blank card skips the prompt (see `requestRemove`).
    @State private var pendingRemovalSlug: String?

    /// Slug of the action whose editing form is open, or `nil` to show the list. Drives the in-pane
    /// list ⇄ detail navigation (a plain state swap rather than a nested `NavigationStack`, which
    /// would fight the app's existing window toolbar).
    @State private var editingSlug: String?

    /// Transient list selection — set on click, immediately consumed to open the editor, then
    /// cleared. Lives only so navigation is selection-driven: a `Button`/tap gesture on a row would
    /// swallow the press and disable `List`'s drag-to-reorder, whereas plain selectable rows keep
    /// both (click selects → open; drag reorders).
    @State private var selectedSlug: String?

    /// Slug of the incomplete action whose discard the user is confirming on back, or `nil`.
    @State private var pendingDiscardSlug: String?

    /// Reveals the editor's "Required" indicators regardless of which fields were touched — set when
    /// the user chooses "Keep Editing" on the discard prompt, so they can see what's missing.
    @State private var forceValidation = false

    /// Slug of an action still being created (added via `+` but not yet committed). Its slug is a
    /// placeholder until commit; while set, nothing is persisted, so the file isn't written with the
    /// placeholder slug or an unfinished action.
    @State private var newActionSlug: String?

    /// Readable content-column width; long instructions stay legible. Shared by the list and the
    /// detail form so they line up.
    private let contentMaxWidth: CGFloat = 680

    private var workflowFilePath: String {
        (projectPath as NSString).appendingPathComponent(WorkflowDefinition.relativePath)
    }

    var body: some View {
        content
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .onAppear(perform: load)
            .onChange(of: model) { _ in
                // A programmatic load arms `isLoading`; consume that one change without saving. Real
                // user edits arrive with the flag clear and schedule a save.
                if isLoading { isLoading = false; return }
                scheduleSave()
            }
            .onChange(of: workTaskCoordinator.workflowDefinition) { newValue in
                // Reconcile external edits only when idle; a pending local save will win, and its own
                // write echoes back here (suppressed by the equality check in `reconcile`).
                guard pendingSave == nil else { return }
                reconcile(with: newValue)
            }
            .onChange(of: projectPath) { _ in load() }
            // Confirm before discarding an action with content — removal is non-undoable (HIG reserves
            // this for uncommon, irreversible destructive actions). A destructive-styled button plus
            // the default Cancel; presenting the slug keeps the bound action stable across the dialog.
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
            // Leaving an incomplete action the user typed into: confirm rather than dropping it
            // silently. "Keep Editing" returns and reveals which fields are still required.
            .confirmationDialog(
                "Discard this action?",
                isPresented: Binding(
                    get: { pendingDiscardSlug != nil },
                    set: { if !$0 { pendingDiscardSlug = nil } }
                )
            ) {
                Button("Discard Action", role: .destructive) {
                    pendingDiscardSlug = nil
                    discardEditedAction()
                }
                Button("Keep Editing", role: .cancel) {
                    pendingDiscardSlug = nil
                    forceValidation = true
                }
            } message: {
                Text("It’s missing a name or instructions, so it can’t be saved.")
            }
            // Per macOS HIG, navigation (Back) belongs in the toolbar's leading area as the standard
            // symbol with no text label — not a button floating in the content.
            .toolbar {
                if editingSlug != nil {
                    ToolbarItem(placement: .navigation) {
                        Button(action: closeEditor) {
                            Image(systemName: "chevron.backward")
                        }
                        .help("Back to Workflow")
                        .accessibilityLabel("Back")
                    }
                    // Secondary/destructive actions live in a More menu, not as a prominent button.
                    ToolbarItem(placement: .primaryAction) {
                        Menu {
                            Button(role: .destructive) {
                                if let slug = editingSlug { requestRemove(slug: slug) }
                            } label: {
                                Label("Delete Action", systemImage: "trash")
                            }
                        } label: {
                            Image(systemName: "ellipsis")
                        }
                        .menuIndicator(.hidden)
                        .help("More")
                        .accessibilityLabel("More")
                    }
                }
            }
    }

    @ViewBuilder
    private var content: some View {
        if let slug = editingSlug, let index = model.actions.firstIndex(where: { $0.slug == slug }) {
            WorkflowActionDetailView(
                action: $model.actions[index],
                contentMaxWidth: contentMaxWidth,
                forceValidation: forceValidation
            )
        } else {
            listOrEmpty
                // Floating "+" matching the Prompts section's add affordance (PromptsView), for
                // app-wide consistency. Shown on the list/empty state, not the editing form.
                .overlay(alignment: .bottomTrailing) { addButton }
        }
    }

    @ViewBuilder
    private var listOrEmpty: some View {
        if model.actions.isEmpty {
            emptyPlaceholder
        } else {
            editorList
        }
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
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.horizontal, 32)
    }

    // MARK: - Editor list

    private var editorList: some View {
        List(selection: $selectedSlug) {
            ForEach(model.actions) { action in
                // Plain selectable rows — no Button/tap gesture — so List keeps drag-to-reorder.
                // Navigation is driven by selection (see onChange below).
                WorkflowActionCard(name: action.name, instructions: action.instructions)
                    .tag(action.slug)
                    .listRowSeparator(.hidden)
                    .listRowBackground(Color.clear)
                    .listRowInsets(EdgeInsets(top: 5, leading: 0, bottom: 5, trailing: 0))
                    .contextMenu {
                        Button("Delete", role: .destructive) { requestRemove(slug: action.slug) }
                    }
            }
            .onMove(perform: move)
        }
        // .inset (not .plain) gives the table a built-in leading margin, so the reorder drop
        // indicator's knob has room and isn't clipped at the edge.
        .listStyle(.inset)
        .scrollContentBackground(.hidden)
        .padding(.vertical, 12)
        .onChange(of: selectedSlug) { newValue in
            // Open the clicked row's editor, then clear the selection so its highlight doesn't linger
            // and the same row can be reopened. A reorder drag doesn't set selection, so it never
            // navigates.
            guard let slug = newValue else { return }
            editingSlug = slug
            selectedSlug = nil
        }
        .frame(maxWidth: contentMaxWidth)
        .frame(maxWidth: .infinity)
    }

    /// Floating circular add button, mirroring `PromptsView`'s `createButton` so the two sections
    /// share one add affordance. Appends a blank step and opens its editor.
    private var addButton: some View {
        Button(action: addAction) {
            Image(systemName: "plus")
                .font(.system(size: 16, weight: .medium))
                .foregroundStyle(.primary)
                .frame(width: 36, height: 36)
                .background(.thinMaterial, in: Circle())
                .shadow(color: .black.opacity(0.15), radius: 4, y: 2)
        }
        .buttonStyle(.plain)
        .padding(12)
        .help("Add action")
        .accessibilityLabel("Add action")
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
        // Drop an open editing target that no longer resolves (an external edit removed the card), so
        // the detail form falls back to the list rather than binding a vanished action.
        if let slug = editingSlug, !loaded.actions.contains(where: { $0.slug == slug }) {
            editingSlug = nil
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
        // Track it as the in-progress new action: its slug is a placeholder (the name was empty at
        // creation) and is finalized from the name on commit. Open its form immediately (auto-focuses
        // the name field) so the user can start typing.
        newActionSlug = added.slug
        editingSlug = added.slug
    }

    /// Back button. A complete action just closes. An incomplete one can't be saved, so: if the user
    /// typed something, confirm the discard (so their input isn't dropped silently); if it's an
    /// untouched empty draft, discard it without a prompt.
    private func closeEditor() {
        guard let slug = editingSlug,
              let action = model.actions.first(where: { $0.slug == slug }) else {
            leaveEditor()
            return
        }
        if action.isComplete {
            // Commit. A brand-new action gets its slug derived from the name now (it was a
            // placeholder until the user named it); existing actions keep their frozen slug.
            if slug == newActionSlug { model.finalizeSlug(of: slug) }
            leaveEditor()
        } else if action.name.isEmpty && action.instructions.isEmpty {
            discardEditedAction()
        } else {
            pendingDiscardSlug = slug
        }
    }

    private func leaveEditor() {
        editingSlug = nil
        newActionSlug = nil
        forceValidation = false
    }

    /// Drops the incomplete action's unsaved edits by reverting to the last persisted definition — a
    /// never-saved new action vanishes; an existing one restores its last valid version — then leaves.
    private func discardEditedAction() {
        let reverted = lastLoaded.map(WorkflowEditorModel.init(from:)) ?? WorkflowEditorModel()
        if reverted != model { isLoading = true }
        model = reverted
        leaveEditor()
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
        // If the removed action's form is open, pop back to the list first so its binding doesn't
        // dangle. Then defer the structural mutation one runloop tick (re-finding the index by slug,
        // since the array may have changed) to let the in-flight view update finish before the
        // collection the row was rendered from is mutated.
        if editingSlug == slug { editingSlug = nil }
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
        // Don't persist while a new action is mid-creation — its slug is still a placeholder, to be
        // finalized from the name on commit. The file is written once, with the final slug.
        guard newActionSlug == nil else { return }
        let fileManager = FileManager.default

        // No actions left → remove the file so the project returns to the empty state rather than
        // holding an invalid (action-less) workflow that would fail `validate()`.
        guard !model.actions.isEmpty else {
            try? fileManager.removeItem(atPath: workflowFilePath)
            lastLoaded = nil
            return
        }

        // Never persist while any action is incomplete (missing a name or instructions). The file
        // keeps its last valid state until the required fields are filled, so a half-made action is
        // never written to disk.
        guard model.actions.allSatisfy(\.isComplete) else { return }

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
        // 0o700 matches how the rest of the app creates `.clearway/` (NotesManager, WorkTaskManager).
        try? FileManager.default.createDirectory(
            atPath: directory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
    }
}

// MARK: - Action detail form

/// The editing form shown when a card is tapped: the action's name and its multi-line instructions.
/// Built from a `ScrollView`/`VStack` (not `Form`/`List`) so its text fields focus on the first
/// click, matching `ProjectSettingsView`'s bordered-field styling. Back navigation and the Delete
/// action live in the window toolbar (the macOS-standard place), not in this content.
private struct WorkflowActionDetailView: View {
    @Binding var action: WorkflowEditorModel.EditorAction
    let contentMaxWidth: CGFloat
    /// Forces the "Required" indicators on regardless of which fields were touched (set when the user
    /// chooses "Keep Editing" on the discard prompt, so the missing fields are revealed).
    let forceValidation: Bool

    @FocusState private var nameFocused: Bool
    /// "Required" is shown only after a field has been edited and left empty — never on a pristine
    /// form — so a freshly added action doesn't open pre-flagged as invalid.
    @State private var nameEdited = false
    @State private var instructionsEdited = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                field("Name", isMissing: (nameEdited || forceValidation) && isBlank(action.name)) {
                    TextField("Action name", text: $action.name)
                        .textFieldStyle(.plain)
                        .font(.body)
                        .focused($nameFocused)
                        .accessibilityLabel("Action name")
                }
                field("Instructions", isMissing: (instructionsEdited || forceValidation) && isBlank(action.instructions)) {
                    // TextEditor (not TextField) so Return inserts a line break — instructions are
                    // multi-paragraph prompts. scrollContentBackground(.hidden) lets the field box show.
                    TextEditor(text: $action.instructions)
                        .font(.body)
                        .scrollContentBackground(.hidden)
                        .frame(minHeight: 160)
                        .accessibilityLabel("Action instructions")
                }
            }
                // Group the fields in a material card — the macOS box pattern (matches
                // ProjectSettingsView's sections) rather than letting them float on the bare pane.
                // 20pt inner padding ≈ the system grouped-form inset (macOS has no fixed HIG value;
                // it's the 8-point grid).
                .padding(20)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.thickMaterial, in: RoundedRectangle(cornerRadius: 12))
                .padding(.horizontal, 32)
                .padding(.top, 20)
                .padding(.bottom, 24)
                .frame(maxWidth: contentMaxWidth, alignment: .leading)
                .frame(maxWidth: .infinity)
        }
        .onChange(of: action.name) { _ in nameEdited = true }
        .onChange(of: action.instructions) { _ in instructionsEdited = true }
        // A blank, just-created action lands with its name field focused so the user can type at once.
        .onAppear {
            if action.name.isEmpty && action.instructions.isEmpty { nameFocused = true }
        }
    }

    /// Trimmed-empty check for a required field.
    private func isBlank(_ text: String) -> Bool {
        text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    @ViewBuilder
    private func field<Content: View>(
        _ title: String,
        isMissing: Bool,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Text(title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.secondary)
                if isMissing {
                    Text("Required")
                        .font(.caption)
                        .foregroundStyle(.red)
                }
            }
            // Bordered-box treatment matching ProjectSettingsView's editors (the app's established
            // input-box convention): textBackgroundColor fill, separator border, cornerRadius 6.
            // A missing required field gets a red border.
            content()
                .padding(8)
                .background(Color(.textBackgroundColor), in: RoundedRectangle(cornerRadius: 6))
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .strokeBorder(isMissing ? Color.red.opacity(0.7) : Color(.separatorColor),
                                      lineWidth: 1)
                )
        }
    }
}
