import SwiftUI
import GhosttyKit

// Virtual key codes (Carbon.HIToolbox causes type-checker slowdown in ContentView).
let kVK_Return: UInt16 = 0x24, kVK_ANSI_KeypadEnter: UInt16 = 0x4C
let kVK_UpArrow: UInt16 = 0x7E, kVK_DownArrow: UInt16 = 0x7D

/// Marker set as the terminal title when a hook command fails.
let hookFailedMarker = "__clearway_hook_failed__"

/// Wraps a hook command for use as a Ghostty surface `command:` parameter.
/// Runs the hook through `/bin/sh`, then drops into the user's shell so
/// the terminal stays interactive for debugging.
func hookShellCommand(_ cmd: String) -> String {
    var shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/sh"
    if !shell.hasPrefix("/") || shell.contains("'") || shell.contains(" ") {
        shell = "/bin/sh"
    }
    let exportPath = "export PATH=\(shellEscape(ShellEnvironment.path)); "
    return "/bin/sh -c \(shellEscape(exportPath + "(" + cmd + "); s=$?; if [ $s -ne 0 ]; then printf '\\e]0;\(hookFailedMarker)\\a'; exec \(shell); fi; exit $s"))"
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

/// Tracks the content column width without triggering SwiftUI view updates.
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
            if let wt = worktree, !wt.isMain, wt.branch != nil {
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
                .contentShape(Rectangle()).pointingHandCursor()
                .onTapGesture { worktreeManager.checkPR(for: wtId) }
                .help("Click to re-check")
        case nil:
            HStack(spacing: 4) { Image(systemName: "arrow.triangle.pull"); Text("Check PR") }
                .font(.system(size: 11)).foregroundStyle(.secondary)
                .contentShape(Rectangle()).pointingHandCursor()
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
                    .foregroundStyle(.white)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(.black.opacity(0.6), in: RoundedRectangle(cornerRadius: 6))
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

private extension View {
    func pointingHandCursor() -> some View {
        onHover { if $0 { NSCursor.pointingHand.push() } else { NSCursor.pop() } }
    }
}
