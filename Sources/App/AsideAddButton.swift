import SwiftUI

/// The full-width button pinned below an aside panel's list, adding to the list above it.
struct AsideAddButton: View {
    let title: String
    let action: () -> Void

    var body: some View {
        button
            .padding(.horizontal, 12)
            .padding(.top, 8)
            .padding(.bottom, 12)
    }

    @ViewBuilder
    private var button: some View {
        if #available(macOS 26.0, *) {
            Button(action: action) {
                label
                    .padding(.vertical, 6)
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.plain)
            .glassEffect(.regular.interactive(), in: Capsule())
            .overlay(
                Capsule()
                    .strokeBorder(Color(nsColor: .separatorColor), lineWidth: 0.5)
            )
        } else {
            Button(action: action) {
                label
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .controlSize(.large)
        }
    }

    private var label: some View {
        Label(title, systemImage: "plus")
            .labelStyle(.titleAndIcon)
    }
}
