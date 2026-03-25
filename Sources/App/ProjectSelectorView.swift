import SwiftUI
import AppKit

// MARK: - Project Selector Window Controller

final class ProjectSelectorWindowController: NSWindowController, NSWindowDelegate {
    static let shared = ProjectSelectorWindowController()

    private var projectList: ProjectListManager?

    private init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 300, height: 380),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.isMovableByWindowBackground = true
        window.identifier = NSUserInterfaceItemIdentifier("clearway.projectSelector")
        window.backgroundColor = .clear
        window.hasShadow = true
        window.center()
        window.appearance = NSAppearance(named: .darkAqua)
        super.init(window: window)
        window.delegate = self
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func show(projectList: ProjectListManager, openProjectWindow: @escaping (String) -> Void) {
        guard let window else { return }
        self.projectList = projectList
        window.contentView = NSHostingView(rootView:
            ProjectSelectorView(
                onSelectProject: { [weak self] path in
                    openProjectWindow(path)
                    self?.window?.close()
                },
                onClose: { [weak self] in
                    self?.window?.close()
                }
            )
            .environmentObject(projectList)
        )
        window.center()
        window.makeKeyAndOrderFront(nil)
    }
}

// MARK: - Pointing Hand Cursor

private extension View {
    func pointingHandCursor() -> some View {
        onHover { hovering in
            if hovering {
                NSCursor.pointingHand.push()
            } else {
                NSCursor.pop()
            }
        }
    }
}

// MARK: - Project Selector View

struct ProjectSelectorView: View {
    @EnvironmentObject private var projectList: ProjectListManager
    let onSelectProject: (String) -> Void
    let onClose: () -> Void

    private var sortedPaths: [String] {
        projectList.projectPaths.sorted {
            ($0 as NSString).lastPathComponent
                .localizedCaseInsensitiveCompare(($1 as NSString).lastPathComponent) == .orderedAscending
        }
    }

    var body: some View {
        ZStack(alignment: .topLeading) {
            VStack(spacing: 0) {
                header
                    .padding(.top, 8)
                    .padding(.bottom, 16)

                if projectList.projectPaths.isEmpty {
                    emptyState
                } else {
                    projectListView
                }

                addProjectButton
                    .padding(.vertical, 14)
            }

            closeButton
                .padding(10)
        }
        .frame(width: 300)
        .background(VisualEffectBackground())
        .clipShape(RoundedRectangle(cornerRadius: 20))
        .overlay(
            RoundedRectangle(cornerRadius: 20)
                .strokeBorder(Color.white.opacity(0.15), lineWidth: 1)
        )
    }

    // MARK: - Close Button

    private var closeButton: some View {
        Button(action: onClose) {
            Image(systemName: "xmark.circle.fill")
                .font(.system(size: 14))
                .foregroundStyle(.secondary)
        }
        .buttonStyle(.plain)
        .pointingHandCursor()
    }

    // MARK: - Header

    private var header: some View {
        VStack(alignment: .center, spacing: 8) {
            Image(nsImage: NSApplication.shared.applicationIconImage)
                .resizable()
                .renderingMode(.original)
                .frame(width: 96, height: 96)
                .shadow(color: .black.opacity(0.18), radius: 8, x: 0, y: 3)

            Text("Clearway")
                .bold()
                .font(.title2)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 8)
    }

    // MARK: - Project List

    private var projectListView: some View {
        ScrollView {
            LazyVStack(spacing: 2) {
                ForEach(sortedPaths, id: \.self) { path in
                    projectRow(path: path)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
        }
        .frame(maxHeight: 200)
    }

    private func projectRow(path: String) -> some View {
        return Button {
            onSelectProject(path)
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "folder.fill")
                    .foregroundStyle(.blue)
                    .font(.caption)
                VStack(alignment: .leading, spacing: 2) {
                    Text((path as NSString).lastPathComponent)
                        .fontWeight(.semibold)
                        .lineLimit(1)
                    Text(path)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.head)
                }
                Spacer()
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .cornerRadius(4)
        .contextMenu {
            Button("Remove Project") {
                projectList.removeProject(path)
            }
            Button("Reveal in Finder") {
                NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: path)
            }
        }
    }

    // MARK: - Empty State

    private var emptyState: some View {
        Text("No projects yet")
            .foregroundStyle(.secondary)
            .font(.callout)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 24)
    }

    // MARK: - Add Project

    private var addProjectButton: some View {
        Button {
            if let path = projectList.pickAndAddProject() {
                onSelectProject(path)
            }
        } label: {
            HStack(spacing: 5) {
                Image(systemName: "plus")
                    .font(.caption.weight(.semibold))
                Text("Add Project")
                    .font(.callout.weight(.medium))
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 6)
            .background(Color.white.opacity(0.08))
            .cornerRadius(8)
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(Color.white.opacity(0.12), lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
    }
}
