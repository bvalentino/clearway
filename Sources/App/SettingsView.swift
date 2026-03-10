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
        }
        .formStyle(.grouped)
        .navigationTitle("Settings")
        .frame(width: 450, height: 220)
    }
}
