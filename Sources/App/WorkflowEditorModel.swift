// SwiftUI provides `Array.move(fromOffsets:toOffset:)`, used by `move(from:to:)`. This type itself
// stays UI-free.
import SwiftUI

/// An ordered, editor-facing view of a `WORKFLOW.json` action list. The on-disk `WorkflowDefinition`
/// is an unordered slug-keyed map wired by route pointers; this holds the actions in card order
/// (top-to-bottom == the v1 linear flow) and owns all route rewiring, so the UI never sees a slug,
/// a `start` pointer, or a `routes` map.
///
/// Two invariants uphold the engine's "pointers target frozen slugs, `name` is cosmetic" contract:
/// slugs freeze at creation (a rename touches only `name`), and `toDefinition` is the only place
/// routes are computed — always from current card order — so add/remove/move can't dangle a pointer.
struct WorkflowEditorModel: Equatable {

    struct EditorAction: Equatable, Identifiable {
        /// The engine's stable pointer target, frozen after the action is first persisted so renames
        /// stay cosmetic. The exception: a brand-new action's placeholder slug is re-derived from its
        /// name once on creation-commit (`finalizeSlug(of:)`), before it has been referenced.
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

    /// The single routing outcome v1 uses.
    static let successOutcome = "success"

    /// Fallback slug body for an empty / all-symbol name (`action`, `action_2`, …).
    static let fallbackSlugBase = "action"

    init(actions: [EditorAction] = []) {
        self.actions = actions
    }

    /// Builds the editor list in flow order (start → … → terminal, then any unreached islands).
    init(from definition: WorkflowDefinition) {
        self.actions = definition.orderedActionSlugs().compactMap { slug in
            guard let action = definition.actions[slug] else { return nil }
            return EditorAction(slug: slug, name: action.name, instructions: action.instructions)
        }
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

    /// A frozen slug from `name`: unique against `existing`, with an `action` fallback for an empty
    /// name. Collisions and reserved backlog markers (`new` / `ready_to_start`) get a numeric suffix —
    /// the engine ignores those markers, so an action keyed by one would fail `validate()`.
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

    /// Re-derives a new action's slug from its current name (deduped). Called once on creation-commit,
    /// since the name is empty when `+` is tapped. Only safe before the action has been referenced —
    /// afterwards slugs stay frozen.
    mutating func finalizeSlug(of slug: String) {
        guard let index = actions.firstIndex(where: { $0.slug == slug }) else { return }
        let others = Set(actions.enumerated().compactMap { $0.offset == index ? nil : $0.element.slug })
        actions[index].slug = Self.makeSlug(from: actions[index].name, existing: others)
    }

    // MARK: - Serialization

    /// Rebuilds a `WorkflowDefinition` from card order: `start` is the first slug, each non-last card
    /// routes `success` to the next, the last is terminal. `version`/`agent`/`hooks` and per-action
    /// reserved fields (`maxAttempts` / `onMaxAttempts`) are carried forward from `base` so fields the
    /// editor never surfaces survive a write; a `nil` base uses v1 defaults. The editor owns only
    /// `name`, `instructions`, and `routes`.
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
            actions: map
        )
    }
}
