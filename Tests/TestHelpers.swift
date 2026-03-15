@testable import wtpad

func makeWorktree(
    branch: String? = "test",
    path: String? = "/tmp/test",
    isMain: Bool = false
) -> Worktree {
    Worktree(
        branch: branch,
        path: path,
        isMain: isMain
    )
}
