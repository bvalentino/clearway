import SwiftUI

/// The icon both sidebar header controls wear: secondary until the pointer is over it.
private struct SidebarHeaderIcon: View {
    let systemImage: String
    let isHovering: Bool

    var body: some View {
        Image(systemName: systemImage)
            .font(.body)
            .frame(width: 24, height: 24)
            .contentShape(Rectangle())
            .foregroundStyle(isHovering ? .primary : .secondary)
    }
}

struct SidebarHeaderButton: View {
    let systemImage: String
    let action: () -> Void
    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            SidebarHeaderIcon(systemImage: systemImage, isHovering: isHovering)
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
    }
}

struct SidebarHeaderMenu<Content: View>: View {
    let systemImage: String
    @ViewBuilder let content: Content
    @State private var isHovering = false

    var body: some View {
        Menu {
            content
        } label: {
            SidebarHeaderIcon(systemImage: systemImage, isHovering: isHovering)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .onHover { isHovering = $0 }
    }
}
