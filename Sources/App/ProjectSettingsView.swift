import SwiftUI

struct ProjectSettingsView: View {
    let projectPath: String
    @EnvironmentObject private var workTaskCoordinator: WorkTaskCoordinator
    @EnvironmentObject private var settings: SettingsManager
    @EnvironmentObject private var promptManager: PromptManager
    @State private var hooks: ProjectHooks
    @State private var maxConcurrentAgents: Int
    @State private var pollingInterval: ProjectSettings.PollingInterval
    @State private var workflowText = ""
    @State private var workflowStatus: WorkflowStatus = .empty
    /// Suppresses external reload while a local save is pending.
    @State private var pendingSave: DispatchWorkItem?
    /// Suppresses scheduleSave when text is set programmatically by loadWorkflowFile.
    @State private var isLoading = false

    @State private var planningText = ""
    @State private var planningStatus: WorkflowStatus = .empty
    @State private var pendingPlanningSave: DispatchWorkItem?
    @State private var isLoadingPlanning = false

    private enum WorkflowStatus: Equatable {
        case empty
        case loaded
        case saved
        case invalid
    }

    init(projectPath: String) {
        self.projectPath = projectPath
        self._hooks = State(initialValue: ProjectHooks.load(for: projectPath))
        self._maxConcurrentAgents = State(initialValue: ProjectSettings.maxConcurrentAgents(for: projectPath))
        self._pollingInterval = State(initialValue: ProjectSettings.pollingInterval(for: projectPath))
    }

    private var workflowFilePath: String {
        (projectPath as NSString).appendingPathComponent("WORKFLOW.md")
    }

    private var planningFilePath: String {
        (projectPath as NSString).appendingPathComponent("PLANNING.md")
    }

    private static let hooksFooter = "Variables: {{ branch }}, {{ worktree_path }}, {{ primary_worktree_path }}, {{ repo_path }}"
    private static let workflowFooter = """
        Defines how agents handle tasks. YAML frontmatter configures hooks \
        (after_create, before_run), agent command, and timeout. \
        The markdown body is the prompt template sent to the agent. \
        Variables: {{ task.title }}, {{ task.body }}, {{ task.id }}, {{ task.path }}, \
        {{ attempt }}, {{ status.ready_for_review }}, {{ status.done }}, etc.
        """

    private static let workflowTemplate = """
        ---
        hooks:
          after_create: echo "worktree ready"
          before_run: echo "starting agent"
        agent:
          command: claude
        ---

        Read the task at {{ task.path }} and complete it.

        When done, update the task status to `{{ status.ready_for_review }}` \
        by editing the `status:` field in the task file's YAML frontmatter. \
        Once you set the status, do not change it again.
        """

    private static let planningFooter = """
        Defines how agents plan tasks. YAML frontmatter configures the agent command. \
        The markdown body is the prompt template. \
        Variables: {{ task.title }}, {{ task.body }}, {{ task.id }}, {{ task.path }}.
        """

    private static let planningTemplate = """
        ---
        agent:
          command: claude
        ---

        Read the task at {{ task.path }} and create an implementation plan.

        Research the codebase to understand the architecture, then append a \
        detailed implementation plan to the task file.
        """

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                // MARK: - Hooks

                SettingsSection("Hooks", footer: Self.hooksFooter) {
                    SettingsRow("After Worktree Create") {
                        TextField("Command", text: $hooks.afterCreate)
                            .textFieldStyle(.roundedBorder)
                    }
                    Divider()
                        .padding(.vertical, 12)
                    SettingsRow("Before Worktree Remove") {
                        TextField("Command", text: $hooks.beforeRemove)
                            .textFieldStyle(.roundedBorder)
                    }
                }

                // MARK: - Prompts

                SettingsSection("Prompts", footer: "Directory where reusable prompt files are stored. Shared across all projects.") {
                    SettingsRow("Prompts Directory") {
                        TextField(SettingsManager.defaultPromptsDirectory, text: $settings.promptsDirectory)
                            .textFieldStyle(.roundedBorder)
                    }
                }

                // MARK: - Automation

                SettingsSection("Automation", footer: "Automatically process tasks marked as Ready to Start.") {
                    HStack {
                        Text("Polling")
                        Spacer()
                        Picker("", selection: $pollingInterval) {
                            ForEach(ProjectSettings.PollingInterval.allCases, id: \.self) { interval in
                                Text(interval.label).tag(interval)
                            }
                        }
                        .labelsHidden()
                    }
                    Divider()
                        .padding(.vertical, 8)
                    HStack {
                        Text("Maximum In Progress")
                        Spacer()
                        Stepper("\(maxConcurrentAgents)", value: $maxConcurrentAgents, in: 1...16)
                    }
                }

                // MARK: - WORKFLOW.md

                SettingsSection("WORKFLOW.md", footer: Self.workflowFooter, trailing: { workflowTrailing }) {
                    MarkdownEditorView(text: $workflowText)
                        .background(Color(.textBackgroundColor))
                        .cornerRadius(6)
                        .overlay(
                            RoundedRectangle(cornerRadius: 6)
                                .strokeBorder(Color(.separatorColor), lineWidth: 1)
                        )
                        .frame(minHeight: 350)
                        .padding(4)
                }

                // MARK: - PLANNING.md

                SettingsSection("PLANNING.md", footer: Self.planningFooter, trailing: { planningTrailing }) {
                    MarkdownEditorView(text: $planningText)
                        .background(Color(.textBackgroundColor))
                        .cornerRadius(6)
                        .overlay(
                            RoundedRectangle(cornerRadius: 6)
                                .strokeBorder(Color(.separatorColor), lineWidth: 1)
                        )
                        .frame(minHeight: 350)
                        .padding(4)
                }
            }
            .padding(32)
            .frame(maxWidth: 680)
            .frame(maxWidth: .infinity)
        }
        .onAppear {
            loadWorkflowFile()
            loadPlanningFile()
        }
        .onChange(of: hooks.afterCreate) { _ in hooks.save(for: projectPath) }
        .onChange(of: hooks.beforeRemove) { _ in hooks.save(for: projectPath) }
        .onChange(of: maxConcurrentAgents) { newValue in
            ProjectSettings.setMaxConcurrentAgents(newValue, for: projectPath)
        }
        .onChange(of: pollingInterval) { newValue in
            ProjectSettings.setPollingInterval(newValue, for: projectPath)
            if newValue == .disabled {
                workTaskCoordinator.isAutoProcessing = false
            } else if workTaskCoordinator.isAutoProcessing {
                // Restart timer with new interval
                workTaskCoordinator.restartAutoProcessingTimer()
            }
        }
        .onChange(of: settings.promptsDirectory) { newValue in
            promptManager.setDirectory(newValue)
        }
        .onChange(of: workflowText) { _ in
            guard !isLoading else { return }
            scheduleSave()
        }
        .onChange(of: workTaskCoordinator.workflowConfig) { _ in
            // Reload from disk when the file watcher detects external changes,
            // but skip if we have a pending local save (our own write triggered the watcher).
            guard pendingSave == nil else { return }
            loadWorkflowFile()
        }
        .onChange(of: planningText) { _ in
            guard !isLoadingPlanning else { return }
            schedulePlanningSave()
        }
        .onChange(of: workTaskCoordinator.planningConfig) { _ in
            guard pendingPlanningSave == nil else { return }
            loadPlanningFile()
        }
    }

    // MARK: - Trailing Content

    @ViewBuilder
    private var workflowTrailing: some View {
        HStack(spacing: 8) {
            if workflowStatus == .empty {
                Button("Use Template") { applyTemplate() }
                    .buttonStyle(.link)
                    .font(.caption)
            }
            statusBadge(for: workflowStatus)
        }
    }

    @ViewBuilder
    private var planningTrailing: some View {
        HStack(spacing: 8) {
            if planningStatus == .empty {
                Button("Use Template") { applyPlanningTemplate() }
                    .buttonStyle(.link)
                    .font(.caption)
            }
            statusBadge(for: planningStatus)
        }
    }

    // MARK: - Status Badge

    @ViewBuilder
    private func statusBadge(for status: WorkflowStatus) -> some View {
        switch status {
        case .empty:
            Label("No file", systemImage: "doc")
                .font(.caption)
                .foregroundStyle(.secondary)
        case .loaded:
            EmptyView()
        case .saved:
            Label("Saved", systemImage: "checkmark.circle.fill")
                .font(.caption)
                .foregroundStyle(.green)
        case .invalid:
            Label("Invalid YAML", systemImage: "exclamationmark.triangle.fill")
                .font(.caption)
                .foregroundStyle(.orange)
        }
    }

    // MARK: - Template

    private func applyTemplate() {
        workflowText = Self.workflowTemplate
    }

    private func applyPlanningTemplate() {
        planningText = Self.planningTemplate
    }

    // MARK: - File I/O

    private func loadWorkflowFile() {
        let fm = FileManager.default
        guard let data = fm.contents(atPath: workflowFilePath),
              let content = String(data: data, encoding: .utf8) else {
            if workflowText.isEmpty {
                workflowStatus = .empty
            }
            return
        }
        // Suppress scheduleSave while updating text programmatically
        isLoading = true
        defer { isLoading = false }
        if content != workflowText {
            workflowText = content
        }
        workflowStatus = .loaded
    }

    private func scheduleSave() {
        pendingSave?.cancel()
        let work = DispatchWorkItem {
            performSave()
        }
        pendingSave = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: work)
    }

    private func performSave() {
        defer { pendingSave = nil }

        let fm = FileManager.default
        if workflowText.isEmpty {
            workflowStatus = fm.fileExists(atPath: workflowFilePath) ? .loaded : .empty
            return
        }

        // Skip write if file content is already identical
        if let existing = fm.contents(atPath: workflowFilePath),
           existing == workflowText.data(using: .utf8) {
            return
        }

        let isValid = WorkflowConfig.parse(from: workflowText) != nil

        guard let data = workflowText.data(using: .utf8) else { return }
        guard fm.createFile(atPath: workflowFilePath, contents: data, attributes: [.posixPermissions: 0o600]) else {
            // Write failed — leave status unchanged
            return
        }

        workflowStatus = isValid ? .saved : .invalid
    }

    // MARK: - PLANNING.md File I/O

    private func loadPlanningFile() {
        let fm = FileManager.default
        guard let data = fm.contents(atPath: planningFilePath),
              let content = String(data: data, encoding: .utf8) else {
            if planningText.isEmpty {
                planningStatus = .empty
            }
            return
        }
        isLoadingPlanning = true
        defer { isLoadingPlanning = false }
        if content != planningText {
            planningText = content
        }
        planningStatus = .loaded
    }

    private func schedulePlanningSave() {
        pendingPlanningSave?.cancel()
        let work = DispatchWorkItem {
            performPlanningSave()
        }
        pendingPlanningSave = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: work)
    }

    private func performPlanningSave() {
        defer { pendingPlanningSave = nil }

        let fm = FileManager.default
        if planningText.isEmpty {
            planningStatus = fm.fileExists(atPath: planningFilePath) ? .loaded : .empty
            return
        }

        if let existing = fm.contents(atPath: planningFilePath),
           existing == planningText.data(using: .utf8) {
            return
        }

        let isValid = WorkflowConfig.parse(from: planningText) != nil

        guard let data = planningText.data(using: .utf8) else { return }
        guard fm.createFile(atPath: planningFilePath, contents: data, attributes: [.posixPermissions: 0o600]) else {
            return
        }

        planningStatus = isValid ? .saved : .invalid
    }
}

// MARK: - Settings Components

/// A section with a header above the card, optional trailing content, and a footer below.
private struct SettingsSection<Content: View, Trailing: View>: View {
    let title: String
    var footer: String?
    let trailing: Trailing
    let content: Content

    init(
        _ title: String,
        footer: String? = nil,
        @ViewBuilder trailing: () -> Trailing = { EmptyView() },
        @ViewBuilder content: () -> Content
    ) {
        self.title = title
        self.footer = footer
        self.trailing = trailing()
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Text(title)
                    .font(.system(.body, weight: .regular))
                    .foregroundStyle(.secondary)
                Spacer()
                trailing
            }
            .padding(.horizontal, 4)

            VStack(alignment: .leading, spacing: 0) { content }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(12)
                .background(.thickMaterial)
                .cornerRadius(12)

            if let footer {
                Text(footer)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 4)
            }
        }
    }
}

/// A labeled row inside a settings card — label above, content below.
private struct SettingsRow<Content: View>: View {
    let label: String
    @ViewBuilder let content: Content

    init(_ label: String, @ViewBuilder content: () -> Content) {
        self.label = label
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(label)
                .font(.subheadline.weight(.medium))
            content
        }
    }
}

