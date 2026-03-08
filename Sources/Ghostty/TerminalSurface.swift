import SwiftUI
import GhosttyKit

/// SwiftUI wrapper around the Ghostty SurfaceView NSView.
struct TerminalSurface: NSViewRepresentable {
    let app: ghostty_app_t

    func makeNSView(context: Context) -> Ghostty.SurfaceView {
        let view = Ghostty.SurfaceView(app)
        return view
    }

    func updateNSView(_ nsView: Ghostty.SurfaceView, context: Context) {
        // Nothing to update — the surface manages itself
    }
}
