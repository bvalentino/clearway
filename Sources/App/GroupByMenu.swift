import SwiftUI

/// The gear in the sidebar's Worktrees header: the axis the list sections by, then the
/// worktree settings sheet.
struct GroupByMenu: View {
    @EnvironmentObject private var groupManager: WorktreeGroupManager
    let onSettings: () -> Void

    var body: some View {
        SidebarHeaderMenu(systemImage: "gearshape") {
            Picker("Group by", selection: Binding(
                get: { groupManager.grouping },
                set: { groupManager.setGrouping($0) }
            )) {
                ForEach(WorktreeGrouping.allCases) { grouping in
                    Text(grouping.displayName).tag(grouping)
                }
            }
            .pickerStyle(.inline)

            Divider()

            Button("Worktree Settings…", action: onSettings)
        }
    }
}

/// A borderless menu sized to match `SidebarHeaderButton`, for the sidebar's section headers.
struct SidebarHeaderMenu<Content: View>: View {
    let systemImage: String
    @ViewBuilder let content: Content

    var body: some View {
        Menu {
            content
        } label: {
            Image(systemName: systemImage)
                .font(.body)
                .frame(width: 24, height: 24)
                .contentShape(Rectangle())
                .foregroundStyle(.secondary)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
    }
}
