import AppKit

/// Colors for Markdown syntax highlighting (dark mode only).
enum MarkdownTheme {
    static let text = NSColor(red: 0.878, green: 0.878, blue: 0.878, alpha: 1)
    static let syntax = NSColor(red: 0.45, green: 0.45, blue: 0.45, alpha: 1)
    static let heading = NSColor(red: 0.95, green: 0.95, blue: 0.95, alpha: 1)
    static let bold = NSColor(red: 0.9, green: 0.9, blue: 0.9, alpha: 1)
    static let italic = NSColor(red: 0.8, green: 0.8, blue: 0.8, alpha: 1)
    static let code = NSColor(red: 0.9, green: 0.45, blue: 0.45, alpha: 1)
    static let link = NSColor(red: 0.4, green: 0.6, blue: 0.9, alpha: 1)
    static let blockquote = NSColor(red: 0.6, green: 0.6, blue: 0.6, alpha: 1)
}

/// Applies regex-based Markdown syntax highlighting to an NSTextStorage.
/// Always re-highlights the full document because multi-line constructs
/// (fenced code blocks) make incremental highlighting unreliable.
enum MarkdownSyntaxHighlighter {

    static let lineSpacing: CGFloat = 8

    // MARK: - Public

    static func highlight(textStorage: NSTextStorage) {
        let string = textStorage.string
        guard !string.isEmpty else { return }
        let fullRange = NSRange(location: 0, length: (string as NSString).length)

        // Batch all attribute changes into a single layout pass.
        // Without this, the "reset to base style" step temporarily changes
        // heading fonts, causing content height to bounce and scroll to jump.
        textStorage.beginEditing()
        defer { textStorage.endEditing() }

        // Reset to base style
        let baseFont = textStorage.attribute(.font, at: 0, effectiveRange: nil) as? NSFont
            ?? NSFont.monospacedSystemFont(ofSize: 14, weight: .regular)
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineSpacing = lineSpacing
        textStorage.addAttributes([
            .foregroundColor: MarkdownTheme.text,
            .font: baseFont,
            .paragraphStyle: paragraph,
        ], range: fullRange)

        // Collect fenced code block ranges first to skip them in later patterns
        var codeBlockRanges: [NSRange] = []
        fencedCodeRegex.enumerateMatches(in: string, range: fullRange) { match, _, _ in
            guard let match else { return }
            codeBlockRanges.append(match.range)
            textStorage.addAttribute(.foregroundColor, value: MarkdownTheme.code, range: match.range)
        }

        let skip: (NSRange) -> Bool = { range in
            codeBlockRanges.contains { NSIntersectionRange($0, range).length > 0 }
        }

        // Headings
        headingRegex.enumerateMatches(in: string, range: fullRange) { match, _, _ in
            guard let match, !skip(match.range) else { return }
            let headingFont = NSFont.monospacedSystemFont(ofSize: baseFont.pointSize + 4, weight: .bold)
            textStorage.addAttribute(.foregroundColor, value: MarkdownTheme.syntax, range: match.range(at: 1))
            textStorage.addAttributes([
                .foregroundColor: MarkdownTheme.heading,
                .font: headingFont,
            ], range: match.range(at: 2))
        }

        // Bold
        let boldFont = NSFont.monospacedSystemFont(ofSize: baseFont.pointSize, weight: .bold)
        boldRegex.enumerateMatches(in: string, range: fullRange) { match, _, _ in
            guard let match, !skip(match.range) else { return }
            textStorage.addAttribute(.foregroundColor, value: MarkdownTheme.syntax, range: match.range(at: 1))
            textStorage.addAttributes([
                .foregroundColor: MarkdownTheme.bold,
                .font: boldFont,
            ], range: match.range(at: 2))
            textStorage.addAttribute(.foregroundColor, value: MarkdownTheme.syntax, range: match.range(at: 3))
        }

        // Italic (*text* and _text_, but not **text** or __text__)
        let italicDescriptor = baseFont.fontDescriptor.withSymbolicTraits(.italic)
        let italicFont = NSFont(descriptor: italicDescriptor, size: baseFont.pointSize) ?? baseFont
        let applyItalic: (NSTextCheckingResult?, NSRegularExpression.MatchingFlags, UnsafeMutablePointer<ObjCBool>) -> Void = { match, _, _ in
            guard let match, !skip(match.range) else { return }
            let full = match.range
            let content = match.range(at: 1)
            // Dim the opening marker
            let openMarker = NSRange(location: full.location, length: content.location - full.location)
            textStorage.addAttribute(.foregroundColor, value: MarkdownTheme.syntax, range: openMarker)
            // Style the content
            textStorage.addAttributes([
                .foregroundColor: MarkdownTheme.italic,
                .font: italicFont,
            ], range: content)
            // Dim the closing marker
            let closeStart = content.location + content.length
            let closeMarker = NSRange(location: closeStart, length: full.location + full.length - closeStart)
            textStorage.addAttribute(.foregroundColor, value: MarkdownTheme.syntax, range: closeMarker)
        }
        italicStarRegex.enumerateMatches(in: string, range: fullRange, using: applyItalic)
        italicUnderRegex.enumerateMatches(in: string, range: fullRange, using: applyItalic)

        // Strikethrough
        strikethroughRegex.enumerateMatches(in: string, range: fullRange) { match, _, _ in
            guard let match, !skip(match.range) else { return }
            textStorage.addAttribute(.foregroundColor, value: MarkdownTheme.syntax, range: match.range(at: 1))
            textStorage.addAttributes([
                .foregroundColor: MarkdownTheme.syntax,
                .strikethroughStyle: NSUnderlineStyle.single.rawValue,
            ], range: match.range(at: 2))
            textStorage.addAttribute(.foregroundColor, value: MarkdownTheme.syntax, range: match.range(at: 3))
        }

        // Inline code
        inlineCodeRegex.enumerateMatches(in: string, range: fullRange) { match, _, _ in
            guard let match, !skip(match.range) else { return }
            textStorage.addAttribute(.foregroundColor, value: MarkdownTheme.code, range: match.range)
        }

        // Links
        linkRegex.enumerateMatches(in: string, range: fullRange) { match, _, _ in
            guard let match, !skip(match.range) else { return }
            textStorage.addAttribute(.foregroundColor, value: MarkdownTheme.syntax, range: match.range(at: 1))
            textStorage.addAttribute(.foregroundColor, value: MarkdownTheme.link, range: match.range(at: 2))
            textStorage.addAttribute(.foregroundColor, value: MarkdownTheme.syntax, range: match.range(at: 3))
            textStorage.addAttribute(.foregroundColor, value: MarkdownTheme.syntax, range: match.range(at: 4))
            textStorage.addAttribute(.foregroundColor, value: MarkdownTheme.syntax, range: match.range(at: 5))
            textStorage.addAttribute(.foregroundColor, value: MarkdownTheme.syntax, range: match.range(at: 6))
        }

        // Blockquotes
        blockquoteRegex.enumerateMatches(in: string, range: fullRange) { match, _, _ in
            guard let match, !skip(match.range) else { return }
            textStorage.addAttribute(.foregroundColor, value: MarkdownTheme.syntax, range: match.range(at: 1))
            textStorage.addAttribute(.foregroundColor, value: MarkdownTheme.blockquote, range: match.range(at: 2))
        }

        // List markers
        listMarkerRegex.enumerateMatches(in: string, range: fullRange) { match, _, _ in
            guard let match, !skip(match.range) else { return }
            textStorage.addAttribute(.foregroundColor, value: MarkdownTheme.syntax, range: match.range(at: 2))
        }

        // Horizontal rules
        horizontalRuleRegex.enumerateMatches(in: string, range: fullRange) { match, _, _ in
            guard let match, !skip(match.range) else { return }
            textStorage.addAttribute(.foregroundColor, value: MarkdownTheme.syntax, range: match.range)
        }
    }

    // MARK: - Regex Patterns

    private static let fencedCodeRegex = try! NSRegularExpression(
        pattern: "^(`{3,})[^`]*$\\n([\\s\\S]*?)^\\1\\s*$",
        options: [.anchorsMatchLines]
    )

    private static let headingRegex = try! NSRegularExpression(
        pattern: "^(#{1,6})\\s+(.+)$",
        options: [.anchorsMatchLines]
    )

    private static let boldRegex = try! NSRegularExpression(
        pattern: "(\\*\\*|__)(.+?)(\\1)",
        options: []
    )

    // Match *text* or _text_ but not **text** or __text__
    private static let italicStarRegex = try! NSRegularExpression(
        pattern: "(?<!\\*)\\*(?!\\*)(.+?)(?<!\\*)\\*(?!\\*)",
        options: []
    )
    private static let italicUnderRegex = try! NSRegularExpression(
        pattern: "(?<!_)_(?!_)(.+?)(?<!_)_(?!_)",
        options: []
    )

    private static let strikethroughRegex = try! NSRegularExpression(
        pattern: "(~~)(.+?)(~~)",
        options: []
    )

    private static let inlineCodeRegex = try! NSRegularExpression(
        pattern: "(?<!`)`(?!`)(.+?)(?<!`)`(?!`)",
        options: []
    )

    private static let linkRegex = try! NSRegularExpression(
        pattern: "(\\[)(.+?)(\\])(\\()(.+?)(\\))",
        options: []
    )

    private static let blockquoteRegex = try! NSRegularExpression(
        pattern: "^(>+)\\s?(.*)$",
        options: [.anchorsMatchLines]
    )

    private static let listMarkerRegex = try! NSRegularExpression(
        pattern: "^(\\s*)([-*]|\\d+\\.|[-*]\\s\\[[ xX]\\])\\s",
        options: [.anchorsMatchLines]
    )

    private static let horizontalRuleRegex = try! NSRegularExpression(
        pattern: "^([-*_]{3,})\\s*$",
        options: [.anchorsMatchLines]
    )
}
