import Foundation
import cmark

enum MarkdownRenderer {

    private static let gfmExtensionNames = ["table", "strikethrough", "autolink", "tasklist"]

    /// The C guard inside `ensure_registered` is a non-atomic check-then-set,
    /// so a lazy static is what actually makes first-call registration safe.
    private static let coreExtensionsRegistered: Void = {
        cmark_gfm_core_extensions_ensure_registered()
    }()

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
        _ = coreExtensionsRegistered

        // SMART would rewrite `--flag` and straight quotes in task documents
        // as typographic dashes and curly quotes.
        let options = CMARK_OPT_UNSAFE | CMARK_OPT_FOOTNOTES
            | CMARK_OPT_STRIKETHROUGH_DOUBLE_TILDE | CMARK_OPT_TABLE_PREFER_STYLE_ATTRIBUTES

        guard let parser = cmark_parser_new(options) else {
            return escapedPre(markdown)
        }
        defer { cmark_parser_free(parser) }

        for name in gfmExtensionNames {
            guard let ext = cmark_find_syntax_extension(name) else { continue }
            cmark_parser_attach_syntax_extension(parser, ext)
        }

        cmark_parser_feed(parser, markdown, markdown.utf8.count)
        guard let doc = cmark_parser_finish(parser) else {
            return escapedPre(markdown)
        }
        defer { cmark_node_free(doc) }

        // The extension list is owned by the parser, so this must render before
        // the `cmark_parser_free` defer above unwinds.
        let extensions = cmark_parser_get_syntax_extensions(parser)
        guard let cStr = cmark_render_html(doc, options, extensions) else {
            return escapedPre(markdown)
        }
        defer { free(cStr) }

        return String(cString: cStr)
    }

    private static func escapedPre(_ text: String) -> String {
        "<pre>\(text.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;"))</pre>"
    }
}
