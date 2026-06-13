import SwiftUI

/// The Workflow section's detail pane: authors `.clearway/WORKFLOW.json` as a reorderable list of
/// action cards. Top-to-bottom card order is the v1 linear flow; `WorkflowEditorModel.toDefinition`
/// turns it into pointers on save.
struct WorkflowEditorView: View {
    let projectPath: String

    @EnvironmentObject private var workTaskCoordinator: WorkTaskCoordinator

    @State private var model = WorkflowEditorModel()
    /// Last definition loaded from disk; the base each save preserves. `nil` = no valid file yet.
    @State private var lastLoaded: WorkflowDefinition?
    @State private var pendingSave: DispatchWorkItem?
    /// Suppresses the autosave that a *programmatic* model load would otherwise trigger, so opening
    /// the section or reconciling an external edit never writes back. Armed by `load()` only when the
    /// load actually changes `model`; the `onChange(of: model)` handler clears it.
    @State private var isLoading = false

    @State private var pendingRemovalSlug: String?

    /// Slug of the action whose form is open; `nil` shows the list.
    @State private var editingSlug: String?

    /// List edit mode (the toolbar's Edit/Done). A `List` row can't carry both a tap-to-open handler
    /// and `onMove` — any tap disables the drag — so the two modes never coexist: normal rows tap to
    /// open, edit rows reorder and delete.
    @State private var isEditing = false

    @State private var pendingDiscardSlug: String?

    /// Forces the "Required" indicators on after the user picks "Keep Editing".
    @State private var forceValidation = false

    /// An action added via `+` but not yet committed. Its slug is a placeholder, so nothing persists
    /// while this is set.
    @State private var newActionSlug: String?

    private let contentMaxWidth: CGFloat = 680

    private var workflowFilePath: String {
        (projectPath as NSString).appendingPathComponent(WorkflowDefinition.relativePath)
    }

    var body: some View {
        content
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .background(Color(nsColor: .windowBackgroundColor))
            .onAppear(perform: load)
            // A new action is suppressed from autosave until committed; commit it here so switching
            // away (e.g. another sidebar section) before Back doesn't drop its typed content.
            .onDisappear(perform: commitPendingNewAction)
            .onChange(of: model) { _ in
                if isLoading { isLoading = false; return }
                scheduleSave()
            }
            .onChange(of: workTaskCoordinator.workflowDefinition) { newValue in
                // A pending local save wins; its own write echoes back here and is dropped by reconcile.
                guard pendingSave == nil else { return }
                reconcile(with: newValue)
            }
            .onChange(of: projectPath) { _ in isEditing = false; load() }
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
        } else {
            listOrEmpty
                .overlay(alignment: .bottomTrailing) {
                    if !isEditing { addButton }
                }
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
        let definition = workTaskCoordinator.workflowDefinition
        let loaded = definition.map(WorkflowEditorModel.init(from:)) ?? WorkflowEditorModel()
        // Arm the guard only on a real change; arming it for a no-op load would swallow the next edit.
        if loaded != model { isLoading = true }
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
        if reverted != model { isLoading = true }
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
        // Pop the form first so its binding doesn't dangle, then defer the mutation a tick (re-finding
        // the index by slug) so the List finishes its current update before the array changes.
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
        guard newActionSlug == nil else { return }
        let fileManager = FileManager.default

        // No actions → remove the file; an action-less workflow would fail validate().
        guard !model.actions.isEmpty else {
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
