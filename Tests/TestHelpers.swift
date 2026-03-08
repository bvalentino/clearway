@testable import wtpad

func makeWorktree(
    branch: String? = "test",
    path: String? = "/tmp/test",
    isMain: Bool = false,
    mainState: String? = nil,
    operationState: String? = nil,
    commitMessage: String = "test",
    ciStatus: String? = nil
) -> Worktree {
    Worktree(
        branch: branch,
        path: path,
        kind: "worktree",
        commit: Worktree.Commit(sha: "abc", shortSha: "abc", message: commitMessage, timestamp: 1),
        workingTree: nil,
        mainState: mainState ?? (isMain ? "is_main" : nil),
        integrationReason: nil,
        operationState: operationState,
        main: nil,
        remote: nil,
        worktree: Worktree.WorktreeMeta(state: nil, reason: nil, detached: false),
        ci: ciStatus.map { Worktree.CI(status: $0, source: nil, stale: nil, url: nil) },
        isMain: isMain,
        isCurrent: false,
        isPrevious: false,
        symbols: nil
    )
}
