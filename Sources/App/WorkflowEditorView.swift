import SwiftUI

/// The Workflow section's detail pane: authors `.clearway/WORKFLOW.json` as a reorderable list of
/// action cards. Top-to-bottom card order is the v1 linear flow; `WorkflowEditorModel.toDefinition`
/// turns it into pointers on save.
struct WorkflowEditorView: View {
    let projectPath: String

    @EnvironmentObject private var workTaskCoordinator: WorkTaskCoordinator

    @State private var model = WorkflowEditorModel()
    /// Last definition loaded from disk; the base each save preserves. Sourced from the coordinator's
    /// **raw** (non-validated) cache, never the validated `workflowDefinition` — which is `nil` for a
    /// planning-only file and would cause the next save to drop `planning`. `nil` = no file yet.
    @State private var lastLoaded: WorkflowDefinition?
    @State private var pendingSave: DispatchWorkItem?
    /// Set when a programmatic load changes `model`, so its `onChange` doesn't write the load back.
    @State private var suppressNextSave = false

    @State private var pendingRemovalSlug: String?

    /// Slug of the action whose form is open; `nil` shows the list.
    @State private var editingSlug: String?

    /// List edit mode. A `List` row can't have both a tap-to-open handler and `onMove`, so normal-mode
    /// rows tap to open and edit-mode rows reorder/delete.
    @State private var isEditing = false

    @State private var pendingDiscardSlug: String?

    /// Forces the "Required" indicators on after the user picks "Keep Editing".
    @State private var forceValidation = false

    /// An action added but not yet committed; its placeholder slug means nothing persists while set.
    @State private var newActionSlug: String?

    /// Whether the pinned planning instruction's detail editor is open.
    @State private var editingPlanning = false

    /// A planning instruction just added (still blank); like `newActionSlug`, it suppresses the save
    /// until commit so a placeholder empty `planning` object is never written.
    @State private var planningIsNew = false

    private let contentMaxWidth: CGFloat = 680

    private var workflowFilePath: String {
        (projectPath as NSString).appendingPathComponent(WorkflowDefinition.relativePath)
    }

    var body: some View {
        content
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .background(Color(nsColor: .windowBackgroundColor))
            .onAppear(perform: load)
            // Commit a new action / planning on the way out, so leaving before Back keeps the content.
            .onDisappear {
                commitPendingNewAction()
                if editingPlanning { closePlanningEditor() }
            }
            .onChange(of: model) { _ in
                if suppressNextSave { suppressNextSave = false; return }
                scheduleSave()
            }
            .onChange(of: workTaskCoordinator.rawWorkflowDefinition) { newValue in
                // A pending local save wins; its own write echoes back here and is dropped by reconcile.
                guard pendingSave == nil else { return }
                reconcile(with: newValue)
            }
            .onChange(of: projectPath) { _ in isEditing = false; editingPlanning = false; load() }
            // An empty list hides both Edit/Done and +, so leaving edit mode on would strand the user.
            .onChange(of: model.actions.isEmpty) { empty in
                if empty { isEditing = false }
            }
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
            .toolbar {
                if editingSlug != nil {
                    ToolbarItem(placement: .navigation) {
                        Button(action: closeEditor) {
                            Image(systemName: "chevron.backward")
                        }
                        .help("Back to Workflow")
                        .accessibilityLabel("Back")
                    }
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
                } else if editingPlanning {
                    ToolbarItem(placement: .navigation) {
                        Button(action: closePlanningEditor) {
                            Image(systemName: "chevron.backward")
                        }
                        .help("Back to Workflow")
                        .accessibilityLabel("Back")
                    }
                    ToolbarItem(placement: .primaryAction) {
                        Menu {
                            Button(role: .destructive, action: removePlanning) {
                                Label("Remove Planning", systemImage: "trash")
                            }
                        } label: {
                            Image(systemName: "ellipsis")
                        }
                        .menuIndicator(.hidden)
                        .help("More")
                        .accessibilityLabel("More")
                    }
                } else if !model.actions.isEmpty {
                    ToolbarItem(placement: .primaryAction) {
                        Button(isEditing ? "Done" : "Edit") {
                            isEditing.toggle()
                        }
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
        } else if editingPlanning {
            WorkflowPlanningDetailView(instructions: planningTextBinding, contentMaxWidth: contentMaxWidth)
        } else {
            VStack(spacing: 0) {
                planningEntry
                listOrEmpty
            }
            .overlay(alignment: .bottomTrailing) {
                if !isEditing { addButton }
            }
        }
    }

    /// A two-way binding to the planning text, mapping the optional model field to the detail editor's
    /// non-optional `TextEditor` binding.
    private var planningTextBinding: Binding<String> {
        Binding(get: { model.planning ?? "" }, set: { model.planning = $0 })
    }

    // MARK: - Pinned planning entry

    /// The pinned "Planning" row above the actions list: a card matching the action rows when an
    /// instruction exists, or an add affordance when none does. Outside the `List`, so it is never
    /// drag-reorderable. A divider separates it from the actions below.
    private var planningEntry: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Planning")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)

            if let instructions = model.planning {
                Button { openPlanningEditor() } label: {
                    WorkflowActionCard(name: "Planning", instructions: instructions)
                }
                .buttonStyle(PressableCardButtonStyle())
            } else {
                Button(action: addPlanning) {
                    planningPlaceholderCard
                }
                .buttonStyle(PressableCardButtonStyle())
            }

            Divider()
                .padding(.top, 6)
        }
        .padding(.horizontal, 20)
        .padding(.top, 16)
        .frame(maxWidth: contentMaxWidth)
        .frame(maxWidth: .infinity)
    }

    private var planningPlaceholderCard: some View {
        HStack(spacing: 12) {
            Image(systemName: "plus.circle")
                .font(.system(size: 20))
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text("Add planning instruction")
                    .font(.headline)
                    .foregroundStyle(.secondary)
                Text("Runs when you tap Plan, before the worktree exists.")
                    .font(.subheadline)
                    .foregroundStyle(.tertiary)
                    .lineLimit(2)
            }
            Spacer(minLength: 8)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: WorkflowActionCard.cornerRadius))
        .contentShape(RoundedRectangle(cornerRadius: WorkflowActionCard.cornerRadius))
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
        // Two row variants so a row never carries both tap-to-open and `onMove` (see `isEditing`).
        List {
            if isEditing {
                ForEach(model.actions) { action in
                    editRow(for: action)
                }
                .onMove(perform: move)
            } else {
                ForEach(model.actions) { action in
                    normalRow(for: action)
                }
            }
        }
        // .inset keeps the reorder drop indicator's knob from clipping at the leading edge.
        .listStyle(.inset)
        .scrollContentBackground(.hidden)
        .padding(.vertical, 12)
        .frame(maxWidth: contentMaxWidth)
        .frame(maxWidth: .infinity)
    }

    private func normalRow(for action: WorkflowEditorModel.EditorAction) -> some View {
        Button { editingSlug = action.slug } label: {
            WorkflowActionCard(name: action.name, instructions: action.instructions)
        }
        .buttonStyle(PressableCardButtonStyle())
        .listRowSeparator(.hidden)
        .listRowBackground(Color.clear)
        .listRowInsets(EdgeInsets(top: 5, leading: 0, bottom: 5, trailing: 0))
        .contextMenu {
            Button("Edit") { editingSlug = action.slug }
            Button("Delete", role: .destructive) { requestRemove(slug: action.slug) }
        }
    }

    private func editRow(for action: WorkflowEditorModel.EditorAction) -> some View {
        WorkflowActionCard(
            name: action.name,
            instructions: action.instructions,
            isEditing: true,
            onDelete: { requestRemove(slug: action.slug) }
        )
            .listRowSeparator(.hidden)
            .listRowBackground(Color.clear)
            .listRowInsets(EdgeInsets(top: 5, leading: 0, bottom: 5, trailing: 0))
    }

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
        let definition = workTaskCoordinator.rawWorkflowDefinition
        let loaded = definition.map(WorkflowEditorModel.init(from:)) ?? WorkflowEditorModel()
        // Suppress only a real change; a no-op load would otherwise swallow the next edit.
        if loaded != model { suppressNextSave = true }
        lastLoaded = definition
        model = loaded
        if let slug = editingSlug, !loaded.actions.contains(where: { $0.slug == slug }) {
            editingSlug = nil
        }
    }

    /// Pulls an external edit in, skipping the echo of our own save.
    private func reconcile(with newValue: WorkflowDefinition?) {
        guard newValue != lastLoaded else { return }
        load()
    }

    // MARK: - Mutations

    private func addAction() {
        let added = model.add()
        newActionSlug = added.slug
        editingSlug = added.slug
    }

    // MARK: - Planning mutations

    private func addPlanning() {
        model.planning = ""
        planningIsNew = true
        editingPlanning = true
    }

    private func openPlanningEditor() {
        planningIsNew = false
        editingPlanning = true
    }

    /// Back from the planning editor: a blank instruction is treated as "no planning" (so a newly
    /// added blank entry is discarded and a cleared one is removed), then the write is flushed since
    /// a new planning's saves were suppressed while editing.
    private func closePlanningEditor() {
        if model.planning?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true {
            model.planning = nil
        }
        finishPlanningEdit()
    }

    private func removePlanning() {
        model.planning = nil
        finishPlanningEdit()
    }

    /// Exits the planning editor and flushes the write, since a new planning's saves were suppressed
    /// while editing.
    private func finishPlanningEdit() {
        planningIsNew = false
        editingPlanning = false
        pendingSave?.cancel()
        performSave()
    }

    /// Back: commit a complete action (deriving a new action's slug from its name), discard an
    /// untouched blank one, or confirm before discarding a partially-typed one.
    private func closeEditor() {
        guard let slug = editingSlug,
              let action = model.actions.first(where: { $0.slug == slug }) else {
            leaveEditor()
            return
        }
        if action.isComplete {
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

    /// Commits a complete new action when the view leaves before Back. Flushes synchronously because
    /// the debounced save is suppressed while `newActionSlug` is set; an incomplete draft is dropped.
    private func commitPendingNewAction() {
        guard let slug = newActionSlug,
              let action = model.actions.first(where: { $0.slug == slug }),
              action.isComplete else { return }
        model.finalizeSlug(of: slug)
        newActionSlug = nil
        pendingSave?.cancel()
        performSave()
    }

    /// Reverts the open action's unsaved edits by reloading the last persisted definition, then leaves.
    private func discardEditedAction() {
        let reverted = lastLoaded.map(WorkflowEditorModel.init(from:)) ?? WorkflowEditorModel()
        if reverted != model { suppressNextSave = true }
        model = reverted
        leaveEditor()
    }

    /// Confirms before removing an action with content; a blank card is removed straight away.
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
        // Pop the form so its binding doesn't dangle, then defer the mutation a tick so the List
        // finishes its current update before the array changes.
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
        // A new action's slug is still a placeholder — wait for the commit to write the final slug.
        // A freshly added (still blank) planning is likewise held until commit.
        guard newActionSlug == nil, !planningIsNew else { return }
        let fileManager = FileManager.default

        // Remove the file only when it would hold neither actions nor a planning instruction — now
        // that the file can exist solely to carry planning, an empty action list alone no longer
        // means "delete it".
        guard !model.actions.isEmpty || model.planning != nil else {
            try? fileManager.removeItem(atPath: workflowFilePath)
            lastLoaded = nil
            return
        }

        // Don't write a half-made action; keep the last valid file until the required fields are filled.
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
        try? FileManager.default.createDirectory(
            atPath: directory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
    }
}

// MARK: - Planning detail form

/// The editing form for the pinned planning instruction: a single multi-line instructions field.
/// Unlike an action, planning has no name, slug, or routes. Back navigation and Remove live in the
/// window toolbar.
private struct WorkflowPlanningDetailView: View {
    @Binding var instructions: String
    let contentMaxWidth: CGFloat

    @FocusState private var focused: Bool

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 8) {
                Text("Instructions")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.secondary)
                // TextEditor (not TextField) so Return inserts a line break.
                TextEditor(text: $instructions)
                    .font(.body)
                    .scrollContentBackground(.hidden)
                    .frame(minHeight: 200)
                    .focused($focused)
                    .padding(8)
                    .background(Color(.textBackgroundColor), in: RoundedRectangle(cornerRadius: 6))
                    .overlay(
                        RoundedRectangle(cornerRadius: 6)
                            .strokeBorder(Color(.separatorColor), lineWidth: 1)
                    )
                    .accessibilityLabel("Planning instructions")
                Text("Runs when you tap Plan, before the worktree exists. "
                    + "Use {{ task.title }}, {{ task.body }}, {{ task.id }}, {{ task.path }}.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
                .workflowDetailFormContainer(maxWidth: contentMaxWidth)
        }
        .onAppear { if instructions.isEmpty { focused = true } }
    }
}

// MARK: - Action detail form

/// The editing form for one action: its name and multi-line instructions. Back navigation and Delete
/// live in the window toolbar, not in this content.
private struct WorkflowActionDetailView: View {
    @Binding var action: WorkflowEditorModel.EditorAction
    let contentMaxWidth: CGFloat
    /// Forces the "Required" indicators on regardless of which fields were touched.
    let forceValidation: Bool

    @FocusState private var nameFocused: Bool
    /// "Required" shows only after a field is edited and left empty, so a fresh action isn't pre-flagged.
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
                    // TextEditor (not TextField) so Return inserts a line break.
                    TextEditor(text: $action.instructions)
                        .font(.body)
                        .scrollContentBackground(.hidden)
                        .frame(minHeight: 160)
                        .accessibilityLabel("Action instructions")
                }
            }
                .workflowDetailFormContainer(maxWidth: contentMaxWidth)
        }
        .onChange(of: action.name) { _ in nameEdited = true }
        .onChange(of: action.instructions) { _ in instructionsEdited = true }
        .onAppear {
            if action.name.isEmpty && action.instructions.isEmpty { nameFocused = true }
        }
    }

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

private extension View {
    /// Shared chrome for the editor's detail forms (planning + action): a material card with content
    /// padding, centered to the editor's max content width.
    func workflowDetailFormContainer(maxWidth: CGFloat) -> some View {
        self
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.thickMaterial, in: RoundedRectangle(cornerRadius: 12))
            .padding(.horizontal, 32)
            .padding(.top, 20)
            .padding(.bottom, 24)
            .frame(maxWidth: maxWidth, alignment: .leading)
            .frame(maxWidth: .infinity)
    }
}
