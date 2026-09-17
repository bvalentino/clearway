import Foundation

/// The apps Clearway offers out of the box. Raw values are the persisted form and must not change.
/// Clearway detects nothing — a built-in only supplies a fixed label and a starting command.
enum OpenInBuiltIn: String, Codable, CaseIterable, Identifiable {
    case finder
    case vsCode
    case cursor
    case zed

    var id: String { rawValue }

    var label: String {
        switch self {
        case .finder: return "Finder"
        case .vsCode: return "VS Code"
        case .cursor: return "Cursor"
        case .zed: return "Zed"
        }
    }

    var defaultCommand: String {
        switch self {
        case .finder: return "open"
        case .vsCode: return "code"
        case .cursor: return "cursor"
        case .zed: return "zed"
        }
    }
}

/// One entry in the user's "Open in" list: a label and the command to run with the worktree
/// path appended. A built-in's label lives in its `kind`, so there is no field to edit.
struct OpenInApp: Identifiable, Codable, Equatable {
    enum Kind: Codable, Equatable {
        case builtIn(OpenInBuiltIn)
        case custom(label: String)
    }

    let id: UUID
    var kind: Kind
    var command: String

    init(id: UUID = UUID(), kind: Kind, command: String) {
        self.id = id
        self.kind = kind
        self.command = command
    }

    var label: String {
        switch kind {
        case .builtIn(let builtIn): return builtIn.label
        case .custom(let label): return label
        }
    }

    var builtIn: OpenInBuiltIn? {
        switch kind {
        case .builtIn(let builtIn): return builtIn
        case .custom: return nil
        }
    }

    /// Each built-in may be added at most once, so one already in `apps` drops out.
    static func availableBuiltIns(excluding apps: [OpenInApp]) -> [OpenInBuiltIn] {
        let used = Set(apps.compactMap(\.builtIn))
        return OpenInBuiltIn.allCases.filter { !used.contains($0) }
    }

    /// The editor sheet's fields, shared by add-custom and edit. `builtIn` is nil for a custom
    /// entry, which is the only case that shows a label field.
    struct Draft: Equatable {
        var builtIn: OpenInBuiltIn?
        var label: String
        var command: String

        private var trimmedLabel: String { label.trimmingCharacters(in: .whitespaces) }
        private var trimmedCommand: String { command.trimmingCharacters(in: .whitespaces) }

        var isValid: Bool {
            !trimmedCommand.isEmpty && (builtIn != nil || !trimmedLabel.isEmpty)
        }

        /// The entry this draft describes, under `id` — the edited entry's, or a fresh one when
        /// adding, so add and edit share one save path. A built-in keeps its kind, so editing one
        /// can only change the command.
        func app(id: UUID) -> OpenInApp {
            OpenInApp(
                id: id,
                kind: builtIn.map(Kind.builtIn) ?? .custom(label: trimmedLabel),
                command: trimmedCommand
            )
        }
    }
}

extension OpenInApp.Draft {

    /// Declared out of line so `Draft` keeps its synthesized memberwise init.
    init(app: OpenInApp) {
        self.init(builtIn: app.builtIn, label: app.label, command: app.command)
    }
}
