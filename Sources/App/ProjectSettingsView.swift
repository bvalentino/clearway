import SwiftUI

struct ProjectSettingsView: View {
    let projectPath: String
    @State private var hooks: ProjectHooks

    init(projectPath: String) {
        self.projectPath = projectPath
        self._hooks = State(initialValue: ProjectHooks.load(for: projectPath))
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
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
            }
            .padding(32)
            .frame(maxWidth: 680)
            .frame(maxWidth: .infinity)
        }
        .onChange(of: hooks.afterCreate) { _ in hooks.save(for: projectPath) }
        .onChange(of: hooks.beforeRemove) { _ in hooks.save(for: projectPath) }
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
