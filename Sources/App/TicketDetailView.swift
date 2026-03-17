import SwiftUI

/// A sheet for editing a ticket's title and markdown body.
struct TicketDetailView: View {
    @EnvironmentObject private var ticketManager: TicketManager
    @Environment(\.dismiss) private var dismiss

    let ticket: Ticket
    @State private var title: String
    @State private var bodyText: String
    @State private var pendingSave: DispatchWorkItem?

    init(ticket: Ticket) {
        self.ticket = ticket
        _title = State(initialValue: ticket.title)
        _bodyText = State(initialValue: ticket.body)
    }

    var body: some View {
        VStack(spacing: 0) {
            // Title bar
            HStack {
                TextField("Title", text: $title)
                    .textFieldStyle(.plain)
                    .font(.title2.bold())

                Spacer()

                TicketStatusBadge(status: currentTicket.status)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 16)

            Divider()

            // Body editor
            TextEditor(text: $bodyText)
                .font(.system(.body, design: .monospaced))
                .scrollContentBackground(.hidden)
                .padding(4)
        }
        .frame(minWidth: 600, minHeight: 400)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Done") { dismiss() }
            }
            ToolbarItem(placement: .destructiveAction) {
                Button(role: .destructive) {
                    ticketManager.deleteTicket(currentTicket)
                    dismiss()
                } label: {
                    Image(systemName: "trash")
                }
            }
        }
        .onChange(of: title) { _ in scheduleSave() }
        .onChange(of: bodyText) { _ in scheduleSave() }
        .onDisappear {
            // Flush any pending save — guard against deleted ticket
            pendingSave?.cancel()
            guard ticketManager.tickets.contains(where: { $0.id == ticket.id }) else { return }
            saveNow()
        }
    }

    /// The latest version of this ticket from the manager.
    private var currentTicket: Ticket {
        ticketManager.tickets.first { $0.id == ticket.id } ?? ticket
    }

    private func scheduleSave() {
        pendingSave?.cancel()
        let work = DispatchWorkItem { saveNow() }
        pendingSave = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: work)
    }

    private func saveNow() {
        var updated = currentTicket
        updated.title = title
        updated.body = bodyText
        ticketManager.updateTicket(updated)
    }
}
