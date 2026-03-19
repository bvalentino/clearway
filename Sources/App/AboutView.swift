import SwiftUI
import AppKit

// MARK: - About Window Controller

final class AboutWindowController: NSWindowController, NSWindowDelegate {
    static let shared = AboutWindowController()

    private init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 320, height: 300),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.identifier = NSUserInterfaceItemIdentifier("wtpad.about")
        window.center()
        window.appearance = NSAppearance(named: .darkAqua)
        window.contentView = NSHostingView(rootView: AboutView())
        super.init(window: window)
        window.delegate = self
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func show() {
        guard let window else { return }
        window.center()
        window.makeKeyAndOrderFront(nil)
    }
}

// MARK: - About View

private struct AboutView: View {
    private var version: String? {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String
    }

    private var commit: String { BuildInfo.commit }

    var body: some View {
        VStack(alignment: .center) {
            Image(nsImage: NSApplication.shared.applicationIconImage)
                .resizable()
                .renderingMode(.original)
                .frame(width: 96, height: 96)
                .shadow(color: .black.opacity(0.18), radius: 8, x: 0, y: 3)

            VStack(alignment: .center, spacing: 24) {
                VStack(alignment: .center, spacing: 8) {
                    Text("wtpad")
                        .bold()
                        .font(.title)
                    Text("A workspace manager built on Ghostty.")
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                        .font(.caption)
                        .opacity(0.8)
                }
                .textSelection(.enabled)

                VStack(spacing: 2) {
                    if let version {
                        AboutPropertyRow(label: "Version", text: version)
                    }
                    AboutPropertyRow(
                        label: "Commit",
                        text: commit,
                        url: URL(string: "https://github.com/bvalentino/wtpad-mac/commit/\(commit)")
                    )
                }
                .frame(maxWidth: .infinity)
            }
            .frame(maxWidth: .infinity)
        }
        .padding(.top, 8)
        .padding(32)
        .frame(minWidth: 280)
        .background(VisualEffectBackground().ignoresSafeArea())
    }
}

// MARK: - Components

private struct AboutPropertyRow: View {
    let label: String
    let text: String
    var url: URL? = nil

    @ViewBuilder private var textView: some View {
        Text(text)
            .frame(width: 120, alignment: .leading)
            .padding(.leading, 2)
            .opacity(0.8)
            .monospaced()
    }

    var body: some View {
        HStack(spacing: 4) {
            Text(label)
                .frame(width: 80, alignment: .trailing)
                .padding(.trailing, 2)
            if let url {
                Link(destination: url) {
                    textView
                }
            } else {
                textView
            }
        }
        .font(.callout)
        .textSelection(.enabled)
        .frame(maxWidth: .infinity)
    }
}

struct VisualEffectBackground: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = .underWindowBackground
        view.blendingMode = .behindWindow
        view.state = .followsWindowActiveState
        return view
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {}
}
