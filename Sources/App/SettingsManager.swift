import SwiftUI

enum SettingsKey {
    static let mainTerminalCommand = "wtpad.mainTerminalCommand"
    static let showFocusBorder = "wtpad.showFocusBorder"
}

/// Manages user preferences, persisted via UserDefaults.
@MainActor
class SettingsManager: ObservableObject {
    @Published var mainTerminalCommand: String {
        didSet {
            if mainTerminalCommand.count > 256 {
                mainTerminalCommand = String(mainTerminalCommand.prefix(256))
                return
            }
            if mainTerminalCommand.isEmpty {
                UserDefaults.standard.removeObject(forKey: SettingsKey.mainTerminalCommand)
            } else {
                UserDefaults.standard.set(mainTerminalCommand, forKey: SettingsKey.mainTerminalCommand)
            }
        }
    }

    @Published var showFocusBorder: Bool {
        didSet {
            UserDefaults.standard.set(showFocusBorder, forKey: SettingsKey.showFocusBorder)
        }
    }

    init() {
        self.mainTerminalCommand = UserDefaults.standard.string(forKey: SettingsKey.mainTerminalCommand) ?? ""
        self.showFocusBorder = UserDefaults.standard.object(forKey: SettingsKey.showFocusBorder) as? Bool ?? true
    }
}
