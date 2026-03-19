import Foundation
import cmark

enum MarkdownRenderer {

    /// Converts Markdown text to a full HTML document with embedded CSS.
    static func renderHTML(from markdown: String) -> String {
        let bodyHTML = renderBody(from: markdown)
        return """
        <!DOCTYPE html>
        <html>
        <head>
        <meta charset="utf-8">
        <meta name="viewport" content="width=device-width, initial-scale=1">
        <style>\(PreviewCSS.css)</style>
        </head>
        <body>\(bodyHTML)</body>
        </html>
        """
    }

    /// Converts Markdown text to an HTML fragment (no wrapper document).
    static func renderBody(from markdown: String) -> String {
        let options = CMARK_OPT_UNSAFE | CMARK_OPT_FOOTNOTES | CMARK_OPT_SMART
            | CMARK_OPT_STRIKETHROUGH_DOUBLE_TILDE | CMARK_OPT_TABLE_PREFER_STYLE_ATTRIBUTES

        guard let parser = cmark_parser_new(options) else {
            return escapedPre(markdown)
        }
        defer { cmark_parser_free(parser) }

        cmark_parser_feed(parser, markdown, markdown.utf8.count)
        guard let doc = cmark_parser_finish(parser) else {
            return escapedPre(markdown)
        }
        defer { cmark_node_free(doc) }

        guard let cStr = cmark_render_html(doc, options, nil) else {
            return escapedPre(markdown)
        }
        defer { free(cStr) }

        return String(cString: cStr)
    }

    private static func escapedPre(_ text: String) -> String {
        "<pre>\(text.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;"))</pre>"
    }
}
