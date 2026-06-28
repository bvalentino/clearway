import SwiftUI

struct WorktreeSettingsSheet: View {
    let projectPath: String
    @Environment(\.dismiss) private var dismiss
    @State private var hooks: WorktreeHooks

    init(projectPath: String) {
        self.projectPath = projectPath
        _hooks = State(initialValue: WorktreeHooks.load(for: projectPath))
    }

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 16) {
                Text("Worktree Settings")
                    .font(.headline)

                VStack(alignment: .leading, spacing: 8) {
                    Text("Hooks")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)

                    VStack(alignment: .leading, spacing: 0) {
                        hookField("After create", text: $hooks.afterCreate)
                        Divider()
                            .padding(.vertical, 12)
                        hookField("Before remove", text: $hooks.beforeRemove)
                    }
                    .padding(14)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 10))
                }
            }
            .padding(20)

            Divider()

            HStack {
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
            .padding(16)
        }
        .frame(width: 450)
        .onChange(of: hooks.afterCreate) { _ in hooks.save(for: projectPath) }
        .onChange(of: hooks.beforeRemove) { _ in hooks.save(for: projectPath) }
    }

    private func hookField(_ label: String, text: Binding<String>) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(label)
                .font(.subheadline.weight(.medium))
            TextField("", text: text)
                .textFieldStyle(.roundedBorder)
        }
    }
}
