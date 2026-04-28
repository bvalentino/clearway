import SwiftUI

/// Sentence-card editor for `.clearway/workflow.json`. Renders one trigger
/// header per `WorkTask.Status` with a stack of action cards reading
/// `Run [agent] with [command]` underneath. Edits debounce-save to disk;
/// external edits propagate back via `WorkTaskCoordinator.workflowAutomation`.
struct WorkflowEditorView: View {
    let projectPath: String
    @EnvironmentObject private var workTaskCoordinator: WorkTaskCoordinator

    /// Local in-flight model — the source of truth while the editor is on
    /// screen. Synced *out* via `scheduleSave` and *in* via the coordinator's
    /// `workflowAutomation` publisher (gated by `pendingSave` to avoid loops).
    @State private var automation: WorkflowAutomation
    /// Pending debounced save. Cancelled on every keystroke; nil when no save
    /// is in flight, which is also the gate that lets external reloads write
    /// back over `automation`.
    @State private var pendingSave: DispatchWorkItem?
    /// True while we're replacing `automation` from the coordinator, so the
    /// resulting `onChange` doesn't schedule a redundant save back to disk.
    @State private var isApplyingExternal = false

    init(projectPath: String) {
        self.projectPath = projectPath
        // Seed from disk rather than the coordinator's published value: the
        // coordinator's reload is debounced 300ms behind the file watcher, so
        // a fresh disk read here shows the user the newest content immediately
        // when they open Settings during that window. Once the coordinator
        // catches up, `onChange(of: workflowAutomation)` is a no-op.
        _automation = State(initialValue: WorkflowAutomation.load(projectPath: projectPath))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ForEach(WorkTask.Status.allCases, id: \.self) { status in
                triggerSection(for: status)
            }
        }
        .onChange(of: automation) { _ in
            guard !isApplyingExternal else { return }
            scheduleSave()
        }
        .onChange(of: workTaskCoordinator.workflowAutomation) { external in
            // External writers (file watcher, other editor) have authority
            // only when no local edit is pending — otherwise we'd clobber
            // the user's in-flight typing with stale on-disk state.
            guard pendingSave == nil else { return }
            guard external != automation else { return }
            isApplyingExternal = true
            automation = external
            isApplyingExternal = false
        }
    }

    // MARK: - Trigger Section

    @ViewBuilder
    private func triggerSection(for status: WorkTask.Status) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            triggerHeader(for: status)

            let actions = automation.actions(for: status)
            if actions.isEmpty {
                emptyActionsRow(for: status)
            } else {
                ForEach(Array(actions.enumerated()), id: \.element.id) { index, action in
                    actionCard(
                        for: status,
                        action: action,
                        index: index,
                        total: actions.count
                    )
                }
                addActionRow(for: status)
            }
        }
    }

    @ViewBuilder
    private func triggerHeader(for status: WorkTask.Status) -> some View {
        HStack(spacing: 8) {
            Image(systemName: triggerIcon(for: status))
                .foregroundStyle(.secondary)
            HStack(spacing: 4) {
                Text("If Task status is")
                    .foregroundStyle(.secondary)
                Text(status.label)
                    .fontWeight(.semibold)
            }
            Spacer()
        }
        .font(.body)
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.thickMaterial, in: RoundedRectangle(cornerRadius: 10))
    }

    @ViewBuilder
    private func emptyActionsRow(for status: WorkTask.Status) -> some View {
        HStack(spacing: 8) {
            Text("No actions")
                .font(.callout)
                .foregroundStyle(.tertiary)
            Spacer()
            addActionButton(for: status)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .padding(.leading, 24)
    }

    @ViewBuilder
    private func addActionRow(for status: WorkTask.Status) -> some View {
        HStack {
            addActionButton(for: status)
            Spacer()
        }
        .padding(.leading, 24)
    }

    private func addActionButton(for status: WorkTask.Status) -> some View {
        Button {
            appendAction(to: status)
        } label: {
            Label("Add Action", systemImage: "plus.circle")
                .font(.callout)
        }
        .buttonStyle(.borderless)
    }

    // MARK: - Action Card

    @ViewBuilder
    private func actionCard(
        for status: WorkTask.Status,
        action: WorkflowAutomation.Action,
        index: Int,
        total: Int
    ) -> some View {
        // Index-based read is O(1) per keystroke; the id-based fallback only
        // kicks in if a concurrent edit shifted the action under us, in which
        // case we render the captured snapshot until the next view update.
        let agentBinding = Binding<String>(
            get: {
                let actions = automation.rules[status] ?? []
                if index < actions.count, actions[index].id == action.id {
                    return actions[index].agent
                }
                return actions.first(where: { $0.id == action.id })?.agent ?? action.agent
            },
            set: { newValue in updateAction(in: status, id: action.id) { $0.agent = newValue } }
        )
        let commandBinding = Binding<String>(
            get: {
                let actions = automation.rules[status] ?? []
                if index < actions.count, actions[index].id == action.id {
                    return actions[index].command
                }
                return actions.first(where: { $0.id == action.id })?.command ?? action.command
            },
            set: { newValue in updateAction(in: status, id: action.id) { $0.command = newValue } }
        )
        let renderedCommand = commandBinding.wrappedValue

        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .top, spacing: 6) {
                Text("Run")
                    .foregroundStyle(.secondary)
                TextField("claude", text: agentBinding)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 120)
                Text("with")
                    .foregroundStyle(.secondary)
                TextField("command to run", text: commandBinding, axis: .vertical)
                    .textFieldStyle(.roundedBorder)
                    .lineLimit(1...8)
                reorderControls(for: status, index: index, total: total)
                Button {
                    deleteAction(in: status, id: action.id)
                } label: {
                    Image(systemName: "trash")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.borderless)
                .help("Remove action")
            }

            if !renderedCommand.isEmpty,
               let highlighted = highlightedTokens(in: renderedCommand) {
                Text(highlighted)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .padding(.leading, 4)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .lineLimit(3)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(Color(.separatorColor), lineWidth: 0.5)
        )
        .padding(.leading, 24)
    }

    /// Up/down chevrons for shifting an action within its trigger. Cards
    /// can't live in a `List` (the card visual style depends on a custom
    /// background), so we expose explicit reorder controls instead of
    /// `.onMove`. The button is hidden — but still occupies layout space —
    /// when the move would be out of range, so the card never reflows mid-drag.
    @ViewBuilder
    private func reorderControls(for status: WorkTask.Status, index: Int, total: Int) -> some View {
        VStack(spacing: 2) {
            Button {
                moveAction(in: status, from: index, to: index - 1)
            } label: {
                Image(systemName: "chevron.up")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.borderless)
            .disabled(index == 0)
            .opacity(index == 0 ? 0.3 : 1)
            .help("Move action up")

            Button {
                moveAction(in: status, from: index, to: index + 1)
            } label: {
                Image(systemName: "chevron.down")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.borderless)
            .disabled(index >= total - 1)
            .opacity(index >= total - 1 ? 0.3 : 1)
            .help("Move action down")
        }
    }

    // MARK: - Variable Tokens

    /// Returns an `AttributedString` preview of `text` with `{{ … }}` ranges
    /// pill-tinted in the accent color. Returns nil when the string contains
    /// no tokens — caller suppresses the preview row in that case.
    private func highlightedTokens(in text: String) -> AttributedString? {
        var attributed = AttributedString(text)
        var foundToken = false

        var searchStart = text.startIndex
        while searchStart < text.endIndex,
              let openRange = text.range(of: "{{", range: searchStart..<text.endIndex),
              let closeRange = text.range(of: "}}", range: openRange.upperBound..<text.endIndex) {
            foundToken = true
            let tokenRange = openRange.lowerBound..<closeRange.upperBound
            if let attributedRange = Range(tokenRange, in: attributed) {
                attributed[attributedRange].backgroundColor = Color.accentColor.opacity(0.18)
                attributed[attributedRange].foregroundColor = Color.accentColor
            }
            searchStart = closeRange.upperBound
        }

        return foundToken ? attributed : nil
    }

    // MARK: - SF Symbols

    private func triggerIcon(for status: WorkTask.Status) -> String {
        switch status {
        case .new: return "circle"
        case .readyToStart: return "play.circle"
        case .inProgress: return "arrow.triangle.2.circlepath"
        case .qa: return "checkmark.shield"
        case .readyForReview: return "eye"
        case .done: return "checkmark.circle"
        case .canceled: return "xmark.circle"
        }
    }

    // MARK: - Mutation

    private func appendAction(to status: WorkTask.Status) {
        var rules = automation.rules
        var actions = rules[status] ?? []
        actions.append(WorkflowAutomation.Action(command: "", agent: "claude"))
        rules[status] = actions
        automation = WorkflowAutomation(rules: rules)
    }

    private func deleteAction(in status: WorkTask.Status, id: UUID) {
        var rules = automation.rules
        guard var actions = rules[status] else { return }
        actions.removeAll { $0.id == id }
        if actions.isEmpty {
            rules.removeValue(forKey: status)
        } else {
            rules[status] = actions
        }
        automation = WorkflowAutomation(rules: rules)
    }

    private func moveAction(in status: WorkTask.Status, from source: Int, to destination: Int) {
        var rules = automation.rules
        guard var actions = rules[status] else { return }
        guard source >= 0, source < actions.count,
              destination >= 0, destination < actions.count,
              source != destination else { return }
        let item = actions.remove(at: source)
        actions.insert(item, at: destination)
        rules[status] = actions
        automation = WorkflowAutomation(rules: rules)
    }

    private func updateAction(
        in status: WorkTask.Status,
        id: UUID,
        _ mutate: (inout WorkflowAutomation.Action) -> Void
    ) {
        var rules = automation.rules
        guard var actions = rules[status],
              let index = actions.firstIndex(where: { $0.id == id }) else { return }
        var action = actions[index]
        mutate(&action)
        actions[index] = action
        rules[status] = actions
        automation = WorkflowAutomation(rules: rules)
    }

    // MARK: - Save

    private func scheduleSave() {
        pendingSave?.cancel()
        let snapshot = automation
        let work = DispatchWorkItem {
            performSave(snapshot)
        }
        pendingSave = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: work)
    }

    private func performSave(_ snapshot: WorkflowAutomation) {
        defer { pendingSave = nil }
        do {
            try snapshot.save(to: projectPath)
        } catch {
            // Surface only via console — the editor stays usable so the user
            // can keep editing; the next save attempt will retry naturally.
            Ghostty.logger.warning("Failed to save workflow.json: \(error.localizedDescription, privacy: .public)")
        }
    }
}
