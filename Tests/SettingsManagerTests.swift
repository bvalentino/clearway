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

        manager.recordOpenInUse(zed)

        XCTAssertEqual(manager.lastUsedOpenInApp, zed)
    }

    func test_lastUsedOpenInApp_isNilWhenTheIdNamesNoCurrentApp() {
        let manager = SettingsManager(defaults: defaults)
        let zed = OpenInApp(kind: .builtIn(.zed), command: "zed")
        let finder = OpenInApp(kind: .builtIn(.finder), command: "open")
        manager.openInApps = [finder, zed]
        manager.recordOpenInUse(zed)

        manager.openInApps = [finder]

        XCTAssertNil(manager.lastUsedOpenInApp)
        XCTAssertEqual(manager.lastUsedOpenInAppId, zed.id, "Nothing is cleaned up on delete")
    }

    func test_lastUsedOpenInAppId_persistsAcrossInstances() {
        let zed = OpenInApp(kind: .builtIn(.zed), command: "zed")
        let first = SettingsManager(defaults: defaults)
        first.openInApps = [zed]
        first.recordOpenInUse(zed)

        let second = SettingsManager(defaults: defaults)
        XCTAssertEqual(second.lastUsedOpenInAppId, zed.id)
        XCTAssertEqual(second.lastUsedOpenInApp, zed)
    }

    func test_recordOpenInUse_remembersTheApp() {
        let zed = OpenInApp(kind: .builtIn(.zed), command: "zed")
        let manager = SettingsManager(defaults: defaults)
        manager.openInApps = [OpenInApp(kind: .builtIn(.finder), command: "open"), zed]

        manager.recordOpenInUse(zed)

        XCTAssertEqual(manager.lastUsedOpenInAppId, zed.id)
        XCTAssertEqual(manager.lastUsedOpenInApp, zed)
    }

    // MARK: - Primary Open In app

    func test_primaryOpenInApp_isNilWhenTheListIsEmpty() {
        let manager = SettingsManager(defaults: defaults)
        manager.openInApps = []

        XCTAssertNil(manager.primaryOpenInApp)
    }

    func test_primaryOpenInApp_isTheFirstAppBeforeAnythingIsRemembered() {
        let manager = SettingsManager(defaults: defaults)
        let finder = OpenInApp(kind: .builtIn(.finder), command: "open")
        manager.openInApps = [finder, OpenInApp(kind: .builtIn(.zed), command: "zed")]

        XCTAssertEqual(manager.primaryOpenInApp, finder)
    }

    func test_primaryOpenInApp_isTheRememberedApp() {
        let manager = SettingsManager(defaults: defaults)
        let zed = OpenInApp(kind: .builtIn(.zed), command: "zed")
        manager.openInApps = [OpenInApp(kind: .builtIn(.finder), command: "open"), zed]

        manager.recordOpenInUse(zed)

        XCTAssertEqual(manager.primaryOpenInApp, zed)
    }

    func test_primaryOpenInApp_fallsBackToTheFirstOnceTheRememberedAppIsDeleted() {
        let manager = SettingsManager(defaults: defaults)
        let finder = OpenInApp(kind: .builtIn(.finder), command: "open")
        let zed = OpenInApp(kind: .builtIn(.zed), command: "zed")
        manager.openInApps = [finder, zed]
        manager.recordOpenInUse(zed)

        manager.openInApps = [finder]

        XCTAssertEqual(manager.primaryOpenInApp, finder)
    }

    // MARK: - Open In button title

    func test_openInButtonTitle_namesTheFirstAppBeforeAnythingIsRemembered() {
        let manager = SettingsManager(defaults: defaults)
        manager.openInApps = [
            OpenInApp(kind: .builtIn(.finder), command: "open"),
            OpenInApp(kind: .custom(label: "Cursor"), command: "cursor")
        ]

        XCTAssertEqual(manager.openInButtonTitle, "Open in Finder")
    }

    func test_openInButtonTitle_namesTheRememberedApp() {
        let manager = SettingsManager(defaults: defaults)
        let cursor = OpenInApp(kind: .custom(label: "Cursor"), command: "cursor")
        manager.openInApps = [OpenInApp(kind: .builtIn(.finder), command: "open"), cursor]

        manager.recordOpenInUse(cursor)

        XCTAssertEqual(manager.openInButtonTitle, "Open in Cursor")
    }

    /// `upsert` keeps the edited entry's id, so the memory survives a rename and the label has to
    /// follow it. Resolving against the live list on every read is what makes that true.
    func test_openInButtonTitle_followsARenameOfTheRememberedApp() {
        let manager = SettingsManager(defaults: defaults)
        var cursor = OpenInApp(kind: .custom(label: "Cursor"), command: "cursor")
        manager.openInApps = [OpenInApp(kind: .builtIn(.finder), command: "open"), cursor]
        manager.recordOpenInUse(cursor)

        cursor.kind = .custom(label: "Cursor Nightly")
        manager.openInApps = OpenInApp.upsert(cursor, into: manager.openInApps)

        XCTAssertEqual(manager.primaryOpenInApp, cursor)
        XCTAssertEqual(manager.openInButtonTitle, "Open in Cursor Nightly")
    }

    func test_openInButtonTitle_isTheBareLabelWhenTheListIsEmpty() {
        let manager = SettingsManager(defaults: defaults)
        manager.openInApps = []

        XCTAssertEqual(manager.openInButtonTitle, "Open in")
    }

    // MARK: - Menu Open In apps

    func test_menuOpenInApps_isEmptyWhenTheListIsEmpty() {
        let manager = SettingsManager(defaults: defaults)
        manager.openInApps = []

        XCTAssertTrue(manager.menuOpenInApps.isEmpty)
    }

    func test_menuOpenInApps_isEmptyForASingleApp() {
        let manager = SettingsManager(defaults: defaults)
        manager.openInApps = [OpenInApp(kind: .builtIn(.finder), command: "open")]

        XCTAssertTrue(manager.menuOpenInApps.isEmpty)
    }

    func test_menuOpenInApps_omitsThePrimaryApp() {
        let manager = SettingsManager(defaults: defaults)
        let finder = OpenInApp(kind: .builtIn(.finder), command: "open")
        let zed = OpenInApp(kind: .builtIn(.zed), command: "zed")
        let cursor = OpenInApp(kind: .custom(label: "Cursor"), command: "cursor")
        manager.openInApps = [finder, zed, cursor]

        XCTAssertEqual(manager.menuOpenInApps, [zed, cursor])
    }

    func test_menuOpenInApps_omitsTheRememberedAppAndKeepsListOrder() {
        let manager = SettingsManager(defaults: defaults)
        let finder = OpenInApp(kind: .builtIn(.finder), command: "open")
        let zed = OpenInApp(kind: .builtIn(.zed), command: "zed")
        let cursor = OpenInApp(kind: .custom(label: "Cursor"), command: "cursor")
        manager.openInApps = [finder, zed, cursor]

        manager.recordOpenInUse(zed)

        XCTAssertEqual(manager.menuOpenInApps, [finder, cursor])
    }
}
