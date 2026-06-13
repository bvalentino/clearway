// SwiftUI (not just Foundation) for `Array.move(fromOffsets:toOffset:)` — the reorder helper that
// backs `onMove`. This type stays UI-free (no views); it only borrows that collection algorithm.
import SwiftUI

/// An ordered, editor-facing view of a `WORKFLOW.json` action list.
///
/// The on-disk `WorkflowDefinition` keeps an **unordered** slug-keyed map and defines flow with
/// route pointers. This type holds the actions in **card order** (top-to-bottom == the v1 linear
/// flow) and owns all route rewiring, so the authoring UI manipulates a simple array and never
/// sees a slug, a `start` pointer, or a `routes` map.
///
/// Two invariants make the engine's "pointers target frozen slugs, `name` is cosmetic" contract
/// hold from the editor side:
/// - **Slugs freeze at creation** (`EditorAction.slug` is `let`). Renaming an action mutates only
///   `name`, never the slug, so live runs pointing at a slug keep working across a rename.
/// - **`toDefinition` is the single place routes are computed**, always from current card order, so
///   add/remove/move can't leave a dangling pointer.
struct WorkflowEditorModel: Equatable {

    /// A single action card. `slug` is frozen once the action is persisted; `name`/`instructions`
    /// are user-editable.
    struct EditorAction: Equatable, Identifiable {
        /// The engine's stable pointer target. Frozen after the action is first persisted, so renames
        /// stay cosmetic and live runs keep resolving. The one exception is a brand-new action, whose
        /// slug is re-derived from its name once on creation-commit (`finalizeSlug(of:)`) — before it
        /// has ever been persisted or referenced, so changing it then is safe.
        fileprivate(set) var slug: String
        var name: String
        var instructions: String

        var id: String { slug }

        /// Both a name and instructions are required. An incomplete action is never persisted and is
        /// discarded when the user leaves its editor.
        var isComplete: Bool {
            !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                && !instructions.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
    }

    /// Actions in card order. Order *is* the v1 linear flow; `toDefinition` turns it into pointers.
    /// Structural changes should go through `add`/`remove`/`move` (they keep slug generation
    /// centralized); `name`/`instructions` are safe to mutate in place since the slug is immutable.
    var actions: [EditorAction]

    /// The single routing outcome v1 uses. A linear chain wires each action's `success` route to
    /// the next card.
    static let successOutcome = "success"

    /// Fallback slug body for an empty / all-symbol name (`action`, `action_2`, …).
    static let fallbackSlugBase = "action"

    init(actions: [EditorAction] = []) {
        self.actions = actions
    }

    /// Builds the editor list from a loaded definition, walking `orderedActionSlugs()` so cards
    /// come out in flow order (start → … → terminal, then any unreached islands appended).
    init(from definition: WorkflowDefinition) {
        self.actions = definition.orderedActionSlugs().compactMap { slug in
            guard let action = definition.actions[slug] else { return nil }
            return EditorAction(slug: slug, name: action.name, instructions: action.instructions)
        }
    }

    // MARK: - Slug generation

    /// Sanitizes a display name into a slug body: lowercase, each run of non-ASCII-alphanumeric
    /// characters collapses to a single `_`, and leading/trailing `_` are trimmed. May return an
    /// empty string for an all-symbol name (the caller substitutes a fallback).
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

    /// Generates a frozen slug from `name`: unique against `existing`, never a reserved backlog
    /// marker (`new` / `ready_to_start`), with an `action` fallback for empty/all-symbol names.
    /// Collisions and reserved hits get a numeric `_2`/`_3` suffix. The reserved check is in the
    /// dedup loop, so a name that slugifies to `new` becomes `new_2` rather than a value the engine
    /// would ignore as a pre-worktree marker (which would fail `validate()`).
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

    /// Appends a new action as the bottom (new terminal) card with a freshly-generated frozen slug.
    /// The former terminal's `success` route relinks to it implicitly on the next `toDefinition`.
    @discardableResult
    mutating func add(name: String = "", instructions: String = "") -> EditorAction {
        let slug = Self.makeSlug(from: name, existing: Set(actions.map { $0.slug }))
        let action = EditorAction(slug: slug, name: name, instructions: instructions)
        actions.append(action)
        return action
    }

    /// Removes the action at `index` (no-op if out of range). Relinking is implicit: `toDefinition`
    /// recomputes routes from the new card order, so the predecessor reconnects to the successor
    /// with no dangling pointer, and removing the last card leaves its predecessor terminal.
    mutating func remove(at index: Int) {
        guard actions.indices.contains(index) else { return }
        actions.remove(at: index)
    }

    /// Reorders cards. `start` and every `success` pointer follow the new card order on the next
    /// `toDefinition`. Signature matches SwiftUI's `onMove`.
    mutating func move(from source: IndexSet, to destination: Int) {
        actions.move(fromOffsets: source, toOffset: destination)
    }

    /// Re-derives a brand-new action's slug from its current name, deduped against the others. Call
    /// once on creation-commit: a new action is created with a placeholder slug (its name is still
    /// empty at the moment `+` is tapped), so this turns "Sample" into `sample` instead of leaving
    /// the `action` fallback. Only safe before the action has been persisted/referenced — afterwards
    /// slugs stay frozen.
    mutating func finalizeSlug(of slug: String) {
        guard let index = actions.firstIndex(where: { $0.slug == slug }) else { return }
        let others = Set(actions.enumerated().compactMap { $0.offset == index ? nil : $0.element.slug })
        actions[index].slug = Self.makeSlug(from: actions[index].name, existing: others)
    }

    // MARK: - Serialization

    /// Rebuilds an on-disk `WorkflowDefinition` from card order: `start` is the first slug, each
    /// non-last action's `success` route points at the next slug, and the last action is terminal
    /// (no routes). `agent`/`hooks`/`version` are re-emitted from `base` (the last-loaded
    /// definition) so fields the editor never surfaces survive every write verbatim; a `nil` base
    /// (the empty-state first write) uses v1 defaults and omits `agent`/`hooks`.
    ///
    /// Per-action fields the editor doesn't surface (`maxAttempts` / `onMaxAttempts` — reserved in
    /// v1) are likewise carried forward from `base` by matching frozen slug, so a hand-authored
    /// loop guard isn't silently dropped on the first editor save. The editor owns only `name`,
    /// `instructions`, and `routes`.
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
            // Drop a carried-forward escape pointer whose target the editor removed — keeping it
            // would dangle and fail validate(); the editor's "every write is valid" guarantee wins.
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
