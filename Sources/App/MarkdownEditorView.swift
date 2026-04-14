import AppKit
import SwiftUI

/// A Markdown editor backed by NSTextView with syntax highlighting.
struct MarkdownEditorView: NSViewRepresentable {
    @Binding var text: String
    @Environment(\.colorScheme) private var colorScheme

    func makeCoordinator() -> Coordinator {
        Coordinator(text: $text)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let textView = NSTextView()
        textView.isRichText = false
        textView.allowsUndo = true
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.usesFindPanel = true
        textView.drawsBackground = false
        textView.textContainerInset = NSSize(width: 20, height: 20)
        textView.textContainer?.lineFragmentPadding = 0
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.textContainer?.widthTracksTextView = true

        let font = NSFont.monospacedSystemFont(ofSize: 14, weight: .regular)
        textView.font = font
        textView.typingAttributes = Self.typingAttributes(font: font)

        textView.delegate = context.coordinator
        context.coordinator.textView = textView

        // Set initial text without triggering highlighting
        textView.string = text

        let scrollView = NSScrollView()
        scrollView.documentView = textView
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.drawsBackground = false

        // Attach textStorage delegate and highlight after view hierarchy is assembled
        textView.textStorage?.delegate = context.coordinator
        if !text.isEmpty {
            context.coordinator.highlightAll()
        }
        context.coordinator.lastAppliedColorScheme = colorScheme

        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let textView = scrollView.documentView as? NSTextView else { return }

        // Refresh the coordinator's binding so derived bindings (e.g. body-only views
        // that remap into a larger buffer) see the current getter/setter rather than
        // the one captured at makeCoordinator time.
        context.coordinator.updateBinding(_text)

        // When the SwiftUI color scheme changes, re-apply typing attributes and
        // re-run the highlighter so cached attribute runs pick up the new theme colors.
        if context.coordinator.lastAppliedColorScheme != colorScheme {
            context.coordinator.lastAppliedColorScheme = colorScheme
            context.coordinator.applyAppearanceChange()
        }

        // Sync text from binding → NSTextView, guarding against feedback loops
        guard !context.coordinator.isUpdating, textView.string != text else { return }
        context.coordinator.isUpdating = true

        // Preserve selection and scroll position across programmatic text replacement
        let selectedRanges = textView.selectedRanges
        let scrollOrigin = scrollView.contentView.bounds.origin

        textView.string = text
        if !text.isEmpty {
            context.coordinator.highlightAll()
        }

        // Clamp ranges to the new string length to avoid out-of-bounds
        let length = (textView.string as NSString).length
        let clamped: [NSValue] = selectedRanges.compactMap { value in
            let r = value.rangeValue
            let loc = min(r.location, length)
            let len = min(r.length, length - loc)
            return NSValue(range: NSRange(location: loc, length: len))
        }
        textView.selectedRanges = clamped.isEmpty ? [NSValue(range: NSRange(location: 0, length: 0))] : clamped
        scrollView.contentView.scroll(to: scrollOrigin)
        scrollView.reflectScrolledClipView(scrollView.contentView)

        context.coordinator.isUpdating = false
    }

    private static func typingAttributes(font: NSFont) -> [NSAttributedString.Key: Any] {
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineSpacing = MarkdownSyntaxHighlighter.lineSpacing
        return [
            .font: font,
            .foregroundColor: MarkdownTheme.text,
            .paragraphStyle: paragraph,
        ]
    }

    // MARK: - Coordinator

    final class Coordinator: NSObject, NSTextViewDelegate, NSTextStorageDelegate {
        @Binding var text: String
        weak var textView: NSTextView?
        var isUpdating = false
        var lastAppliedColorScheme: ColorScheme?
        private var pendingHighlight: DispatchWorkItem?

        init(text: Binding<String>) {
            _text = text
        }

        func applyAppearanceChange() {
            guard let textView else { return }
            let font = textView.font ?? NSFont.monospacedSystemFont(ofSize: 14, weight: .regular)
            textView.typingAttributes = MarkdownEditorView.typingAttributes(font: font)
            highlightAll()
        }

        /// Refresh the backing binding when the parent rebuilds with a different
        /// getter/setter (e.g. derived body-only bindings that swap semantics at runtime).
        func updateBinding(_ binding: Binding<String>) {
            _text = binding
        }

        func textDidChange(_ notification: Notification) {
            guard !isUpdating, let textView else { return }
            isUpdating = true
            text = textView.string
            isUpdating = false
        }

        func textStorage(
            _ textStorage: NSTextStorage,
            didProcessEditing editedMask: NSTextStorageEditActions,
            range editedRange: NSRange,
            changeInLength delta: Int
        ) {
            guard !isUpdating, editedMask.contains(.editedCharacters) else { return }
            // Schedule highlighting after the text system finishes processing
            // the current edit. Highlighting inside didProcessEditing extends
            // the edited range to the full document, causing a full layout
            // invalidation that resets scroll position on long documents.
            scheduleHighlight()
        }

        func highlightAll() {
            guard let textView, let textStorage = textView.textStorage else { return }
            guard let scrollView = textView.enclosingScrollView else {
                MarkdownSyntaxHighlighter.highlight(textStorage: textStorage)
                return
            }

            let scrollOrigin = scrollView.contentView.bounds.origin
            MarkdownSyntaxHighlighter.highlight(textStorage: textStorage)
            // Force layout so the content size is finalized, then restore
            // scroll position before the display pass can jump it.
            if let textContainer = textView.textContainer {
                textView.layoutManager?.ensureLayout(for: textContainer)
            }
            scrollView.contentView.scroll(to: scrollOrigin)
            scrollView.reflectScrolledClipView(scrollView.contentView)
        }

        private func scheduleHighlight() {
            pendingHighlight?.cancel()
            let work = DispatchWorkItem { [weak self] in
                self?.highlightAll()
            }
            pendingHighlight = work
            DispatchQueue.main.async(execute: work)
        }
    }
}
