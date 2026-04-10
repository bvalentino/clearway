import AppKit
import Combine
import SwiftUI
import GhosttyKit

extension Ghostty {
    /// NSView subclass that hosts a single Ghostty terminal surface.
    class SurfaceView: NSView, ObservableObject, NSTextInputClient {
        @Published var title: String = ""
        @Published var healthy: Bool = true
        @Published var hoverUrl: String?
        @Published var cellSize: NSSize = .zero
        @Published var pwd: String?
        @Published var childExitCode: UInt32?

        /// The working directory passed at initialization, used as a fallback for respawning.
        let initialWorkingDirectory: String?

        private(set) var surfacePtr: ghostty_surface_t?

        var surface: ghostty_surface_t? { surfacePtr }

        /// Whether this surface has a running foreground process that warrants
        /// a confirmation dialog before closing.
        var needsConfirmQuit: Bool {
            guard let surface = surfacePtr else { return false }
            return ghostty_surface_needs_confirm_quit(surface)
        }

        private var markedText = NSMutableAttributedString()
        private var keyTextAccumulator: [String]?
        @Published private(set) var focused: Bool = false

        override var acceptsFirstResponder: Bool { true }

        init(_ app: ghostty_app_t, workingDirectory: String? = nil, command: String? = nil) {
            self.initialWorkingDirectory = workingDirectory
            super.init(frame: NSRect(x: 0, y: 0, width: 800, height: 600))

            self.wantsLayer = true

            var config = ghostty_surface_config_new()
            config.userdata = Unmanaged.passUnretained(self).toOpaque()
            config.platform_tag = GHOSTTY_PLATFORM_MACOS
            config.platform = ghostty_platform_u(macos: ghostty_platform_macos_s(
                nsview: Unmanaged.passUnretained(self).toOpaque()
            ))
            config.scale_factor = Double(NSScreen.main?.backingScaleFactor ?? 2.0)

            // Set working directory and command using closures to keep C strings alive
            let createSurface: (inout ghostty_surface_config_s) -> ghostty_surface_t? = { cfg in
                if let dir = workingDirectory {
                    return dir.withCString { dirPtr in
                        cfg.working_directory = dirPtr
                        if let cmd = command {
                            return cmd.withCString { cmdPtr in
                                cfg.command = cmdPtr
                                return ghostty_surface_new(app, &cfg)
                            }
                        }
                        return ghostty_surface_new(app, &cfg)
                    }
                } else if let cmd = command {
                    return cmd.withCString { cmdPtr in
                        cfg.command = cmdPtr
                        return ghostty_surface_new(app, &cfg)
                    }
                }
                return ghostty_surface_new(app, &cfg)
            }

            guard let surface = createSurface(&config) else {
                Ghostty.logger.critical("ghostty_surface_new failed")
                return
            }
            self.surfacePtr = surface
            ghostty_surface_set_focus(surface, false)

            updateTrackingAreas()
        }

        required init?(coder: NSCoder) {
            fatalError("init(coder:) is not supported")
        }

        /// Free the underlying ghostty surface, signaling the shell with SIGHUP.
        ///
        /// Safe to call multiple times — subsequent calls are no-ops.
        /// Called automatically by `deinit` if not called earlier.
        func closeSurface() {
            guard let surface = surfacePtr else { return }
            surfacePtr = nil
            ghostty_surface_free(surface)
        }

        deinit {
            closeSurface()
            trackingAreas.forEach { removeTrackingArea($0) }
        }

        // MARK: - Focus

        override func becomeFirstResponder() -> Bool {
            let result = super.becomeFirstResponder()
            if result { setFocus(true) }
            return result
        }

        override func resignFirstResponder() -> Bool {
            let result = super.resignFirstResponder()
            if result { setFocus(false) }
            return result
        }

        func setFocus(_ focused: Bool) {
            guard self.focused != focused else { return }
            self.focused = focused
            guard let surface = surfacePtr else { return }
            ghostty_surface_set_focus(surface, focused)
        }

        // MARK: - Layout

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
        }

        override func setFrameSize(_ newSize: NSSize) {
            super.setFrameSize(newSize)
            sizeDidChange(newSize)
        }

        override func setBoundsSize(_ newSize: NSSize) {
            super.setBoundsSize(newSize)
            sizeDidChange(newSize)
        }

        func sizeDidChange(_ size: CGSize) {
            guard let surface = surfacePtr else { return }
            let scaledSize = convertToBacking(size)
            ghostty_surface_set_size(surface, UInt32(scaledSize.width), UInt32(scaledSize.height))
        }

        override func viewDidChangeBackingProperties() {
            super.viewDidChangeBackingProperties()
            guard let surface = surfacePtr else { return }
            let scaleFactor = Double(window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2.0)
            ghostty_surface_set_content_scale(surface, scaleFactor, scaleFactor)

            let scaledSize = convertToBacking(frame.size)
            ghostty_surface_set_size(surface, UInt32(scaledSize.width), UInt32(scaledSize.height))
        }

        // MARK: - Tracking Areas

        override func updateTrackingAreas() {
            trackingAreas.forEach { removeTrackingArea($0) }

            let area = NSTrackingArea(
                rect: bounds,
                options: [.mouseEnteredAndExited, .mouseMoved, .activeInKeyWindow, .inVisibleRect],
                owner: self,
                userInfo: nil
            )
            addTrackingArea(area)
            super.updateTrackingAreas()
        }

        // MARK: - Mouse Events

        override func mouseDown(with event: NSEvent) {
            if window?.firstResponder !== self {
                window?.makeFirstResponder(self)
            }
            guard let surface = surfacePtr else { return }
            let pos = mousePosition(event)
            ghostty_surface_mouse_pos(surface, pos.x, pos.y, ghosttyMods(event.modifierFlags))
            ghostty_surface_mouse_button(surface, GHOSTTY_MOUSE_PRESS, GHOSTTY_MOUSE_LEFT, ghosttyMods(event.modifierFlags))
        }

        override func mouseUp(with event: NSEvent) {
            guard let surface = surfacePtr else { return }
            let pos = mousePosition(event)
            ghostty_surface_mouse_pos(surface, pos.x, pos.y, ghosttyMods(event.modifierFlags))
            ghostty_surface_mouse_button(surface, GHOSTTY_MOUSE_RELEASE, GHOSTTY_MOUSE_LEFT, ghosttyMods(event.modifierFlags))
        }

        override func rightMouseDown(with event: NSEvent) {
            guard let surface = surfacePtr else { return }
            let pos = mousePosition(event)
            ghostty_surface_mouse_pos(surface, pos.x, pos.y, ghosttyMods(event.modifierFlags))
            ghostty_surface_mouse_button(surface, GHOSTTY_MOUSE_PRESS, GHOSTTY_MOUSE_RIGHT, ghosttyMods(event.modifierFlags))
        }

        override func rightMouseUp(with event: NSEvent) {
            guard let surface = surfacePtr else { return }
            let pos = mousePosition(event)
            ghostty_surface_mouse_pos(surface, pos.x, pos.y, ghosttyMods(event.modifierFlags))
            ghostty_surface_mouse_button(surface, GHOSTTY_MOUSE_RELEASE, GHOSTTY_MOUSE_RIGHT, ghosttyMods(event.modifierFlags))
        }

        override func mouseMoved(with event: NSEvent) {
            guard let surface = surfacePtr else { return }
            let pos = mousePosition(event)
            ghostty_surface_mouse_pos(surface, pos.x, pos.y, ghosttyMods(event.modifierFlags))
        }

        override func mouseDragged(with event: NSEvent) {
            guard let surface = surfacePtr else { return }
            let pos = mousePosition(event)
            ghostty_surface_mouse_pos(surface, pos.x, pos.y, ghosttyMods(event.modifierFlags))
        }

        override func scrollWheel(with event: NSEvent) {
            guard let surface = surfacePtr else { return }
            var mods: ghostty_input_scroll_mods_t = 0
            if event.hasPreciseScrollingDeltas { mods |= 1 }
            ghostty_surface_mouse_scroll(surface, event.scrollingDeltaX, event.scrollingDeltaY, mods)
        }

        private func mousePosition(_ event: NSEvent) -> NSPoint {
            let local = convert(event.locationInWindow, from: nil)
            return NSPoint(x: local.x, y: bounds.height - local.y)
        }

        // MARK: - Keyboard Events

        override func performKeyEquivalent(with event: NSEvent) -> Bool {
            guard event.type == .keyDown, surfacePtr != nil, focused else { return false }
            guard event.modifierFlags.contains(.control) ||
                  event.modifierFlags.contains(.command) else { return false }

            // Let Ctrl+digit pass through to SwiftUI keyboard shortcuts (pane switching)
            if event.modifierFlags.contains(.control) && !event.modifierFlags.contains(.command),
               let chars = event.charactersIgnoringModifiers, chars.count == 1,
               let scalar = chars.unicodeScalars.first, scalar >= "0" && scalar <= "9" {
                return false
            }

            keyDown(with: event)
            return true
        }

        override func doCommand(by selector: Selector) {
            // Intentionally empty — prevent interpretKeyEvents from dispatching
            // control-key combos up the responder chain.
        }

        override func keyDown(with event: NSEvent) {
            guard surfacePtr != nil else {
                interpretKeyEvents([event])
                return
            }

            let flags = event.modifierFlags
            let action = event.isARepeat ? GHOSTTY_ACTION_REPEAT : GHOSTTY_ACTION_PRESS

            // Fast path for control-key combos (Ctrl+C, Ctrl+D, etc.).
            // Bypass interpretKeyEvents entirely so AppKit can't swallow the event.
            // Use event.characters (not charactersIgnoringModifiers) so control
            // characters like 0x03 are detected and ghostty encodes them itself.
            if flags.contains(.control) && !flags.contains(.command) && !flags.contains(.option) && !hasMarkedText() {
                sendKeyEvent(action, event: event, text: event.characters ?? "", composing: false)
                return
            }

            // Normal path: use interpretKeyEvents for IME / dead key support
            keyTextAccumulator = []
            defer { keyTextAccumulator = nil }

            let markedTextBefore = markedText.length > 0

            interpretKeyEvents([event])

            // Sync preedit state
            syncPreedit(clearIfNeeded: markedTextBefore)

            if let list = keyTextAccumulator, !list.isEmpty {
                for text in list {
                    sendKeyEvent(action, event: event, text: text, composing: false)
                }
            } else {
                sendKeyEvent(action, event: event, text: event.characters ?? "", composing: markedText.length > 0 || markedTextBefore)
            }
        }

        override func keyUp(with event: NSEvent) {
            sendKeyEvent(GHOSTTY_ACTION_RELEASE, event: event)
        }

        override func flagsChanged(with event: NSEvent) {
            guard let surface = surfacePtr else { return }

            let isPress: Bool
            switch Int(event.keyCode) {
            case 56, 60: isPress = event.modifierFlags.contains(.shift)
            case 59, 62: isPress = event.modifierFlags.contains(.control)
            case 58, 61: isPress = event.modifierFlags.contains(.option)
            case 55, 54: isPress = event.modifierFlags.contains(.command)
            default: return
            }

            var keyEvent = ghostty_input_key_s()
            keyEvent.action = isPress ? GHOSTTY_ACTION_PRESS : GHOSTTY_ACTION_RELEASE
            keyEvent.keycode = UInt32(event.keyCode)
            keyEvent.mods = ghosttyMods(event.modifierFlags)
            keyEvent.composing = false
            keyEvent.text = nil
            ghostty_surface_key(surface, keyEvent)
        }

        private func syncPreedit(clearIfNeeded: Bool = true) {
            guard let surface = surfacePtr else { return }
            if markedText.length > 0 {
                let str = markedText.string
                str.withCString { cStr in
                    ghostty_surface_preedit(surface, cStr, UInt(str.utf8.count))
                }
            } else if clearIfNeeded {
                ghostty_surface_preedit(surface, nil, 0)
            }
        }

        /// Whether ghostty handles this codepoint internally (control chars, function keys).
        /// These should not be sent as text or unshifted_codepoint — ghostty encodes
        /// them from the keycode + mods via its KeyEncoder.
        private func isGhosttyEncodedChar(_ value: UInt32) -> Bool {
            value < 0x20 || (value >= 0xF700 && value <= 0xF8FF)
        }

        private func sendKeyEvent(
            _ action: ghostty_input_action_e,
            event: NSEvent,
            text: String = "",
            composing: Bool = false
        ) {
            guard let surface = surfacePtr else { return }

            var keyEvent = ghostty_input_key_s()
            keyEvent.action = action
            keyEvent.keycode = UInt32(event.keyCode)
            keyEvent.mods = ghosttyMods(event.modifierFlags)
            keyEvent.composing = composing

            // Control and command never contribute to text translation — ghostty
            // handles control character encoding internally via KeyEncoder.
            keyEvent.consumed_mods = ghosttyMods(
                event.modifierFlags.subtracting([.control, .command]))

            // Provide the unshifted codepoint so ghostty can map keys correctly.
            if event.type == .keyDown || event.type == .keyUp {
                if let chars = event.characters(byApplyingModifiers: []),
                   let codepoint = chars.unicodeScalars.first,
                   !isGhosttyEncodedChar(codepoint.value) {
                    keyEvent.unshifted_codepoint = codepoint.value
                }
            }

            // Determine whether to send text. Single ghostty-encoded characters
            // (control chars, PUA function keys) are skipped — ghostty handles
            // them by keycode alone.
            let shouldSendText = !text.isEmpty && !composing
                && !(text.unicodeScalars.count == 1
                     && isGhosttyEncodedChar(text.unicodeScalars.first!.value))

            if shouldSendText {
                text.withCString { cStr in
                    keyEvent.text = cStr
                    ghostty_surface_key(surface, keyEvent)
                }
            } else {
                keyEvent.text = nil
                ghostty_surface_key(surface, keyEvent)
            }
        }

        // MARK: - Cursor

        func setCursorShape(_ shape: ghostty_action_mouse_shape_e) {
            switch shape {
            case GHOSTTY_MOUSE_SHAPE_DEFAULT:
                NSCursor.arrow.set()
            case GHOSTTY_MOUSE_SHAPE_TEXT:
                NSCursor.iBeam.set()
            case GHOSTTY_MOUSE_SHAPE_POINTER:
                NSCursor.pointingHand.set()
            case GHOSTTY_MOUSE_SHAPE_CROSSHAIR:
                NSCursor.crosshair.set()
            default:
                break
            }
        }

        func setCursorVisibility(_ visible: Bool) {
            NSCursor.setHiddenUntilMouseMoves(!visible)
        }

        // MARK: - Text Injection

        /// Send a string to the terminal as if typed.
        func sendText(_ text: String) {
            guard let surface = surfacePtr else { return }
            text.withCString { cStr in
                ghostty_surface_text(surface, cStr, UInt(text.utf8.count))
            }
        }

        /// Send a command string followed by Enter to the terminal.
        func sendCommand(_ command: String) {
            let trimmed = command
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .components(separatedBy: .newlines)
                .first ?? ""
            guard !trimmed.isEmpty else { return }
            sendText(trimmed)
            sendEnter()
        }

        /// Send text to the terminal via bracketed paste, preserving newlines.
        ///
        /// Uses ghostty's paste action (which handles bracketed paste mode negotiation)
        /// by temporarily placing the text on the system clipboard, then restoring the
        /// previous clipboard contents.
        func sendPaste(_ text: String, submit: Bool = true) {
            guard let surface = surfacePtr else { return }
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return }

            let pasteboard = NSPasteboard.general
            let savedItems = pasteboard.pasteboardItems?.map { item -> [NSPasteboard.PasteboardType: Data] in
                var dict: [NSPasteboard.PasteboardType: Data] = [:]
                for type in item.types {
                    if let data = item.data(forType: type) {
                        dict[type] = data
                    }
                }
                return dict
            } ?? []

            pasteboard.clearContents()
            pasteboard.setString(trimmed, forType: .string)

            // ghostty_surface_binding_action reads the clipboard synchronously
            // before returning — the restore below is safe.
            let action = "paste_from_clipboard"
            _ = ghostty_surface_binding_action(
                surface, action, UInt(action.utf8.count)
            )

            if submit {
                sendEnter()
            }

            pasteboard.clearContents()
            let items = savedItems.map { dict -> NSPasteboardItem in
                let item = NSPasteboardItem()
                for (type, data) in dict {
                    item.setData(data, forType: type)
                }
                return item
            }
            pasteboard.writeObjects(items)
        }

        /// Simulate pressing the Enter/Return key.
        private func sendEnter() {
            guard let surface = surfacePtr else { return }
            let kVKReturn: UInt32 = 36

            var key = ghostty_input_key_s()
            key.keycode = kVKReturn
            key.mods = GHOSTTY_MODS_NONE
            key.composing = false
            key.text = nil

            key.action = GHOSTTY_ACTION_PRESS
            ghostty_surface_key(surface, key)

            key.action = GHOSTTY_ACTION_RELEASE
            ghostty_surface_key(surface, key)
        }

        // MARK: - NSTextInputClient

        func insertText(_ string: Any, replacementRange: NSRange) {
            let str: String
            if let s = string as? NSAttributedString {
                str = s.string
            } else if let s = string as? String {
                str = s
            } else {
                return
            }

            unmarkText()

            if keyTextAccumulator != nil {
                keyTextAccumulator?.append(str)
            } else {
                guard let surface = surfacePtr else { return }
                str.withCString { cStr in
                    ghostty_surface_text(surface, cStr, UInt(str.utf8.count))
                }
            }
        }

        func setMarkedText(_ string: Any, selectedRange: NSRange, replacementRange: NSRange) {
            if let s = string as? NSAttributedString {
                markedText = NSMutableAttributedString(attributedString: s)
            } else if let s = string as? String {
                markedText = NSMutableAttributedString(string: s)
            }
            if keyTextAccumulator == nil {
                syncPreedit()
            }
        }

        func unmarkText() {
            if markedText.length > 0 {
                markedText.mutableString.setString("")
                syncPreedit()
            }
        }

        func selectedRange() -> NSRange {
            NSRange(location: NSNotFound, length: 0)
        }

        func markedRange() -> NSRange {
            if markedText.length > 0 {
                return NSRange(location: 0, length: markedText.length)
            }
            return NSRange(location: NSNotFound, length: 0)
        }

        func hasMarkedText() -> Bool {
            markedText.length > 0
        }

        func attributedSubstring(forProposedRange range: NSRange, actualRange: NSRangePointer?) -> NSAttributedString? {
            nil
        }

        func validAttributesForMarkedText() -> [NSAttributedString.Key] {
            []
        }

        func firstRect(forCharacterRange range: NSRange, actualRange: NSRangePointer?) -> NSRect {
            guard let surface = surfacePtr else { return .zero }
            var x: Double = 0, y: Double = 0, w: Double = 0, h: Double = 0
            ghostty_surface_ime_point(surface, &x, &y, &w, &h)
            guard let window = self.window else { return .zero }
            let viewPoint = NSPoint(x: x, y: frame.height - y)
            let windowPoint = convert(viewPoint, to: nil)
            let screenPoint = window.convertPoint(toScreen: windowPoint)
            return NSRect(x: screenPoint.x, y: screenPoint.y, width: w, height: h)
        }

        func characterIndex(for point: NSPoint) -> Int {
            0
        }

        // MARK: - Modifier Translation

        private func ghosttyMods(_ flags: NSEvent.ModifierFlags) -> ghostty_input_mods_e {
            var mods = GHOSTTY_MODS_NONE.rawValue
            if flags.contains(.shift) { mods |= GHOSTTY_MODS_SHIFT.rawValue }
            if flags.contains(.control) { mods |= GHOSTTY_MODS_CTRL.rawValue }
            if flags.contains(.option) { mods |= GHOSTTY_MODS_ALT.rawValue }
            if flags.contains(.command) { mods |= GHOSTTY_MODS_SUPER.rawValue }
            if flags.contains(.capsLock) { mods |= GHOSTTY_MODS_CAPS.rawValue }
            return ghostty_input_mods_e(rawValue: mods)
        }
    }
}
