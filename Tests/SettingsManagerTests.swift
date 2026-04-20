import AppKit
import SwiftUI
import XCTest
@testable import Clearway

@MainActor
final class SettingsManagerTests: XCTestCase {

    private var defaults: UserDefaults!
    private var suiteName: String!

    override func setUp() async throws {
        try await super.setUp()
        suiteName = "SettingsManagerTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() async throws {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        suiteName = nil
        try await super.tearDown()
    }

    func test_defaultColorScheme_isSystem() {
        let manager = SettingsManager(defaults: defaults)
        XCTAssertEqual(manager.colorScheme, .system)
    }

    func test_colorScheme_persistsAcrossInstances() {
        let first = SettingsManager(defaults: defaults)
        first.colorScheme = .light

        let second = SettingsManager(defaults: defaults)
        XCTAssertEqual(second.colorScheme, .light)
    }

    func test_colorScheme_allThreeValuesRoundTrip() {
        for value in ColorSchemePreference.allCases {
            let setter = SettingsManager(defaults: defaults)
            setter.colorScheme = value
            let reader = SettingsManager(defaults: defaults)
            XCTAssertEqual(reader.colorScheme, value, "Round-trip failed for \(value)")
        }
    }

    func test_swiftUIColorScheme_mapping() {
        XCTAssertNil(ColorSchemePreference.system.swiftUIColorScheme)
        XCTAssertEqual(ColorSchemePreference.light.swiftUIColorScheme, .light)
        XCTAssertEqual(ColorSchemePreference.dark.swiftUIColorScheme, .dark)
    }

    func test_nsAppearance_mapping() {
        XCTAssertNil(ColorSchemePreference.system.nsAppearance)
        XCTAssertEqual(ColorSchemePreference.light.nsAppearance?.name, .aqua)
        XCTAssertEqual(ColorSchemePreference.dark.nsAppearance?.name, .darkAqua)
    }

    // MARK: - Main terminal command

    func test_configuredMainTerminalCommand_isNilWhenUnset() {
        let manager = SettingsManager(defaults: defaults)
        XCTAssertNil(manager.configuredMainTerminalCommand)
    }

    func test_configuredMainTerminalCommand_isNilWhenWhitespaceOnly() {
        let manager = SettingsManager(defaults: defaults)
        manager.mainTerminalCommand = "   "
        XCTAssertNil(manager.configuredMainTerminalCommand)
    }

    func test_configuredMainTerminalCommand_returnsTrimmedValue() {
        let manager = SettingsManager(defaults: defaults)
        manager.mainTerminalCommand = "  codex  "
        XCTAssertEqual(manager.configuredMainTerminalCommand, "codex")
    }

    func test_resolvedMainTerminalCommand_fallsBackToDefault_whenBlank() {
        let manager = SettingsManager(defaults: defaults)
        manager.mainTerminalCommand = ""
        XCTAssertEqual(manager.resolvedMainTerminalCommand, SettingsManager.defaultMainTerminalCommand)
    }

    // MARK: - Always open secondary

    func test_alwaysOpenSecondary_defaultsToFalse() {
        let manager = SettingsManager(defaults: defaults)
        XCTAssertFalse(manager.alwaysOpenSecondary)
    }

    func test_alwaysOpenSecondary_persistsAcrossInstances() {
        let first = SettingsManager(defaults: defaults)
        first.alwaysOpenSecondary = true

        let second = SettingsManager(defaults: defaults)
        XCTAssertTrue(second.alwaysOpenSecondary)
    }

    func test_alwaysOpenSecondary_canBeTurnedOff() {
        let first = SettingsManager(defaults: defaults)
        first.alwaysOpenSecondary = true
        first.alwaysOpenSecondary = false

        let second = SettingsManager(defaults: defaults)
        XCTAssertFalse(second.alwaysOpenSecondary)
    }
}
