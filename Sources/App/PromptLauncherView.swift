import AppKit
import SwiftUI

/// The initial, pre-process screen of every main-panel tab. Users type a prompt
/// that gets piped into a fresh `claude` (or configured) process on Enter, or
/// click *Open terminal* to spawn a plain login shell. Both transitions happen
/// in-place — the tab's `TerminalTab.Kind` flips from `.launcher` to `.surface`.
///
/// Pure SwiftUI + one `NSViewRepresentable` wrapper around `NSTextView`.
/// SwiftUI's `TextEditor` cannot distinguish Enter from Shift+Enter on macOS
/// without private APIs, so we bridge to `NSTextView` for clean `keyDown` hooks.
struct PromptLauncherView: View {
    /// Resolved command label used as the text area placeholder (caller passes `SettingsManager.resolvedMainTerminalCommand`).
    let command: String
    @Binding var draft: String
    let onSubmit: (String) -> Void
    let onOpenTerminal: () -> Void

    @State private var contentHeight: CGFloat = 36
    @FocusState private var editorFocused: Bool

    private let minHeight: CGFloat = 36
    private let maxHeight: CGFloat = 200

    var body: some View {
        VStack(spacing: 0) {
            Spacer(minLength: 0)

            Button(action: onOpenTerminal) {
                HStack(spacing: 12) {
                    Text("Open Shell")
                    Text("ESC")
                        .font(.system(size: 9, weight: .medium, design: .monospaced))
                        .foregroundStyle(.secondary)
                }
            }
            .buttonStyle(.bordered)
            .keyboardShortcut(.escape, modifiers: [])

            Spacer(minLength: 0)

            PromptTextEditor(
                text: $draft,
                placeholder: command,
                onSubmit: submit,
                isFocused: $editorFocused,
                contentHeight: $contentHeight
            )
            .frame(height: min(max(contentHeight, minHeight), maxHeight))
            .background(Color(nsColor: .textBackgroundColor))
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .strokeBorder(Color(nsColor: .separatorColor), lineWidth: 0.5)
            )
            .clipShape(RoundedRectangle(cornerRadius: 10))
            .padding(.horizontal, 20)
            .padding(.bottom, 20)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear { editorFocused = true }
    }

    private func submit() {
        let trimmed = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        onSubmit(trimmed)
    }
}

// MARK: - NSTextView bridge

/// `NSTextView`-backed editor that distinguishes Enter (submit) from
/// Shift+Enter (newline). Cmd+Enter also submits, matching common chat UIs.
private struct PromptTextEditor: NSViewRepresentable {
    @Binding var text: String
    let placeholder: String
    let onSubmit: () -> Void
    @FocusState.Binding var isFocused: Bool
    @Binding var contentHeight: CGFloat

    func makeCoordinator() -> Coordinator {
        Coordinator(text: $text, contentHeight: $contentHeight, onSubmit: onSubmit)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let textView = SubmitTextView()
        textView.isRichText = false
        textView.allowsUndo = true
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.drawsBackground = false
        textView.textContainerInset = NSSize(width: 12, height: 10)
        textView.textContainer?.lineFragmentPadding = 0
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.textContainer?.widthTracksTextView = true
        textView.font = NSFont.systemFont(ofSize: 13)
        textView.delegate = context.coordinator
        textView.onSubmitRequested = { context.coordinator.submit() }
        textView.placeholder = placeholder
        textView.string = text

        context.coordinator.textView = textView

        let scrollView = NSScrollView()
        scrollView.documentView = textView
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.drawsBackground = false

        DispatchQueue.main.async { context.coordinator.recomputeHeight() }
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let textView = scrollView.documentView as? SubmitTextView else { return }
        context.coordinator.updateBinding(_text, contentHeight: _contentHeight, onSubmit: onSubmit)
        if !context.coordinator.isUpdating, textView.string != text {
            context.coordinator.isUpdating = true
            textView.string = text
            context.coordinator.isUpdating = false
            DispatchQueue.main.async { context.coordinator.recomputeHeight() }
        }
        if textView.placeholder != placeholder {
            textView.placeholder = placeholder
            textView.needsDisplay = true
        }
        if isFocused {
            // Defer so the text view has a chance to attach to a window on first render.
            DispatchQueue.main.async {
                if let window = textView.window, window.firstResponder !== textView {
                    window.makeFirstResponder(textView)
                }
            }
        }
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        @Binding var text: String
        @Binding var contentHeight: CGFloat
        private var onSubmit: () -> Void
        weak var textView: NSTextView?
        var isUpdating = false

        init(text: Binding<String>, contentHeight: Binding<CGFloat>, onSubmit: @escaping () -> Void) {
            _text = text
            _contentHeight = contentHeight
            self.onSubmit = onSubmit
        }

        func updateBinding(_ binding: Binding<String>, contentHeight: Binding<CGFloat>, onSubmit: @escaping () -> Void) {
            _text = binding
            _contentHeight = contentHeight
            self.onSubmit = onSubmit
        }

        func textDidChange(_ notification: Notification) {
            guard !isUpdating, let textView else { return }
            isUpdating = true
            text = textView.string
            isUpdating = false
            recomputeHeight()
        }

        func recomputeHeight() {
            guard let textView,
                  let layoutManager = textView.layoutManager,
                  let container = textView.textContainer else { return }
            layoutManager.ensureLayout(for: container)
            let used = layoutManager.usedRect(for: container).height
            let total = used + textView.textContainerInset.height * 2
            if abs(total - contentHeight) > 0.5 {
                contentHeight = total
            }
        }

        func submit() { onSubmit() }
    }
}

/// `NSTextView` subclass that routes plain Enter to a submit callback while
/// leaving Shift+Enter and Option+Enter to the default newline behavior.
private final class SubmitTextView: NSTextView {
    var onSubmitRequested: (() -> Void)?
    var placeholder: String = ""
    private var didAutoFocus = false

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard !didAutoFocus, let window else { return }
        didAutoFocus = true
        // Defer to the next runloop turn so SwiftUI's default focus choice
        // (which may prefer the "Open terminal" button) doesn't clobber us.
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            window.makeFirstResponder(self)
        }
    }

    override func keyDown(with event: NSEvent) {
        let isReturn = event.keyCode == 0x24 || event.keyCode == 0x4C
        if isReturn {
            let mods = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            // Shift+Enter or Option+Enter inserts a newline; plain Enter or Cmd+Enter submits.
            if mods == [] || mods == .command {
                onSubmitRequested?()
                return
            }
        }
        super.keyDown(with: event)
    }

    override func didChangeText() {
        super.didChangeText()
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard string.isEmpty, !placeholder.isEmpty else { return }
        let attrs: [NSAttributedString.Key: Any] = [
            .font: font ?? NSFont.systemFont(ofSize: 13),
            .foregroundColor: NSColor.placeholderTextColor
        ]
        let inset = textContainerInset
        let padding = textContainer?.lineFragmentPadding ?? 0
        let origin = NSPoint(x: inset.width + padding, y: inset.height)
        (placeholder as NSString).draw(at: origin, withAttributes: attrs)
    }
}

#Preview {
    PromptLauncherView(
        command: "claude",
        draft: .constant(""),
        onSubmit: { print("submit: \($0)") },
        onOpenTerminal: { print("open terminal") }
    )
    .frame(width: 800, height: 500)
}
