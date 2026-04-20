import SwiftUI

struct SettingsView: View {
    @ObservedObject var settings: SettingsManager

    var body: some View {
        Form {
            Section {
                Picker("Command", selection: $settings.mainTerminalCommand) {
                    Text("None").tag("")
                    Text("claude").tag("claude")
                }
            } header: {
                Text("Main Terminal")
            } footer: {
                Text("Choose \"None\" to open new tabs directly in a login shell.")
            }

            Section("Appearance") {
                Picker("Color Scheme", selection: $settings.colorScheme) {
                    Text("System").tag(ColorSchemePreference.system)
                    Text("Light").tag(ColorSchemePreference.light)
                    Text("Dark").tag(ColorSchemePreference.dark)
                }
                .pickerStyle(.segmented)
                Toggle("Show focus border on active pane", isOn: $settings.showFocusBorder)
                Toggle("Open secondary terminal on start", isOn: $settings.openSecondaryOnStart)
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
        .frame(width: 450, height: 420)
    }
}
