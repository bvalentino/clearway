import Foundation

enum PortAttribution {

    /// Maps each listening socket onto the worktree that owns it, keyed by `Worktree.id`.
    ///
    /// `worktrees` is the full tracked list, not the sidebar's visible one: worktrees nest, and a
    /// listener inside a hidden child belongs to that child — it is simply not rendered — never to
    /// its visible parent. Among the worktrees containing a cwd the **longest path wins**, which is
    /// what a bare `hasPrefix` sweep would get wrong.
    static func attribute(
        _ listeners: [PortScanner.Listener],
        to worktrees: [Worktree]
    ) -> [String: [UInt16]] {
        let paths = worktrees.compactMap { worktree in
            worktree.path.map { (id: worktree.id, path: $0, descendantPrefix: $0 + "/") }
        }
        var ports: [String: Set<UInt16>] = [:]
        for listener in listeners {
            let owner = paths
                .filter { listener.cwd == $0.path || listener.cwd.hasPrefix($0.descendantPrefix) }
                .max { $0.path.count < $1.path.count }
            guard let owner else { continue }
            ports[owner.id, default: []].insert(listener.port)
        }
        return ports.mapValues { $0.sorted() }
    }

    static func visible(_ ports: [UInt16], hiding hidden: Set<UInt16>) -> [UInt16] {
        ports.filter { !hidden.contains($0) }
    }
}
