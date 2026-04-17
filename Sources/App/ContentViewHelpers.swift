import SwiftUI
import GhosttyKit
import os

// Virtual key codes (Carbon.HIToolbox causes type-checker slowdown in ContentView).
let kVK_Return: UInt16 = 0x24, kVK_ANSI_KeypadEnter: UInt16 = 0x4C
let kVK_UpArrow: UInt16 = 0x7E, kVK_DownArrow: UInt16 = 0x7D

private let hookLogger = Logger(
    subsystem: Bundle.main.bundleIdentifier ?? "app.getclearway.mac",
    category: "hook"
)

/// Wraps a hook command for use as a Ghostty surface `command:` parameter.
///
/// Runs the hook through `/bin/sh` with the resolved user PATH exported. On
/// failure, prints a red banner with the exit status and then exits with the
/// same status — so `ghosttyChildExited` fires reliably, letting the UI
/// transition into a visible "failed" state (with output preserved on screen).
func hookShellCommand(_ cmd: String) -> String {
    let resolvedPath = ShellEnvironment.path
    let exportPath = "export PATH=\(shellEscape(resolvedPath)); "
    let failBanner = "printf '\\n\\033[31m[hook failed: exit %d]\\033[0m\\n' \"$s\""
    let script = exportPath + "(" + cmd + "); s=$?; if [ $s -ne 0 ]; then \(failBanner); fi; exit $s"
    let wrapped = "/bin/sh -c \(shellEscape(script))"
    hookLogger.info("hook command: \(cmd, privacy: .private)")
    hookLogger.debug("wrapped: \(wrapped, privacy: .private)")
    return wrapped
}

enum SidePanelTab: String, CaseIterable {
    case task = "Task"
    case todos = "Todos"
    case notes = "Notes"
    case prompts = "Prompts"
}

/// Tracks the lifecycle of an after-create hook: blocking the main terminal,
/// running in background, or inactive.
enum AfterCreateHookState {
    case none
    case blocking(InlineHook)
    case background(InlineHook)
    case failed(InlineHook)

    var inlineHook: InlineHook? {
        switch self {
        case .none: return nil
        case .blocking(let hook), .background(let hook), .failed(let hook): return hook
        }
    }

    var isFailed: Bool {
        if case .failed = self { return true }
        return false
    }
}

/// Tracks the content column's live width without triggering SwiftUI view updates.
///
/// This is intentionally a bare reference class, not `@Observable`, `ObservableObject`,
/// or `@Published`. Mutating `width` must NOT invalidate any view body. Why: the column
/// width is passed as `ideal:` to `.navigationSplitViewColumnWidth`, and SwiftUI re-seeds
/// the column to `ideal` whenever that modifier is re-evaluated with a changed value.
/// If this tracker triggered re-renders during a drag, the user's dragged width would
/// snap back mid-drag. See `commitListsColumnWidth()` for where the value is persisted.
class ColumnWidthTracker {
    var width: CGFloat = 340
}

/// Status bar showing the worktree path and PR status at the bottom of the detail pane.
struct WorktreeStatusBar: View {
    let path: String
    let worktree: Worktree?
    @Binding var showCopiedFeedback: Bool
    @EnvironmentObject private var worktreeManager: WorktreeManager

    var body: some View {
        HStack(spacing: 0) {
            Text(showCopiedFeedback ? "Copied!" : path)
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(showCopiedFeedback ? .primary : .secondary)
                .lineLimit(1)
                .truncationMode(.middle)
                .animation(.easeInOut(duration: 0.15), value: showCopiedFeedback)
                .contentShape(Rectangle())
                .onTapGesture {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(path, forType: .string)
                    showCopiedFeedback = true
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1) { showCopiedFeedback = false }
                }
            Spacer()
            if let wt = worktree, !wt.isMain {
                prStatusView(for: wt.id)
            }
        }
        .padding(.horizontal, 20)
        .padding(.top, 10)
        .padding(.bottom, 12)
        .background(.bar)
        .overlay(alignment: .top) { Divider() }
    }

    @ViewBuilder
    private func prStatusView(for wtId: String) -> some View {
        switch worktreeManager.worktreePRStates[wtId] {
        case .loading:
            Text("Checking…").font(.system(size: 11)).foregroundStyle(.secondary)
        case .result(let pr?):
            HStack(spacing: 5) {
                Text("#\(pr.number)").font(.system(size: 11, design: .monospaced)).foregroundStyle(.primary)
                Text("·").foregroundStyle(.tertiary)
                Text(pr.title).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1).truncationMode(.tail)
            }
            .contentShape(Rectangle())
            .onTapGesture {
                if let url = URL(string: pr.url), url.scheme == "https" { NSWorkspace.shared.open(url) }
            }
        case .result(nil):
            HStack(spacing: 4) { Image(systemName: "arrow.triangle.pull"); Text("No PR") }
                .font(.system(size: 11)).foregroundStyle(.secondary)
                .contentShape(Rectangle()).pointerCursorOnHover()
                .onTapGesture { worktreeManager.checkPR(for: wtId) }
                .help("Click to re-check")
        case nil:
            HStack(spacing: 4) { Image(systemName: "arrow.triangle.pull"); Text("Check PR") }
                .font(.system(size: 11)).foregroundStyle(.secondary)
                .contentShape(Rectangle()).pointerCursorOnHover()
                .onTapGesture { worktreeManager.checkPR(for: wtId) }
                .help("Check for pull request")
        }
    }
}

/// A terminal pane that observes its surface's focus state and draws a border when focused.
struct FocusableTerminal: View {
    @ObservedObject var surfaceView: Ghostty.SurfaceView
    let badge: String
    let ctrlHeld: Bool
    let showBorder: Bool

    var body: some View {
        TerminalSurface(surfaceView: surfaceView)
            .overlay(alignment: .topLeading) {
                Text(badge)
                    .font(.system(size: 12, weight: .medium, design: .rounded))
                    .foregroundStyle(Color(nsColor: .textBackgroundColor))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(Color(nsColor: .labelColor).opacity(0.75), in: RoundedRectangle(cornerRadius: 6))
                    .padding(8)
                    .allowsHitTesting(false)
                    .opacity(ctrlHeld ? 1 : 0)
            }
            .overlay {
                if showBorder && surfaceView.focused {
                    Rectangle()
                        .strokeBorder(Color.accentColor, lineWidth: 1)
                        .allowsHitTesting(false)
                }
            }
    }
}

/// Uses AppKit cursor rects so the pointing-hand takes priority over
/// I-beam rects set by surrounding text views.
struct PointerCursorOnHover: ViewModifier {
    func body(content: Content) -> some View {
        content.overlay(PointerCursorOverlay())
    }
}

private struct PointerCursorOverlay: NSViewRepresentable {
    func makeNSView(context: Context) -> PointerCursorNSView { PointerCursorNSView() }
    func updateNSView(_: PointerCursorNSView, context: Context) {}
}

private class PointerCursorNSView: NSView {
    // Return nil so clicks pass through to the SwiftUI button underneath.
    // NSWindow tracks cursor rects independently of hit testing, so the
    // pointing-hand cursor still appears.
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .pointingHand)
    }
}

extension View {
    func pointerCursorOnHover() -> some View {
        modifier(PointerCursorOnHover())
    }
}
