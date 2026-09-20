import AppKit
import SwiftUI

/// A popup button that fills the width it is offered. A SwiftUI `Picker` clamps to the AppKit
/// intrinsic width of the `NSPopUpButton` it wraps — 80pt for these lists — and
/// `.frame(maxWidth: .infinity)` only centers that 80pt control, so a fixed-width sheet column
/// cannot be filled with one.
struct FullWidthPicker<Value: Hashable>: NSViewRepresentable {
    struct Row: Equatable {
        let value: Value
        let title: String
        var symbol: String?
        var tint: Color?
    }

    let label: String
    @Binding var selection: Value
    let rows: [Row]

    @Environment(\.isEnabled) private var isEnabled

    func makeCoordinator() -> Coordinator {
        Coordinator(selection: $selection)
    }

    func makeNSView(context: Context) -> NSPopUpButton {
        let button = NSPopUpButton(frame: .zero, pullsDown: false)
        button.target = context.coordinator
        button.action = #selector(Coordinator.selectionChanged(_:))
        // `LabeledField` draws the visible label; the `Picker` this replaces carried its title for
        // VoiceOver even under `.labelsHidden()`.
        button.setAccessibilityLabel(label)
        return button
    }

    func updateNSView(_ nsView: NSPopUpButton, context: Context) {
        context.coordinator.selection = $selection
        // Rebuilding unconditionally would close an open menu on every keystroke elsewhere in the
        // sheet.
        if context.coordinator.rows != rows {
            context.coordinator.rows = rows
            nsView.menu = Self.menu(for: rows)
        }
        if let index = rows.firstIndex(where: { $0.value == selection }) {
            nsView.selectItem(at: index)
        } else {
            nsView.select(nil)
        }
        // `.disabled(_:)` sets the environment value but does not reach an AppKit control.
        nsView.isEnabled = isEnabled
    }

    func sizeThatFits(
        _ proposal: ProposedViewSize, nsView: NSPopUpButton, context: Context
    ) -> CGSize? {
        let intrinsic = nsView.intrinsicContentSize
        // SwiftUI also probes with `.infinity`, which is not a width to adopt.
        let proposed = proposal.width ?? intrinsic.width
        return CGSize(
            width: proposed.isFinite ? proposed : intrinsic.width, height: intrinsic.height
        )
    }

    private static func menu(for rows: [Row]) -> NSMenu {
        let menu = NSMenu()
        // The items carry no action of their own, so auto-enabling would validate them against the
        // responder chain and grey the whole list out.
        menu.autoenablesItems = false
        for row in rows {
            let item = NSMenuItem()
            item.title = row.title
            item.image = symbolImage(row.symbol, tint: row.tint)
            menu.addItem(item)
        }
        return menu
    }

    private static func symbolImage(_ symbol: String?, tint: Color?) -> NSImage? {
        guard let symbol,
              let image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil) else {
            return nil
        }
        var configuration = NSImage.SymbolConfiguration(
            pointSize: NSFont.menuFont(ofSize: 0).pointSize, weight: .regular
        )
        if let tint {
            configuration = configuration.applying(
                NSImage.SymbolConfiguration(paletteColors: [NSColor(tint)])
            )
        }
        let tinted = image.withSymbolConfiguration(configuration)
        // AppKit recolors a template image to the menu's own text color, taking the tint away.
        tinted?.isTemplate = false
        return tinted
    }

    @MainActor
    final class Coordinator: NSObject {
        var selection: Binding<Value>
        /// The rows the live menu was built from, so the action resolves against what it shows.
        var rows: [Row] = []

        init(selection: Binding<Value>) {
            self.selection = selection
        }

        @objc func selectionChanged(_ sender: NSPopUpButton) {
            let index = sender.indexOfSelectedItem
            guard rows.indices.contains(index) else { return }
            selection.wrappedValue = rows[index].value
        }
    }
}
