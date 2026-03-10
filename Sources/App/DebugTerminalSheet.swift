import SwiftUI
import GhosttyKit

struct DebugTerminalSheet: View {
    let error: String
    let projectPath: String
    @EnvironmentObject private var ghosttyApp: Ghostty.App
    @Environment(\.dismiss) private var dismiss
    @State private var surface: Ghostty.SurfaceView?

    var body: some View {
        VStack(spacing: 0) {
            // Error banner
            HStack {
                Label("Error loading worktrees", systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.red)
                    .font(.callout.bold())
                Spacer()
                Button("Close") { dismiss() }
                    .keyboardShortcut(.cancelAction)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)

            Text(error)
                .foregroundStyle(.secondary)
                .font(.callout)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 12)
                .padding(.bottom, 8)

            Divider()

            // Terminal
            if let surface {
                TerminalSurface(surfaceView: surface)
            } else {
                Spacer()
                Text("Terminal unavailable")
                    .foregroundStyle(.secondary)
                Spacer()
            }
        }
        .frame(minWidth: 600, minHeight: 400)
        .onAppear {
            guard let app = ghosttyApp.app else { return }
            surface = Ghostty.SurfaceView(app, workingDirectory: projectPath)
        }
        .onDisappear {
            surface?.closeSurface()
            surface = nil
        }
        .onReceive(NotificationCenter.default.publisher(for: .ghosttyCloseSurface)) { notification in
            guard let deadSurface = notification.object as? Ghostty.SurfaceView,
                  deadSurface === surface,
                  let processAlive = notification.userInfo?[GhosttyNotificationKey.processAlive] as? Bool,
                  !processAlive else { return }
            dismiss()
        }
    }
}
