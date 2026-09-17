import GhosttyKit

/// Running a `SavedCommand` in a worktree.
///
/// On the manager rather than in the Run dropdown because a view resolves no worktree and awaits
/// nothing: this opens the tab, waits for the shell's first prompt, and picks between staging the
/// prompt and promoting the tab.
extension TerminalManager {

    /// Open a new main-terminal tab in `worktree` and hand it `command`.
    func run(_ command: SavedCommand, in worktree: Worktree, app: ghostty_app_t) {
        switch CommandLaunch.launch(for: command) {
        case .shell(let send):
            guard let surface = appendShellTab(for: worktree, app: app) else { return }
            Task { @MainActor in
                await Self.awaitShellPrompt(on: surface)
                for step in send.steps {
                    switch step {
                    case .text(let line): surface.sendText(line)
                    case .enter: surface.sendEnter()
                    }
                }
            }

        case .agent(let agent, let prompt, let submit):
            let worktreeId = worktree.id
            let tabId = appendLauncherTab(for: worktree, app: app, agentOverride: agent)
            guard submit else {
                objectWillChange.send()
                launcherDrafts[tabId] = prompt
                return
            }
            Task { @MainActor in
                await promoteLauncherToAgent(
                    tabId: tabId,
                    in: worktreeId,
                    app: app,
                    command: agent,
                    prompt: prompt
                )
            }
        }
    }

    /// Wait until a freshly spawned shell is at a prompt before injecting into it.
    ///
    /// The gate is the first non-`nil` `pwd`, which libghostty publishes from the OSC 7 that shell
    /// integration emits at the prompt. Measured on a live surface: zsh reported it 196-218 ms after
    /// the tab was appended, and text sent on that edge landed on a fully rendered prompt line and
    /// ran exactly once. Injecting with no gate at all is *not* safe to ship even though it executes:
    /// the tty queue buffers the text, so it is echoed above the login banner and then replayed onto
    /// a half-built prompt, leaving a garbled tab.
    ///
    /// `shellReadinessFallback` is for shells Ghostty injects no integration into, where `pwd` never
    /// arrives — `/bin/dash -i` never reported one, and the wait timed out at 763 ms, after which
    /// both the run and the stage landed cleanly on dash's prompt. 750 ms is ~3.5x the observed
    /// 200 ms prompt latency, and only a shell that reports nothing ever pays it.
    private static func awaitShellPrompt(on surface: Ghostty.SurfaceView) async {
        let deadline = ContinuousClock.now + shellReadinessFallback
        while surface.pwd == nil, ContinuousClock.now < deadline {
            try? await Task.sleep(for: shellReadinessPoll)
        }
    }
}

private let shellReadinessFallback: Duration = .milliseconds(750)
private let shellReadinessPoll: Duration = .milliseconds(10)
