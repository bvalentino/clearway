import CoreGraphics

enum TaskTerminalLayout {
    static let minimumHeight: CGFloat = 80
    static let minimumEditorHeight: CGFloat = 120

    static func height(stored: CGFloat?, available: CGFloat) -> CGFloat {
        clamp(stored ?? available / 2, available: available)
    }

    static func draggedHeight(from current: CGFloat, translation: CGFloat, available: CGFloat) -> CGFloat {
        clamp(current - translation, available: available)
    }

    private static func clamp(_ value: CGFloat, available: CGFloat) -> CGFloat {
        min(max(value, minimumHeight), max(minimumHeight, available - minimumEditorHeight))
    }
}
