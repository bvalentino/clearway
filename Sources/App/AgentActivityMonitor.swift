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
    /// The last enable attempt's outcome, and nothing after it: no watcher re-checks a settings file
    /// or a socket once the attempt is over. Published costs nothing here, unlike the tool name,
    /// because it changes only when the toggle does.
    @Published private(set) var health: AgentHookHealth = .off
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
        let install = AgentHookInstaller.install(home: home)
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
        let socket: AgentHookSocketOutcome
        switch outcome {
        case .listening(let opened):
            listener = opened
            socket = .listening
        case .ownedByAnotherInstance:
            socket = .ownedByAnotherInstance
        case .unopenable:
            socket = .unopenable
        }
        health = AgentHookHealth.resolve(install: install, socket: socket)
    }

    private func stop() {
        // Holding a listener is what "this process owns the feed" means — one is built only on the
        // `.listening` outcome — so it gates the uninstall exactly as it gates the unlink. An
        // instance that found a live owner would otherwise take that owner's hook block out of
        // every agent settings file, leaving it bound to a socket no hook forwards to any more.
        let owned = listener != nil
        // Releasing the listener is the whole socket teardown: its `deinit` cancels the source,
        // whose cancel handler closes the descriptor, and unlinks the inode it bound.
        listener = nil
        health = .off
        store = AgentActivityStore()
        publish()
        if owned { AgentHookInstaller.uninstall(home: home) }
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

/// What `HookSocketListener.start` answers. An optional could not tell a path another instance owns
/// from a path nothing can bind, and the two mean opposite things to the operator.
/// `AgentHookSocketOutcome` is the same three answers without the listener, which is what
/// `AgentHookHealth.resolve` takes: the health model stays `import Foundation` only, so every rule
/// it applies is reachable from XCTest with no socket.
enum HookSocketOutcome {
    case listening(HookSocketListener)
    case ownedByAnotherInstance
    case unopenable
}

/// The listening socket as an RAII holder: a nonisolated `deinit` touching only its own stored
/// values reads nothing isolated, so releasing it is the whole teardown. `ScheduledWork` is the
/// precedent.
///
/// Everything below is `nonisolated static` on purpose. `setEventHandler` and `setCancelHandler`
/// take a `@convention(block)` closure, so a literal written inside an actor-isolated method carries
/// that isolation into libdispatch and traps the moment the queue runs it — the trap that cost
/// v1.9.3 a shipped crash. Built here, outside any actor, the blocks carry none, and `onPayload` is
/// a plain function-typed parameter the compiler checks statically instead.
final class HookSocketListener {
    private let source: DispatchSourceRead
    private let socketPath: String
    private let bound: stat

    private init(source: DispatchSourceRead, socketPath: String, bound: stat) {
        self.source = source
        self.socketPath = socketPath
        self.bound = bound
    }

    /// The unlink lives here because binding is what earns it: an instance that found the path owned
    /// builds no listener, so it cannot remove a socket it never bound. Nothing else holds a
    /// reference, so it runs synchronously at `listener = nil` and a disable immediately followed by
    /// an enable cannot take away the socket the new listener has just bound.
    ///
    /// It is scoped to the inode rather than the name, because binding earns the inode and only the
    /// inode: an older build with no connect probe — or the window between this one's probe and its
    /// bind — can replace the path while this instance runs, and unlinking by name would then delete
    /// the live owner's socket. That is the same theft through a third door.
    deinit {
        source.cancel()
        var current = stat()
        guard stat(socketPath, &current) == 0,
              current.st_dev == bound.st_dev,
              current.st_ino == bound.st_ino
        else { return }
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
        case .unopenable: return .unopenable
        }

        let source = DispatchSource.makeReadSource(
            fileDescriptor: descriptor,
            queue: DispatchQueue(label: "app.getclearway.agent-hooks", qos: .utility)
        )
        source.setEventHandler { acceptPending(descriptor, onPayload) }
        source.setCancelHandler { close(descriptor) }
        source.resume()
        return .listening(HookSocketListener(source: source, socketPath: socketPath, bound: identity(of: socketPath)))
    }

    /// The inode `bind` created, so the `deinit` can tell this instance's socket from a path another
    /// process has since replaced. A `stat` that fails leaves a zeroed identity, which matches
    /// nothing: the inode is then left for the next launch's probe to find unanswered and reclaim.
    private nonisolated static func identity(of socketPath: String) -> stat {
        var identity = stat()
        _ = stat(socketPath, &identity)
        return identity
    }

    /// `HookSocketOutcome` cannot serve here: there is no listener yet, only a descriptor.
    private enum DescriptorOutcome {
        case open(Int32)
        case ownedByAnotherInstance
        case unopenable
    }

    private nonisolated static func listeningDescriptor(at socketPath: String) -> DescriptorOutcome {
        guard let address = unixAddress(for: socketPath) else {
            Ghostty.logger.error("\(socketPath, privacy: .public) does not fit a Unix socket address.")
            return .unopenable
        }

        switch probe(at: address) {
        case .liveOwner:
            // Refused rather than taken over: a live owner's surfaces carry the ids that match its
            // socket, so its events are the ones that mean anything.
            Ghostty.logger.warning(
                "A process is already listening at \(socketPath, privacy: .public) — most likely a second Clearway; this one runs without hook events until that one quits."
            )
            return .ownedByAnotherInstance
        case .unexplained(let code):
            Ghostty.logger.error(
                "The agent hook socket at \(socketPath, privacy: .public) could not be probed: \(code, privacy: .public)"
            )
            return .unopenable
        case .stale:
            break
        }

        let descriptor = socket(AF_UNIX, SOCK_STREAM, 0)
        guard descriptor >= 0 else {
            let failure = errno
            Ghostty.logger.error("The agent hook socket could not be created: \(failure, privacy: .public)")
            return .unopenable
        }
        // Nothing is serving the path — the probe settled that — so anything standing there is an
        // inode a process died without closing, and `bind` refuses an address that already exists.
        // Without this, every launch after a crash would listen on nothing.
        unlink(socketPath)
        let bound = withUnixAddress(address) { bind(descriptor, $0, $1) }
        // Non-blocking, because the accept loop below drains until there is nothing left to take.
        guard bound == 0,
              listen(descriptor, 64) == 0,
              fcntl(descriptor, F_SETFL, fcntl(descriptor, F_GETFL, 0) | O_NONBLOCK) == 0
        else {
            let failure = errno
            Ghostty.logger.error("The agent hook socket could not be bound at \(socketPath, privacy: .public): \(failure, privacy: .public)")
            close(descriptor)
            return .unopenable
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

    /// What a `connect` to the path found. Three answers rather than a `Bool` because only a refusal
    /// that is *accounted for* may authorise the unlink: an errno nobody checked proves nothing
    /// about who is there, and `EACCES` — a socket, or a containing directory, whose mode denies
    /// this process — is the one that costs. Read as "nobody is there" it unlinked a live owner's
    /// path and left both instances reporting that they were listening.
    private enum PathProbe {
        /// `connect` succeeded: another process is serving the path right now.
        case liveOwner

        /// `ENOENT`, `ECONNREFUSED` or `ENOTSOCK`: nothing is served there, so whatever stands at
        /// the path is an inode to unlink before binding.
        case stale

        case unexplained(code: Int32)
    }

    /// One `connect(2)` on a throwaway descriptor, the whole liveness test: `connect` is the only
    /// thing that can tell a live owner from the inode a process killed without closing left
    /// behind, since `bind` refuses both with `EADDRINUSE`. Unlinking unconditionally therefore
    /// handed the path to whichever instance started last, and the first went deaf with no error
    /// anywhere. A local `AF_UNIX` connect completes or fails in the kernel without waiting on the
    /// peer, so there is nothing to time out. The live owner sees one connection that closes with
    /// nothing written, which its own accept loop drops before any consumer.
    ///
    /// A live listener whose backlog of 64 is full also refuses, so an instance with that many
    /// unaccepted connections reads as stale. The accept loop drains to `EAGAIN` on every event and
    /// hook connections are one per lifecycle event, so reaching it means the queue is parked; it is
    /// a known limit rather than a reason for a retry.
    ///
    /// A probe descriptor that cannot be created is `.unexplained` for the same reason as an
    /// unaccounted-for errno: nothing was learned, and under `EMFILE` a descriptor freed between
    /// here and the `socket(2)` in the caller is enough to take a live instance's socket.
    private nonisolated static func probe(at address: sockaddr_un) -> PathProbe {
        let descriptor = socket(AF_UNIX, SOCK_STREAM, 0)
        guard descriptor >= 0 else { return .unexplained(code: errno) }
        defer { close(descriptor) }
        guard withUnixAddress(address, { connect(descriptor, $0, $1) }) != 0 else { return .liveOwner }
        switch errno {
        case ENOENT, ECONNREFUSED, ENOTSOCK: return .stale
        case let code: return .unexplained(code: code)
        }
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
