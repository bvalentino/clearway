@testable import Clearway

func makeWorktree(
    branch: String? = "test",
    path: String? = "/tmp/test",
    isMain: Bool = false,
    headStatus: HeadStatus = .attached
) -> Worktree {
    Worktree(
        branch: branch,
        path: path,
        isMain: isMain,
        headStatus: headStatus
    )
}
