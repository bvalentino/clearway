import Foundation
import os

/// Holds the resolved `PATH`, guards the single flight, and decides when to resolve again.
///
/// The known value and the in-flight resolution are separate state, because a degraded value
/// must stay readable — returned at once, never awaited — while its replacement resolves.
///
/// Whether a resolution has *completed* is tracked apart from whether it produced a value: only
/// the very first caller ever blocks on the shell. Once any answer has come back — including a
/// failure, which is deliberately not cached — later callers take the best value available and
/// let the retry run behind them.
final class ShellPathStore: @unchecked Sendable {

    private static let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "app.getclearway.mac",
        category: "shell-environment"
    )

    private let resolve: @Sendable () -> ShellPathResolver.Outcome
    private let lock = NSLock()
    private var knownPath: String?
    private var knownIsFull = false
    private var hasCompletedAResolution = false
    private var inFlight: Task<Void, Never>?

    init(resolve: @escaping @Sendable () -> ShellPathResolver.Outcome = { ShellPathResolver().resolve() }) {
        self.resolve = resolve
    }

    /// The best known `PATH`, unioned with the baseline. Synchronous, and free of side
    /// effects: a property read that spawns a shell would be a surprise, and the shell can
    /// open an approval browser, so starting a resolution belongs on an explicit call.
    var currentPath: String {
        ShellPathValidation.unionWithBaseline(lock.withLock { knownPath } ?? "")
    }

    /// Starts a resolution without waiting for it. Used at application start so the first
    /// agent launch does not pay for the shell.
    func startResolution() {
        lock.withLock {
            guard !knownIsFull else { return }
            startResolutionLocked()
        }
    }

    /// The `PATH` for an agent launch, starting a resolution when one is needed.
    ///
    /// A full value returns at once. Anything less starts a background attempt to improve it —
    /// a degraded value to replace it, an earlier failure to retry it — and returns the best
    /// value available without waiting. Only the first caller of all, with no resolution yet
    /// finished, joins the one in flight and awaits it, bounded by the resolver's own limit.
    func awaitPath() async -> String {
        let pending: Task<Void, Never>? = lock.withLock {
            if knownIsFull { return nil }
            let task = startResolutionLocked()
            return hasCompletedAResolution ? nil : task
        }
        await pending?.value
        return currentPath
    }

    private func log(_ outcome: ShellPathResolver.Outcome, recovered: Bool) {
        switch outcome {
        case .full(let path) where recovered:
            Self.logger.notice("Shell PATH recovered from degraded: \(path, privacy: .public)")
        case .full(let path):
            Self.logger.notice("Shell PATH resolved: \(path, privacy: .public)")
        case .degraded(let path):
            Self.logger.warning("Shell PATH is degraded — .zshrc-only entries may be missing: \(path, privacy: .public)")
        case .failed:
            Self.logger.warning("Shell PATH unresolved — using the baseline")
        }
    }

    @discardableResult
    private func startResolutionLocked() -> Task<Void, Never> {
        if let inFlight { return inFlight }
        if isDegradedLocked {
            Self.logger.notice("Shell PATH retrying the interactive shell to replace the degraded value")
        }
        let task = Task<Void, Never> { [self] in
            let outcome = await withCheckedContinuation { continuation in
                // The resolution blocks on a shell, so it must not run on the cooperative pool.
                DispatchQueue.global(qos: .userInitiated).async {
                    continuation.resume(returning: self.resolve())
                }
            }
            let recovered: Bool = lock.withLock {
                let wasDegraded = isDegradedLocked
                switch outcome {
                case .full(let path): (knownPath, knownIsFull) = (path, true)
                case .degraded(let path): (knownPath, knownIsFull) = (path, false)
                // A failure is not cached, so a later launch retries — in the background,
                // since the attempt below marks the resolution completed either way. An
                // earlier degraded value is kept: it works, and it beats the baseline.
                case .failed: break
                }
                hasCompletedAResolution = true
                inFlight = nil
                return wasDegraded && knownIsFull
            }
            log(outcome, recovered: recovered)
        }
        inFlight = task
        return task
    }

    /// Only valid while `lock` is held.
    private var isDegradedLocked: Bool {
        knownPath != nil && !knownIsFull
    }
}
