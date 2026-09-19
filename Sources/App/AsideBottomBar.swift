import SwiftUI

/// The bar along the bottom of an aside panel, carrying the `+` that adds to the list above it.
struct AsideBottomBar: View {
    let help: String
    let action: () -> Void

    var body: some View {
        HStack(spacing: 0) {
            SidebarHeaderButton(systemImage: "plus", action: action)
                .help(help)
                .accessibilityLabel(help)
            Spacer()
        }
        .padding(.leading, 8)
        .padding(.vertical, 4)
        .frame(maxWidth: .infinity)
        .background(.bar)
        .overlay(alignment: .top) { Divider() }
    }
}
