import SwiftUI

struct SettingsView: View {
    @ObservedObject var settings: SettingsManager
    @EnvironmentObject private var cliInstaller: CLIInstaller

    var body: some View {
        Form {
            Section("Main Terminal") {
                TextField("Command", text: $settings.mainTerminalCommand, prompt: Text("claude"))
                    .textFieldStyle(.roundedBorder)
            }

            Section("Appearance") {
                Toggle("Show focus border on active pane", isOn: $settings.showFocusBorder)
            }

            Section("Command Line Tools") {
                if cliInstaller.isInstalled {
                    HStack {
                        Text("wtpad CLI installed.")
                        Spacer()
                        Button("Uninstall") {
                            cliInstaller.uninstall()
                        }
                    }
                    Text("See `wtpad --help` for more information.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    HStack {
                        Text("wtpad CLI not installed.")
                            .foregroundStyle(.secondary)
                        Spacer()
                        Button("Install Command Line Tools") {
                            cliInstaller.install()
                        }
                        .disabled(WtpadBinary.bundledPath == nil)
                    }
                    Text("Install the wtpad command to /usr/local/bin for use from your terminal.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Settings")
        .frame(width: 450, height: 300)
    }
}
