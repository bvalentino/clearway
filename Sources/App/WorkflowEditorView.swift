import SwiftUI

/// The **Workflow** section's detail pane — authors a project's `.clearway/WORKFLOW.json` as a
/// stack of action cards. Stub for the navigation-plumbing slice; the editor UI lands in Phase 3.
struct WorkflowEditorView: View {
    let projectPath: String

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                Text("Workflow")
                    .font(.largeTitle.weight(.bold))
            }
            .padding(32)
            .frame(maxWidth: 680)
            .frame(maxWidth: .infinity)
        }
    }
}
