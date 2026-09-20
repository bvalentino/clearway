import AppKit
import SwiftUI

enum SettingsKey {
    static let mainTerminalCommand = "clearway.mainTerminalCommand"
    static let showFocusBorder = "clearway.showFocusBorder"
    static let promptsDirectory = "clearway.promptsDirectory"
    static let colorScheme = "clearway.colorScheme"
    static let openSecondaryOnStart = "clearway.openSecondaryOnStart"
    static let showDetachedWorktrees = "clearway.showDetachedWorktrees"
    static let openInApps = "clearway.openInApps"
    static let lastUsedOpenInApp = "clearway.lastUsedOpenInApp"
}

enum ColorSchemePreference: String, CaseIterable, Identifiable {
    case system, light, dark

    var id: String { rawValue }

    var swiftUIColorScheme: SwiftUI.ColorScheme? {
        switch self {
        case .system: return nil
        case .light: return .light
        case .dark: return .dark
        }
    }

    var nsAppearance: NSAppearance? {
        switch self {
        case .system: return nil
        case .light: return NSAppearance(named: .aqua)
        case .dark: return NSAppearance(named: .darkAqua)
        }
    }
}

/// Manages user preferences, persisted via UserDefaults.
@MainActor
class SettingsManager: ObservableObject {
    /// Fallback command when `mainTerminalCommand` is unset or whitespace-only.
    nonisolated static let defaultMainTerminalCommand = "claude"

    private let defaults: UserDefaults

    /// `mainTerminalCommand` trimmed, or nil when the user has left it blank.
    /// Used by the launcher to decide whether to show the prompt form (non-nil) or
    /// skip straight to a login shell (nil).
    var configuredMainTerminalCommand: String? {
        let trimmed = mainTerminalCommand.trimmingCharacters(in: .whitespaces)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// `configuredMainTerminalCommand`, or `defaultMainTerminalCommand` when nil.
    /// Prefer `configuredMainTerminalCommand` at call sites that need to detect
    /// the unset case (e.g. the launcher); use this only where a fallback is required.
    var resolvedMainTerminalCommand: String {
        configuredMainTerminalCommand ?? Self.defaultMainTerminalCommand
    }

    @Published var mainTerminalCommand: String {
        didSet {
            if mainTerminalCommand.count > 256 {
                mainTerminalCommand = String(mainTerminalCommand.prefix(256))
                return
            }
            if mainTerminalCommand.isEmpty {
                defaults.removeObject(forKey: SettingsKey.mainTerminalCommand)
            } else {
                defaults.set(mainTerminalCommand, forKey: SettingsKey.mainTerminalCommand)
            }
        }
    }

    @Published var showFocusBorder: Bool {
        didSet {
            defaults.set(showFocusBorder, forKey: SettingsKey.showFocusBorder)
        }
    }

    @Published var openSecondaryOnStart: Bool {
        didSet {
            defaults.set(openSecondaryOnStart, forKey: SettingsKey.openSecondaryOnStart)
        }
    }

    @Published var showDetachedWorktrees: Bool {
        didSet {
            defaults.set(showDetachedWorktrees, forKey: SettingsKey.showDetachedWorktrees)
        }
    }

    static let defaultPromptsDirectory = "~/.clearway/prompts"

    @Published var promptsDirectory: String {
        didSet {
            if promptsDirectory.isEmpty || promptsDirectory == Self.defaultPromptsDirectory {
                defaults.removeObject(forKey: SettingsKey.promptsDirectory)
            } else {
                defaults.set(promptsDirectory, forKey: SettingsKey.promptsDirectory)
            }
        }
    }

    /// The list a fresh install starts with, and what a missing or undecodable stored value falls
    /// back to. An empty list is a legitimate stored value and never reaches this.
    private nonisolated static var seedOpenInApps: [OpenInApp] {
        [OpenInApp(kind: .builtIn(.finder), command: OpenInBuiltIn.finder.defaultCommand)]
    }

    @Published var openInApps: [OpenInApp] {
        didSet {
            persistOpenInApps()
        }
    }

    /// The app the toolbar's Open in button repeats on a click. Resolved against the live list on
    /// every read, so an id naming a deleted app is nothing remembered and needs no cleanup.
    var lastUsedOpenInApp: OpenInApp? { openInApps.first { $0.id == lastUsedOpenInAppId } }

    /// What the toolbar's Open in label half opens. The remembered app when one resolves, the first
    /// app in the list otherwise, so the button is a split button from the first launch and only an
    /// empty list leaves it without an action — and an empty list hides it.
    var primaryOpenInApp: OpenInApp? { lastUsedOpenInApp ?? openInApps.first }

    /// The toolbar's Open in label, which names the app a click will open. An empty list hides the
    /// item, so the bare fallback is never rendered.
    var openInButtonTitle: String {
        primaryOpenInApp.map { "Open in \($0.label)" } ?? "Open in"
    }

    /// The toolbar dropdown's items: everything the label half does not already open. The sidebar's
    /// context submenu has no primary and lists `openInApps` whole.
    var menuOpenInApps: [OpenInApp] {
        let primaryId = primaryOpenInApp?.id
        return openInApps.filter { $0.id != primaryId }
    }

    /// Records the app as the last one opened from the toolbar, the way `recordLastRun` does for
    /// Run, so the view never writes the id itself. Re-opening the app already recorded writes
    /// nothing — that is the label half's every click, and `objectWillChange` on an app-wide
    /// `EnvironmentObject` would re-evaluate every view observing settings for no change.
    func recordOpenInUse(_ app: OpenInApp) {
        guard lastUsedOpenInAppId != app.id else { return }
        lastUsedOpenInAppId = app.id
    }

    @Published var lastUsedOpenInAppId: UUID? {
        didSet {
            if let lastUsedOpenInAppId {
                defaults.set(lastUsedOpenInAppId.uuidString, forKey: SettingsKey.lastUsedOpenInApp)
            } else {
                defaults.removeObject(forKey: SettingsKey.lastUsedOpenInApp)
            }
        }
    }

    @Published var colorScheme: ColorSchemePreference {
        didSet {
            defaults.set(colorScheme.rawValue, forKey: SettingsKey.colorScheme)
            NSApp?.appearance = colorScheme.nsAppearance
        }
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.mainTerminalCommand = defaults.string(forKey: SettingsKey.mainTerminalCommand) ?? ""
        self.showFocusBorder = defaults.object(forKey: SettingsKey.showFocusBorder) as? Bool ?? true
        self.openSecondaryOnStart = defaults.object(forKey: SettingsKey.openSecondaryOnStart) as? Bool ?? false
        self.showDetachedWorktrees = defaults.object(forKey: SettingsKey.showDetachedWorktrees) as? Bool ?? false
        self.promptsDirectory = defaults.string(forKey: SettingsKey.promptsDirectory) ?? Self.defaultPromptsDirectory
        self.lastUsedOpenInAppId = defaults.string(forKey: SettingsKey.lastUsedOpenInApp)
            .flatMap(UUID.init(uuidString:))
        let stored = defaults.string(forKey: SettingsKey.colorScheme)
        self.colorScheme = stored.flatMap(ColorSchemePreference.init(rawValue:)) ?? .system
        let storedData = defaults.data(forKey: SettingsKey.openInApps)
        let decodedApps = storedData.flatMap { try? JSONDecoder().decode([OpenInApp].self, from: $0) }
        self.openInApps = decodedApps ?? Self.seedOpenInApps
        // didSet doesn't fire during init, so mirror the initial values out here.
        NSApp?.appearance = self.colorScheme.nsAppearance
        // Seeded only for a genuinely absent key. A value that failed to decode is left where it
        // is: overwriting it would destroy the user's list for good, where leaving it lets a build
        // that understands the format read it back. Decision 9 asks for the reseed, not the write.
        if storedData == nil {
            persistOpenInApps()
        } else if decodedApps == nil {
            Ghostty.logger.error("SettingsManager: couldn't decode \(SettingsKey.openInApps); showing the seed")
        }
    }

    private func persistOpenInApps() {
        guard let data = try? JSONEncoder().encode(openInApps) else {
            Ghostty.logger.error("SettingsManager: failed to encode openInApps; the edit will not survive relaunch")
            return
        }
        defaults.set(data, forKey: SettingsKey.openInApps)
    }
}
