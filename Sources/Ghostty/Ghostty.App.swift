import AppKit
import GhosttyKit

extension Ghostty {
    /// Manages the global `ghostty_app_t` lifecycle.
    class App: ObservableObject {
        enum Readiness: String {
            case loading, error, ready
        }

        @Published var readiness: Readiness = .loading
        @Published private(set) var config: Config

        @Published var app: ghostty_app_t? {
            didSet {
                guard let old = oldValue else { return }
                ghostty_app_free(old)
            }
        }

        init() {
            self.config = Config()
            guard config.loaded else {
                readiness = .error
                return
            }

            var runtime_cfg = ghostty_runtime_config_s(
                userdata: Unmanaged.passUnretained(self).toOpaque(),
                supports_selection_clipboard: true,
                wakeup_cb: { userdata in App.wakeup(userdata) },
                action_cb: { app, target, action in App.action(app!, target: target, action: action) },
                read_clipboard_cb: { userdata, loc, state in App.readClipboard(userdata, location: loc, state: state) },
                confirm_read_clipboard_cb: { userdata, str, state, request in
                    App.confirmReadClipboard(userdata, string: str, state: state, request: request)
                },
                write_clipboard_cb: { userdata, loc, content, len, confirm in
                    App.writeClipboard(userdata, location: loc, content: content, len: len, confirm: confirm)
                },
                close_surface_cb: { userdata, processAlive in App.closeSurface(userdata, processAlive: processAlive) }
            )

            guard let app = ghostty_app_new(&runtime_cfg, config.config) else {
                logger.critical("ghostty_app_new failed")
                readiness = .error
                return
            }
            self.app = app

            ghostty_app_set_focus(app, NSApp.isActive)

            let center = NotificationCenter.default
            center.addObserver(
                self,
                selector: #selector(keyboardSelectionDidChange),
                name: NSTextInputContext.keyboardSelectionDidChangeNotification,
                object: nil)
            center.addObserver(
                self,
                selector: #selector(applicationDidBecomeActive),
                name: NSApplication.didBecomeActiveNotification,
                object: nil)
            center.addObserver(
                self,
                selector: #selector(applicationDidResignActive),
                name: NSApplication.didResignActiveNotification,
                object: nil)

            self.readiness = .ready
        }

        deinit {
            self.app = nil
            NotificationCenter.default.removeObserver(self)
        }

        func appTick() {
            guard let app = self.app else { return }
            ghostty_app_tick(app)
        }

        // MARK: - Notifications

        @objc private func keyboardSelectionDidChange(notification: NSNotification) {
            guard let app = self.app else { return }
            ghostty_app_keyboard_changed(app)
        }

        @objc private func applicationDidBecomeActive(notification: NSNotification) {
            guard let app = self.app else { return }
            ghostty_app_set_focus(app, true)
        }

        @objc private func applicationDidResignActive(notification: NSNotification) {
            guard let app = self.app else { return }
            ghostty_app_set_focus(app, false)
        }

        // MARK: - Helpers

        /// Get the SurfaceView from the userdata pointer stored on a surface.
        private static func surfaceViewFromTarget(_ target: ghostty_target_s) -> SurfaceView? {
            guard target.tag == GHOSTTY_TARGET_SURFACE else { return nil }
            let surface = target.target.surface
            guard let userdata = ghostty_surface_userdata(surface) else { return nil }
            return Unmanaged<SurfaceView>.fromOpaque(userdata).takeUnretainedValue()
        }

        // MARK: - Runtime Callbacks

        static func wakeup(_ userdata: UnsafeMutableRawPointer?) {
            let state = Unmanaged<App>.fromOpaque(userdata!).takeUnretainedValue()
            DispatchQueue.main.async { state.appTick() }
        }

        static func action(_ app: ghostty_app_t, target: ghostty_target_s, action: ghostty_action_s) -> Bool {
            switch action.tag {
            case GHOSTTY_ACTION_SET_TITLE:
                guard let surface = surfaceViewFromTarget(target) else { return false }
                guard let titlePtr = action.action.set_title.title else { return true }
                let title = String(cString: titlePtr)
                DispatchQueue.main.async { surface.title = title }
                return true

            case GHOSTTY_ACTION_MOUSE_SHAPE:
                guard let surface = surfaceViewFromTarget(target) else { return false }
                DispatchQueue.main.async { surface.setCursorShape(action.action.mouse_shape) }
                return true

            case GHOSTTY_ACTION_MOUSE_OVER_LINK:
                guard let surface = surfaceViewFromTarget(target) else { return false }
                let info = action.action.mouse_over_link
                let url: String? = if info.url != nil { String(cString: info.url) } else { nil }
                DispatchQueue.main.async { surface.hoverUrl = url }
                return true

            case GHOSTTY_ACTION_OPEN_URL:
                let info = action.action.open_url
                guard let urlPtr = info.url else { return false }
                let str = String(cString: urlPtr)
                guard let url = URL(string: str) else { return false }
                NSWorkspace.shared.open(url)
                return true

            case GHOSTTY_ACTION_QUIT:
                DispatchQueue.main.async { NSApp.terminate(nil) }
                return true

            case GHOSTTY_ACTION_CLOSE_WINDOW:
                DispatchQueue.main.async {
                    NSApp.keyWindow?.close()
                }
                return true

            case GHOSTTY_ACTION_NEW_WINDOW:
                NotificationCenter.default.post(name: .ghosttyNewWindow, object: nil)
                return true

            case GHOSTTY_ACTION_RENDERER_HEALTH:
                guard let surface = surfaceViewFromTarget(target) else { return false }
                let healthy = action.action.renderer_health == GHOSTTY_RENDERER_HEALTH_HEALTHY
                DispatchQueue.main.async { surface.healthy = healthy }
                return true

            case GHOSTTY_ACTION_CELL_SIZE:
                guard let surface = surfaceViewFromTarget(target) else { return false }
                let cs = action.action.cell_size
                DispatchQueue.main.async {
                    surface.cellSize = NSSize(width: CGFloat(cs.width), height: CGFloat(cs.height))
                }
                return true

            case GHOSTTY_ACTION_MOUSE_VISIBILITY:
                guard let surface = surfaceViewFromTarget(target) else { return false }
                let visible = action.action.mouse_visibility == GHOSTTY_MOUSE_VISIBLE
                DispatchQueue.main.async { surface.setCursorVisibility(visible) }
                return true

            case GHOSTTY_ACTION_PWD:
                guard let surface = surfaceViewFromTarget(target) else { return false }
                if let pwdPtr = action.action.pwd.pwd {
                    let pwd = String(cString: pwdPtr)
                    DispatchQueue.main.async { surface.pwd = pwd }
                }
                return true

            case GHOSTTY_ACTION_DESKTOP_NOTIFICATION:
                guard let surface = surfaceViewFromTarget(target) else { return false }
                DispatchQueue.main.async {
                    NotificationCenter.default.post(name: .ghosttyDesktopNotification, object: surface)
                }
                return true

            case GHOSTTY_ACTION_RENDER,
                 GHOSTTY_ACTION_SECURE_INPUT,
                 GHOSTTY_ACTION_COLOR_CHANGE,
                 GHOSTTY_ACTION_CONFIG_CHANGE,
                 GHOSTTY_ACTION_RELOAD_CONFIG,
                 GHOSTTY_ACTION_KEY_SEQUENCE,
                 GHOSTTY_ACTION_KEY_TABLE,
                 GHOSTTY_ACTION_RING_BELL,
                 GHOSTTY_ACTION_SCROLLBAR,
                 GHOSTTY_ACTION_SIZE_LIMIT,
                 GHOSTTY_ACTION_INITIAL_SIZE,
                 GHOSTTY_ACTION_SHOW_CHILD_EXITED,
                 GHOSTTY_ACTION_PROGRESS_REPORT,
                 GHOSTTY_ACTION_COMMAND_FINISHED,
                 GHOSTTY_ACTION_READONLY,
                 GHOSTTY_ACTION_PROMPT_TITLE,
                 GHOSTTY_ACTION_QUIT_TIMER:
                return true  // acknowledge but no-op

            default:
                return false
            }
        }

        static func readClipboard(
            _ userdata: UnsafeMutableRawPointer?,
            location: ghostty_clipboard_e,
            state: UnsafeMutableRawPointer?
        ) {
            guard let userdata else { return }
            let surfaceView = Unmanaged<SurfaceView>.fromOpaque(userdata).takeUnretainedValue()
            guard let surface = surfaceView.surface else { return }

            let pasteboard: NSPasteboard = switch location {
            case GHOSTTY_CLIPBOARD_SELECTION:
                NSPasteboard(name: NSPasteboard.Name("com.ghostty.selection"))
            default:
                NSPasteboard.general
            }

            let str = pasteboard.string(forType: .string) ?? ""
            str.withCString { cStr in
                ghostty_surface_complete_clipboard_request(surface, cStr, state, false)
            }
        }

        static func confirmReadClipboard(
            _ userdata: UnsafeMutableRawPointer?,
            string: UnsafePointer<CChar>?,
            state: UnsafeMutableRawPointer?,
            request: ghostty_clipboard_request_e
        ) {
            // Auto-confirm all clipboard requests for now
            guard let userdata else { return }
            let surfaceView = Unmanaged<SurfaceView>.fromOpaque(userdata).takeUnretainedValue()
            guard let surface = surfaceView.surface else { return }
            ghostty_surface_complete_clipboard_request(surface, string, state, false)
        }

        static func writeClipboard(
            _ userdata: UnsafeMutableRawPointer?,
            location: ghostty_clipboard_e,
            content: UnsafePointer<ghostty_clipboard_content_s>?,
            len: Int,
            confirm: Bool
        ) {
            guard let content, len > 0 else { return }

            let pasteboard: NSPasteboard = switch location {
            case GHOSTTY_CLIPBOARD_SELECTION:
                NSPasteboard(name: NSPasteboard.Name("com.ghostty.selection"))
            default:
                NSPasteboard.general
            }

            for i in 0..<len {
                let item = content[i]
                guard let mimePtr = item.mime, let dataPtr = item.data else { continue }
                let mime = String(cString: mimePtr)
                if mime == "text/plain" {
                    let data = String(cString: dataPtr)
                    pasteboard.clearContents()
                    pasteboard.setString(data, forType: .string)
                    break
                }
            }
        }

        static func closeSurface(_ userdata: UnsafeMutableRawPointer?, processAlive: Bool) {
            guard let userdata else { return }
            let surfaceView = Unmanaged<SurfaceView>.fromOpaque(userdata).takeUnretainedValue()
            DispatchQueue.main.async {
                guard surfaceView.surfacePtr != nil else { return }
                NotificationCenter.default.post(name: .ghosttyCloseSurface, object: surfaceView, userInfo: [
                    GhosttyNotificationKey.processAlive: processAlive,
                ])
            }
        }
    }
}

// MARK: - Notification Names

extension Notification.Name {
    static let ghosttyCloseSurface = Notification.Name("com.wtpad.ghostty.closeSurface")
    static let ghosttyDesktopNotification = Notification.Name("com.wtpad.ghostty.desktopNotification")
    static let ghosttyNewWindow = Notification.Name("com.wtpad.ghostty.newWindow")
}

// MARK: - Notification UserInfo Keys

enum GhosttyNotificationKey {
    static let processAlive = "process_alive"
}
