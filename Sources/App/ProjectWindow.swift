import SwiftUI

/// Per-window wrapper that resolves the project path and owns per-window state.
///
/// On launch the binding starts as `nil`; we resolve it from the last active
/// project. If no projects exist, the welcome view is shown.
struct ProjectWindow: View {
    @Binding var projectPath: String?
    @EnvironmentObject private var projectList: ProjectListManager
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        content
            .onChange(of: projectList.projectPaths) { paths in
                guard let path = projectPath, !paths.contains(path) else { return }
                if paths.isEmpty {
                    projectPath = nil
                } else {
                    dismiss()
                }
            }
    }

    @ViewBuilder
    private var content: some View {
        if let path = projectPath {
            ProjectContentView(projectPath: path)
        } else if let path = projectList.lastActiveProjectPath {
            // WindowGroup(for:) passes nil on initial launch; redirect to last active project.
            Color.clear.onAppear { projectPath = path }
        } else {
            WelcomeView(projectPath: $projectPath)
        }
    }
}

/// Welcome view shown when no projects have been added.
struct WelcomeView: View {
    @Binding var projectPath: String?
    @EnvironmentObject private var projectList: ProjectListManager

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "terminal")
                .font(.system(size: 48))
                .foregroundStyle(.secondary)
            Text("Add a project to get started")
                .foregroundStyle(.secondary)
            Button("Add Project") {
                if let path = projectList.pickAndAddProject() {
                    projectPath = path
                }
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// Owns per-window `WorktreeManager` and `TerminalManager`, then renders `ContentView`.
struct ProjectContentView: View {
    let projectPath: String
    @EnvironmentObject private var ghosttyApp: Ghostty.App
    @StateObject private var worktreeManager: WorktreeManager
    @StateObject private var terminalManager = TerminalManager()
    @StateObject private var claudeTaskManager = ClaudeTaskManager()

    init(projectPath: String) {
        self.projectPath = projectPath
        _worktreeManager = StateObject(wrappedValue: WorktreeManager(projectPath: projectPath))
    }

    var body: some View {
        ContentView()
            .environmentObject(worktreeManager)
            .environmentObject(terminalManager)
            .environmentObject(claudeTaskManager)
    }
}
