import XCTest
@testable import Clearway

@MainActor
final class TerminalManagerTests: XCTestCase {

    // MARK: - setInitialPanelVisibility

    func test_setInitialPanelVisibility_mainWorktree_secondaryFollowsProvider() {
        let manager = TerminalManager()
        let main = makeWorktree(branch: "main", path: "/tmp/main", isMain: true)

        manager.openSecondaryOnStartProvider = { false }
        manager.setInitialPanelVisibility(for: main.id, worktree: main)
        XCTAssertFalse(manager.isSecondaryVisible(for: main.id))
        XCTAssertFalse(manager.isAsideVisible(for: main.id), "aside stays hidden on the main worktree")

        let other = makeWorktree(branch: "main-2", path: "/tmp/main-2", isMain: true)
        manager.openSecondaryOnStartProvider = { true }
        manager.setInitialPanelVisibility(for: other.id, worktree: other)
        XCTAssertTrue(manager.isSecondaryVisible(for: other.id))
    }

    func test_setInitialPanelVisibility_nonMainWorktree_asideAlwaysOn_secondaryFollowsProvider() {
        let manager = TerminalManager()
        let wt = makeWorktree(branch: "feature", path: "/tmp/feature", isMain: false)

        manager.openSecondaryOnStartProvider = { false }
        manager.setInitialPanelVisibility(for: wt.id, worktree: wt)
        XCTAssertTrue(manager.isAsideVisible(for: wt.id))
        XCTAssertFalse(manager.isSecondaryVisible(for: wt.id))

        let wt2 = makeWorktree(branch: "feature-2", path: "/tmp/feature-2", isMain: false)
        manager.openSecondaryOnStartProvider = { true }
        manager.setInitialPanelVisibility(for: wt2.id, worktree: wt2)
        XCTAssertTrue(manager.isAsideVisible(for: wt2.id))
        XCTAssertTrue(manager.isSecondaryVisible(for: wt2.id))
    }

    func test_setInitialPanelVisibility_providerChangeDoesNotMutateExistingPane() {
        let manager = TerminalManager()
        let wt = makeWorktree(branch: "feature", path: "/tmp/feature", isMain: false)

        manager.openSecondaryOnStartProvider = { true }
        manager.setInitialPanelVisibility(for: wt.id, worktree: wt)
        XCTAssertTrue(manager.isSecondaryVisible(for: wt.id))

        // Flipping the setting after the pane was seeded must not move existing panes —
        // the provider is consulted only at pane creation, so a manual `Cmd+\` toggle
        // the user made earlier would otherwise be clobbered.
        manager.openSecondaryOnStartProvider = { false }
        XCTAssertTrue(manager.isSecondaryVisible(for: wt.id))

        // Likewise, toggling the setting on must not resurrect a manually hidden pane.
        manager.toggleSecondary(for: wt.id)
        XCTAssertFalse(manager.isSecondaryVisible(for: wt.id))
        manager.openSecondaryOnStartProvider = { true }
        XCTAssertFalse(manager.isSecondaryVisible(for: wt.id))
    }

    func test_openSecondaryOnStartProvider_defaultsToFalse() {
        let manager = TerminalManager()
        let wt = makeWorktree(branch: "feature", path: "/tmp/feature", isMain: false)

        manager.setInitialPanelVisibility(for: wt.id, worktree: wt)
        XCTAssertFalse(manager.isSecondaryVisible(for: wt.id),
                       "unwired provider must default to the opt-in-safe `false` path")
    }
}
