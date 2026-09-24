import SwiftUI

struct SettingsView: View {
    @ObservedObject var settings: SettingsManager
    @ObservedObject var agentActivity: AgentActivityMonitor

    var body: some View {
        Form {
            Section {
                Picker("Command", selection: $settings.mainTerminalCommand) {
                    Text("None").tag("")
                    ForEach(agentAllowlist, id: \.self) { agent in
                        Text(agent).tag(agent)
                    }
                }
            } header: {
                Text("Main Terminal")
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
                Toggle("Show detached worktrees", isOn: $settings.showDetachedWorktrees)
                // The one subtitle in the app: Codex skips a hook it has not been told to trust,
                // so without this line its users see a toggle that is on and does nothing.
                Toggle(isOn: $settings.agentHooksEnabled) {
                    Text("Show agent activity")
                    Text("Codex requires running /hooks once to trust the hooks Clearway installs.")
                }
                if let message = agentActivity.health.message {
                    Label(message, systemImage: "exclamationmark.triangle")
                        .font(.callout)
                        .foregroundStyle(.red)
                }
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

            OpenInAppsSettingsSection(settings: settings)
            HiddenPortsSettingsSection(settings: settings)
        }
        .formStyle(.grouped)
        .navigationTitle("Settings")
        .frame(width: 450, height: 560)
    }
}
