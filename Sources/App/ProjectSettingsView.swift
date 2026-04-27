import SwiftUI

struct ProjectSettingsView: View {
    let projectPath: String
    @EnvironmentObject private var workTaskCoordinator: WorkTaskCoordinator
    @State private var hooks: ProjectHooks
    @State private var maxConcurrentAgents: Int
    @State private var pollingInterval: ProjectSettings.PollingInterval

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

    private var planningFilePath: String {
        (projectPath as NSString).appendingPathComponent("PLANNING.md")
    }

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

                SettingsSection("Hooks") {
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

                // MARK: - Workflow (workflow.json)

                SettingsSection(
                    "Workflow",
                    footer: "Run agent commands automatically when a task changes status. Stored in `.clearway/workflow.json`."
                ) {
                    WorkflowEditorView(projectPath: projectPath)
                }
            }
            .padding(32)
            .frame(maxWidth: 680)
            .frame(maxWidth: .infinity)
        }
        .onAppear {
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

    private func applyPlanningTemplate() {
        planningText = Self.planningTemplate
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
            try? fm.removeItem(atPath: planningFilePath)
            planningStatus = fm.fileExists(atPath: planningFilePath) ? .loaded : .empty
            return
        }

        if let existing = fm.contents(atPath: planningFilePath),
           existing == planningText.data(using: .utf8) {
            return
        }

        let isValid = PlanningConfig.parse(from: planningText) != nil

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
