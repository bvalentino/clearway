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
            ForEach(WorkflowAutomation.automatableStatuses, id: \.self) { status in
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
                    actionCard(for: status, action: action, index: index)
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
        index: Int
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

        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text("Run")
                    .foregroundStyle(.secondary)
                // Single-option Picker mirrors the SettingsView "Command"
                // chooser. The list is intentionally a closed set rather than
                // a free-form text field — adding an agent binary is a
                // first-class app capability, not per-action user input.
                Picker("Agent", selection: agentBinding) {
                    Text("claude").tag("claude")
                }
                .labelsHidden()
                .pickerStyle(.menu)
                Text("with")
                    .foregroundStyle(.secondary)
                Spacer()
                Button {
                    deleteAction(in: status, id: action.id)
                } label: {
                    Image(systemName: "xmark")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.borderless)
                .help("Remove action")
            }

            promptEditor(commandBinding: commandBinding)

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

    /// Multi-line prompt editor for the action's command. The text is pasted
    /// verbatim into the agent's running terminal (no shell interpretation),
    /// so this is fundamentally a *prompt* field — not a shell command —
    /// hence the larger surface and TextEditor instead of a single-line
    /// TextField. Renders a custom rounded border + placeholder overlay
    /// because TextEditor on macOS ships without either by default.
    @ViewBuilder
    private func promptEditor(commandBinding: Binding<String>) -> some View {
        // Padding lives on the *container* (one value, applied symmetrically
        // by the ZStack) so the placeholder and the live TextEditor text
        // share an inset rather than each fighting their own. The TextEditor
        // itself takes no extra outer padding — its NSTextView already
        // contributes ~5pt of internal lead, which combined with this 8pt
        // container inset lands the caret at roughly 13pt from each edge.
        let promptFont = Font.system(.body, design: .monospaced)
        ZStack(alignment: .topLeading) {
            if commandBinding.wrappedValue.isEmpty {
                Text("Prompt to inject into the agent")
                    .font(promptFont)
                    .foregroundStyle(.tertiary)
                    .padding(.leading, 5)
                    .padding(.top, 0)
                    .allowsHitTesting(false)
            }
            TextEditor(text: commandBinding)
                .font(promptFont)
                .scrollContentBackground(.hidden)
        }
        .padding(8)
        .frame(minHeight: 80)
        .background(Color(.textBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .stroke(Color(.separatorColor), lineWidth: 0.5)
        )
        .frame(maxWidth: .infinity)
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
