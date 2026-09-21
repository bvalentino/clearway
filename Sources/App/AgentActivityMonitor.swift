import Darwin
import Dispatch
import Foundation

/// The one owner of the hook socket. It installs the hooks, listens for what they forward, and
/// publishes the derivations `AgentActivityStore` computes — nothing else. Every rule lives in the
/// store, which is a value type a test can drive without a socket.
///
/// One per process, because the socket is a single fixed path: a second owner would try to bind it
/// twice. Nothing here has a clock — a surface leaves a state only because an event said so.
@MainActor
final class AgentActivityMonitor: ObservableObject {
    /// The in-flight tool of each lead, keyed by surface id. Its own observable object rather than
    /// a `@Published` on the monitor because it changes twice per tool call while the sidebar's two
    /// values change once a turn: on the monitor it invalidated every view observing any of them,
    /// in every window, which is exactly what the tab strip's chip-scoped `@ObservedObject` exists
    /// to avoid. Only the chip observes this.
    @MainActor
    final class ToolNames: ObservableObject {
        @Published fileprivate(set) var bySurface: [String: String] = [:]
    }

    @Published private(set) var worktreePhases: [String: AgentPhase] = [:]
    @Published private(set) var worktreeSubagents: [String: [AgentSubagent]] = [:]
    let toolNames = ToolNames()

    private let paths: AgentHookPaths
    private let home: String
    private var store = AgentActivityStore()
    private var listener: HookSocketListener?
    private var isEnabled = false

    init(home: String = NSHomeDirectory()) {
        self.home = home
        paths = AgentHookPaths(home: home)
    }

    /// The whole toggle: on installs the hooks and opens the listener, off closes it, forgets every
    /// surface and removes the hooks.
    ///
    /// The latch is the transition, not the listener: `ClearwayApp` drives this from an `.onAppear`
    /// that fires once per window, and both installers are synchronous settings-file rewrites on
    /// the main actor. Latching on `listener` instead would re-run the install for every window
    /// once a bind had failed, and re-run the uninstall for every window while the toggle is off.
    func setEnabled(_ enabled: Bool) {
        guard enabled != isEnabled else { return }
        isEnabled = enabled
        if enabled {
            start()
        } else {
            stop()
        }
    }

    /// What `TerminalManager.retireSurface` is wired to. A surface Clearway has torn down stops
    /// counting at once, and a hook process still in flight when its tab closed cannot revive it.
    func retire(surfaceId: UUID) {
        store.retire(surfaceId: surfaceId.uuidString)
        publish()
    }

    private func start() {
        AgentHookInstaller.install(home: home)
        listener = HookSocketListener.start(socketPath: paths.socketPath) { [weak self] payload in
            // The forwarder sends only once both ids are set, so a payload that does not parse is
            // always something wrong — a truncated read, or a field an agent has renamed. Nothing
            // here has a clock, so every dropped event is permanent: a surface mid-tool-call keeps
            // its dot and its tool label for good. That raises the bar on saying so rather than
            // lowering it, and this line is the only place that can.
            guard let envelope = AgentHookEnvelope.parse(payload) else {
                Ghostty.logger.warning("A hook payload of \(payload.count) bytes did not parse and was dropped.")
                return
            }
            Task { @MainActor in self?.receive(envelope) }
        }
    }

    private func stop() {
        listener = nil
        // After the cancel, and on the main actor both times, so a disable immediately followed by
        // an enable cannot unlink the socket the new listener just bound.
        unlink(paths.socketPath)
        store = AgentActivityStore()
        publish()
        AgentHookInstaller.uninstall(home: home)
    }

    private func receive(_ envelope: AgentHookEnvelope) {
        store.apply(envelope)
        publish()
    }

    /// Only a changed value is republished. `PreToolUse`/`PostToolUse` fire around every tool call,
    /// and assigning an unchanged value to a `@Published` still re-renders every observer of it.
    private func publish() {
        let phases = store.worktreePhases
        if phases != worktreePhases { worktreePhases = phases }
        let subagents = store.worktreeSubagents
        if subagents != worktreeSubagents { worktreeSubagents = subagents }
        let names = store.surfaceToolNames
        if names != toolNames.bySurface { toolNames.bySurface = names }
    }
}

/// The listening socket, held so that releasing it tears the source down: the cancel handler closes
/// the descriptor, and a nonisolated `deinit` that only releases a holder reads nothing isolated.
/// `ScheduledWork` is the precedent.
///
/// Everything below is `nonisolated static` on purpose. `setEventHandler` and `setCancelHandler`
/// take a `@convention(block)` closure, so a literal written inside an actor-isolated method carries
/// that isolation into libdispatch and traps the moment the queue runs it — the trap that cost
/// v1.9.3 a shipped crash. Built here, outside any actor, the blocks carry none, and `onPayload` is
/// a plain function-typed parameter the compiler checks statically instead.
final class HookSocketListener {
    private let source: DispatchSourceRead

    private init(source: DispatchSourceRead) {
        self.source = source
    }

    deinit {
        source.cancel()
    }

    /// Its own serial queue, never a global one: a connection is read to EOF on it, and parking a
    /// shared pool worker is what left `ShellPathStore` waiting behind a backgrounded editor.
    nonisolated static func start(
        socketPath: String,
        onPayload: @escaping @Sendable (Data) -> Void
    ) -> HookSocketListener? {
        guard let descriptor = listeningDescriptor(at: socketPath) else { return nil }

        let source = DispatchSource.makeReadSource(
            fileDescriptor: descriptor,
            queue: DispatchQueue(label: "app.getclearway.agent-hooks", qos: .utility)
        )
        source.setEventHandler { acceptPending(descriptor, onPayload) }
        source.setCancelHandler { close(descriptor) }
        source.resume()
        return HookSocketListener(source: source)
    }

    private nonisolated static func listeningDescriptor(at socketPath: String) -> Int32? {
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let pathBytes = Array(socketPath.utf8)
        guard pathBytes.count < MemoryLayout.size(ofValue: address.sun_path) else {
            Ghostty.logger.error("\(socketPath, privacy: .public) does not fit a Unix socket address.")
            return nil
        }
        withUnsafeMutableBytes(of: &address.sun_path) { $0.copyBytes(from: pathBytes) }

        let descriptor = socket(AF_UNIX, SOCK_STREAM, 0)
        guard descriptor >= 0 else {
            Ghostty.logger.error("The agent hook socket could not be created: \(errno)")
            return nil
        }
        // A process that died without closing leaves the inode behind, and `bind` refuses an address
        // that already exists — so every launch after a crash would listen on nothing.
        unlink(socketPath)
        let bound = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        // Non-blocking, because the accept loop below drains until there is nothing left to take.
        guard bound == 0,
              listen(descriptor, 64) == 0,
              fcntl(descriptor, F_SETFL, fcntl(descriptor, F_GETFL, 0) | O_NONBLOCK) == 0
        else {
            Ghostty.logger.error("The agent hook socket could not be bound at \(socketPath, privacy: .public): \(errno)")
            close(descriptor)
            return nil
        }
        return descriptor
    }

    /// Drains every pending connection: a read source coalesces, so one event can stand for several
    /// hook processes that arrived together.
    private nonisolated static func acceptPending(_ descriptor: Int32, _ onPayload: @Sendable (Data) -> Void) {
        while true {
            let connection = accept(descriptor, nil, nil)
            guard connection >= 0 else { return }
            onPayload(payload(from: connection))
            close(connection)
        }
    }

    /// One hook invocation, read to EOF — which the forwarder's `nc` produces by shutting its write
    /// side when its own stdin ends. The read timeout is a floor under a peer that connects and then
    /// says nothing: it is not an expiry on anything, it keeps one silent connection from parking
    /// the queue every later event arrives on.
    private nonisolated static func payload(from connection: Int32) -> Data {
        var flags = fcntl(connection, F_GETFL, 0)
        flags = fcntl(connection, F_SETFL, flags & ~O_NONBLOCK)
        var timeout = timeval(tv_sec: 2, tv_usec: 0)
        setsockopt(connection, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))

        var payload = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while true {
            let count = buffer.withUnsafeMutableBytes { read(connection, $0.baseAddress, $0.count) }
            if count > 0 {
                payload.append(contentsOf: buffer[0..<count])
            } else if count < 0 && errno == EINTR {
                continue
            } else {
                return payload
            }
        }
    }
}
