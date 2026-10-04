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

extension Worktree {
    static func gitdir(forWorktreeAt worktreePath: String) -> String? {
        let dotGit = (worktreePath as NSString).appendingPathComponent(".git")
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: dotGit, isDirectory: &isDir) else { return nil }
        if isDir.boolValue { return dotGit }
        guard let raw = try? String(contentsOfFile: dotGit, encoding: .utf8) else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("gitdir: ") else { return nil }
        let pathPart = String(trimmed.dropFirst("gitdir: ".count)).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !pathPart.isEmpty else { return nil }
        if pathPart.hasPrefix("/") {
            return pathPart
        }
        let base = URL(fileURLWithPath: worktreePath, isDirectory: true)
        return URL(fileURLWithPath: pathPart, relativeTo: base).standardizedFileURL.path
    }

    /// The git operation in progress in `gitdir`, if any, with the branch name the operation
    /// recorded. The markers are git's own, as its shipped `git-prompt.sh` reads them; only rebase
    /// and bisect record a branch, so the other four leave the row's "(detached)" display name and
    /// it is `.inProgress` that keeps it out of `Worktree.visible`'s hidden set.
    ///
    /// The branch-recovering probes run first because a conflicted `rebase -i` leaves
    /// `CHERRY_PICK_HEAD` beside its rebase state, and the branch is the better answer there.
    /// `rebase-apply/applying` is what separates `git am` from `git rebase --apply`, which writes
    /// `head-name` into the same directory.
    static func inProgressOp(gitdir: String) -> (branch: String?, status: HeadStatus)? {
        let branchProbes: [(String, HeadStatus)] = [
            ("rebase-merge/head-name", .rebasing),
            ("rebase-apply/head-name", .rebasing),
            ("BISECT_START", .bisecting),
        ]
        for (relative, status) in branchProbes {
            let path = (gitdir as NSString).appendingPathComponent(relative)
            guard let raw = try? String(contentsOfFile: path, encoding: .utf8) else { continue }
            var name = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            if name.hasPrefix("refs/heads/") {
                name = String(name.dropFirst("refs/heads/".count))
            }
            if !name.isEmpty {
                return (name, status)
            }
        }

        let branchlessMarkers = [
            "rebase-apply/applying",
            "MERGE_HEAD",
            "CHERRY_PICK_HEAD",
            "REVERT_HEAD",
        ]
        for relative in branchlessMarkers {
            let path = (gitdir as NSString).appendingPathComponent(relative)
            if FileManager.default.fileExists(atPath: path) {
                return (nil, .inProgress)
            }
        }
        return nil
    }

    static func applyHeadResolution(to worktrees: [Worktree]) -> [Worktree] {
        worktrees.map { wt in
            guard wt.headStatus == .detached, let path = wt.path else { return wt }
            guard let gitdir = gitdir(forWorktreeAt: path),
                  let op = inProgressOp(gitdir: gitdir) else { return wt }
            return Worktree(
                branch: op.branch,
                path: wt.path,
                isMain: wt.isMain,
                headStatus: op.status
            )
        }
    }

    /// The worktrees whose `TASK.md` is visible: those with both a branch and a path. `worktrees`
    /// must be head-resolved, so a rebase or bisect counts. This is the one rule both the app's
    /// Tasks list and `cway task` use.
    static func taskCarriers(_ worktrees: [Worktree]) -> [(branch: String, path: String)] {
        worktrees.compactMap { worktree in
            guard let branch = worktree.branch, let path = worktree.path else { return nil }
            return (branch, path)
        }
    }
}
