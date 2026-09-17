import XCTest
@testable import Clearway

@MainActor
final class OpenInAppsSettingsTests: XCTestCase {

    private var defaults: UserDefaults!
    private var suiteName: String!

    override func setUp() async throws {
        try await super.setUp()
        suiteName = "OpenInAppsSettingsTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() async throws {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        suiteName = nil
        try await super.tearDown()
    }

    func test_freshSuite_seedsFinderAlone() {
        let manager = SettingsManager(defaults: defaults)

        XCTAssertEqual(manager.openInApps.count, 1)
        XCTAssertEqual(manager.openInApps.first?.kind, .builtIn(.finder))
        XCTAssertEqual(manager.openInApps.first?.label, "Finder")
        XCTAssertEqual(manager.openInApps.first?.command, "open")
    }

    func test_freshSuite_writesTheSeedToDefaults() {
        _ = SettingsManager(defaults: defaults)

        XCTAssertNotNil(defaults.data(forKey: SettingsKey.openInApps))
    }

    func test_emptyList_persistsAsEmptyRatherThanReseeding() {
        let first = SettingsManager(defaults: defaults)
        first.openInApps = []

        let second = SettingsManager(defaults: defaults)
        XCTAssertEqual(second.openInApps, [])
    }

    func test_corruptStoredValue_yieldsTheFinderSeed() {
        defaults.set(Data([0x00, 0x01, 0x02, 0xFF]), forKey: SettingsKey.openInApps)

        let manager = SettingsManager(defaults: defaults)

        XCTAssertEqual(manager.openInApps.count, 1)
        XCTAssertEqual(manager.openInApps.first?.kind, .builtIn(.finder))
        XCTAssertEqual(manager.openInApps.first?.command, "open")
    }

    /// An undecodable value is what a rollback past a format change looks like. Showing the seed is
    /// decision 9; writing it over the stored bytes would destroy the user's list for good.
    func test_undecodableStoredValue_isLeftOnDiskRatherThanOverwritten() {
        let stored = Data([0x00, 0x01, 0x02, 0xFF])
        defaults.set(stored, forKey: SettingsKey.openInApps)

        _ = SettingsManager(defaults: defaults)

        XCTAssertEqual(defaults.data(forKey: SettingsKey.openInApps), stored)
    }

    func test_storedValueOfTheWrongType_yieldsTheFinderSeed() {
        defaults.set("not a JSON array", forKey: SettingsKey.openInApps)

        let manager = SettingsManager(defaults: defaults)

        XCTAssertEqual(manager.openInApps.map(\.kind), [.builtIn(.finder)])
    }

    func test_additions_surviveAndPreserveOrder() {
        let first = SettingsManager(defaults: defaults)
        first.openInApps.append(OpenInApp(kind: .builtIn(.zed), command: "zed"))
        first.openInApps.append(OpenInApp(kind: .custom(label: "Xcode"), command: "xed"))

        let second = SettingsManager(defaults: defaults)
        XCTAssertEqual(second.openInApps, first.openInApps)
        XCTAssertEqual(second.openInApps.map(\.label), ["Finder", "Zed", "Xcode"])
    }

    func test_removal_survives() {
        let first = SettingsManager(defaults: defaults)
        first.openInApps = [
            OpenInApp(kind: .builtIn(.finder), command: "open"),
            OpenInApp(kind: .builtIn(.cursor), command: "cursor")
        ]
        first.openInApps.removeFirst()

        let second = SettingsManager(defaults: defaults)
        XCTAssertEqual(second.openInApps.map(\.kind), [.builtIn(.cursor)])
    }

    func test_commandEdit_survives() {
        let first = SettingsManager(defaults: defaults)
        first.openInApps[0].command = "open -R"

        let second = SettingsManager(defaults: defaults)
        XCTAssertEqual(second.openInApps.first?.command, "open -R")
        XCTAssertEqual(second.openInApps.first?.id, first.openInApps[0].id)
    }
}
