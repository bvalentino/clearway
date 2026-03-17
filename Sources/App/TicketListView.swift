import SwiftUI

/// The project home — a dispatch board showing all tickets.
struct TicketListView: View {
    @EnvironmentObject private var ticketManager: TicketManager
    var onStart: (Ticket) -> Void
    var onOpen: (Ticket) -> Void

    @State private var editingTicket: Ticket?

    var body: some View {
        Group {
            if ticketManager.tickets.isEmpty {
                emptyState
            } else {
                ticketList
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .sheet(item: $editingTicket) { ticket in
            TicketDetailView(ticket: ticket)
        }
    }

    private var emptyState: some View {
        VStack(spacing: 16) {
            Image(systemName: "ticket")
                .font(.system(size: 48))
                .foregroundStyle(.tertiary)
            Text("No tickets yet")
                .font(.title3)
                .foregroundStyle(.secondary)
            Button("New Ticket") {
                createAndEdit()
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
        }
    }

    private var ticketList: some View {
        ScrollView {
            LazyVStack(spacing: 12) {
                ForEach(ticketManager.tickets) { ticket in
                    TicketCard(
                        ticket: ticket,
                        onEdit: { editingTicket = ticket },
                        onStart: { onStart(ticket) },
                        onOpen: { onOpen(ticket) }
                    )
                }
            }
            .padding(20)
        }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    createAndEdit()
                } label: {
                    Image(systemName: "plus")
                }
                .help("New Ticket")
            }
        }
    }

    private func createAndEdit() {
        if let ticket = ticketManager.createTicket(title: "New Ticket") {
            editingTicket = ticket
        }
    }
}

// MARK: - Ticket Card

private struct TicketCard: View {
    let ticket: Ticket
    var onEdit: () -> Void
    var onStart: () -> Void
    var onOpen: () -> Void
    @EnvironmentObject private var ticketManager: TicketManager

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 6) {
                Text(ticket.title)
                    .font(.headline)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)

                TicketStatusBadge(status: ticket.status)

                if !ticket.body.isEmpty {
                    Text(ticket.body.prefix(120))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            actionButton
        }
        .padding(16)
        .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 12))
        .contentShape(Rectangle())
        .onTapGesture { onEdit() }
        .contextMenu {
            Button { onEdit() } label: {
                Label("Edit", systemImage: "pencil")
            }
            Divider()
            if ticket.status == .started || ticket.status == .open {
                Button {
                    ticketManager.setStatus(ticket, to: .done)
                } label: {
                    Label("Mark Done", systemImage: "checkmark.circle")
                }
            }
            if ticket.status == .done {
                Button {
                    ticketManager.setStatus(ticket, to: .open)
                } label: {
                    Label("Reopen", systemImage: "arrow.uturn.backward")
                }
            }
            Divider()
            Button(role: .destructive) {
                ticketManager.deleteTicket(ticket)
            } label: {
                Label("Delete", systemImage: "trash")
            }
        }
    }

    @ViewBuilder
    private var actionButton: some View {
        switch ticket.status {
        case .open:
            Button("Start", action: onStart)
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
        case .started:
            Button("Open", action: onOpen)
                .buttonStyle(.bordered)
                .controlSize(.regular)
        case .done:
            Image(systemName: "checkmark.circle.fill")
                .font(.title2)
                .foregroundStyle(.green)
        }
    }
}

// MARK: - Status Badge

struct TicketStatusBadge: View {
    let status: Ticket.Status

    var body: some View {
        Text(status.label)
            .font(.caption2)
            .fontWeight(.medium)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .foregroundStyle(badgeColor)
            .background(badgeColor.opacity(0.12), in: Capsule())
    }

    private var badgeColor: Color {
        switch status {
        case .open: return .blue
        case .started: return .green
        case .done: return .secondary
        }
    }
}
