import GhosttyKit
import SwiftUI

/// Identifiable state for presenting a hook terminal sheet.
struct HookSheet: Identifiable {
    let id = UUID()
    let title: String
    let command: String
    let surface: Ghostty.SurfaceView
    /// Called when the hook succeeds (auto) or the user clicks "Run in Background".
    let onContinue: () -> Void
    /// Called when the user clicks "Force remove" after a before-remove hook fails. Nil for after-create hooks.
    var onForce: (() -> Void)?
}

/// A modal sheet that runs a hook command in a terminal.
/// Auto-dismisses on success. On failure, drops into an interactive
/// shell for debugging with a "Close" button.
struct HookTerminalSheet: View {
    let hook: HookSheet
    @ObservedObject var surface: Ghostty.SurfaceView
    @Environment(\.dismiss) private var dismiss
    @State private var failed = false

    var body: some View {
        VStack(spacing: 0) {
            header(failed: failed)
            Divider()
            TerminalSurface(surfaceView: hook.surface)
        }
        .frame(minWidth: 600, minHeight: 400)
        .onChange(of: surface.title) { title in
            if title == hookFailedMarker { failed = true }
        }
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

    private func header(failed: Bool) -> some View {
        HStack(spacing: 8) {
            if failed {
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(.red)
            } else {
                ProgressView()
                    .controlSize(.small)
            }

            VStack(alignment: .leading, spacing: 2) {
                Text(hook.title)
                    .font(.callout.bold())
                Text(hook.command)
                    .font(.callout.monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer()

            if failed {
                Button("Close") { dismiss() }
                if let onForce = hook.onForce {
                    Button("Force Remove", role: .destructive) {
                        onForce()
                        dismiss()
                    }
                }
            } else {
                Button("Run in Background") {
                    hook.onContinue()
                    dismiss()
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }
}
