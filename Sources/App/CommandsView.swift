import SwiftUI

/// The Commands sidebar destination: the global, ordered list of saved commands, with the editor
/// sheet reached by clicking a card or the floating `+`.
struct CommandsView: View {
    @EnvironmentObject private var savedCommandManager: SavedCommandManager
    @State private var filter: CommandFilter = .all
    @State private var editorTarget: CommandEditorTarget?

    private var visibleCommands: [SavedCommand] {
        SavedCommand.filter(savedCommandManager.commands, by: filter)
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if visibleCommands.isEmpty {
                emptyState
            } else {
                commandList
            }
        }
        .overlay(alignment: .bottomTrailing) {
            createButton
        }
        .sheet(item: $editorTarget) { target in
            CommandEditorSheet(command: target.command)
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Commands")
                    .font(.title2.weight(.semibold))
                Text("Saved actions for terminal or agents.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            Picker("Filter", selection: $filter) {
                ForEach(CommandFilter.allCases, id: \.self) { option in
                    Text(option.title).tag(option)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 260)
        }
        .frame(maxWidth: contentWidth, alignment: .leading)
        .frame(maxWidth: .infinity)
        .padding(20)
    }

    private var commandList: some View {
        List {
            ForEach(visibleCommands) { command in
                CommandCard(command: command)
                    .listRowSeparator(.hidden)
                    .listRowInsets(EdgeInsets(top: 4, leading: 0, bottom: 4, trailing: 0))
                    .listRowBackground(Color.clear)
                    .moveDisabled(filter.isActive)
                    .onTapGesture { editorTarget = CommandEditorTarget(command: command) }
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
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .frame(maxWidth: contentWidth)
        .frame(maxWidth: .infinity)
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
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var createButton: some View {
        Button {
            editorTarget = CommandEditorTarget(command: nil)
        } label: {
            Image(systemName: "plus")
                .font(.system(size: 16, weight: .medium))
                .foregroundStyle(.primary)
                .frame(width: 36, height: 36)
                .background(.thinMaterial, in: Circle())
                .shadow(color: .black.opacity(0.15), radius: 4, y: 2)
        }
        .buttonStyle(.plain)
        .padding(12)
    }

    private var contentWidth: CGFloat { 720 }
}

/// Identifies which command the sheet is editing; `nil` is the create case.
private struct CommandEditorTarget: Identifiable {
    let command: SavedCommand?
    var id: String { command?.id.uuidString ?? "new" }
}

// MARK: - Card

private struct CommandCard: View {
    let command: SavedCommand

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(command.name.isEmpty ? "Untitled" : command.name)
                    .font(.body.weight(.semibold))
                    .foregroundStyle(command.name.isEmpty ? .secondary : .primary)
                    .lineLimit(1)

                Text(command.text)
                    .font(.callout.monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            KindLabel(kind: command.kind)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 10))
        .contentShape(RoundedRectangle(cornerRadius: 10))
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
