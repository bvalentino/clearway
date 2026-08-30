import XCTest
@testable import Clearway

/// The footnote, raw-HTML and CSS cases are regression guards rather than GFM
/// features — they pin behaviour that must survive the extension work.
final class MarkdownRendererTests: XCTestCase {

    func testPipeTableRendersAsTable() {
        let html = MarkdownRenderer.renderBody(from: """
        | a | b |
        |---|---|
        | 1 | 2 |
        """)

        XCTAssertTrue(html.contains("<table>"), html)
        XCTAssertTrue(html.contains("<th>a</th>"), html)
        XCTAssertTrue(html.contains("<td>1</td>"), html)
    }

    func testUncheckedTaskItemRendersCheckbox() {
        let html = MarkdownRenderer.renderBody(from: "- [ ] todo")

        XCTAssertTrue(html.contains("<input type=\"checkbox\" disabled=\"\" />"), html)
    }

    func testCheckedTaskItemRendersCheckedCheckbox() {
        let html = MarkdownRenderer.renderBody(from: "- [x] done")

        XCTAssertTrue(html.contains("<input type=\"checkbox\" checked=\"\" disabled=\"\" />"), html)
    }

    func testDoubleTildeRendersStrikethrough() {
        let html = MarkdownRenderer.renderBody(from: "~~struck~~")

        XCTAssertTrue(html.contains("<del>struck</del>"), html)
    }

    func testBareWWWURLAutolinks() {
        let html = MarkdownRenderer.renderBody(from: "Visit www.example.com today.")

        XCTAssertTrue(html.contains("href=\"http://www.example.com\""), html)
    }

    func testBareHTTPSURLAutolinks() {
        let html = MarkdownRenderer.renderBody(from: "Visit https://example.com today.")

        XCTAssertTrue(html.contains("href=\"https://example.com\""), html)
    }

    func testPunctuationIsNotSmartened() {
        let html = MarkdownRenderer.renderBody(from: "Use --flag ... \"quoted\" and 'single'")

        XCTAssertTrue(html.contains("--flag"), html)
        XCTAssertTrue(html.contains("..."), html)
        XCTAssertTrue(html.contains("&quot;"), html)
        XCTAssertTrue(html.contains("'"), html)
        for smart in ["–", "—", "…", "\u{201C}", "\u{201D}", "\u{2018}", "\u{2019}"] {
            XCTAssertFalse(html.contains(smart), "unexpected \(smart) in \(html)")
        }
    }

    func testFootnotesStillRender() {
        let html = MarkdownRenderer.renderBody(from: """
        Text with a note.[^1]

        [^1]: The note.
        """)

        XCTAssertTrue(html.contains("class=\"footnote-ref\""), html)
        XCTAssertTrue(html.contains("id=\"fn1\""), html)
    }

    func testRawHTMLSurvives() {
        let html = MarkdownRenderer.renderBody(from: "<div class=\"raw\">kept</div>")

        XCTAssertTrue(html.contains("<div class=\"raw\">"), html)
    }

    func testPreviewCSSMatchesEmittedTaskListMarkup() {
        let css = PreviewCSS.css

        XCTAssertTrue(css.contains("input[type=\"checkbox\"]"), css)
        XCTAssertFalse(css.contains("contains-task-list"), css)
        XCTAssertFalse(css.contains("task-list-item"), css)
    }
}
