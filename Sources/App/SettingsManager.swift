import AppKit
import SwiftUI

enum SettingsKey {
    static let mainTerminalCommand = "clearway.mainTerminalCommand"
    static let runMainTerminalCommandForMain = "clearway.runMainTerminalCommandForMain"
    static let showFocusBorder = "clearway.showFocusBorder"
    static let promptsDirectory = "clearway.promptsDirectory"
    static let colorScheme = "clearway.colorScheme"
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
    private let defaults: UserDefaults

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

    @Published var runMainTerminalCommandForMain: Bool {
        didSet {
            defaults.set(runMainTerminalCommandForMain, forKey: SettingsKey.runMainTerminalCommandForMain)
        }
    }

    @Published var showFocusBorder: Bool {
        didSet {
            defaults.set(showFocusBorder, forKey: SettingsKey.showFocusBorder)
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

    @Published var colorScheme: ColorSchemePreference {
        didSet {
            defaults.set(colorScheme.rawValue, forKey: SettingsKey.colorScheme)
            NSApp?.appearance = colorScheme.nsAppearance
        }
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.mainTerminalCommand = defaults.string(forKey: SettingsKey.mainTerminalCommand) ?? ""
        self.runMainTerminalCommandForMain = defaults.object(forKey: SettingsKey.runMainTerminalCommandForMain) as? Bool ?? true
        self.showFocusBorder = defaults.object(forKey: SettingsKey.showFocusBorder) as? Bool ?? true
        self.promptsDirectory = defaults.string(forKey: SettingsKey.promptsDirectory) ?? Self.defaultPromptsDirectory
        let stored = defaults.string(forKey: SettingsKey.colorScheme)
        self.colorScheme = stored.flatMap(ColorSchemePreference.init(rawValue:)) ?? .system
        // didSet doesn't fire during init, so mirror the initial value to NSApp here.
        NSApp?.appearance = self.colorScheme.nsAppearance
    }
}
