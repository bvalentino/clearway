import SwiftUI

/// The gear in the sidebar's Worktrees header: the axis the list sections by, then the
/// worktree settings sheet. Copies `GroupSectionHeader`'s borderless-menu-in-a-header shape.
struct GroupByMenu: View {
    @EnvironmentObject private var groupManager: WorktreeGroupManager
    let onSettings: () -> Void

    var body: some View {
        Menu {
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
        } label: {
            Image(systemName: "gearshape")
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
