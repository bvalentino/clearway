// SwiftUI provides `Array.move(fromOffsets:toOffset:)`, used by `move(from:to:)`. This type itself
// stays UI-free.
import SwiftUI

/// An ordered, editor-facing view of a `WORKFLOW.json` action list: the actions in card order
/// (top-to-bottom == the v1 linear flow), with all route rewiring owned here so the UI never sees a
/// slug or pointer. Slugs freeze at creation, and `toDefinition` is the only place routes are computed
/// (from current order), so add/remove/move can't dangle a pointer.
struct WorkflowEditorModel: Equatable {

    struct EditorAction: Equatable, Identifiable {
        /// The engine's stable pointer target, frozen so renames stay cosmetic. A new action's
        /// placeholder slug is re-derived from its name once on commit (`finalizeSlug(of:)`).
        fileprivate(set) var slug: String
        var name: String
        var instructions: String

        var id: String { slug }

        /// Both fields are required; an incomplete action is never persisted.
        var isComplete: Bool {
            !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                && !instructions.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
    }

    /// Actions in card order (the v1 linear flow). Route structural changes through `add`/`remove`/
    /// `move`; `name`/`instructions` are safe to mutate in place since the slug is frozen.
    var actions: [EditorAction]

    /// The pinned planning instruction, edited above the action list. `nil` = no planning entry;
    /// non-`nil` (even empty) = a `planning` object is persisted. Outside the action graph — it has
    /// no slug and never participates in routing.
    var planning: String?

    /// The single routing outcome v1 uses.
    static let successOutcome = "success"

    /// Fallback slug body for an empty / all-symbol name (`action`, `action_2`, …).
    static let fallbackSlugBase = "action"

    init(actions: [EditorAction] = [], planning: String? = nil) {
        self.actions = actions
        self.planning = planning
    }

    /// Builds the editor list in flow order (start → … → terminal, then any unreached islands).
    init(from definition: WorkflowDefinition) {
        self.actions = definition.orderedActionSlugs().compactMap { slug in
            guard let action = definition.actions[slug] else { return nil }
            return EditorAction(slug: slug, name: action.name, instructions: action.instructions)
        }
        self.planning = definition.planning?.instructions
    }

    // MARK: - Slug generation

    /// Lowercases a name and collapses each run of non-ASCII-alphanumerics to a single `_`, trimming
    /// leading/trailing `_`. Returns empty for an all-symbol name (the caller substitutes a fallback).
    static func slugify(_ name: String) -> String {
        var result = ""
        for character in name.lowercased() {
            if character.isASCII, character.isLetter || character.isNumber {
                result.append(character)
            } else if !result.hasSuffix("_") {
                result.append("_")
            }
        }
        while result.hasPrefix("_") { result.removeFirst() }
        while result.hasSuffix("_") { result.removeLast() }
        return result
    }

    /// A unique slug from `name`: an `action` fallback for an empty name, a numeric suffix for a
    /// collision or a reserved backlog marker (which the engine ignores, so it would fail `validate()`).
    static func makeSlug(from name: String, existing: Set<String>) -> String {
        let reserved = WorkTask.ReservedStatus.backlogMarkers
        var base = slugify(name)
        if base.isEmpty { base = fallbackSlugBase }
        var candidate = base
        var suffix = 2
        while existing.contains(candidate) || reserved.contains(candidate) {
            candidate = "\(base)_\(suffix)"
            suffix += 1
        }
        return candidate
    }

    // MARK: - Mutations

    /// Appends a new terminal card; the former terminal relinks to it on the next `toDefinition`.
    @discardableResult
    mutating func add(name: String = "", instructions: String = "") -> EditorAction {
        let slug = Self.makeSlug(from: name, existing: Set(actions.map { $0.slug }))
        let action = EditorAction(slug: slug, name: name, instructions: instructions)
        actions.append(action)
        return action
    }

    /// Removes the action at `index` (no-op if out of range); `toDefinition` relinks predecessor to
    /// successor from the new order, leaving the last card terminal.
    mutating func remove(at index: Int) {
        guard actions.indices.contains(index) else { return }
        actions.remove(at: index)
    }

    /// Reorders cards; `start` and every route follow on the next `toDefinition`. Matches `onMove`.
    mutating func move(from source: IndexSet, to destination: Int) {
        actions.move(fromOffsets: source, toOffset: destination)
    }

    /// Re-derives a new action's slug from its name (deduped). Called once on commit, since the name
    /// is empty when `+` is tapped; only safe before the slug has been referenced.
    mutating func finalizeSlug(of slug: String) {
        guard let index = actions.firstIndex(where: { $0.slug == slug }) else { return }
        let others = Set(actions.enumerated().compactMap { $0.offset == index ? nil : $0.element.slug })
        actions[index].slug = Self.makeSlug(from: actions[index].name, existing: others)
    }

    // MARK: - Serialization

    /// Rebuilds a `WorkflowDefinition` from card order: `start` is the first slug, each non-last card
    /// routes `success` to the next, the last is terminal. The editor owns `planning` (carried from
    /// the model, not `base`). Fields the editor doesn't surface (`version`/`agent`/`hooks`, per-action
    /// `maxAttempts`/`onMaxAttempts`) carry forward from `base`; a `nil` base uses v1 defaults.
    func toDefinition(preserving base: WorkflowDefinition?) -> WorkflowDefinition {
        let liveSlugs = Set(actions.map { $0.slug })
        var map: [String: WorkflowDefinition.Action] = [:]
        for (index, action) in actions.enumerated() {
            let routes: [String: String]
            if index + 1 < actions.count {
                routes = [Self.successOutcome: actions[index + 1].slug]
            } else {
                routes = [:]
            }
            let preserved = base?.actions[action.slug]
            // Drop a carried-forward escape pointer whose target was removed — it would dangle and
            // fail validate().
            let escape = preserved?.onMaxAttempts.flatMap { liveSlugs.contains($0) ? $0 : nil }
            map[action.slug] = WorkflowDefinition.Action(
                name: action.name,
                instructions: action.instructions,
                routes: routes,
                maxAttempts: preserved?.maxAttempts,
                onMaxAttempts: escape
            )
        }
        return WorkflowDefinition(
            version: base?.version ?? 1,
            start: actions.first?.slug ?? "",
            agent: base?.agent ?? .default,
            hooks: base?.hooks,
            planning: planning.map { WorkflowDefinition.Planning(instructions: $0) },
            actions: map
        )
    }
}
