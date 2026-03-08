import SwiftUI

struct ContentView: View {
    @EnvironmentObject private var ghosttyApp: Ghostty.App

    var body: some View {
        Group {
            switch ghosttyApp.readiness {
            case .loading:
                ProgressView("Loading terminal...")

            case .error:
                VStack(spacing: 12) {
                    Image(systemName: "exclamationmark.triangle")
                        .font(.largeTitle)
                    Text("Failed to initialize terminal")
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)

            case .ready:
                if let app = ghosttyApp.app {
                    TerminalSurface(app: app)
                }
            }
        }
    }
}
