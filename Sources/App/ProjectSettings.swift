import CryptoKit
import Foundation

/// Per-project settings stored in UserDefaults.
enum ProjectSettings {
}

/// Per-project hook configuration stored in UserDefaults.
struct ProjectHooks {
    var afterCreate: String
    var beforeRemove: String

    /// Template variables available for hook command interpolation.
    struct Context {
        let branch: String
        let worktreePath: String
        let primaryWorktreePath: String
    }

    /// Returns the interpolated command for a hook, or nil if the hook is empty.
    /// All variable values are shell-escaped to prevent injection via crafted branch names or paths.
    func interpolated(_ keyPath: KeyPath<ProjectHooks, String>, context: Context) -> String? {
        let template = self[keyPath: keyPath]
        guard !template.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return template
            .replacingOccurrences(of: "{{ branch }}", with: shellEscape(context.branch))
            .replacingOccurrences(of: "{{ worktree_path }}", with: shellEscape(context.worktreePath))
            .replacingOccurrences(of: "{{ primary_worktree_path }}", with: shellEscape(context.primaryWorktreePath))
            .replacingOccurrences(of: "{{ repo_path }}", with: shellEscape(context.primaryWorktreePath))
    }

    /// Chains two optional shell commands with `&&`, returning nil if both are nil.
    static func chainCommands(_ first: String?, _ second: String?) -> String? {
        switch (first, second) {
        case let (a?, b?): "(\(a)) && (\(b))"
        case let (a?, nil): a
        case let (nil, b?): b
        case (nil, nil): nil
        }
    }

    // MARK: - Persistence

    static func load(for projectPath: String, defaults: UserDefaults = .standard) -> ProjectHooks {
        let prefix = ProjectHooks.keyPrefix(for: projectPath)
        return ProjectHooks(
            afterCreate: defaults.string(forKey: "\(prefix).hook.post_create") ?? "",
            beforeRemove: defaults.string(forKey: "\(prefix).hook.pre_remove") ?? ""
        )
    }

    func save(for projectPath: String, defaults: UserDefaults = .standard) {
        let prefix = ProjectHooks.keyPrefix(for: projectPath)
        defaults.set(afterCreate, forKey: "\(prefix).hook.post_create")
        defaults.set(beforeRemove, forKey: "\(prefix).hook.pre_remove")
    }

    static func keyPrefix(for projectPath: String) -> String {
        let hash = SHA256.hash(data: Data(projectPath.utf8))
        let hex = hash.prefix(8).map { String(format: "%02x", $0) }.joined()
        return "clearway.project.\(hex)"
    }
}
