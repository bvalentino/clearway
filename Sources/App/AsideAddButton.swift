import SwiftUI

/// The full-width button pinned below an aside panel's list, adding to the list above it.
struct AsideAddButton: View {
    let title: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Label(title, systemImage: "plus")
                .labelStyle(.titleAndIcon)
                .frame(maxWidth: .infinity)
        }
        .applyGlassButtonStyle()
        .controlSize(.large)
        .padding(.horizontal, 12)
        .padding(.top, 8)
        .padding(.bottom, 12)
    }
}
