import SwiftUI

/// Shown in the side panel when the wtpad CLI is not installed to PATH.
struct WtpadInstallView: View {
    @ObservedObject var installer: CLIInstaller
    var onInstalled: () -> Void

    private var canInstall: Bool {
        WtpadBinary.bundledPath != nil
    }

    var body: some View {
        VStack(spacing: 20) {
            Spacer()

            Image(systemName: "terminal")
                .font(.system(size: 36))
                .foregroundStyle(.secondary)

            VStack(spacing: 8) {
                Text("Install wtpad CLI")
                    .font(.headline)
                Text("Install the command line tool to enable task tracking in your terminal.")
                    .font(.caption)
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            VStack(spacing: 10) {
                Button {
                    installer.install()
                    if installer.isInstalled {
                        onInstalled()
                    }
                } label: {
                    Text("Install Command Line Tools")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(!canInstall)

                if !canInstall {
                    Text("Rebuild the app with Go to embed the CLI.")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }

                Link("View on GitHub", destination: URL(string: "https://github.com/bvalentino/wtpad")!)
                    .font(.caption)
            }

            Spacer()
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
