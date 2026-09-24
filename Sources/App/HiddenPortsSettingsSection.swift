import SwiftUI

/// Settings → Hidden Ports. Its own file so `SettingsView` stays a plain `Form`.
struct HiddenPortsSettingsSection: View {

    @ObservedObject var settings: SettingsManager

    var body: some View {
        Section("Hidden Ports") {
            if settings.hiddenPorts.isEmpty {
                Text("None")
                    .foregroundStyle(.secondary)
            } else {
                ForEach(settings.hiddenPorts.sorted(), id: \.self) { port in
                    row(port)
                }
            }
        }
    }

    private func row(_ port: UInt16) -> some View {
        HStack {
            Text(PortLink.label(port))
            Spacer()
            Button {
                settings.unhidePort(port)
            } label: {
                Image(systemName: "minus.circle")
            }
            .buttonStyle(.borderless)
            .help("Unhide")
            .accessibilityLabel("Unhide")
        }
    }
}
