import Foundation

/// The managed block of hook entries, reconciled by content rather than carried with a version
/// counter: compute what Clearway wants, drop every entry recognised as its own, put the wanted
/// ones back, and let the caller write only if the result differs. That cannot drift when the file
/// is hand-edited, which a recorded version can.
///
/// Pure, over the `[String: Any]` `JSONSerialization` hands back, and the same shape serves both
/// agents' files. The schema is theirs: no marker key is added to an entry Clearway writes, because
/// an unrecognised key is a validation risk for nothing.
enum AgentHookSettings {

    /// Idempotent by construction — an install is an uninstall followed by one group per event, so
    /// a block already on disk is replaced rather than duplicated.
    static func install(into settings: [String: Any]) -> [String: Any] {
        // A value Clearway cannot read is a value it must not overwrite — the same rule the event
        // loop below keeps, and the one `uninstall` keeps for this very key. Without this the
        // `as? [String: Any] ?? [:]` beneath reads a non-object `hooks` as empty and writes the
        // block straight over it, which is the one place in this file that broke the rule.
        if let hooks = settings["hooks"], !(hooks is [String: Any]) { return settings }
        var result = uninstall(from: settings)
        var hooks = result["hooks"] as? [String: Any] ?? [:]

        for event in AgentHookScript.installedEvents {
            // No `matcher` key: it means a different thing per event — tool name, startup reason,
            // agent type — and an omitted one matches every occurrence. `"*"` is not a valid regex
            // and would be a silent miss.
            let group: [String: Any] = ["hooks": [["type": "command", "command": AgentHookScript.command]]]

            guard let existing = hooks[event] else {
                hooks[event] = [group]
                continue
            }
            // A value Clearway cannot read is a value it must not overwrite.
            guard var groups = existing as? [[String: Any]] else { continue }
            groups.append(group)
            hooks[event] = groups
        }

        result["hooks"] = hooks
        return result
    }

    static func uninstall(from settings: [String: Any]) -> [String: Any] {
        guard let hooks = settings["hooks"] as? [String: Any] else { return settings }

        var remaining: [String: Any] = [:]
        for (event, value) in hooks {
            guard let groups = value as? [[String: Any]] else {
                remaining[event] = value
                continue
            }
            let survivors = groups.compactMap(withoutClearwayEntries)
            // Only a container Clearway emptied is dropped. One the user left empty is theirs.
            if !survivors.isEmpty || groups.isEmpty {
                remaining[event] = survivors
            }
        }

        var result = settings
        if remaining.isEmpty, !hooks.isEmpty {
            result.removeValue(forKey: "hooks")
        } else {
            result["hooks"] = remaining
        }
        return result
    }

    /// Containment rather than equality, so a hand-edited entry that carries a matcher or spells
    /// the same path differently is still Clearway's and still comes out.
    static func isClearwayEntry(_ entry: Any) -> Bool {
        guard let entry = entry as? [String: Any],
              entry["type"] as? String == "command",
              let command = entry["command"] as? String
        else { return false }
        return command.contains(AgentHookScript.scriptPathMarker)
    }

    /// `nil` when the group held nothing but Clearway's entries, which is what lets the caller drop
    /// the group, then the event array, then the `hooks` object in turn.
    private static func withoutClearwayEntries(_ group: [String: Any]) -> [String: Any]? {
        guard let entries = group["hooks"] as? [Any] else { return group }
        let survivors = entries.filter { !isClearwayEntry($0) }
        guard !survivors.isEmpty || entries.isEmpty else { return nil }

        var result = group
        result["hooks"] = survivors
        return result
    }
}
