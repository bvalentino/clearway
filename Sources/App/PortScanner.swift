import Darwin

enum PortScanner {
    struct Listener: Equatable, Sendable {
        let cwd: String
        let port: UInt16
    }

    nonisolated static func scan() -> [Listener] {
        ordered(allPids().flatMap { pid -> [Listener] in
            let ports = listeningPorts(pid: pid)
            guard !ports.isEmpty, let cwd = currentDirectory(pid: pid) else { return [] }
            return ports.map { Listener(cwd: cwd, port: $0) }
        })
    }

    /// `proc_listpids` orders by pid, so an unrelated process starting or exiting reshuffles the
    /// array. Ordering by `(cwd, port)` makes the result depend on the set of listeners alone,
    /// which is what `PortMonitor`'s equality check needs: a reshuffle must not republish.
    nonisolated static func ordered(_ listeners: [Listener]) -> [Listener] {
        listeners.sorted { ($0.cwd, $0.port) < ($1.cwd, $1.port) }
    }

    private static func allPids() -> [pid_t] {
        let capacity = proc_listpids(UInt32(PROC_ALL_PIDS), 0, nil, 0)
        guard capacity > 0 else { return [] }
        var pids = [pid_t](repeating: 0, count: Int(capacity) / MemoryLayout<pid_t>.stride)
        let written = proc_listpids(UInt32(PROC_ALL_PIDS), 0, &pids, capacity)
        guard written > 0 else { return [] }
        return pids.prefix(Int(written) / MemoryLayout<pid_t>.stride).filter { $0 > 0 }
    }

    private static func listeningPorts(pid: pid_t) -> Set<UInt16> {
        let capacity = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, nil, 0)
        guard capacity > 0 else { return [] }
        var descriptors = [proc_fdinfo](
            repeating: proc_fdinfo(),
            count: Int(capacity) / MemoryLayout<proc_fdinfo>.stride
        )
        let written = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, &descriptors, capacity)
        guard written > 0 else { return [] }

        let socketSize = Int32(MemoryLayout<socket_fdinfo>.stride)
        var ports: Set<UInt16> = []
        for descriptor in descriptors.prefix(Int(written) / MemoryLayout<proc_fdinfo>.stride) {
            guard descriptor.proc_fdtype == UInt32(PROX_FDTYPE_SOCKET) else { continue }
            var socket = socket_fdinfo()
            guard proc_pidfdinfo(pid, descriptor.proc_fd, PROC_PIDFDSOCKETINFO, &socket, socketSize) == socketSize,
                  socket.psi.soi_kind == SOCKINFO_TCP,
                  socket.psi.soi_proto.pri_tcp.tcpsi_state == TSI_S_LISTEN else { continue }
            let lport = socket.psi.soi_proto.pri_tcp.tcpsi_ini.insi_lport
            ports.insert(UInt16(bigEndian: UInt16(truncatingIfNeeded: lport)))
        }
        return ports
    }

    private static func currentDirectory(pid: pid_t) -> String? {
        var info = proc_vnodepathinfo()
        let size = Int32(MemoryLayout<proc_vnodepathinfo>.stride)
        guard proc_pidinfo(pid, PROC_PIDVNODEPATHINFO, 0, &info, size) == size else { return nil }
        let path = withUnsafeBytes(of: &info.pvi_cdir.vip_path) {
            String(cString: $0.baseAddress!.assumingMemoryBound(to: CChar.self))
        }
        return path.isEmpty ? nil : path
    }
}
