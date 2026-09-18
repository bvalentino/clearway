import SwiftUI

/// A form row: a persistent label above its control. Shared so the app's sheets cannot drift into
/// placeholder-only fields.
struct LabeledField<Content: View>: View {
    private let label: String
    private let content: Content

    init(_ label: String, @ViewBuilder content: () -> Content) {
        self.label = label
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(label)
                .font(.subheadline.weight(.medium))
            content
        }
    }
}
