import SwiftUI

/// The one place the app splits button styling between Liquid Glass and its pre-macOS 26 fallback.
extension View {
    @ViewBuilder
    func applyPrimaryActionStyle(tint: Color = .accentColor) -> some View {
        if #available(macOS 26.0, *) {
            self.buttonStyle(.glassProminent)
                .tint(tint)
        } else {
            self.buttonStyle(.borderedProminent)
                .tint(tint)
        }
    }
}
