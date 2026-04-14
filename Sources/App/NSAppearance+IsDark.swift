import AppKit

extension NSAppearance {
    var isDark: Bool { bestMatch(from: [.darkAqua, .vibrantDark]) != nil }
}
