import Foundation

/// Owns a debounce `DispatchWorkItem` and cancels it on release, so replacing or
/// clearing the holder cancels the pending work.
final class ScheduledWork {
    private let item: DispatchWorkItem

    init(_ item: DispatchWorkItem) {
        self.item = item
    }

    deinit {
        item.cancel()
    }
}
