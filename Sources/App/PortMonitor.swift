import Foundation

@MainActor
final class PortMonitor: ObservableObject {
    @Published private(set) var listeners: [PortScanner.Listener] = []

    private var pollTask: Task<Void, Never>?

    init() {
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                let scanned = await Task.detached(priority: .utility) { PortScanner.scan() }.value
                guard let self else { return }
                if scanned != listeners { listeners = scanned }
                try? await Task.sleep(for: .seconds(2))
            }
        }
    }

    nonisolated deinit {
        pollTask?.cancel()
    }
}
