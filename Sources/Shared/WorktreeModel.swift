import Foundation

enum HeadStatus {
    case attached
    case rebasing
    case bisecting
    /// A git operation that records no branch name is in progress: cherry-pick, revert, merge or
    /// `git am`. HEAD is detached, but not bare-detached, so the row stays as visible and as
    /// unremovable as `.rebasing`/`.bisecting`.
    case inProgress
    case detached
}

/// A worktree entry parsed from `git worktree list --porcelain`.
struct Worktree: Identifiable, Hashable {
    var id: String { path ?? branch ?? "" }

    let branch: String?
    let path: String?
    let isMain: Bool
    let headStatus: HeadStatus

    var displayName: String { branch ?? "(detached)" }

    var canRemove: Bool { headStatus == .attached }
    var canFetchPR: Bool { headStatus == .attached }

    /// The rule `TerminalManager.isOpen` applies, lifted here so `visible` can reach it without
    /// the manager. Widening "open" means widening it here, for both callers.
    func isOpen(openIds: [String]) -> Bool {
        isMain || openIds.contains(id)
    }

    static func visible(_ worktrees: [Worktree], showingDetached: Bool, openIds: [String]) -> [Worktree] {
        guard !showingDetached else { return worktrees }
        return worktrees.filter { worktree in
            worktree.headStatus != .detached || worktree.isOpen(openIds: openIds)
        }
    }

    /// Sort worktrees: main first, then open (by open order), then closed (alphabetical).
    static func sorted(_ worktrees: [Worktree], openIds: [String]) -> [Worktree] {
        let openOrder = Dictionary(uniqueKeysWithValues: openIds.enumerated().map { ($1, $0) })
        return worktrees.sorted { a, b in
            if a.isMain != b.isMain { return a.isMain }
            let aIdx = openOrder[a.id]
            let bIdx = openOrder[b.id]
            if let ai = aIdx, let bi = bIdx { return ai < bi }
            if (aIdx == nil) != (bIdx == nil) { return aIdx != nil }
            return a.displayName.localizedCaseInsensitiveCompare(b.displayName) == .orderedAscending
        }
    }
}

extension Worktree {
    /// Parses `git worktree list --porcelain` output into `Worktree` entries.
    static func parseList(_ output: String) -> [Worktree] {
        let blocks = output.components(separatedBy: "\n\n").filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        var worktrees: [Worktree] = []

        for (index, block) in blocks.enumerated() {
            let lines = block.components(separatedBy: "\n")
            var path: String?
            var branch: String?
            var isDetached = false

            for line in lines {
                if line.hasPrefix("worktree ") {
                    path = String(line.dropFirst("worktree ".count))
                } else if line.hasPrefix("branch refs/heads/") {
                    branch = String(line.dropFirst("branch refs/heads/".count))
                } else if line == "detached" {
                    isDetached = true
                }
            }

            // Skip entries with no path (shouldn't happen with porcelain output)
            guard path != nil else { continue }

            let isMain = index == 0
            if isDetached { branch = nil }
            let headStatus: HeadStatus = isDetached ? .detached : .attached

            worktrees.append(Worktree(branch: branch, path: path, isMain: isMain, headStatus: headStatus))
        }

        return worktrees
    }
}
