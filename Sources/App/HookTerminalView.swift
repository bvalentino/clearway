import GhosttyKit
import SwiftUI

/// Identifiable state for presenting a hook terminal sheet.
struct HookSheet: Identifiable {
    let id = UUID()
    let title: String
    let command: String
    let surface: Ghostty.SurfaceView
    /// Called when the hook succeeds (auto) or the user clicks "Continue Anyway" after failure.
    let onContinue: () -> Void
}

/// A modal sheet that runs a hook command in a terminal.
/// Auto-dismisses on success. On failure, drops into an interactive
/// shell and shows Cancel / Continue Anyway buttons.
struct HookTerminalSheet: View {
    let hook: HookSheet
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            TerminalSurface(surfaceView: hook.surface)
        }
        .frame(minWidth: 600, minHeight: 400)
        .onReceive(NotificationCenter.default.publisher(for: .ghosttyChildExited)) { notification in
            guard let surface = notification.object as? Ghostty.SurfaceView,
                  surface === hook.surface,
                  let exitCode = notification.userInfo?[GhosttyNotificationKey.exitCode] as? UInt32,
                  exitCode == 0 else { return }
            hook.onContinue()
            dismiss()
        }
        .onAppear {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                hook.surface.window?.makeFirstResponder(hook.surface)
            }
        }
    }

    private var header: some View {
        HStack(spacing: 8) {
            ProgressView()
                .controlSize(.small)

            VStack(alignment: .leading, spacing: 2) {
                Text(hook.title)
                    .font(.callout.bold())
                Text(hook.command)
                    .font(.callout.monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer()

            Button("Run in Background") {
                hook.onContinue()
                dismiss()
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }
}
