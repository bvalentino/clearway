import SwiftUI

struct SettingsView: View {
    @ObservedObject var settings: SettingsManager

    var body: some View {
        Form {
            Section("Main Terminal") {
                TextField("Command", text: $settings.mainTerminalCommand, prompt: Text("claude"))
                    .textFieldStyle(.roundedBorder)
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Settings")
        .frame(width: 450, height: 120)
    }
}
