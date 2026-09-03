import Foundation

/// Owns a `NotificationCenter` block-observer token and deregisters it on release.
final class NotificationObservation {
    private let token: any NSObjectProtocol

    init(_ token: any NSObjectProtocol) {
        self.token = token
    }

    deinit {
        NotificationCenter.default.removeObserver(token)
    }
}
