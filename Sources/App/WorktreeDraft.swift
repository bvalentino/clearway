import Foundation

/// The New Worktree sheet's two text fields and the rule that binds them: a name fills the
/// branch until the branch is edited by hand, and clearing the branch hands control back.
///
/// The mutators are the only way to change state, because a SwiftUI `.onChange(of:)` cannot
/// tell a user keystroke from the name-driven write it would itself trigger. The branch field
/// binds a setter to `setBranch` — the user-edit path — while `setName` writes the state.
struct WorktreeDraft: Equatable {
    private(set) var name: String = ""
    private(set) var branch: String = ""
    private(set) var branchIsHandEdited: Bool = false

    /// Declared so the synthesized memberwise initializer is not: `private(set)` does not
    /// suppress it, and it would let a caller build a hand-edited draft with an empty branch —
    /// a state no mutator can reach, which neither regenerates from the name nor creates.
    init() {} // swiftlint:disable:this unneeded_synthesized_initializer

    /// Lowercases, keeps ASCII letters and digits, turns every other run of characters into a
    /// single hyphen, and trims the leading and trailing ones. No prefix, and no
    /// transliteration: `"Café Ausflug"` is `caf-ausflug`.
    static func slug(_ name: String) -> String {
        var result = ""
        var separatorPending = false
        for character in name.lowercased() {
            guard character.isASCII, character.isLetter || character.isNumber else {
                separatorPending = true
                continue
            }
            if separatorPending && !result.isEmpty { result.append("-") }
            separatorPending = false
            result.append(character)
        }
        return result
    }

    mutating func setName(_ newValue: String) {
        name = newValue
        if !branchIsHandEdited { branch = Self.slug(newValue) }
    }

    /// The hand-edit path. It sanitises spaces only — a branch may legitimately contain `/`,
    /// `_` and `.` — and an empty result resumes name-driven generation.
    mutating func setBranch(_ newValue: String) {
        let sanitized = newValue.replacingOccurrences(of: " ", with: "-")
        branch = sanitized
        branchIsHandEdited = !sanitized.isEmpty
    }
}
