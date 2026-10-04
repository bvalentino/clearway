import SwiftUI

struct SkillSettingsSection: View {

    @State private var status: SkillInstallStatus?

    var body: some View {
        Section("Agents") {
            if let status {
                LabeledContent("Clearway Skill") {
                    Button(status.isInstalled ? "Uninstall" : "Install") {
                        if status.isInstalled {
                            SkillInstaller.uninstall(home: NSHomeDirectory(), bundlePath: Bundle.main.bundlePath)
                        } else {
                            SkillInstaller.install(home: NSHomeDirectory(), bundlePath: Bundle.main.bundlePath)
                        }
                        refresh()
                    }
                }
                ForEach(status.messages, id: \.self) { message in
                    Label(message, systemImage: "exclamationmark.triangle")
                        .font(.callout)
                        .foregroundStyle(.red)
                }
            }
        }
        .onAppear(perform: refresh)
    }

    private func refresh() {
        status = SkillInstaller.status(home: NSHomeDirectory(), bundlePath: Bundle.main.bundlePath)
    }
}
