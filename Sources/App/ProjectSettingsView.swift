import SwiftUI

struct ProjectSettingsView: View {
    let projectPath: String
    @EnvironmentObject private var workTaskCoordinator: WorkTaskCoordinator
    @State private var hooks: ProjectHooks
    @State private var workflowText = ""
    @State private var workflowStatus: WorkflowStatus = .empty
    /// Suppresses external reload while a local save is pending.
    @State private var pendingSave: DispatchWorkItem?
    /// Suppresses scheduleSave when text is set programmatically by loadWorkflowFile.
    @State private var isLoading = false

    private enum WorkflowStatus: Equatable {
        case empty
        case loaded
        case saved
        case invalid
    }

    init(projectPath: String) {
        self.projectPath = projectPath
        self._hooks = State(initialValue: ProjectHooks.load(for: projectPath))
    }

    private var workflowFilePath: String {
        (projectPath as NSString).appendingPathComponent("WORKFLOW.md")
    }

    private static let hooksFooter = "Variables: {{ branch }}, {{ worktree_path }}, {{ primary_worktree_path }}, {{ repo_path }}"
    private static let workflowFooter = """
        Defines how agents handle tasks. YAML frontmatter configures hooks \
        (after_create, before_run, after_run), agent command, and timeout. \
        The markdown body is the prompt template sent to the agent — use \
        {{ task.title }}, {{ task.body }}, {{ task.id }}, and {{ attempt }} \
        for interpolation.
        """

    private static let workflowTemplate = """
        ---
        hooks:
          after_create: echo "worktree ready"
          before_run: echo "starting agent"
        agent:
          command: claude
        ---

        {{ task.title }}

        {{ task.body }}
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

                // MARK: - WORKFLOW.md

                SettingsSection("WORKFLOW.md", footer: Self.workflowFooter, trailing: { workflowTrailing }) {
                    TextEditor(text: $workflowText)
                        .font(.system(.body, design: .monospaced))
                        .scrollContentBackground(.hidden)
                        .padding(8)
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
        .onAppear { loadWorkflowFile() }
        .onChange(of: hooks.afterCreate) { _ in hooks.save(for: projectPath) }
        .onChange(of: hooks.beforeRemove) { _ in hooks.save(for: projectPath) }
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
            workflowStatusBadge
        }
    }

    // MARK: - Status Badge

    @ViewBuilder
    private var workflowStatusBadge: some View {
        switch workflowStatus {
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

/// A labeled row inside a settings card. Renders a divider above when not the first item.
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

