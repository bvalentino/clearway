import SwiftUI

/// Settings → Open In Apps. Its own file so `SettingsView` stays a plain `Form`.
struct OpenInAppsSettingsSection: View {

    @ObservedObject var settings: SettingsManager

    @State private var editing: EditorTarget?

    var body: some View {
        Section {
            ForEach(settings.openInApps) { app in
                row(app)
            }
        } header: {
            HStack {
                Text("Open In Apps")
                Spacer()
                addMenu
            }
        }
    }

    private func row(_ app: OpenInApp) -> some View {
        HStack(spacing: 8) {
            Text(app.label)
            Spacer()
            Text(app.command)
                .font(.callout.monospaced())
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
            Button {
                editing = EditorTarget(app: app)
            } label: {
                Image(systemName: "pencil")
            }
            .buttonStyle(.borderless)
            .help("Edit")
            Button(role: .destructive) {
                settings.openInApps.removeAll { $0.id == app.id }
            } label: {
                Image(systemName: "minus.circle")
            }
            .buttonStyle(.borderless)
            .help("Remove")
        }
    }

    /// The sheet is presented from here rather than from the `Section` — a modifier applied to a
    /// `Section` inside a `Form` is applied to its content, which is empty until an app is added.
    private var addMenu: some View {
        let available = OpenInApp.availableBuiltIns(excluding: settings.openInApps)
        return Menu("Add") {
            ForEach(available) { builtIn in
                Button(builtIn.label) { add(builtIn) }
            }
            if !available.isEmpty { Divider() }
            Button("Custom…") { editing = EditorTarget(app: nil) }
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .sheet(item: $editing) { target in
            OpenInAppEditorSheet(app: target.app) { draft in
                save(draft.app(id: target.app?.id ?? UUID()))
            }
        }
    }

    private func add(_ builtIn: OpenInBuiltIn) {
        settings.openInApps.append(OpenInApp(kind: .builtIn(builtIn), command: builtIn.defaultCommand))
    }

    private func save(_ app: OpenInApp) {
        settings.openInApps = OpenInApp.upsert(app, into: settings.openInApps)
    }

    private struct EditorTarget: Identifiable {
        let app: OpenInApp?
        var id: String { app?.id.uuidString ?? "new" }
    }
}

/// The add-custom / edit sheet. A built-in shows no name field, because its label lives in its
/// kind and there is nothing to edit.
private struct OpenInAppEditorSheet: View {

    let app: OpenInApp?
    let onSave: (OpenInApp.Draft) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var draft: OpenInApp.Draft

    init(app: OpenInApp?, onSave: @escaping (OpenInApp.Draft) -> Void) {
        self.app = app
        self.onSave = onSave
        _draft = State(
            initialValue: app.map(OpenInApp.Draft.init(app:))
                ?? OpenInApp.Draft(builtIn: nil, label: "", command: "")
        )
    }

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 16) {
                Text(app?.label ?? "New App")
                    .font(.headline)
                    .frame(maxWidth: .infinity, alignment: .center)

                if draft.builtIn == nil {
                    TextField("Name", text: $draft.label)
                        .textFieldStyle(.roundedBorder)
                }

                TextField("Command", text: $draft.command)
                    .textFieldStyle(.roundedBorder)
            }
            .padding(20)

            Divider()

            footer
        }
        .frame(width: 320)
    }

    private var footer: some View {
        HStack {
            Spacer()
            Button("Cancel") { dismiss() }
                .keyboardShortcut(.cancelAction)
            Button("Save") {
                onSave(draft)
                dismiss()
            }
            .keyboardShortcut(.defaultAction)
            .disabled(!draft.isValid)
        }
        .padding(16)
    }
}
