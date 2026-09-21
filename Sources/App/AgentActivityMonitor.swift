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
    @Published private(set) var socketState: AgentHookSocketState = .off
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
        // Unconditional, and ahead of the listener on purpose: an instance that finds the socket
        // owned still installs the identical block, which is a content reconciliation that writes
        // only on a difference, so a second Clearway is a no-op here rather than a fight.
        AgentHookInstaller.install(home: home)
        let outcome = HookSocketListener.start(socketPath: paths.socketPath) { [weak self] payload in
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
        switch outcome {
        case .listening(let opened):
            listener = opened
            socketState = .listening
        case .ownedByAnotherInstance:
            socketState = .ownedByAnotherInstance
        case .unavailable:
            socketState = .unavailable
        }
    }

    private func stop() {
        // The whole teardown: the listener's `deinit` cancels the source and unlinks the path it
        // bound. An instance that found the path owned holds no listener, so nothing here can take
        // the live instance's socket.
        listener = nil
        socketState = .off
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

/// What the one fixed socket path is doing for this process. `.ownedByAnotherInstance` is a second
/// Clearway on the machine — `build.sh`'s `Clearway (<worktree>).app` beside `ci.sh`'s
/// `Clearway.app` — that found the path answering and left it alone; `.unavailable` is a bind that
/// failed for any other reason, which is neither off nor somebody else's doing.
enum AgentHookSocketState {
    case off
    case listening
    case ownedByAnotherInstance
    case unavailable
}

/// What `HookSocketListener.start` answers. An optional could not tell a path another instance owns
/// from a path nothing can bind, and the two mean opposite things to the operator.
enum HookSocketOutcome {
    case listening(HookSocketListener)
    case ownedByAnotherInstance
    case unavailable
}

/// The listening socket, held so that releasing it is the whole teardown: the cancel handler closes
/// the descriptor, the `deinit` unlinks the path, and a nonisolated `deinit` that touches only its
/// own stored values reads nothing isolated. `ScheduledWork` is the precedent.
///
/// Everything below is `nonisolated static` on purpose. `setEventHandler` and `setCancelHandler`
/// take a `@convention(block)` closure, so a literal written inside an actor-isolated method carries
/// that isolation into libdispatch and traps the moment the queue runs it — the trap that cost
/// v1.9.3 a shipped crash. Built here, outside any actor, the blocks carry none, and `onPayload` is
/// a plain function-typed parameter the compiler checks statically instead.
final class HookSocketListener {
    private let source: DispatchSourceRead
    private let socketPath: String

    private init(source: DispatchSourceRead, socketPath: String) {
        self.source = source
        self.socketPath = socketPath
    }

    /// The unlink lives here because binding is what earns it: an instance that found the path owned
    /// builds no listener, so it cannot remove a socket it never bound. It runs synchronously
    /// wherever the last reference is dropped — on the main actor, in `stop()` — and after the
    /// cancel, so a disable immediately followed by an enable cannot unlink the socket the new
    /// listener has just bound.
    deinit {
        source.cancel()
        unlink(socketPath)
    }

    /// Its own serial queue, never a global one: a connection is read to EOF on it, and parking a
    /// shared pool worker is what left `ShellPathStore` waiting behind a backgrounded editor.
    nonisolated static func start(
        socketPath: String,
        onPayload: @escaping @Sendable (Data) -> Void
    ) -> HookSocketOutcome {
        let descriptor: Int32
        switch listeningDescriptor(at: socketPath) {
        case .open(let opened): descriptor = opened
        case .ownedByAnotherInstance: return .ownedByAnotherInstance
        case .unavailable: return .unavailable
        }

        let source = DispatchSource.makeReadSource(
            fileDescriptor: descriptor,
            queue: DispatchQueue(label: "app.getclearway.agent-hooks", qos: .utility)
        )
        source.setEventHandler { acceptPending(descriptor, onPayload) }
        source.setCancelHandler { close(descriptor) }
        source.resume()
        return .listening(HookSocketListener(source: source, socketPath: socketPath))
    }

    /// `HookSocketOutcome` cannot serve here: there is no listener yet, only a descriptor.
    private enum DescriptorOutcome {
        case open(Int32)
        case ownedByAnotherInstance
        case unavailable
    }

    private nonisolated static func listeningDescriptor(at socketPath: String) -> DescriptorOutcome {
        guard let address = unixAddress(for: socketPath) else {
            Ghostty.logger.error("\(socketPath, privacy: .public) does not fit a Unix socket address.")
            return .unavailable
        }

        // Refused rather than taken over: a live owner's surfaces carry the ids that match its
        // socket, so its events are the ones that mean anything.
        guard !isAnswering(at: address) else {
            Ghostty.logger.warning("Another Clearway instance is listening at \(socketPath, privacy: .public); this one runs without hook events.")
            return .ownedByAnotherInstance
        }

        let descriptor = socket(AF_UNIX, SOCK_STREAM, 0)
        guard descriptor >= 0 else {
            Ghostty.logger.error("The agent hook socket could not be created: \(errno)")
            return .unavailable
        }
        // A process that died without closing leaves the inode behind, and `bind` refuses an address
        // that already exists — so every launch after a crash would listen on nothing.
        unlink(socketPath)
        let bound = withUnixAddress(address) { bind(descriptor, $0, $1) }
        // Non-blocking, because the accept loop below drains until there is nothing left to take.
        guard bound == 0,
              listen(descriptor, 64) == 0,
              fcntl(descriptor, F_SETFL, fcntl(descriptor, F_GETFL, 0) | O_NONBLOCK) == 0
        else {
            Ghostty.logger.error("The agent hook socket could not be bound at \(socketPath, privacy: .public): \(errno)")
            close(descriptor)
            return .unavailable
        }
        return .open(descriptor)
    }

    /// The address for `socketPath`, or nil when it does not fit `sun_path` — `copyBytes` traps on
    /// an overflow rather than truncating. Internal so the fixture standing in for a killed
    /// instance binds through the same guard instead of a copy of it.
    nonisolated static func unixAddress(for socketPath: String) -> sockaddr_un? {
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let pathBytes = Array(socketPath.utf8)
        guard pathBytes.count < MemoryLayout.size(ofValue: address.sun_path) else { return nil }
        withUnsafeMutableBytes(of: &address.sun_path) { $0.copyBytes(from: pathBytes) }
        return address
    }

    /// The address rebound to the `sockaddr` and length every socket call takes.
    nonisolated static func withUnixAddress<Answer>(
        _ address: sockaddr_un,
        _ body: (UnsafePointer<sockaddr>, socklen_t) -> Answer
    ) -> Answer {
        var target = address
        return withUnsafePointer(to: &target) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                body($0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
    }

    /// One `connect(2)` on a throwaway descriptor, the whole liveness test. **Only a return of 0
    /// defends the path**: every errno falls through to the unlink, which is what Clearway did
    /// unconditionally before — `ECONNREFUSED` from an inode a killed instance left behind,
    /// `ENOTSOCK` from a file or a directory standing there, `ENOENT` from nothing at all, and an
    /// unforeseen one besides, since reading an unknown errno as an owner would disable the feature
    /// until the next reboot. A local `AF_UNIX` connect completes or fails in the kernel without
    /// waiting on the peer, so there is nothing to time out. The live owner sees one connection that
    /// closes with nothing written, which its own accept loop drops as an empty payload.
    ///
    /// A live listener whose backlog of 64 is full also refuses, so an instance with that many
    /// unaccepted connections reads as stale. The accept loop drains to `EAGAIN` on every event and
    /// hook connections are one per lifecycle event, so reaching it means the queue is parked; it is
    /// a known limit rather than a reason for a retry.
    private nonisolated static func isAnswering(at address: sockaddr_un) -> Bool {
        let probe = socket(AF_UNIX, SOCK_STREAM, 0)
        guard probe >= 0 else { return false }
        defer { close(probe) }
        return withUnixAddress(address) { connect(probe, $0, $1) } == 0
    }

    /// Drains every pending connection: a read source coalesces, so one event can stand for several
    /// hook processes that arrived together.
    private nonisolated static func acceptPending(_ descriptor: Int32, _ onPayload: @Sendable (Data) -> Void) {
        while true {
            let connection = accept(descriptor, nil, nil)
            guard connection >= 0 else { return }
            let received = payload(from: connection)
            // A connection that closes with nothing written is a hang-up — another instance's
            // liveness probe, or an `nc -w 1` that gave up — and is not a message, so it never
            // reaches the callback to be reported as a payload that did not parse.
            if !received.isEmpty { onPayload(received) }
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
