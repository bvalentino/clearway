import Foundation

/// The `~/.clearway` layout and the forwarder Clearway installs into it. Text and paths only — the
/// disk is `AgentHookInstaller`'s business.
enum AgentHookScript {
    static let clearwayDir = (NSHomeDirectory() as NSString).appendingPathComponent(".clearway")
    static let hooksDir = (clearwayDir as NSString).appendingPathComponent("hooks")
    static let scriptPath = (hooksDir as NSString).appendingPathComponent("clearway-hook.sh")
    static let socketPath = (clearwayDir as NSString).appendingPathComponent("hook.sock")

    /// `0700` on the directory is the whole access control on the socket: the app is unsandboxed and
    /// binds under `$HOME` rather than on a port, so nothing else gates who can connect.
    static let dirMode = 0o700
    static let scriptMode = 0o755

    /// The tail every Clearway hook entry carries, whatever the user's shell spelling of the prefix.
    /// Recognition is containment of this, never equality with `command`.
    static let scriptPathMarker = "/.clearway/hooks/clearway-hook.sh"

    /// What goes in the hook entry. Both agents run a `command` with no `args` through a shell, so
    /// `"$HOME"` resolves on either.
    static let command = "\"$HOME\"\(scriptPathMarker)"

    /// The forwarder. Three guards, then one `nc` round trip, then an unconditional `exit 0` — a
    /// hook that exits non-zero can block or deny a tool call, and Clearway decides nothing.
    ///
    /// The first guard is what makes an agent Clearway did not launch a no-op; the second keeps a
    /// surface with no worktree — the hook sheet, the debug terminal — from sending a preamble the
    /// server would refuse anyway. `/usr/bin/nc` is absolute so a shadowed `nc` on `PATH` cannot
    /// silently break forwarding, and **never** carries `-N`: macOS reads that as a probe count,
    /// not OpenBSD's shutdown flag. It already shuts the write side on stdin EOF, which is what
    /// lets the server read one connection to EOF.
    static let body = #"""
    #!/bin/sh
    [ -n "$CLEARWAY_SURFACE_ID" ] || exit 0
    [ -n "$CLEARWAY_WORKTREE_ID" ] || exit 0
    [ -S "$CLEARWAY_HOOK_SOCKET" ] || exit 0
    { printf '%s\n%s\n' "$CLEARWAY_SURFACE_ID" "$CLEARWAY_WORKTREE_ID"; cat; } | /usr/bin/nc -U -w 1 "$CLEARWAY_HOOK_SOCKET" >/dev/null 2>&1
    exit 0

    """#

    static let installedEvents = [
        "SessionStart",
        "SessionEnd",
        "UserPromptSubmit",
        "PreToolUse",
        "PostToolUse",
        "PermissionRequest",
        "SubagentStart",
        "SubagentStop",
        "Stop",
    ]
}

/// The identity a surface carries into every agent it hosts, and out of every hook that agent
/// fires. The names live here rather than in `Sources/Ghostty`, which wraps libghostty and must not
/// know Clearway has a hook feature; `Ghostty.SurfaceView` reaches this through a process-scoped
/// provider wired in `ClearwayApp.init`.
enum AgentHookIdentity {
    static let surfaceIdKey = "CLEARWAY_SURFACE_ID"
    static let worktreeIdKey = "CLEARWAY_WORKTREE_ID"
    static let socketKey = "CLEARWAY_HOOK_SOCKET"

    /// The worktree pair is omitted rather than blanked when there is none, so the forwarder's
    /// second guard fires and the surface stays invisible.
    static func environment(surfaceId: UUID, worktreeId: String?) -> [(key: String, value: String)] {
        var pairs = [(key: surfaceIdKey, value: surfaceId.uuidString)]
        if let worktreeId {
            pairs.append((key: worktreeIdKey, value: worktreeId))
        }
        pairs.append((key: socketKey, value: AgentHookScript.socketPath))
        return pairs
    }
}
