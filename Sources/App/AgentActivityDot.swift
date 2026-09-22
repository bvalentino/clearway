import SwiftUI

/// The dot on the trailing edge of a row that can carry agent activity. One shape and one size for
/// every state; the working dot's pulsing glow is the only thing that varies, and it belongs here
/// rather than to the callers so the two rows cannot drift.
struct AgentActivityDot: View {
    enum Kind {
        case waiting
        case working
        case notification

        /// What a phase alone calls for. Both rows' rules start here and add only what is theirs:
        /// an idle phase carries no dot of its own.
        init?(phase: AgentPhase) {
            switch phase {
            case .waiting: self = .waiting
            case .working: self = .working
            case .idle: return nil
            }
        }
    }

    let kind: Kind
    @State private var glowExpanded = false

    var body: some View {
        switch kind {
        case .waiting:
            circle(.purple, help: "Waiting for permission")
                .transition(.opacity)
        case .working:
            circle(.orange, help: "Agent is working")
                .shadow(color: .orange, radius: glowExpanded ? 4 : 1)
                .shadow(color: .orange.opacity(0.5), radius: glowExpanded ? 6 : 2)
                .animation(.easeInOut(duration: 1.5).repeatForever(autoreverses: true), value: glowExpanded)
                .onAppear { glowExpanded = true }
                .onDisappear { glowExpanded = false }
                .transition(.opacity)
        case .notification:
            circle(.blue, help: "Terminal notification")
        }
    }

    private func circle(_ color: Color, help: String) -> some View {
        Circle()
            .fill(color)
            .frame(width: 7, height: 7)
            .help(help)
    }
}
