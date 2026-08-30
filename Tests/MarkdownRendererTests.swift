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

    /// Without `CMARK_OPT_TABLE_PREFER_STYLE_ATTRIBUTES` cmark emits `align=`, a
    /// presentational hint that loses to `PreviewCSS`'s `th, td { text-align: left }`,
    /// so every aligned column would silently render left-aligned.
    func testTableColumnAlignmentUsesStyleAttribute() {
        let html = MarkdownRenderer.renderBody(from: """
        | a | b |
        |:--|--:|
        | 1 | 2 |
        """)

        XCTAssertTrue(html.contains("style=\"text-align: right\""), html)
        XCTAssertFalse(html.contains("align=\"right\""), html)
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

    /// `CMARK_OPT_STRIKETHROUGH_DOUBLE_TILDE` is what stops a single tilde from
    /// striking text through — task documents write ranges like `~5~10 minutes`.
    func testSingleTildeIsNotStrikethrough() {
        let html = MarkdownRenderer.renderBody(from: "Takes ~5~10 minutes.")

        XCTAssertFalse(html.contains("<del>"), html)
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
        let html = MarkdownRenderer.renderBody(from: "- [ ] todo")
        XCTAssertTrue(html.contains("<li><input type=\"checkbox\" disabled=\"\" />"), html)

        let css = PreviewCSS.css
            .split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .joined(separator: " ")

        XCTAssertTrue(css.contains("li:has(> input[type=\"checkbox\"]) { list-style: none; }"), css)
        XCTAssertTrue(
            css.contains("li:has(> input[type=\"checkbox\"]) > p:first-of-type { display: inline; }"),
            css
        )
        XCTAssertFalse(css.contains("contains-task-list"), css)
        XCTAssertFalse(css.contains("task-list-item"), css)
    }
}
