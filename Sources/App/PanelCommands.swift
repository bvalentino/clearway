import SwiftUI

/// A panel the View menu can show or hide in the focused project window.
struct PanelToggle {
    let isVisible: Bool
    let toggle: () -> Void
}

private struct SidebarToggleKey: FocusedValueKey {
    typealias Value = PanelToggle
}

private struct BottomPanelToggleKey: FocusedValueKey {
    typealias Value = PanelToggle
}

private struct AsideToggleKey: FocusedValueKey {
    typealias Value = PanelToggle
}

extension FocusedValues {
    var sidebarToggle: PanelToggle? {
        get { self[SidebarToggleKey.self] }
        set { self[SidebarToggleKey.self] = newValue }
    }

    var bottomPanelToggle: PanelToggle? {
        get { self[BottomPanelToggleKey.self] }
        set { self[BottomPanelToggleKey.self] = newValue }
    }

    var asideToggle: PanelToggle? {
        get { self[AsideToggleKey.self] }
        set { self[AsideToggleKey.self] = newValue }
    }
}

/// View menu item that shows or hides one panel in the focused project window, disabled wherever
/// that panel doesn't apply. Takes the focused-value key path rather than reading a fixed one, so
/// all three panels share this single declaration site for their key equivalent.
struct PanelToggleMenuItem: View {
    private let noun: String
    private let shortcut: KeyboardShortcut
    @FocusedValue private var panel: PanelToggle?

    init(_ noun: String, shortcut: KeyboardShortcut, panel: KeyPath<FocusedValues, PanelToggle?>) {
        self.noun = noun
        self.shortcut = shortcut
        _panel = FocusedValue(panel)
    }

    var body: some View {
        Button(panel?.isVisible == true ? "Hide \(noun)" : "Show \(noun)") { panel?.toggle() }
            .keyboardShortcut(shortcut)
            .disabled(panel == nil)
    }
}
