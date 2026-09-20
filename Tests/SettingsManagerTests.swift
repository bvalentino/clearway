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

    // MARK: - Open secondary on start

    func test_openSecondaryOnStart_defaultsToFalse() {
        let manager = SettingsManager(defaults: defaults)
        XCTAssertFalse(manager.openSecondaryOnStart)
    }

    func test_openSecondaryOnStart_persistsAcrossInstances() {
        let first = SettingsManager(defaults: defaults)
        first.openSecondaryOnStart = true

        let second = SettingsManager(defaults: defaults)
        XCTAssertTrue(second.openSecondaryOnStart)
    }

    func test_openSecondaryOnStart_canBeTurnedBackOff() {
        let first = SettingsManager(defaults: defaults)
        first.openSecondaryOnStart = true
        first.openSecondaryOnStart = false

        let second = SettingsManager(defaults: defaults)
        XCTAssertFalse(second.openSecondaryOnStart)
    }

    // MARK: - Show detached worktrees

    func test_showDetachedWorktrees_defaultsToFalse() {
        let manager = SettingsManager(defaults: defaults)
        XCTAssertFalse(manager.showDetachedWorktrees)
    }

    func test_showDetachedWorktrees_persistsAcrossInstances() {
        let first = SettingsManager(defaults: defaults)
        first.showDetachedWorktrees = true

        let second = SettingsManager(defaults: defaults)
        XCTAssertTrue(second.showDetachedWorktrees)
    }

    func test_showDetachedWorktrees_canBeTurnedBackOff() {
        let first = SettingsManager(defaults: defaults)
        first.showDetachedWorktrees = true
        first.showDetachedWorktrees = false

        let second = SettingsManager(defaults: defaults)
        XCTAssertFalse(second.showDetachedWorktrees)
    }

    // MARK: - Last used Open In app

    func test_lastUsedOpenInApp_isNilOnAFreshSuite() {
        let manager = SettingsManager(defaults: defaults)
        XCTAssertNil(manager.lastUsedOpenInAppId)
        XCTAssertNil(manager.lastUsedOpenInApp)
    }

    func test_lastUsedOpenInApp_resolvesTheRememberedId() {
        let manager = SettingsManager(defaults: defaults)
        let zed = OpenInApp(kind: .builtIn(.zed), command: "zed")
        manager.openInApps = [OpenInApp(kind: .builtIn(.finder), command: "open"), zed]

        manager.lastUsedOpenInAppId = zed.id

        XCTAssertEqual(manager.lastUsedOpenInApp, zed)
    }

    func test_lastUsedOpenInApp_isNilWhenTheIdNamesNoCurrentApp() {
        let manager = SettingsManager(defaults: defaults)
        let zed = OpenInApp(kind: .builtIn(.zed), command: "zed")
        let finder = OpenInApp(kind: .builtIn(.finder), command: "open")
        manager.openInApps = [finder, zed]
        manager.lastUsedOpenInAppId = zed.id

        manager.openInApps = [finder]

        XCTAssertNil(manager.lastUsedOpenInApp)
        XCTAssertEqual(manager.lastUsedOpenInAppId, zed.id, "Nothing is cleaned up on delete")
    }

    func test_lastUsedOpenInAppId_persistsAcrossInstances() {
        let zed = OpenInApp(kind: .builtIn(.zed), command: "zed")
        let first = SettingsManager(defaults: defaults)
        first.openInApps = [zed]
        first.lastUsedOpenInAppId = zed.id

        let second = SettingsManager(defaults: defaults)
        XCTAssertEqual(second.lastUsedOpenInAppId, zed.id)
        XCTAssertEqual(second.lastUsedOpenInApp, zed)
    }

    func test_lastUsedOpenInAppId_setBackToNilRemovesTheKey() {
        let zed = OpenInApp(kind: .builtIn(.zed), command: "zed")
        let first = SettingsManager(defaults: defaults)
        first.openInApps = [zed]
        first.lastUsedOpenInAppId = zed.id
        first.lastUsedOpenInAppId = nil

        XCTAssertNil(defaults.object(forKey: SettingsKey.lastUsedOpenInApp))
        XCTAssertNil(SettingsManager(defaults: defaults).lastUsedOpenInAppId)
    }
}
