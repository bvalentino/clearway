import SwiftUI

/// Creates or edits one `SavedCommand`. `command` is `nil` for the create case; the two share a
/// sheet because they edit the same six fields.
struct CommandEditorSheet: View {
    let command: SavedCommand?
    @EnvironmentObject private var savedCommandManager: SavedCommandManager
    @Environment(\.dismiss) private var dismiss
    @State private var name: String
    @State private var kind: SavedCommand.Kind
    @State private var text: String
    @State private var agent: String
    @State private var autoRun: Bool

    init(command: SavedCommand?) {
        self.command = command
        _name = State(initialValue: command?.name ?? "")
        _kind = State(initialValue: command?.kind ?? .terminal)
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

                field("Name") {
                    TextField("", text: $name)
                        .textFieldStyle(.roundedBorder)
                }

                field("Kind") {
                    Picker("Kind", selection: $kind) {
                        ForEach(SavedCommand.Kind.allCases, id: \.self) { option in
                            Text(option.title).tag(option)
                        }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                }

                if kind == .agent {
                    field("Agent") {
                        Picker("Agent", selection: $agent) {
                            ForEach(agentAllowlist, id: \.self) { option in
                                Text(option).tag(option)
                            }
                        }
                        .labelsHidden()
                    }
                }

                // A terminal command is one shell line by construction — `sendCommand` keeps only
                // the first — so only the agent prompt gets a multi-line editor.
                field(kind == .terminal ? "Command" : "Prompt") {
                    if kind == .terminal {
                        TextField("", text: $text)
                            .textFieldStyle(.roundedBorder)
                            .font(.callout.monospaced())
                    } else {
                        TextEditor(text: $text)
                            .font(.callout)
                            .frame(height: 120)
                            .padding(4)
                            .background(Color(.textBackgroundColor), in: RoundedRectangle(cornerRadius: 6))
                            .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(.quaternary))
                    }
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

    private func field<Content: View>(_ label: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(label)
                .font(.subheadline.weight(.medium))
            content()
        }
    }

    private func save() {
        if var existing = command {
            existing.name = trimmedName
            existing.kind = kind
            existing.text = text
            existing.agent = agent
            existing.autoRun = autoRun
            savedCommandManager.update(existing)
        } else {
            savedCommandManager.add(
                SavedCommand(id: UUID(), name: trimmedName, kind: kind, text: text, agent: agent, autoRun: autoRun)
            )
        }
        dismiss()
    }
}
