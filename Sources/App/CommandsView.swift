import SwiftUI

/// The Commands sidebar destination: the global, ordered list of saved commands, with the editor
/// sheet reached by clicking a row, the toolbar `+`, or File > New Command.
struct CommandsView: View {
    @EnvironmentObject private var savedCommandManager: SavedCommandManager
    @State private var filter: CommandFilter = .all
    @State private var editorTarget: CommandEditorTarget?
    @State private var selection: UUID?

    private var visibleCommands: [SavedCommand] {
        SavedCommand.filter(savedCommandManager.commands, by: filter)
    }

    var body: some View {
        Group {
            if visibleCommands.isEmpty {
                emptyState
            } else {
                commandList
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        // Attached here, not to `ContentView`'s `NavigationSplitView`: this view is the detail
        // column's content, which is where toolbar content has to be declared to reach the detail
        // section intact.
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    openEditor(nil)
                } label: {
                    Image(systemName: "plus")
                }
                .help("New command")
            }

            if #available(macOS 26, *) {
                ToolbarSpacer(.fixed, placement: .primaryAction)
            }

            ToolbarItem(placement: .primaryAction) {
                Picker("Filter", selection: $filter) {
                    ForEach(CommandFilter.allCases, id: \.self) { option in
                        Text(option.title).tag(option)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
            }
        }
        .focusedSceneValue(\.newCommandAction) { openEditor(nil) }
        .sheet(item: $editorTarget) { target in
            CommandEditorSheet(command: target.command)
        }
    }

    private var commandList: some View {
        List(selection: $selection) {
            ForEach(visibleCommands) { command in
                CommandRow(command: command)
                    .tag(command.id)
                    .moveDisabled(filter.isActive)
                    .onTapGesture { openEditor(command) }
                    .contextMenu {
                        Button(role: .destructive) {
                            savedCommandManager.delete(command)
                        } label: {
                            Label("Delete", systemImage: "trash")
                        }
                    }
            }
            // A move computed against a filtered subset would rewrite the wrong global positions,
            // so a filtered list refuses it and its rows are `.moveDisabled`.
            .onMove { from, to in
                guard !filter.isActive else { return }
                savedCommandManager.move(fromOffsets: from, toOffset: to)
            }
        }
        .listStyle(.inset)
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "command")
                .font(.system(size: 28))
                .foregroundStyle(.tertiary)
            Text(savedCommandManager.commands.isEmpty ? "No commands" : "No matching commands")
                .foregroundStyle(.secondary)
                .font(.callout)
        }
    }

    /// A row's tap carries the selection itself: the gesture consumes the click the list would
    /// otherwise have selected with, so the highlight has to be set alongside the sheet.
    private func openEditor(_ command: SavedCommand?) {
        selection = command?.id
        editorTarget = CommandEditorTarget(command: command)
    }
}

/// Identifies which command the sheet is editing; `nil` is the create case.
private struct CommandEditorTarget: Identifiable {
    let command: SavedCommand?
    var id: String { command?.id.uuidString ?? "new" }
}

// MARK: - Row

private struct CommandRow: View {
    let command: SavedCommand

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(command.name.isEmpty ? "Untitled" : command.name)
                    .font(.body)
                    .foregroundStyle(command.name.isEmpty ? .secondary : .primary)
                    .lineLimit(1)
                Text(command.text)
                    .font(.caption.monospaced())
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
            KindLabel(kind: command.kind)
        }
        .padding(.vertical, 6)
        .padding(.horizontal, 5)
        .contentShape(Rectangle())
    }
}

private struct KindLabel: View {
    let kind: SavedCommand.Kind

    var body: some View {
        Text(kind.title)
            .font(.caption.weight(.medium))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(.quaternary, in: Capsule())
    }
}

// MARK: - Titles

extension CommandFilter {
    var title: String {
        switch self {
        case .all: return "All"
        case .terminal: return "Terminal"
        case .agent: return "Agent"
        }
    }
}

extension SavedCommand.Kind {
    var title: String {
        switch self {
        case .terminal: return "Terminal"
        case .agent: return "Agent"
        }
    }
}
