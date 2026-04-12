import GhosttyKit
import SwiftUI

/// State for an after-create hook running inline in the secondary terminal slot.
struct InlineHook {
    let worktreeId: String
    let hook: HookSheet
}

/// Identifiable state for presenting a hook terminal (sheet or inline).
struct HookSheet: Identifiable {
    let id = UUID()
    let title: String
    let command: String
    let surface: Ghostty.SurfaceView
    /// Called when the hook succeeds (auto) or the user clicks "Run in Background".
    let onContinue: () -> Void
    /// Called when the user clicks "Force remove" after a before-remove hook fails. Nil for after-create hooks.
    var onForce: (() -> Void)?
    /// When true, "Run in Background" remains available even after the hook fails (e.g. after-create hooks).
    /// When false (default), failure hides the button so the hook acts as a blocking gate.
    var allowContinueOnFailure: Bool = false
}

/// Shared view that runs a hook command in a terminal.
/// On success, calls `onContinue` then `onDismiss`. On failure, drops into an
/// interactive shell for debugging with a "Close" button.
struct HookTerminalView: View {
    let hook: HookSheet
    @ObservedObject private var surface: Ghostty.SurfaceView
    let onDismiss: () -> Void
    let showHeader: Bool

    @State private var failed = false
    @State private var completed = false

    init(hook: HookSheet, onDismiss: @escaping () -> Void, showHeader: Bool = true) {
        self.hook = hook
        self._surface = ObservedObject(wrappedValue: hook.surface)
        self.onDismiss = onDismiss
        self.showHeader = showHeader
    }

    var body: some View {
        VStack(spacing: 0) {
            if showHeader {
                header
                Divider()
            }
            TerminalSurface(surfaceView: surface)
        }
        .onChange(of: surface.title) { title in
            if title == hookFailedMarker { failed = true }
        }
        .onReceive(NotificationCenter.default.publisher(for: .ghosttyChildExited, object: surface)) { notification in
            guard let exitCode = notification.userInfo?[GhosttyNotificationKey.exitCode] as? UInt32
            else { return }
            handleChildExit(exitCode)
        }
        .onAppear {
            // Handle the race where the hook process exited before this view rendered,
            // meaning the .onReceive subscriber missed the ghosttyChildExited notification.
            if let exitCode = surface.childExitCode {
                handleChildExit(exitCode)
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                surface.window?.makeFirstResponder(surface)
            }
        }
    }

    private func handleChildExit(_ exitCode: UInt32) {
        if exitCode == 0 {
            guard !completed else { return }
            completed = true
            hook.onContinue()
            onDismiss()
        } else {
            failed = true
        }
    }

    private var header: some View {
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
                Button("Close") { onDismiss() }
                if let onForce = hook.onForce {
                    Button("Force Remove", role: .destructive) {
                        onForce()
                        onDismiss()
                    }
                }
            }
            if !failed || hook.allowContinueOnFailure {
                Button("Run in Background") {
                    guard !completed else { return }
                    completed = true
                    hook.onContinue()
                    onDismiss()
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }
}

/// Modal sheet wrapper for hook terminals (before-remove, before-run).
struct HookTerminalSheet: View {
    let hook: HookSheet
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        HookTerminalView(hook: hook) { dismiss() }
            .frame(minWidth: 600, minHeight: 400)
    }
}
