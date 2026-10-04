import SwiftUI

struct SkillSettingsSection: View {

    @State private var status: SkillInstallStatus?
    @State private var failures: [SkillInstaller.Failure] = []

    var body: some View {
        Section("Agents") {
            if let status {
                LabeledContent("Clearway Skill") {
                    Button(status.isInstalled ? "Uninstall" : "Install") {
                        let act = status.isInstalled ? SkillInstaller.uninstall : SkillInstaller.install
                        failures = act(NSHomeDirectory(), Bundle.main.bundlePath)
                        refresh()
                    }
                }
                ForEach(failures.map(\.message) + status.messages, id: \.self) { message in
                    Label(message, systemImage: "exclamationmark.triangle")
                        .font(.callout)
                        .foregroundStyle(.red)
                }
            }
        }
        .onAppear {
            failures = []
            refresh()
        }
    }

    private func refresh() {
        status = SkillInstaller.status(home: NSHomeDirectory(), bundlePath: Bundle.main.bundlePath)
    }
}
