import SwiftUI

struct SettingsView: View {
    @ObservedObject var settings: SettingsManager

    var body: some View {
        Form {
            Section("Main Terminal") {
                TextField("Command", text: $settings.mainTerminalCommand, prompt: Text("claude"))
                    .textFieldStyle(.roundedBorder)
            }

            Section("Appearance") {
                Toggle("Show focus border on active pane", isOn: $settings.showFocusBorder)
            }

            Section {
                TextField(
                    "Prompts Directory",
                    text: $settings.promptsDirectory,
                    prompt: Text(SettingsManager.defaultPromptsDirectory)
                )
                .textFieldStyle(.roundedBorder)
            } header: {
                Text("Prompts")
            } footer: {
                Text("Directory where reusable prompt files are stored.")
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Settings")
        .frame(width: 450, height: 360)
    }
}
