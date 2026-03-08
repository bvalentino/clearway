import SwiftUI
import GhosttyKit

/// SwiftUI wrapper that displays a specific Ghostty SurfaceView.
///
/// When `surfaceView` changes, the old view is removed and the new one
/// is installed. Each surface retains its own shell session.
struct TerminalSurface: NSViewRepresentable {
    let surfaceView: Ghostty.SurfaceView

    func makeNSView(context: Context) -> NSView {
        let container = NSView()
        container.wantsLayer = true
        installSurface(surfaceView, in: container)
        return container
    }

    func updateNSView(_ container: NSView, context: Context) {
        // Check if the surface already matches
        if let current = container.subviews.first as? Ghostty.SurfaceView,
           current === surfaceView {
            return
        }

        // Swap surface (container always has at most one child)
        container.subviews.first?.removeFromSuperview()
        installSurface(surfaceView, in: container)
    }

    private func installSurface(_ surface: Ghostty.SurfaceView, in container: NSView) {
        surface.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(surface)
        NSLayoutConstraint.activate([
            surface.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            surface.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            surface.topAnchor.constraint(equalTo: container.topAnchor),
            surface.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])

        // Make sure the surface gets focus
        DispatchQueue.main.async {
            surface.window?.makeFirstResponder(surface)
        }
    }
}
