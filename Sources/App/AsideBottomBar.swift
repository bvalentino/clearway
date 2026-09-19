import SwiftUI

/// The bar along the bottom of an aside panel, carrying the button that adds to the list above it.
struct AsideBottomBar: View {
    let title: String
    let action: () -> Void

    var body: some View {
        HStack(spacing: 0) {
            Button(action: action) {
                Label(title, systemImage: "plus")
                    .labelStyle(.titleAndIcon)
            }
            .applyGlassButtonStyle()
            Spacer()
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity)
        .background(.bar)
        .overlay(alignment: .top) { Divider() }
    }
}
