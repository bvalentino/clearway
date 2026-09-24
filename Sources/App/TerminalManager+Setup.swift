import Foundation
import GhosttyKit

extension TerminalManager {

    /// Open the background "Setup" tab and run the After create hook at its first prompt, leaving
    /// the login shell live when the hook ends.
    func openSetupTab(for worktree: Worktree, app: ghostty_app_t, hook: String) {
        let surface = appendTab(for: worktree, app: app, name: "Setup", activate: false)
        Task { @MainActor in
            let path = await ShellEnvironment.awaitPath()
            await Self.awaitShellPrompt(on: surface)
            surface.sendPaste(hookShellCommand(hook, path: path))
        }
    }
}
