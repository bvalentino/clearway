import SwiftUI

// MARK: - Chip subview (scoped ObservableObject for title updates)

/// A single tab chip that observes only its own surface for title changes.
/// Scoping `@ObservedObject` here prevents whole-strip rebuilds on every title update.
private struct TerminalTabChip: View {
    @ObservedObject var surface: Ghostty.SurfaceView
    let tab: TerminalTab
    let isActive: Bool
    let onActivate: () -> Void
    let onClose: () -> Void
    let onCloseOthers: () -> Void
    let onCloseAll: () -> Void

    @State private var isHovering = false

    var body: some View {
        HStack(spacing: 4) {
            Text(surface.title.isEmpty ? "Terminal" : surface.title)
                .lineLimit(1)
                .truncationMode(.tail)
                .font(.system(size: 12))

            if isHovering || isActive {
                Button {
                    onClose()
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 9, weight: .bold))
                        .frame(width: 14, height: 14)
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
            } else {
                // Reserve space so chip width is stable on hover
                Color.clear
                    .frame(width: 14, height: 14)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background {
            if isActive {
                Capsule().fill(Color.accentColor)
            } else {
                Capsule().fill(Color(nsColor: .quaternaryLabelColor))
            }
        }
        .foregroundStyle(isActive ? Color.white : Color.primary)
        .onHover { hovering in isHovering = hovering }
        .onTapGesture { onActivate() }
        .contextMenu {
            Button("Close Tab") { onClose() }
            Button("Close Other Tabs") { onCloseOthers() }
            Button("Close All Tabs") { onCloseAll() }
        }
    }
}

// MARK: - Main tab strip

/// Horizontal scrollable strip of tab chips for the main terminal panel of a worktree.
struct MainTerminalTabStrip: View {
    let worktreeId: String
    let onCloseTab: (UUID, String) -> Void

    @EnvironmentObject private var ghosttyApp: Ghostty.App
    @EnvironmentObject private var terminalManager: TerminalManager

    var body: some View {
        if #available(macOS 26.0, *) {
            stripContent
                .padding(4)
                .glassEffect(in: Capsule())
                .overlay(
                    Capsule()
                        .strokeBorder(Color(nsColor: .separatorColor), lineWidth: 0.5)
                )
                .padding(.horizontal, 12)
                .padding(.vertical, 12)
        } else {
            stripContent
                .padding(4)
                .background(.bar)
                .padding(.horizontal, 12)
                .padding(.vertical, 12)
        }
    }

    private var stripContent: some View {
        HStack(spacing: 0) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 4) {
                    let tabs = terminalManager.mainTabs(for: worktreeId)
                    let activeId = terminalManager.mainActiveTabId(for: worktreeId)
                    ForEach(tabs, id: \.id) { tab in
                        TerminalTabChip(
                            surface: tab.surface,
                            tab: tab,
                            isActive: tab.id == activeId,
                            onActivate: {
                                terminalManager.activateMainTab(id: tab.id, in: worktreeId)
                            },
                            onClose: {
                                onCloseTab(tab.id, worktreeId)
                            },
                            onCloseOthers: {
                                for other in terminalManager.mainTabs(for: worktreeId) where other.id != tab.id {
                                    onCloseTab(other.id, worktreeId)
                                }
                            },
                            onCloseAll: {
                                for other in terminalManager.mainTabs(for: worktreeId) {
                                    onCloseTab(other.id, worktreeId)
                                }
                            }
                        )
                    }
                }
                .padding(.horizontal, 4)
            }

            Button {
                guard let app = ghosttyApp.app else { return }
                terminalManager.newShellTab(for: worktreeId, app: app)
            } label: {
                Image(systemName: "plus")
                    .font(.system(size: 12, weight: .medium))
                    .frame(width: 28, height: 28)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(ghosttyApp.app == nil)
        }
    }
}
