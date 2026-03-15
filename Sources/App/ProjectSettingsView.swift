import SwiftUI

struct ProjectSettingsView: View {
    let projectPath: String
    @Environment(\.dismiss) private var dismiss
    @State private var hooks: ProjectHooks

    init(projectPath: String) {
        self.projectPath = projectPath
        self._hooks = State(initialValue: ProjectHooks.load(for: projectPath))
    }

    private static let variablesHint = "Available variables: {{ branch }}, {{ worktree_path }}, {{ primary_worktree_path }}, {{ repo_path }}"

    var body: some View {
        VStack(spacing: 0) {
            // Title bar with close button
            HStack {
                Button {
                    dismiss()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                        .font(.title2)
                }
                .buttonStyle(.plain)
                .keyboardShortcut(.cancelAction)

                Spacer()

                Text("Project Settings")
                    .font(.headline)

                Spacer()

                // Invisible spacer to center the title
                Image(systemName: "xmark.circle.fill")
                    .font(.title2)
                    .hidden()
            }
            .padding(.horizontal, 16)
            .padding(.top, 12)
            .padding(.bottom, 4)

            Form {
                Section("After Worktree Create") {
                    TextField("Command", text: $hooks.afterCreate)
                        .textFieldStyle(.roundedBorder)
                    Text(Self.variablesHint)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Section("Before Worktree Remove") {
                    TextField("Command", text: $hooks.beforeRemove)
                        .textFieldStyle(.roundedBorder)
                    Text(Self.variablesHint)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .formStyle(.grouped)
        }
        .frame(width: 450, height: 400)
        .onChange(of: hooks.afterCreate) { _ in hooks.save(for: projectPath) }
        .onChange(of: hooks.beforeRemove) { _ in hooks.save(for: projectPath) }
    }
}
