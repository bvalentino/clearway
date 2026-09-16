import SwiftUI
import GhosttyKit

/// The worktree toolbar's Run dropdown: every saved command, in saved order, run in the selected
/// worktree's main terminal.
struct RunCommandMenu: View {
    @EnvironmentObject private var savedCommandManager: SavedCommandManager
    @EnvironmentObject private var terminalManager: TerminalManager
    @EnvironmentObject private var ghosttyApp: Ghostty.App

    let worktree: Worktree

    var body: some View {
        Menu {
            ForEach(savedCommandManager.commands) { command in
                Button(command.name) { run(command) }
            }
        } label: {
            Image(systemName: "play")
        }
        .menuIndicator(.hidden)
        .help("Run a saved command")
        .disabled(savedCommandManager.commands.isEmpty || ghosttyApp.app == nil)
    }

    private func run(_ command: SavedCommand) {
        guard let app = ghosttyApp.app else { return }
        Self.run(command, in: worktree, app: app, terminalManager: terminalManager)
    }
}

extension RunCommandMenu {
    /// Open a new main-terminal tab in `worktree` and hand it the command.
    ///
    /// Static because nothing here reads view state: the run action is the rule, the `Menu` is one
    /// door onto it.
    @MainActor
    static func run(
        _ command: SavedCommand,
        in worktree: Worktree,
        app: ghostty_app_t,
        terminalManager: TerminalManager
    ) {
        switch CommandLaunch.launch(for: command) {
        case .shell(let send):
            let tabId = terminalManager.appendShellTab(for: worktree, app: app)
            guard let surface = terminalManager.mainTabs(for: worktree.id)
                .first(where: { $0.id == tabId })?.surface else { return }
            Task { @MainActor in
                await awaitShellPrompt(on: surface)
                surface.sendLines(send.lines, runsLastLine: send.runsLastLine)
            }

        case .agent(let agent, let prompt, let submit):
            let tabId = terminalManager.appendLauncherTab(for: worktree, app: app, agentOverride: agent)
            guard submit else {
                terminalManager.objectWillChange.send()
                terminalManager.launcherDrafts[tabId] = prompt
                return
            }
            Task { @MainActor in
                await terminalManager.promoteLauncherToAgent(
                    tabId: tabId,
                    in: worktree.id,
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
