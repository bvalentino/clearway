import Foundation

/// The user's login shell `PATH`, so subprocesses find tools like `gh` even when the app
/// is launched from Finder / Launchpad, which use a minimal PATH.
///
/// Note: git commands no longer depend on this — they use ``GitResolver`` to find the git
/// binary directly. This PATH is used for non-git tools (hooks, agent commands).
enum ShellEnvironment {

    private static let store = ShellPathStore()

    /// The best known PATH, always unioned with the baseline so `cat`, `rm`, and `ls` are
    /// found whatever the resolution produced. Reading this never starts a resolution.
    static var path: String {
        store.currentPath
    }

    /// A process environment dictionary with the best known PATH. Built on each read: a cached
    /// snapshot would freeze a degraded PATH for the process lifetime.
    ///
    /// Reading it never starts a resolution, so a subprocess spawn cannot open the approval
    /// browser a profile script may wait on. That trigger belongs on an agent launch.
    static var processEnvironment: [String: String] {
        var environment = ProcessInfo.processInfo.environment
        environment["PATH"] = path
        return environment
    }

    /// Resolves the PATH ahead of the first agent launch. Returns at once; the shell runs
    /// on a background queue.
    static func startEagerResolution() {
        store.startResolution()
    }

    /// The PATH for an agent launch, resolving one if none is known yet.
    static func awaitPath() async -> String {
        await store.awaitPath()
    }
}
