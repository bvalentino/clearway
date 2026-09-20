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
        let worktreeId = values[AgentHookIdentity.worktreeIdKey] ?? ""
        return "\(surfaceId)\n\(worktreeId)\n"
    }

    private let body = #"{"hook_event_name":"PreToolUse","tool_name":"Bash"}"#

    // MARK: - The round trip

    func testTheEnvironmentRoundTripsThroughTheForwardersPreamble() {
        let surfaceId = UUID()
        let worktreeId = "/Users/x/clearway/.worktrees/feature"

        let pairs = AgentHookIdentity.environment(surfaceId: surfaceId, worktreeId: worktreeId)
        let envelope = AgentHookEnvelope.parse(Data("\(preamble(pairs))\(body)".utf8))

        XCTAssertEqual(envelope?.surfaceId, surfaceId.uuidString)
        XCTAssertEqual(envelope?.worktreeId, worktreeId)
        XCTAssertEqual(envelope?.event.hookEventName, "PreToolUse")
    }

    /// A worktree path carrying spaces is the case the preamble exists for: the values are never
    /// quoted or escaped on the way through, because a line break is the only delimiter.
    func testAWorktreePathWithSpacesSurvivesIntact() {
        let worktreeId = "/Users/x/my repo/.worktrees/a b"

        let pairs = AgentHookIdentity.environment(surfaceId: UUID(), worktreeId: worktreeId)
        let envelope = AgentHookEnvelope.parse(Data("\(preamble(pairs))\(body)".utf8))

        XCTAssertEqual(envelope?.worktreeId, worktreeId)
    }

    // MARK: - The surfaces that carry no worktree

    /// The hook sheet and the debug terminal pass no worktree id, so the forwarder's second guard
    /// fires and nothing is ever sent. The parser refuses the payload anyway, which is what makes
    /// the guard a saved round trip rather than the only thing standing between those surfaces and
    /// a lit dot.
    func testASurfaceWithNoWorktreeSendsNothingTheParserWouldAccept() {
        let pairs = AgentHookIdentity.environment(surfaceId: UUID(), worktreeId: nil)

        XCTAssertNil(pairs.first(where: { $0.key == AgentHookIdentity.worktreeIdKey }))
        XCTAssertNil(AgentHookEnvelope.parse(Data("\(preamble(pairs))\(body)".utf8)))
    }

    // MARK: - The socket

    func testEverySurfaceIsToldWhereToSend() {
        let pairs = AgentHookIdentity.environment(surfaceId: UUID(), worktreeId: nil)

        XCTAssertEqual(
            pairs.first(where: { $0.key == AgentHookIdentity.socketKey })?.value,
            AgentHookPaths().socketPath
        )
    }
}
