import Foundation

/// The two pure rules that decide what `clearway.position` each sidebar row carries after a drag.
///
/// Separate from `WorktreeGroupManager.swift` so that file stays under its length budget; neither
/// touches the manager's state, so both are `static` and unit-tested without a repository.
extension WorktreeGroupManager {

    /// Places `ids` into the slots `stored` gives them, in the new order, leaving every other
    /// stored ID where it was. IDs `stored` does not hold yet are appended.
    static func repositioned(_ stored: [String], with ids: [String]) -> [String] {
        let moving = Set(ids)
        var incoming = ids[...]
        var result: [String] = []
        for id in stored {
            if moving.contains(id) {
                // A slot with no id left to take it is a duplicate of one already placed; dropping
                // it heals a stored order that recorded the same id twice.
                if let next = incoming.popFirst() { result.append(next) }
            } else {
                result.append(id)
            }
        }
        result.append(contentsOf: incoming)
        return result
    }

    /// The position each member of `section` should carry once the rendered rows have been moved
    /// into `newOrder`, limited to the ones that changed.
    ///
    /// A drag reassigns exactly the values the section already occupied: the permuted IDs take
    /// them in ascending order, so a row the caller omitted — hidden by the detached filter or the
    /// search field — keeps the slot it had. A member without a value, and any ID the section did
    /// not hold, takes the next integer above the section's maximum. A value two members share
    /// counts once, so a section that came to hold a duplicate is healed by the first drag rather
    /// than handed the same collision back.
    static func reassignedPositions(
        section: [(id: String, position: Int?)],
        newOrder: [String]
    ) -> [String: Int] {
        let permuted = repositioned(section.map(\.id), with: newOrder)
        var pool = Set(section.compactMap(\.position)).sorted()
        var next = (pool.last ?? -1) + 1
        while pool.count < permuted.count {
            pool.append(next)
            next += 1
        }
        let current = Dictionary(section.map { ($0.id, $0.position) }, uniquingKeysWith: { lhs, _ in lhs })
        var changed: [String: Int] = [:]
        for (id, position) in zip(permuted, pool) where (current[id] ?? nil) != position {
            changed[id] = position
        }
        return changed
    }
}
