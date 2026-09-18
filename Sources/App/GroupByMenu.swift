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
