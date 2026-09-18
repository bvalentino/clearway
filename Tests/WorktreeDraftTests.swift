import XCTest
@testable import Clearway

final class WorktreeDraftSlugTests: XCTestCase {

    func testWorkedExample() {
        XCTAssertEqual(WorktreeDraft.slug("Fix login Bug!"), "fix-login-bug")
    }

    func testAllPunctuationCollapsesToEmpty() {
        XCTAssertEqual(WorktreeDraft.slug("!!!"), "")
    }

    func testLeadingAndTrailingPunctuationIsTrimmed() {
        XCTAssertEqual(WorktreeDraft.slug(" -Fix- "), "fix")
    }

    func testNonASCIIIsNotTransliterated() {
        XCTAssertEqual(WorktreeDraft.slug("Café Ausflug"), "caf-ausflug")
    }

    func testEmptyInput() {
        XCTAssertEqual(WorktreeDraft.slug(""), "")
    }

    func testRunOfSeparatorsBecomesOneHyphen() {
        XCTAssertEqual(WorktreeDraft.slug("a  ///  b"), "a-b")
    }

    func testDigitsAreKept() {
        XCTAssertEqual(WorktreeDraft.slug("Issue 42: Retry"), "issue-42-retry")
    }
}

final class WorktreeDraftTests: XCTestCase {

    func testNameFillsBranchBeforeAnyHandEdit() {
        var draft = WorktreeDraft()
        draft.setName("Fix login Bug!")
        XCTAssertEqual(draft.name, "Fix login Bug!")
        XCTAssertEqual(draft.branch, "fix-login-bug")
        XCTAssertFalse(draft.branchIsHandEdited)
    }

    func testHandEditStopsGeneration() {
        var draft = WorktreeDraft()
        draft.setName("Fix login")
        draft.setBranch("my-own-branch")
        draft.setName("Something else entirely")
        XCTAssertEqual(draft.name, "Something else entirely")
        XCTAssertEqual(draft.branch, "my-own-branch")
        XCTAssertTrue(draft.branchIsHandEdited)
    }

    func testClearingTheBranchResumesGeneration() {
        var draft = WorktreeDraft()
        draft.setBranch("my-own-branch")
        XCTAssertTrue(draft.branchIsHandEdited)
        draft.setBranch("")
        XCTAssertFalse(draft.branchIsHandEdited)
        draft.setName("Fix login Bug!")
        XCTAssertEqual(draft.branch, "fix-login-bug")
    }

    func testHandEditTurnsSpacesIntoHyphens() {
        var draft = WorktreeDraft()
        draft.setBranch("my own branch")
        XCTAssertEqual(draft.branch, "my-own-branch")
        XCTAssertTrue(draft.branchIsHandEdited)
    }

    func testHandEditLeavesSlashUnderscoreAndDotAlone() {
        var draft = WorktreeDraft()
        draft.setBranch("feature/a_b.c")
        XCTAssertEqual(draft.branch, "feature/a_b.c")
    }

    func testHandEditDoesNotRunTheSlugRule() {
        var draft = WorktreeDraft()
        draft.setBranch("Fix/Login!")
        XCTAssertEqual(draft.branch, "Fix/Login!")
    }

    func testDefaultsAreEmpty() {
        let draft = WorktreeDraft()
        XCTAssertEqual(draft.name, "")
        XCTAssertEqual(draft.branch, "")
        XCTAssertFalse(draft.branchIsHandEdited)
    }
}
