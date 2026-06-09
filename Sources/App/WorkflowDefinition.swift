import CryptoKit
import Foundation

/// A parsed `WORKFLOW.json` (read from `.clearway/WORKFLOW.json`). The action graph plus
/// the runtime knobs the loop needs. When this exists and is valid, it is the complete
/// source of truth and the legacy `WORKFLOW.md` (`WorkflowConfig`) is ignored for the project.
///
/// The model is decoded from JSON with snake_case keys (`timeout_ms`, `max_attempts`,
/// `on_max_attempts`, `after_create`, `before_run`); the Swift surface uses camelCase. Flow
/// is defined by **pointers** (`start`, route values) into the slug-keyed `actions` map —
/// order in the file is cosmetic, so the map is intentionally unordered.
struct WorkflowDefinition: Equatable, Decodable {
    /// Schema version. v1 is the only shape this type understands.
    let version: Int

    /// The slug the engine seeds `status` to when a worktree is created. Must resolve to an
    /// existing action (enforced by `validate()`).
    let start: String

    /// Agent command + timeout the loop launches each action with. Defaults applied when the
    /// `agent` object (or any of its fields) is omitted.
    let agent: AgentSettings

    /// Optional shell hooks run around worktree creation / action launch. Absent = no hooks.
    let hooks: Hooks?

    /// The action graph, keyed by **slug**. Order is cosmetic; pointers target slugs, never
    /// `name`, so renaming an action's display label never breaks the graph.
    let actions: [String: Action]

    // MARK: - Nested types

    /// Runtime knobs for the agent that runs each action.
    struct AgentSettings: Equatable, Decodable {
        /// The command to launch (e.g. `"claude"`). Defaults to `"claude"` when omitted.
        let command: String

        /// Per-action timeout in milliseconds. Defaults to `Self.defaultTimeoutMs` when omitted.
        let timeoutMs: Int

        /// Default agent command when `WORKFLOW.json` omits `agent.command`.
        static let defaultCommand = "claude"

        /// Default per-action timeout (10 minutes) when `WORKFLOW.json` omits `agent.timeout_ms`.
        /// Generous because agent steps (implement / test / review) are long-running.
        static let defaultTimeoutMs = 600_000

        /// The defaults used when the entire `agent` object is omitted.
        static let `default` = AgentSettings(command: defaultCommand, timeoutMs: defaultTimeoutMs)

        private enum CodingKeys: String, CodingKey {
            case command
            case timeoutMs = "timeout_ms"
        }

        init(command: String, timeoutMs: Int) {
            self.command = command
            self.timeoutMs = timeoutMs
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            command = try container.decodeIfPresent(String.self, forKey: .command) ?? Self.defaultCommand
            timeoutMs = try container.decodeIfPresent(Int.self, forKey: .timeoutMs) ?? Self.defaultTimeoutMs
        }
    }

    /// Optional shell hooks. Both fields are individually optional so a workflow can define
    /// one without the other.
    struct Hooks: Equatable, Decodable {
        /// Shell command run after a worktree is created for the task.
        let afterCreate: String?

        /// Shell command run before each action's agent launches.
        let beforeRun: String?

        private enum CodingKeys: String, CodingKey {
            case afterCreate = "after_create"
            case beforeRun = "before_run"
        }
    }

    /// A single action — a state `status` can sit on. Terminal when `routes` is empty/absent.
    struct Action: Equatable, Decodable {
        /// Editable display label. Cosmetic — pointers never target it.
        let name: String

        /// The prompt body injected into the agent when this action launches.
        let instructions: String

        /// Outcome → target slug. v1 routing is action→action keyed by outcome (`success`),
        /// so branches/loops drop in later with no format migration. Empty/absent = terminal.
        let routes: [String: String]

        /// Per-action entry cap. **Reserved for a future loop guard and NOT enforced in v1** — the
        /// manual kill ("Stop Agent") is the v1 loop-stopper. Decoded and validated (a reserved part
        /// of the `WORKFLOW.json` format) but never acted on by the engine. `nil` = unset.
        let maxAttempts: Int?

        /// Escape slug routed to when `maxAttempts` is hit. **Reserved for a future loop guard and
        /// NOT enforced in v1.** Its target is still validated to resolve (so a future enforcement
        /// can trust the pointer), but the engine never routes to it today. `nil` = unset.
        let onMaxAttempts: String?

        private enum CodingKeys: String, CodingKey {
            case name
            case instructions
            case routes
            case maxAttempts = "max_attempts"
            case onMaxAttempts = "on_max_attempts"
        }

        init(
            name: String,
            instructions: String,
            routes: [String: String] = [:],
            maxAttempts: Int? = nil,
            onMaxAttempts: String? = nil
        ) {
            self.name = name
            self.instructions = instructions
            self.routes = routes
            self.maxAttempts = maxAttempts
            self.onMaxAttempts = onMaxAttempts
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            name = try container.decode(String.self, forKey: .name)
            instructions = try container.decode(String.self, forKey: .instructions)
            // Absent `routes` = terminal action, so default to empty rather than failing.
            routes = try container.decodeIfPresent([String: String].self, forKey: .routes) ?? [:]
            maxAttempts = try container.decodeIfPresent(Int.self, forKey: .maxAttempts)
            onMaxAttempts = try container.decodeIfPresent(String.self, forKey: .onMaxAttempts)
        }
    }

    private enum CodingKeys: String, CodingKey {
        case version
        case start
        case agent
        case hooks
        case actions
    }

    init(
        version: Int,
        start: String,
        agent: AgentSettings = .default,
        hooks: Hooks? = nil,
        actions: [String: Action]
    ) {
        self.version = version
        self.start = start
        self.agent = agent
        self.hooks = hooks
        self.actions = actions
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        version = try container.decode(Int.self, forKey: .version)
        start = try container.decode(String.self, forKey: .start)
        // An omitted `agent` object falls back entirely to defaults.
        agent = try container.decodeIfPresent(AgentSettings.self, forKey: .agent) ?? .default
        hooks = try container.decodeIfPresent(Hooks.self, forKey: .hooks)
        actions = try container.decode([String: Action].self, forKey: .actions)
    }

    // MARK: - Graph helpers

    /// Terminal = no outgoing routes. Reaching this action ends the loop. An unknown slug is
    /// treated as terminal so the engine never tries to advance past a value it can't resolve.
    func isTerminal(_ slug: String) -> Bool {
        actions[slug]?.routes.isEmpty ?? true
    }

    /// The legal next `status` values an agent may write from `slug` (v1: 0 or 1). Unknown
    /// slugs yield no legal next values. Sorted so the value injected into the agent prompt is
    /// stable across calls — `routes` is an unordered map, so without this the "first" next value
    /// could differ run to run.
    func legalNext(from slug: String) -> [String] {
        Array(actions[slug]?.routes.values ?? [String: String]().values).sorted()
    }
}

// MARK: - Loading + validation

extension WorkflowDefinition {
    /// The well-known location of the workflow file, relative to a project root.
    /// Consolidated under `.clearway/` with `TASK.md` and the backlog.
    static let relativePath = ".clearway/WORKFLOW.json"

    /// A structured, typed description of why a `WORKFLOW.json` failed to load or validate.
    /// Surfaced so callers can report the *specific* defect rather than a generic failure.
    enum LoadError: Error, Equatable {
        /// No file at `.clearway/WORKFLOW.json`. (Distinct from a malformed file — an absent
        /// file just means the project uses the legacy path, not that anything is broken.)
        case fileNotFound(path: String)

        /// The file bytes could not be read or decoded as UTF-8 / JSON.
        case unreadable(reason: String)

        /// JSON decoded but did not match the `WorkflowDefinition` shape.
        case malformedJSON(reason: String)

        /// `actions` is present but empty — a workflow with no actions can never run.
        case noActions

        /// `start` does not resolve to any action in `actions`.
        case startTargetMissing(start: String)

        /// A route's target slug does not resolve to any action.
        case routeTargetMissing(action: String, outcome: String, target: String)

        /// An `on_max_attempts` escape slug does not resolve to any action.
        case onMaxAttemptsTargetMissing(action: String, target: String)
    }

    /// Loads and validates `.clearway/WORKFLOW.json` for a project. Throws a typed `LoadError`
    /// describing the specific defect (missing file, bad JSON, dangling pointer, …).
    static func load(projectPath: String) throws -> WorkflowDefinition {
        let path = (projectPath as NSString).appendingPathComponent(relativePath)
        guard FileManager.default.fileExists(atPath: path) else {
            throw LoadError.fileNotFound(path: path)
        }
        guard let data = FileManager.default.contents(atPath: path) else {
            throw LoadError.unreadable(reason: "could not read file at \(path)")
        }
        let definition: WorkflowDefinition
        do {
            definition = try JSONDecoder().decode(WorkflowDefinition.self, from: data)
        } catch {
            throw LoadError.malformedJSON(reason: String(describing: error))
        }
        try definition.validate()
        return definition
    }

    /// Whether the project has a **valid** `.clearway/WORKFLOW.json`. Returns `true` only when
    /// the file exists, decodes, and passes validation — this is the gate that decides whether
    /// the agent-driven engine (and autopilot) is available, so a malformed file reads as
    /// "no JSON workflow" and the project falls back to the legacy path rather than silently
    /// enabling a broken loop.
    static func hasJSONWorkflow(projectPath: String) -> Bool {
        (try? load(projectPath: projectPath)) != nil
    }

    /// Validates the graph's pointers. Run after a successful decode. Throws the first defect
    /// found so the caller can surface a precise, actionable error.
    func validate() throws {
        guard !actions.isEmpty else { throw LoadError.noActions }

        guard actions[start] != nil else {
            throw LoadError.startTargetMissing(start: start)
        }

        for (slug, action) in actions {
            for (outcome, target) in action.routes where actions[target] == nil {
                throw LoadError.routeTargetMissing(action: slug, outcome: outcome, target: target)
            }
            if let escape = action.onMaxAttempts, actions[escape] == nil {
                throw LoadError.onMaxAttemptsTargetMissing(action: slug, target: escape)
            }
        }
    }
}

// MARK: - Trust

/// `WORKFLOW.json` carries executable config — `agent.command` and shell `hooks` — so before the
/// engine launches anything from it, it must be approved by the user, exactly as the legacy
/// `WORKFLOW.md` path gates execution behind a content fingerprint + UserDefaults approval
/// (`WorkflowConfig`). This reuses that primitive rather than inventing a new trust UI: a SHA-256 of
/// the file's raw bytes, stored per-project in `UserDefaults`. The fingerprint is over the *file
/// bytes* (not the decoded model) so any change to a command, hook, or instruction re-arms approval.
extension WorkflowDefinition {
    /// A deterministic fingerprint of the `.clearway/WORKFLOW.json` bytes for a project, or `nil`
    /// when the file is absent/unreadable. Computed from the raw bytes so any edit to executable
    /// content (or anything else) invalidates a prior approval.
    static func trustFingerprint(projectPath: String) -> String? {
        let path = (projectPath as NSString).appendingPathComponent(relativePath)
        guard let data = FileManager.default.contents(atPath: path) else { return nil }
        let digest = SHA256.hash(data: data)
        return digest.prefix(8).map { String(format: "%02x", $0) }.joined()
    }

    /// Whether the current `.clearway/WORKFLOW.json` bytes are approved for this project. An absent
    /// or unreadable file reads as **not** trusted — the engine never executes an unapproved (or
    /// missing) command path. Mirrors `WorkflowConfig.isTrusted`'s UserDefaults comparison.
    static func isTrusted(projectPath: String) -> Bool {
        guard let fingerprint = trustFingerprint(projectPath: projectPath) else { return false }
        return UserDefaults.standard.string(forKey: trustKey(forProject: projectPath)) == fingerprint
    }

    /// Marks the current `.clearway/WORKFLOW.json` bytes as approved for this project. No-op when the
    /// file is absent/unreadable (nothing to fingerprint).
    static func markTrusted(projectPath: String) {
        guard let fingerprint = trustFingerprint(projectPath: projectPath) else { return }
        UserDefaults.standard.set(fingerprint, forKey: trustKey(forProject: projectPath))
    }

    /// Per-project UserDefaults key. Namespaced distinctly from the legacy `WORKFLOW.md` trust key
    /// (`clearway.workflow.trusted.*`) so the two engines' approvals never collide.
    private static func trustKey(forProject projectPath: String) -> String {
        let hash = SHA256.hash(data: Data(projectPath.utf8))
        let hex = hash.prefix(8).map { String(format: "%02x", $0) }.joined()
        return "clearway.workflow.json.trusted.\(hex)"
    }
}
