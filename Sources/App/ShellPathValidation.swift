import Foundation

/// Decides whether a resolved value is usable as a `PATH`, and guarantees that
/// whatever is used still finds the standard system commands.
///
/// A wrong `PATH` is worse than no `PATH`: it produces terminals where even `cat`
/// and `rm` fail. Every value that reaches a consumer passes through here.
enum ShellPathValidation {

    /// The known-good `PATH` used when no resolution succeeded, and the set every
    /// resolved value is unioned with. Deliberately a constant: reading the inherited
    /// `PATH` would reintroduce the minimal Finder/Launchpad environment.
    static let baseline = "/usr/bin:/bin:/usr/sbin:/sbin"

    /// Returns the sanitized value, or `nil` when it is not a `PATH`.
    ///
    /// Every component that is not absolute is dropped — an empty one (a leading, trailing,
    /// or doubled colon), an explicit `.`, and a relative entry like `node_modules/.bin` all
    /// mean "search the current directory", which agents running in arbitrary checkouts must
    /// never do. Dropping rather than refusing matters: these appear in real profiles, and a
    /// value refused for one of them would leave the user permanently on the degraded
    /// login-only PATH. At least one of the components that remain must be an existing
    /// directory, which is what stops profile output such as a banner line passing as a `PATH`.
    static func sanitize(_ raw: String) -> String? {
        let components = split(raw.trimmingCharacters(in: .whitespacesAndNewlines))
            .filter { $0.hasPrefix("/") }
        guard components.contains(where: isExistingDirectory) else { return nil }
        return components.joined(separator: ":")
    }

    /// Appends the baseline directories that are missing, at the end, keeping the
    /// resolved order and removing duplicates.
    static func unionWithBaseline(_ path: String) -> String {
        var seen = Set<String>()
        return (split(path) + split(baseline))
            .filter { seen.insert($0).inserted }
            .joined(separator: ":")
    }

    private static func split(_ path: String) -> [String] {
        path.split(separator: ":", omittingEmptySubsequences: true).map(String.init)
    }

    private static func isExistingDirectory(_ path: String) -> Bool {
        var isDirectory: ObjCBool = false
        let exists = FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory)
        return exists && isDirectory.boolValue
    }
}
