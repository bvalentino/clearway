import SwiftUI

/// Creates or edits one `SavedCommand`. `command` is `nil` for the create case; the two share a
/// sheet because they edit the same six fields. `newCommandKind` preselects the kind picker for
/// the create case, so a caller that can only use one kind opens the sheet on it.
struct CommandEditorSheet: View {
    let command: SavedCommand?
    @EnvironmentObject private var savedCommandManager: SavedCommandManager
    @Environment(\.dismiss) private var dismiss
    @State private var name: String
    @State private var kind: SavedCommand.Kind
    @State private var text: String
    @State private var agent: String
    @State private var autoRun: Bool
    @FocusState private var textIsFocused: Bool

    init(command: SavedCommand?, newCommandKind: SavedCommand.Kind = .terminal) {
        self.command = command
        _name = State(initialValue: command?.name ?? "")
        _kind = State(initialValue: command?.kind ?? newCommandKind)
        _text = State(initialValue: command?.text ?? "")
        _agent = State(initialValue: command?.agent ?? agentAllowlist.first ?? "")
        _autoRun = State(initialValue: command?.autoRun ?? true)
    }

    private var trimmedName: String {
        name.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var canSave: Bool {
        !trimmedName.isEmpty && !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 16) {
                Text(command == nil ? "New Command" : "Edit Command")
                    .font(.headline)
                    .frame(maxWidth: .infinity, alignment: .center)

                LabeledField("Command kind") {
                    Picker("Command kind", selection: $kind) {
                        ForEach(SavedCommand.Kind.allCases, id: \.self) { option in
                            Text(option.title).tag(option)
                        }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                }

                LabeledField("Menu label") {
                    TextField("", text: $name)
                        .textFieldStyle(.roundedBorder)
                }

                if kind == .agent {
                    LabeledField("Agent") {
                        Picker("Agent", selection: $agent) {
                            ForEach(agentAllowlist, id: \.self) { option in
                                Text(option).tag(option)
                            }
                        }
                        .labelsHidden()
                    }
                }

                LabeledField(kind == .terminal ? "Command" : "Prompt") {
                    TextEditor(text: $text)
                        .font(kind == .terminal ? .body.monospaced() : .body)
                        .focused($textIsFocused)
                        .frame(height: 120)
                        .padding(4)
                        .background(Color(.textBackgroundColor), in: RoundedRectangle(cornerRadius: 6))
                        .overlay(
                            RoundedRectangle(cornerRadius: 6)
                                .strokeBorder(
                                    textIsFocused ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.quaternary),
                                    lineWidth: textIsFocused ? 2 : 1
                                )
                        )
                }

                Toggle("Append Enter to run immediately", isOn: $autoRun)
            }
            .padding(20)

            Divider()

            footer
        }
        .frame(width: 460)
    }

    private var footer: some View {
        HStack {
            if let command {
                Button(role: .destructive) {
                    savedCommandManager.delete(command)
                    dismiss()
                } label: {
                    Text("Delete")
                }
            }
            Spacer()
            Button("Cancel") { dismiss() }
                .keyboardShortcut(.cancelAction)
            Button("Save") { save() }
                .keyboardShortcut(.defaultAction)
                .disabled(!canSave)
        }
        .padding(16)
    }

    private func save() {
        let edited = SavedCommand(
            id: command?.id ?? UUID(),
            name: trimmedName,
            kind: kind,
            text: text,
            agent: agent,
            autoRun: autoRun
        )
        if command == nil {
            savedCommandManager.add(edited)
        } else {
            savedCommandManager.update(edited)
        }
        dismiss()
    }
}
