import CryptoKit
import Foundation

/// Per-project settings stored in UserDefaults.
enum ProjectSettings {
    static let defaultMaxConcurrentAgents = 2

    /// How often auto-processing polls for ready tasks.
    /// `0` means disabled (default).
    enum PollingInterval: Int, CaseIterable {
        case disabled = 0
        case fiveSeconds = 5
        case fifteenSeconds = 15
        case thirtySeconds = 30
        case sixtySeconds = 60

        var label: String {
            switch self {
            case .disabled: return "Disabled"
            case .fiveSeconds: return "5 seconds"
            case .fifteenSeconds: return "15 seconds"
            case .thirtySeconds: return "30 seconds"
            case .sixtySeconds: return "60 seconds"
            }
        }
    }

    // MARK: - Max Concurrent Agents

    static func maxConcurrentAgents(for projectPath: String) -> Int {
        let key = "\(ProjectHooks.keyPrefix(for: projectPath)).maxConcurrentAgents"
        let value = UserDefaults.standard.object(forKey: key) as? Int
        return max(1, min(value ?? defaultMaxConcurrentAgents, 16))
    }

    static func setMaxConcurrentAgents(_ value: Int, for projectPath: String) {
        let key = "\(ProjectHooks.keyPrefix(for: projectPath)).maxConcurrentAgents"
        let clamped = max(1, min(value, 16))
        UserDefaults.standard.set(clamped, forKey: key)
    }

    // MARK: - Polling Interval

    static func pollingInterval(for projectPath: String) -> PollingInterval {
        let key = "\(ProjectHooks.keyPrefix(for: projectPath)).pollingInterval"
        let raw = UserDefaults.standard.object(forKey: key) as? Int ?? 0
        return PollingInterval(rawValue: raw) ?? .disabled
    }

    static func setPollingInterval(_ interval: PollingInterval, for projectPath: String) {
        let key = "\(ProjectHooks.keyPrefix(for: projectPath)).pollingInterval"
        UserDefaults.standard.set(interval.rawValue, forKey: key)
    }

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

    // MARK: - Persistence

    static func load(for projectPath: String) -> ProjectHooks {
        let prefix = ProjectHooks.keyPrefix(for: projectPath)
        let defaults = UserDefaults.standard
        return ProjectHooks(
            afterCreate: defaults.string(forKey: "\(prefix).hook.post_create") ?? "",
            beforeRemove: defaults.string(forKey: "\(prefix).hook.pre_remove") ?? ""
        )
    }

    func save(for projectPath: String) {
        let prefix = ProjectHooks.keyPrefix(for: projectPath)
        let defaults = UserDefaults.standard
        defaults.set(afterCreate, forKey: "\(prefix).hook.post_create")
        defaults.set(beforeRemove, forKey: "\(prefix).hook.pre_remove")
    }

    static func keyPrefix(for projectPath: String) -> String {
        let hash = SHA256.hash(data: Data(projectPath.utf8))
        let hex = hash.prefix(8).map { String(format: "%02x", $0) }.joined()
        return "clearway.project.\(hex)"
    }
}
