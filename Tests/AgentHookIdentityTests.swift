import XCTest
@testable import Clearway

/// Closes the loop between the two halves of the identity contract: the environment a surface hands
/// its shell, and the preamble `AgentHookEnvelope.parse` reads back. Nothing else pins them
/// together — the values travel out through libghostty, through the agent's process, and back in
/// through `clearway-hook.sh`'s `printf`, so the only way to test the round trip in process is to
/// write that `printf` out by hand and check the parser recovers what the provider handed over.
final class AgentHookIdentityTests: XCTestCase {

    /// The forwarder's `printf '%s\n%s\n'` over the two values, spelled exactly as the script does.
    private func preamble(_ pairs: [(key: String, value: String)]) -> String {
        let values = Dictionary(uniqueKeysWithValues: pairs.map { ($0.key, $0.value) })
        let surfaceId = values[AgentHookIdentity.surfaceIdKey] ?? ""
        let owner = values[AgentHookIdentity.ownerKey] ?? ""
        return "\(surfaceId)\n\(owner)\n"
    }

    private let body = #"{"hook_event_name":"PreToolUse","tool_name":"Bash"}"#

    // MARK: - The round trip

    func testTheEnvironmentRoundTripsThroughTheForwardersPreamble() {
        let surfaceId = UUID()
        let worktreePath = "/Users/x/clearway/.worktrees/feature"

        let pairs = AgentHookIdentity.environment(surfaceId: surfaceId, owner: .worktree(worktreePath))
        let envelope = AgentHookEnvelope.parse(Data("\(preamble(pairs))\(body)".utf8))

        XCTAssertEqual(envelope?.surfaceId, surfaceId.uuidString)
        XCTAssertEqual(envelope?.owner, .worktree(worktreePath))
        XCTAssertEqual(envelope?.event.hookEventName, "PreToolUse")
    }

    /// The task owner takes the same route: a task terminal's id has to survive the `printf` and
    /// come back as a `UUID`, or an agent planning a task lights nothing.
    func testATaskOwnerRoundTripsThroughTheForwardersPreamble() {
        let taskId = UUID()

        let pairs = AgentHookIdentity.environment(surfaceId: UUID(), owner: .task(taskId))
        let envelope = AgentHookEnvelope.parse(Data("\(preamble(pairs))\(body)".utf8))

        XCTAssertEqual(envelope?.owner, .task(taskId))
    }

    /// A worktree path carrying spaces is the case the preamble exists for: the values are never
    /// quoted or escaped on the way through, because a line break is the only delimiter.
    func testAWorktreePathWithSpacesSurvivesIntact() {
        let worktreePath = "/Users/x/my repo/.worktrees/a b"

        let pairs = AgentHookIdentity.environment(surfaceId: UUID(), owner: .worktree(worktreePath))
        let envelope = AgentHookEnvelope.parse(Data("\(preamble(pairs))\(body)".utf8))

        XCTAssertEqual(envelope?.owner, .worktree(worktreePath))
    }

    // MARK: - The surfaces that carry no owner

    /// The hook sheet and the debug terminal pass no owner, so the forwarder's second guard
    /// fires and nothing is ever sent. The parser refuses the payload anyway, which is what makes
    /// the guard a saved round trip rather than the only thing standing between those surfaces and
    /// a lit dot.
    func testASurfaceWithNoOwnerSendsNothingTheParserWouldAccept() {
        let pairs = AgentHookIdentity.environment(surfaceId: UUID(), owner: nil)

        XCTAssertNil(pairs.first(where: { $0.key == AgentHookIdentity.ownerKey }))
        XCTAssertNil(AgentHookEnvelope.parse(Data("\(preamble(pairs))\(body)".utf8)))
    }

    // MARK: - The wiring

    /// `ClearwayApp.init` is the only writer of the provider, and unwired it hands every surface an
    /// empty environment with no diagnostic anywhere: the forwarder then exits on its first guard,
    /// every hook is a no-op and the whole feature is dead in a way nothing else here would catch.
    /// The test host launches the app, so the static carries whatever that `init` left on it.
    @MainActor
    func testTheSurfaceProviderIsWiredAtLaunch() {
        let surfaceId = UUID()
        let owner = AgentActivityOwner.worktree("/Users/x/clearway")

        let wired = Ghostty.SurfaceView.agentEnvironment(surfaceId, owner.rawValue)

        XCTAssertEqual(
            wired.map(\.key),
            AgentHookIdentity.environment(surfaceId: surfaceId, owner: owner).map(\.key)
        )
        XCTAssertEqual(
            wired.first(where: { $0.key == AgentHookIdentity.surfaceIdKey })?.value,
            surfaceId.uuidString
        )
        XCTAssertEqual(
            wired.first(where: { $0.key == AgentHookIdentity.ownerKey })?.value,
            owner.rawValue
        )
    }

    // MARK: - The socket

    func testEverySurfaceIsToldWhereToSend() {
        let pairs = AgentHookIdentity.environment(surfaceId: UUID(), owner: nil)

        XCTAssertEqual(
            pairs.first(where: { $0.key == AgentHookIdentity.socketKey })?.value,
            AgentHookPaths().socketPath
        )
    }
}
