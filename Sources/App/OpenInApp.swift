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
///
/// `Hashable` must stay **whole-value**, not narrowed to `id`: the Open in split button is rebuilt
/// by `.id(SettingsManager.menuOpenInApps)`, so an `==` over ids alone would leave the toolbar
/// showing an app's pre-edit command with every test still green.
struct OpenInApp: Identifiable, Codable, Hashable {

    /// `Kind` is stored in its synthesized form, so the **case names and their associated-value
    /// labels are persisted form too** — `{"kind":{"builtIn":{"_0":"zed"}}}` and
    /// `{"kind":{"custom":{"label":"Xcode"}}}`. `_0` comes from `builtIn`'s value being unlabeled,
    /// so adding a label renames the key and orphans every stored entry, and the compiler says
    /// nothing. `OpenInAppTests.test_storedWireFormat_decodesFromItsPersistedBytes` is what
    /// notices; a round-trip test cannot, since it encodes and decodes with the same build.
    enum Kind: Codable, Hashable {
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

    /// Saving from the editor sheet: an edit replaces in place so the entry keeps its position,
    /// and an unknown id appends, which is the add-custom path. List order is menu order, so an
    /// edit that moved its entry would reorder the menu.
    static func upsert(_ app: OpenInApp, into apps: [OpenInApp]) -> [OpenInApp] {
        guard let index = apps.firstIndex(where: { $0.id == app.id }) else { return apps + [app] }
        var updated = apps
        updated[index] = app
        return updated
    }

    /// The editor sheet's fields, shared by add-custom and edit. `builtIn` is nil for a custom
    /// entry, which is the only case that shows a label field.
    struct Draft: Equatable {
        var builtIn: OpenInBuiltIn?
        var label: String
        var command: String

        private var trimmedLabel: String { label.trimmingCharacters(in: .whitespacesAndNewlines) }
        private var trimmedCommand: String { command.trimmingCharacters(in: .whitespacesAndNewlines) }

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
